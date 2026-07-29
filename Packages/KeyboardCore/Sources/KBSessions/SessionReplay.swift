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
public enum SessionReplay {

    /// Şema **ayrı tanımlanmıyor**: `TypingSession` tek kaynak.
    ///
    /// Yazıcı ve okuyucu şemayı ayrı ayrı tarif ederse bir alan eklendiğinde
    /// sessizce ayrışırlar ve golden testi bunu **yakalayamaz** — çünkü
    /// fixture'ı da okuyucu üretiyor. Sözleşmenin "tek sahiplik" kuralının
    /// veri şeması hâli.
    public typealias Session = TypingSession

    // MARK: - Yükleme

    public static func load(directory: String) throws -> [Session] {
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
    public struct Token {
        public var literal: String
        public var committed: String
        public var target: String?
        public var matchesTarget: Bool?
        public var kind: String
        public var delta: Double?
        public var theta: Double?
        public var protected: Bool
        /// Bu token'a ait, decoder'a verilmiş dokunmalar.
        public var touches: [TouchSample]
        public var keyIndices: [Int]
        /// Hizalaması delindi mi (§12.4 sapma bayrağı).
        public var diverged: Bool
        /// Kayıttaki `touchCount` ile türetilen dokunma sayısı uyuşuyor mu.
        ///
        /// Uyuşmuyorsa türetme kaçırmıştır — sessizce yanlış saymaktansa
        /// işaretlenip dışlanır.
        public var touchCountAgrees: Bool
    }

    public static func tokens(of s: Session) -> [Token] {
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
                                 touches: pending.map(\.0), keyIndices: pending.map(\.1),
                                 diverged: a.alignmentDiverged,
                                 touchCountAgrees: c.touchCount == pending.count))
                pending.removeAll()
            case "backspace":
                if !pending.isEmpty { pending.removeLast() }
            case "backspaceWord":
                // Kelime silme TÜM bekleyen dokunmaları düşürür. Tek dokunma
                // düşürmek, kalan dokunmaları bir sonraki token'a taşırdı ve
                // o token'ın hizalaması sessizce bozulurdu.
                pending.removeAll()
            default:
                break
            }
        }
        return out
    }

    // MARK: - Kalibrasyon örnekleri

    /// §12.5: hedefli kayıtta niyet **protokolden** bilinir.
    ///
    /// ## Kapatılan yanlılık — ve nasıl kapatılmadığı
    ///
    /// Üretim öğrenicisi yalnız `committed == literal` token'ları topluyor ve
    /// bunları `.weak` sayıyor. §8.3 bu filtrenin bedelini kaydediyor:
    /// *"parmağı komşu tuşa taşan dokunmalar tam da düzeltmeye yol açanlar,
    /// yani topladıklarımızın dışında"*.
    ///
    /// **İlk uygulama bu yanlılığı kapatmadı, kapattığını iddia etti.** Tuş
    /// indeksi `touch.keyIndex`'ten, yani *fiilen isabet edilen* tuştan
    /// alınıyordu ve `matchesTarget == false` token'lar atılıyordu. Parmak
    /// komşuya taşınca literal değişiyor → token tamamen dışarı. Yani tam da
    /// toplanmak istenen dokunmalar yine dışarıdaydı; toplanan yalnız tuş
    /// sınırı içinde kalan sapmalardı ve bu, tahmini tuş merkezine doğru kırpar.
    ///
    /// Hedefli kaydın üretim verisine **tek üstünlüğü** niyetin bilinmesi.
    /// Doğru kullanım: uzunluk eşitse dokunmayı **hedef karakterin** tuşuna
    /// ata, nereye düşmüş olursa olsun.
    ///
    /// ## Neden yalnız uzunluk eşitken
    ///
    /// Uzunluk farklıysa atlama/fazladan dokunma olmuştur ve pozisyonel eşleme
    /// artık bir kayıt değil, çıkarım olur — §6.2 bunu yasaklıyor. O token
    /// dışlanır ve **dışlanma sayılır**: dışlama oranı, ölçülmek istenen
    /// olgunun kendisiyle korelasyonludur, raporlanmadan bırakılamaz.
    public struct CalibrationExtract {
        public var samples: [CalibrationLearner.Sample] = []
        /// Uzunluk eşitliği bozulduğu için dışlanan token sayısı.
        public var excludedLengthMismatch = 0
        /// Hizalaması delinmiş (sapma bayraklı) token sayısı.
        public var excludedDiverged = 0
        /// Hedeften sapan ama hedef tuşa atanabilen dokunma sayısı — hedefli
        /// kaydın asıl kazancı bu sayıdır.
        public var recoveredDriftedTouches = 0
    }

    public static func calibrationExtract(_ s: Session, layout: KeyLayout)
        -> CalibrationExtract {
        var out = CalibrationExtract()
        // Yalnız kurgulanmış hizalama: `sequential` sırayla varsayıyor, kayıt
        // değil.
        guard s.alignmentSource == .constructed else { return out }

        for tok in tokens(of: s) {
            guard let target = tok.target, !target.isEmpty else { continue }
            if tok.diverged { out.excludedDiverged += 1; continue }

            let targetChars = Array(target)
            guard targetChars.count == tok.touches.count else {
                out.excludedLengthMismatch += 1
                continue
            }
            for (i, t) in tok.touches.enumerated() {
                guard let k = layout.keyIndex(for: targetChars[i]) else {
                    out.excludedLengthMismatch += 1
                    break
                }
                if i < tok.keyIndices.count, tok.keyIndices[i] != k {
                    out.recoveredDriftedTouches += 1
                }
                out.samples.append(.init(point: t.down, keyIndex: k, confidence: .strong))
            }
        }
        return out
    }

    public static func calibrationSamples(_ s: Session, layout: KeyLayout)
        -> [CalibrationLearner.Sample] {
        calibrationExtract(s, layout: layout).samples
    }

    // MARK: - Golden doğrulama

    public struct GoldenResult {
        public var attemptID: String
        public var checked: Int
        public var mismatches: [String]
        public var skipped: String?
    }

    /// Kayıttaki adayları/maliyetleri yeniden üretip karşılaştırır.
    ///
    /// Kayıt **kalibrasyonsuz** modelle alındığı için burada da kalibrasyonsuz
    /// decoder kullanılıyor; aksi hâlde fark kalibrasyondan gelirdi.
    public static func verifyGolden(_ s: Session, decoder: Decoder,
                                    packs: [String: String] = [:],
                                    tolerance: Double = 1e-6) -> GoldenResult {
        guard s.engine.buildConfiguration == "Release" else {
            return GoldenResult(attemptID: s.attemptID, checked: 0, mismatches: [],
                                skipped: "Debug derlemesiyle kaydedilmiş")
        }
        // Paket kimliği eşleşmiyorsa fark **paketten** gelir ve "kod mu, ortam
        // mı" ayrımı yapılamaz (§12.1). Sessizce karşılaştırmak, yorumlanamaz
        // bir "0 uyuşmazlık" ya da yorumlanamaz bir fark üretirdi.
        if !packs.isEmpty {
            for p in s.engine.packs {
                guard let local = packs[p.name] else {
                    return GoldenResult(attemptID: s.attemptID, checked: 0, mismatches: [],
                                        skipped: "paket yerelde yok: \(p.name)")
                }
                if local != p.sha256 {
                    return GoldenResult(attemptID: s.attemptID, checked: 0, mismatches: [],
                                        skipped: "paket farklı: \(p.name)")
                }
            }
        }

        var decoder = decoder
        // Dil durumu kayıttan kurulur: `remember(language:)` her commit'te
        // `previous`'ı değiştiriyor ve SONRAKİ token'ların maliyetini
        // etkiliyor. Kurmadan başlamak ikinci kelimeden itibaren fark üretirdi.
        decoder.languageModel.previous = s.engine.initialLanguage.map { UInt8($0) }
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
                // Token sınırında kayıtlı dil uygulanır — üretimde
                // `remember(language:)` tam burada çalışıyor.
                if let lang = a.commit?.language {
                    decoder.languageModel.previous = UInt8(lang)
                }
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

    public struct Summary {
        public var total = 0
        public var completed = 0
        public var aborted = 0
        public var invalid = 0
        public var debugBuilds = 0
        public var tokens = 0
        public var tokensMatchingTarget = 0
        public var autocorrects = 0
        public var wrongAutocorrects = 0
        public var calibrationSamples = 0
        /// Kalibrasyondan dışlananlar — dışlama oranı raporlanmak zorunda,
        /// çünkü dışlama ölçülmek istenen olguyla korelasyonlu.
        public var excludedLengthMismatch = 0
        public var excludedDiverged = 0
        /// Hedeften sapmış olmasına rağmen hedef tuşa atanabilen dokunma:
        /// hedefli kaydın üretim verisine üstünlüğü tam olarak bu sayı.
        public var recoveredDriftedTouches = 0
        public var keyCoverage: [Int: Int] = [:]
        public var touchesTotal = 0
        public var touchesNeverHit = 0
        public var touchesLeftBounds = 0
        public var touchesCancelled = 0
    }

    public static func summarize(_ sessions: [Session], layout: KeyLayout) -> Summary {
        var s = Summary()
        for x in sessions {
            s.total += 1
            switch x.status {
            case .completed: s.completed += 1
            case .aborted: s.aborted += 1
            case .invalid: s.invalid += 1
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
            let ext = calibrationExtract(x, layout: layout)
            s.calibrationSamples += ext.samples.count
            s.excludedLengthMismatch += ext.excludedLengthMismatch
            s.excludedDiverged += ext.excludedDiverged
            s.recoveredDriftedTouches += ext.recoveredDriftedTouches
            for smp in ext.samples { s.keyCoverage[smp.keyIndex, default: 0] += 1 }
        }
        return s
    }
}
