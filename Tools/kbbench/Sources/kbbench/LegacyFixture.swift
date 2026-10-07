import Foundation
import KBDecoder
import KBGeometry
import KBSessions
import KBSpatial
import KBToolSupport

/// v2 (eski) fixture üretimi
///
/// **v3 fixture'ı burada üretilmiyor.** O, üretim yazıcısından geliyor:
/// `BK_REGENERATE_FIXTURE=1 swift test --filter Fixture`. Buradaki çıktı eski
/// şemayı temsil ediyor ve `LegacyFixtureTests` onu okuyup migrasyon yolunu
/// sınıyor — üretilip kimsenin okumadığı bir dosya, şema kayınca sessizce
/// geçersiz olurdu.
///
/// Fixture SENTETİKTİR — dokunmalar tuş merkezlerine konur, gerçek parmak verisi
/// değildir. Sınadığı şey doğruluk değil, **şema ve replay yolu**.
///
/// Fixture **gerçek `TypingSession` tipiyle ve gerçek encoder'la** üretiliyor.
/// İlk sürüm elle kurulmuş bir `[String: Any]` sözlüğü yazıyordu; şemaya bir
/// alan eklenince fixture sessizce geçersiz oldu ve bunu ancak koşunca gördük.
/// Yazıcının tipini kullanmak, yazıcı-okuyucu ayrışmasını yapısal olarak
/// imkânsız kılıyor.
///
/// Adaylar elle uydurulmuyor, decoder'ın FİİLEN ürettiği değerler yazılıyor;
/// uydurulsaydı golden testi daima kırmızı olur ve hiçbir şey korumazdı.
enum LegacyFixture {

    static func run(_ ctx: BenchContext) -> Int32 {
        let opt = ctx.options
        let layout = ctx.layout
        guard let outDir = opt.legacyFixtureDir else { return 0 }
        let words = ["kalem", "güzel", "çocuk"]
        var session = TypingSession(
            attemptID: "golden-0001", participantID: "golden", sessionOrdinal: 0,
            condition: .calibrationReplay, promptID: "golden",
            promptText: words.joined(separator: " "), promptSource: .builtin,
            split: "dev", alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            posture: .init(hands: .twoThumbs, mobility: .seated),
            engine: .init(buildConfiguration: "Release", appVersion: "fixture",
                          packs: [], beamWidth: opt.beamWidth, oovTheta: 17,
                          suggestionWindow: 3, autoCorrectsOutOfVocabulary: true,
                          calibration: .init(applied: false, strongSamples: 0,
                                             globalX: 0, globalY: 0, rowX: [], rowY: [],
                                             keyX: [], keyY: [], biasX: [], biasY: []),
                          learningFrozen: true, codeRevision: "fixture",
                          initialLanguage: nil),
            geometry: .init(layoutID: layout.id, boundsX: 0, boundsY: 0,
                            boundsWidth: 393, boundsHeight: 216,
                            frameInScreenX: 0, frameInScreenY: 600,
                            frameInScreenWidth: 393, frameInScreenHeight: 216,
                            safeAreaBottom: 34, screenScale: 3,
                            interfaceOrientation: "portrait",
                            deviceModel: "fixture", systemVersion: "0"))

        var tid = 0, aid = 0, clock = 0.0, finalText = ""
        for (wi, word) in words.enumerated() {
            var inc = IncrementalDecoder(decoder: ctx.makeDecoder())
            var touchCount = 0

            for ch in word {
                guard let k = layout.keyIndex(for: ch) else { continue }
                let c = layout.keys[k].center
                inc.append(TouchSample(down: c, timestamp: clock))
                touchCount += 1
                session.touches.append(.init(
                    touchID: tid, phase: "ended", outcome: "committed",
                    rawX: c.x * 393, rawY: c.y * 216, normX: c.x, normY: c.y,
                    decoderX: c.x, decoderY: c.y, timestamp: clock,
                    majorRadius: 10, majorRadiusTolerance: 2,
                    plane: "letters", shift: "off",
                    hitKind: "letter", key: String(ch), keyIndex: k))
                // Adaylar eylem İŞLENDİKTEN sonra (§12.7 sıra kuralı).
                let sugg = inc.results(topK: 5).map {
                    TypingSession.Action.Suggestion(word: $0.word, cost: $0.cost,
                                                    source: Int($0.source),
                                                    language: Int($0.language), shown: true)
                }
                session.actions.append(.init(actionID: aid, t: clock, kind: "letter",
                                             touchID: tid, targetWordIndex: wi,
                                             targetWord: word, suggestions: sugg,
                                             commit: nil, textAfter: finalText))
                tid += 1; aid += 1; clock += 0.15
            }

            finalText += word + " "
            let best = inc.results(topK: 1).first
            session.touches.append(.init(
                touchID: tid, phase: "ended", outcome: "committed",
                rawX: 196.5, rawY: 190, normX: 0.5, normY: 0.88,
                decoderX: nil, decoderY: nil, timestamp: clock,
                majorRadius: 12, majorRadiusTolerance: 2,
                plane: "letters", shift: "off",
                hitKind: "function", key: "space", keyIndex: nil))
            session.actions.append(.init(
                actionID: aid, t: clock, kind: "space", touchID: tid,
                targetWordIndex: wi, targetWord: word, suggestions: nil,
                commit: .init(kind: "literal", literal: word, displayBefore: word,
                              committed: word, delta: nil, theta: nil,
                              bestCost: best?.cost, bestWord: best?.word,
                              language: Int(Language.turkish),
                              touchCount: touchCount, casingApplied: false,
                              literalProtected: true, labelSource: "protocol",
                              confidence: "strong", targetWord: word, matchesTarget: true),
                textAfter: finalText))
            tid += 1; aid += 1; clock += 0.3
        }

        // Kullanıcının "bastım ama olmadı" vakalarının ikisi de şemada temsil edilsin.
        for (outcome, y) in [("neverHit", 0.995), ("leftBounds", 0.97)] {
            session.touches.append(.init(
                touchID: tid, phase: "ended", outcome: outcome,
                rawX: 196.5, rawY: y * 216, normX: 0.5, normY: y,
                decoderX: nil, decoderY: nil, timestamp: clock,
                majorRadius: 11, majorRadiusTolerance: 2,
                plane: "letters", shift: "off", hitKind: nil, key: nil, keyIndex: nil))
            tid += 1; clock += 0.1
        }
        session.finalText = finalText
        session.status = .completed
        session.endedAt = Date(timeIntervalSince1970: clock)

        let dir = URL(fileURLWithPath: BenchContext.resolve(outDir))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Kaydın kendi codec'i (tarih stratejisi, sabit anahtar sırası); fixture
        // yalnız okunur olsun diye girintili.
        let enc = SessionCodec.encoder
        enc.outputFormatting.insert(.prettyPrinted)
        let target = dir.appendingPathComponent("golden-0001.json")
        do { try enc.encode(session).write(to: target) }
        catch { fail("fixture yazılamadı: \(error)") }
        print("golden fixture yazıldı: \(target.path)")
        print("  \(session.touches.count) dokunma · \(session.actions.count) eylem"
              + " · \(words.count) kelime")
        return 0
    }
}
