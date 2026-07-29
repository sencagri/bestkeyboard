import Foundation
import KBGeometry
import KBSpatial
import KBDecoder
import KBLearning

/// Cihazdan gelen yazım kayıtlarını okur ve **yeniden oynatır** — sözleşme §12.
///
/// ## Neden yazıcıyla birlikte gitmeli
///
/// Kayıt formatı tek başına write-only olsaydı, şema hataları ancak pahalı
/// cihaz verisi toplandıktan **sonra** bulunurdu. Cihaz verisi tekrar
/// toplanamaz; bu yüzden okuyucu aynı işin parçası.
///
/// ## Ne yapar
///
/// 1. **Golden doğrulama.** Kayıttaki adaylar ve maliyetler, aynı dokunmalarla
///    yeniden decode edildiğinde birebir çıkmalı. Çıkmıyorsa fark ya kodda ya
///    kayıtta; ikisi de bilinmeye değer. §12.1: bu doğrulama olmadan replay
///    farkının *"değişiklik mi, ortam mı"* olduğu ayırt edilemez.
/// 2. **Üç kollu ölçüm.** Kayıt kalibrasyonsuz modelle alındığı için tek
///    kayıttan §8.6'nın üç kolu da (kalsız / global / hiyerarşik) offline
///    ölçülebilir — kayıt hiçbirine taraf değil.
enum SessionReplay {

    // MARK: - Şema (cihazdakiyle aynı alanlar, yalnız okunan kısmı)

    struct Session: Decodable {
        var schema: Int
        var attemptID: String
        var participantID: String
        var sessionOrdinal: Int
        var condition: String
        var status: String
        var promptID: String
        var promptText: String
        var split: String
        var alignmentSource: String
        var engine: Engine
        var geometry: Geometry
        var touches: [Touch]
        var actions: [Action]
        var finalText: String
        var hadBackspace: Bool

        struct Engine: Decodable {
            var buildConfiguration: String
            var packs: [Pack]
            var beamWidth: Int
            var oovTheta: Double
            var learningFrozen: Bool
            struct Pack: Decodable { var name: String; var sha256: String; var bytes: Int }
        }
        struct Geometry: Decodable {
            var layoutID: String
            var boundsWidth: Double
            var boundsHeight: Double
        }
        struct Touch: Decodable {
            var touchID: Int
            var phase: String
            var outcome: String
            var rawX: Double, rawY: Double
            var normX: Double?, normY: Double?
            var decoderX: Double?, decoderY: Double?
            var timestamp: TimeInterval
            var hitKind: String?
            var key: String?
            var keyIndex: Int?
        }
        struct Action: Decodable {
            var actionID: Int
            var kind: String
            var touchID: Int?
            var targetWordIndex: Int?
            var targetWord: String?
            var suggestions: [Suggestion]?
            var commit: Commit?
            struct Suggestion: Decodable {
                var word: String; var cost: Double; var shown: Bool
            }
            struct Commit: Decodable {
                var kind: String
                var literal: String
                var committed: String
                var delta: Double?
                var theta: Double?
                var literalProtected: Bool
                var labelSource: String
                var targetWord: String?
                var matchesTarget: Bool?
            }
        }
    }

    // MARK: - Yükleme

    static func load(directory: String) throws -> [Session] {
        let url = URL(fileURLWithPath: directory)
        let files = (try? FileManager.default.contentsOfDirectory(at: url,
                                                                  includingPropertiesForKeys: nil))
            ?? []
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var out: [Session] = []
        for f in files where f.pathExtension == "json" {
            let data = try Data(contentsOf: f)
            do { out.append(try d.decode(Session.self, from: data)) }
            catch {
                FileHandle.standardError.write(Data(
                    "uyarı: \(f.lastPathComponent) okunamadı: \(error)\n".utf8))
            }
        }
        return out.sorted { $0.attemptID < $1.attemptID }
    }

    // MARK: - Token çıkarımı

    /// Bir denemenin token'ları — **eylem günlüğünden türetilir**.
    ///
    /// Cihazda token listesi tutulmuyor (§12.6): boşluğu silmek önceki kelimeyi
    /// dokunmalarıyla geri açabildiği için cihazdaki bir liste yanlış sayım
    /// üretirdi. Türetme burada, tam günlük elde varken yapılıyor.
    struct Token {
        var literal: String
        var committed: String
        var target: String?
        var matchesTarget: Bool?
        var kind: String
        var delta: Double?
        var theta: Double?
        var protected: Bool
        /// Bu token'a ait, decoder'a verilmiş dokunmalar.
        var touches: [TouchSample]
        var keyIndices: [Int]
    }

    static func tokens(of s: Session) -> [Token] {
        // Yalnız `committed` sonuçlu harf dokunmaları decoder'a girmiştir.
        var pending: [(TouchSample, Int)] = []
        var out: [Token] = []
        var touchByID: [Int: Session.Touch] = [:]
        for t in s.touches where t.phase == "ended" && t.outcome == "committed" {
            touchByID[t.touchID] = t
        }

        for a in s.actions {
            switch a.kind {
            case "letter":
                guard let id = a.touchID, let t = touchByID[id],
                      let x = t.decoderX, let y = t.decoderY, let k = t.keyIndex
                else { continue }
                pending.append((TouchSample(down: Point(x: x, y: y), timestamp: t.timestamp), k))
            case "space", "symbol", "suggestionPick":
                guard let c = a.commit, c.kind != "empty" else { pending.removeAll(); continue }
                out.append(Token(literal: c.literal, committed: c.committed,
                                 target: c.targetWord, matchesTarget: c.matchesTarget,
                                 kind: c.kind, delta: c.delta, theta: c.theta,
                                 protected: c.literalProtected,
                                 touches: pending.map(\.0), keyIndices: pending.map(\.1)))
                pending.removeAll()
            case "backspace", "backspaceRepeat":
                if !pending.isEmpty { pending.removeLast() }
            default:
                break
            }
        }
        return out
    }

    // MARK: - Kalibrasyon örnekleri

    /// §12.5: hedefli kayıtta niyet **protokolden** bilinir.
    ///
    /// Üretim öğrenicisi yalnız `committed == literal` olan token'ları topluyor
    /// ve bunları `.weak` sayıyor; bu filtrenin sıfıra-zayıflatma yanlılığı
    /// §8.3'te kayıtlı — *"parmağı komşu tuşa taşan dokunmalar tam da
    /// düzeltmeye yol açanlar, yani toplananların dışında"*.
    ///
    /// Hedefli kayıtta bu yanlılık **yok**: `literal == hedef` ise dokunmalar,
    /// nereye düşmüş olurlarsa olsunlar, hedef tuşun kanıtıdır.
    static func calibrationSamples(_ s: Session, layout: KeyLayout)
        -> [CalibrationLearner.Sample] {
        guard s.alignmentSource == "constructed" else { return [] }
        var out: [CalibrationLearner.Sample] = []
        for tok in tokens(of: s) {
            guard tok.matchesTarget == true else { continue }
            for (t, k) in zip(tok.touches, tok.keyIndices) {
                out.append(.init(point: t.down, keyIndex: k, confidence: .strong))
            }
        }
        return out
    }

    // MARK: - Golden doğrulama

    struct GoldenResult {
        var attemptID: String
        var checked: Int
        var mismatches: [String]
        var skipped: String?
    }

    /// Kayıttaki adayları/maliyetleri yeniden üretip karşılaştırır.
    ///
    /// Kayıt **kalibrasyonsuz** modelle alındığı için burada da kalibrasyonsuz
    /// decoder kullanılıyor; aksi hâlde fark kalibrasyondan gelirdi.
    static func verifyGolden(_ s: Session, decoder: Decoder,
                             tolerance: Double = 1e-6) -> GoldenResult {
        guard s.engine.buildConfiguration == "Release" else {
            return GoldenResult(attemptID: s.attemptID, checked: 0, mismatches: [],
                                skipped: "Debug derlemesiyle kaydedilmiş")
        }
        var inc = IncrementalDecoder(decoder: decoder)
        var checked = 0
        var mismatches: [String] = []
        var touchByID: [Int: Session.Touch] = [:]
        for t in s.touches where t.phase == "ended" && t.outcome == "committed" {
            touchByID[t.touchID] = t
        }

        for a in s.actions {
            switch a.kind {
            case "letter":
                guard let id = a.touchID, let t = touchByID[id],
                      let x = t.decoderX, let y = t.decoderY else { continue }
                inc.append(TouchSample(down: Point(x: x, y: y), timestamp: t.timestamp))
                guard let recorded = a.suggestions?.filter({ !$0.word.isEmpty }),
                      !recorded.isEmpty else { continue }
                let live = inc.results(topK: 5)
                checked += 1
                // Yalnız ilk aday karşılaştırılıyor: kayıttaki liste öneri
                // penceresi ve genişletmelerle karışabiliyor, ama top-1 saf
                // decoder çıktısıdır.
                if let r = recorded.first, let l = live.first {
                    if r.word != l.word {
                        mismatches.append("aksiyon \(a.actionID): '\(r.word)' → '\(l.word)'")
                    } else if abs(r.cost - l.cost) > tolerance {
                        mismatches.append(String(format: "aksiyon %d: '%@' maliyet %.6f → %.6f",
                                                 a.actionID, r.word, r.cost, l.cost))
                    }
                }
            case "space", "symbol", "suggestionPick":
                inc = IncrementalDecoder(decoder: decoder)
            case "backspace", "backspaceRepeat":
                // Geri silme artımlı durumu bozuyor; bu noktadan sonra
                // karşılaştırma anlamsız — deneme atlanır.
                return GoldenResult(attemptID: s.attemptID, checked: checked,
                                    mismatches: mismatches,
                                    skipped: "geri silme içeriyor, kısmi doğrulandı")
            default: break
            }
        }
        return GoldenResult(attemptID: s.attemptID, checked: checked,
                            mismatches: mismatches, skipped: nil)
    }

    // MARK: - Özet

    struct Summary {
        var total = 0
        var completed = 0
        var aborted = 0
        var invalid = 0
        var debugBuilds = 0
        var tokens = 0
        var tokensMatchingTarget = 0
        var autocorrects = 0
        var wrongAutocorrects = 0
        var calibrationSamples = 0
        var keyCoverage: [Int: Int] = [:]
        var touchesTotal = 0
        var touchesNeverHit = 0
        var touchesLeftBounds = 0
        var touchesCancelled = 0
    }

    static func summarize(_ sessions: [Session], layout: KeyLayout) -> Summary {
        var s = Summary()
        for x in sessions {
            s.total += 1
            switch x.status {
            case "completed": s.completed += 1
            case "aborted": s.aborted += 1
            case "invalid": s.invalid += 1
            default: break
            }
            if x.engine.buildConfiguration != "Release" { s.debugBuilds += 1 }

            for t in x.touches where t.phase == "ended" || t.phase == "cancelled" {
                s.touchesTotal += 1
                switch t.outcome {
                case "neverHit": s.touchesNeverHit += 1
                case "leftBounds": s.touchesLeftBounds += 1
                case "cancelled": s.touchesCancelled += 1
                default: break
                }
            }

            for tok in tokens(of: x) {
                s.tokens += 1
                if tok.matchesTarget == true { s.tokensMatchingTarget += 1 }
                if tok.kind == "autocorrect" {
                    s.autocorrects += 1
                    // Hedef biliniyorsa yanlış düzeltme ölçülebilir: literal
                    // hedefe eşitken düzeltme uygulandıysa klavye doğruyu bozdu.
                    if tok.matchesTarget == true, tok.committed != tok.target {
                        s.wrongAutocorrects += 1
                    }
                }
            }
            let samples = calibrationSamples(x, layout: layout)
            s.calibrationSamples += samples.count
            for smp in samples { s.keyCoverage[smp.keyIndex, default: 0] += 1 }
        }
        return s
    }
}
