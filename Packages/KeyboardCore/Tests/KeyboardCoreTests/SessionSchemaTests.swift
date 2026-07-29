import Foundation
import Testing
@testable import KBRuntime
@testable import KBSessions

/// Şema v3 ve v2 migrasyonu — plan v8 §2.2.
///
/// Buradaki testlerin ortak iddiası tek: **bilinmeyen, bilinen gibi
/// kaydedilmez.** v2'nin taşımadığı her olgu `.unknown` çıkmalı; nöbetçi bir
/// değer (`-1`, `""`, `[:]`) çıkarsa tüketici onu yasal veri sanar.
@Suite("Şema v3 — sürüm-önce okuma ve migrasyon")
struct SessionSchemaTests {

    // MARK: - Epistemic

    /// `Optional` ile temsil edilemeyen ayrım: "uygulanmaz" ile "bilinmiyor"
    /// aynı `nil`'e düşerse, v2'nin belirsiz backspace'i "geri açma olmadı"
    /// diye okunur.
    @Test("unknown ile notApplicable codec'ten geçerken karışmıyor")
    func epistemicRoundTrip() throws {
        let cases: [Epistemic<Int>] = [.known(7), .unknown, .notApplicable]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            let back = try JSONDecoder().decode(Epistemic<Int>.self, from: data)
            #expect(back == c)
        }
        #expect(Epistemic<Int>.unknown.isUnknown)
        #expect(!Epistemic<Int>.notApplicable.isUnknown)
        #expect(Epistemic<Int>.known(7).value == 7)
        #expect(Epistemic<Int>.unknown.value == nil)
    }

    // MARK: - Sürüm-önce okuma

    @Test("Şema alanı yoksa tahmin edilmez, reddedilir")
    func missingSchemaRejected() {
        let data = Data(#"{"attemptID":"x"}"#.utf8)
        #expect(SessionReader.read(data) == .failure(.missingSchema))
    }

    @Test("Bilinmeyen ileri sürüm reddedilir")
    func futureSchemaRejected() {
        let data = Data(#"{"schema":4}"#.utf8)
        #expect(SessionReader.read(data) == .failure(.unsupportedSchema(4)))
    }

    /// **Asıl mesele bu.** Blanket `decodeIfPresent` kullansaydık, eksik alanlı
    /// bozuk bir v3 sessizce default'a düşer ve "eski kayıt" gibi işlenirdi.
    @Test("Eksik alanlı v3 sessizce default'a düşmez, hata verir")
    func malformedV3Rejected() throws {
        let good = try SessionCodec.encode(Self.canonicalSample())
        var obj = try #require(
            try JSONSerialization.jsonObject(with: good) as? [String: Any])
        obj.removeValue(forKey: "actions")
        let broken = try JSONSerialization.data(withJSONObject: obj)

        switch SessionReader.read(broken) {
        case let .failure(.malformed(schema, _)): #expect(schema == 3)
        case let other: Issue.record("beklenen malformed, gelen: \(other)")
        }
    }

    @Test("Geçerli v3 kayıp vermeden gidip geliyor")
    func v3RoundTrip() throws {
        let original = Self.canonicalSample()
        let data = try SessionCodec.encode(original)
        let back = try #require(try? SessionReader.read(data).get())
        #expect(back == original)
    }

    // MARK: - v2 → kanonik

    /// v2 hem tap'i hem character-repeat'i `"backspace"` yazıyordu. Birine
    /// karar vermek olguyu uydurmaktır; kip `backspaceUnspecified` kalmalı.
    @Test("v2'nin belirsiz backspace'i kesin bir kipe uydurulmuyor")
    func ambiguousBackspaceStaysUnknown() throws {
        let session = try Self.migratedV2()
        let bs = try #require(session.actions.first { $0.kind.isLegacyOnly })
        #expect(bs.kind == .backspaceUnspecified)
        #expect(bs.event.isUnknown, "hangi backspace olduğu bilinmiyor")
        #expect(bs.effect.isUnknown, "v2 yıkıcı etkiyi hiç kaydetmiyordu")
    }

    /// Nöbetçi avı: v2'de olmayan her olgu `.unknown` mı, yoksa yasal görünen
    /// bir değere mi dönüşmüş?
    @Test("v2'de olmayan olgular nöbetçi değil, .unknown")
    func missingV2FactsAreUnknown() throws {
        let s = try Self.migratedV2()
        #expect(s.sourceSchema == 2, "nereden geldiği korunmalı")
        #expect(s.schema == CanonicalSession.currentSchema)

        #expect(s.promptTokens.isUnknown)
        #expect(s.geometry.layoutFingerprint.isUnknown)
        #expect(s.engine.policy.isUnknown,
                "politika condition'dan TÜRETİLMEMELİ — koşul yalnız niyeti gösterir")
        #expect(s.engine.scoring.isUnknown)
        #expect(s.engine.build.provenance.isUnknown)
        #expect(s.engine.calibration.sigma.isUnknown)
        #expect(s.engine.packs.allSatisfy { $0.topology.isUnknown })
        #expect(s.actions.allSatisfy { $0.document.isUnknown })

        let commit = try #require(s.actions.compactMap(\.commit).first)
        #expect(commit.cursorBefore.isUnknown, "geri açma yapılamaz demek")
    }

    /// `tokenID` action kimliğinden türetiliyor: aynı veriyi iki kez okumak
    /// **aynı** kimlikleri vermeli. Global sayaç olsaydı ikinci okuma kayar,
    /// golden karşılaştırması sahte fark üretirdi.
    @Test("Migrasyon deterministik — iki okuma aynı sonucu veriyor")
    func migrationIsDeterministic() throws {
        let data = try Self.v2Data()
        let a = try #require(try? SessionReader.read(data).get())
        let b = try #require(try? SessionReader.read(data).get())
        #expect(a == b)

        let ids = a.actions.compactMap(\.commit).map(\.tokenID)
        #expect(Set(ids).count == ids.count, "kimlikler tekil olmalı")
    }

    /// Bilinen olgular korunmalı — migrasyon her şeyi `.unknown`'a çevirerek
    /// "güvenli" davranırsa eski kayıtlar tamamen değersizleşir.
    @Test("v2'nin taşıdığı olgular korunuyor")
    func knownV2FactsSurvive() throws {
        let s = try Self.migratedV2()
        #expect(s.attemptID == "v2-örnek")
        #expect(s.promptText == "kalem ev")
        #expect(s.engine.beamWidth == 128)
        #expect(s.engine.build.codeRevision == "abc123")
        #expect(s.touches.count == 1)
        #expect(s.touches[0].outcome == .committed)

        let space = try #require(s.actions.first { $0.kind == .space })
        #expect(space.event.value == .space, "space belirsizlik taşımaz")
        let commit = try #require(space.commit)
        #expect(commit.committed == "kalem")
        #expect(commit.label.source == .protocol, "§12.5 etiketi taşınmalı")
        #expect(commit.label.confidence == .strong)
        #expect(commit.label.matchesTarget == true)
    }

    /// Tanınmayan etiket **eksik olgu değil, bozukluktur**. `.unknown` yazıp
    /// geçmek, bozuk kaydı "eski sürüm" diye sessizce kabul etmek olurdu.
    @Test("v2'de tanınmayan §12.5 etiketi bozukluk sayılıyor")
    func unknownLabelIsCorruption() throws {
        var obj = try #require(try JSONSerialization.jsonObject(
            with: try Self.v2Data()) as? [String: Any])
        var actions = try #require(obj["actions"] as? [[String: Any]])
        var commit = try #require(actions[1]["commit"] as? [String: Any])
        commit["confidence"] = "belki"
        actions[1]["commit"] = commit
        obj["actions"] = actions

        let data = try JSONSerialization.data(withJSONObject: obj)
        switch SessionReader.read(data) {
        case let .failure(.malformed(schema, detail)):
            #expect(schema == 2)
            #expect(detail.contains("belki"))
        case let other: Issue.record("beklenen malformed, gelen: \(other)")
        }
    }

    // MARK: - Kind semantiği

    /// Kip sınıflandırması derleyicide tutulmalı: token kapatan ile beam bozan
    /// kümeler ayrık, `backspaceUnspecified` yalnız migrasyonun ürünü.
    @Test("Kip sınıfları tutarlı")
    func kindClassification() {
        for k in CanonicalSession.Action.Kind.allCases {
            #expect(!(k.closesToken && k.invalidatesBeam),
                    "\(k) hem kapatıyor hem bozuyor — reducer hangisini uygular?")
        }
        #expect(CanonicalSession.Action.Kind.allCases.filter(\.isLegacyOnly)
                == [.backspaceUnspecified])
        #expect(CanonicalSession.Action.Kind.newline.closesToken,
                "A1'in kaynağı: newline bir token sınırıdır")
    }

    // MARK: - Örnekler

    private static func v2Data() throws -> Data {
        var s = TypingSession(
            attemptID: "v2-örnek", participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, promptID: "p1",
            promptText: "kalem ev", promptSource: .builtin, split: "train",
            alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0), posture: .init(),
            engine: .init(
                buildConfiguration: "Release", appVersion: "1.0",
                packs: [.init(name: "tr", sha256: "deadbeef", bytes: 10)],
                beamWidth: 128, oovTheta: 17, suggestionWindow: 3,
                autoCorrectsOutOfVocabulary: true,
                calibration: .init(applied: true, strongSamples: 20,
                                   globalX: 0, globalY: 0, rowX: [], rowY: [],
                                   keyX: [], keyY: [],
                                   biasX: [0.1], biasY: [0.2]),
                learningFrozen: true, codeRevision: "abc123",
                initialLanguage: nil),
            geometry: .init(layoutID: "tr-q", boundsX: 0, boundsY: 0,
                            boundsWidth: 393, boundsHeight: 216,
                            frameInScreenX: 0, frameInScreenY: 600,
                            frameInScreenWidth: 393, frameInScreenHeight: 216,
                            safeAreaBottom: 34, screenScale: 3,
                            interfaceOrientation: "portrait",
                            deviceModel: "test", systemVersion: "18"))
        s.touches = [.init(touchID: 0, phase: "ended", outcome: "committed",
                           rawX: 10, rawY: 20, normX: 0.1, normY: 0.2,
                           decoderX: 0.1, decoderY: 0.2, timestamp: 1,
                           majorRadius: 5, majorRadiusTolerance: 1,
                           plane: "letters", shift: "off",
                           hitKind: "letter", key: "k", keyIndex: 3)]
        s.actions = [
            .init(actionID: 0, t: 0, kind: "letter", touchID: 0,
                  targetWordIndex: 0, targetWord: "kalem",
                  suggestions: nil, commit: nil, textAfter: nil),
            .init(actionID: 1, t: 0.1, kind: "space", touchID: nil,
                  targetWordIndex: 0, targetWord: "kalem", suggestions: nil,
                  commit: .init(kind: "literal", literal: "kalem",
                                displayBefore: "kalem", committed: "kalem",
                                delta: nil, theta: nil, bestCost: nil,
                                bestWord: nil, language: 0, touchCount: 5,
                                casingApplied: false, literalProtected: false,
                                labelSource: "protocol", confidence: "strong",
                                targetWord: "kalem", matchesTarget: true),
                  textAfter: nil),
            .init(actionID: 2, t: 0.2, kind: "backspace", touchID: nil,
                  targetWordIndex: 0, targetWord: nil,
                  suggestions: nil, commit: nil, textAfter: nil),
        ]
        return try SessionCodec.encoder.encode(s)
    }

    private static func migratedV2() throws -> CanonicalSession {
        try SessionReader.read(try v2Data()).get()
    }

    private static func canonicalSample() -> CanonicalSession {
        CanonicalSession(
            attemptID: "v3", participantID: "p", sessionOrdinal: 1,
            condition: .behavior, status: .completed,
            promptID: "p1", promptText: "ev", promptSource: .builtin,
            split: "train", promptTokens: .known(["ev"]),
            alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: .init(
                buildConfiguration: "Release", appVersion: "1.0",
                build: .init(codeRevision: "abc",
                             provenance: .known(.init(
                                dirty: false, sourceDigest: "",
                                swiftVersion: "6.0", targetTriple: "arm64",
                                optimization: "-O"))),
                packs: [.init(name: "tr", sha256: "d", bytes: 1,
                              topology: .known(.init(role: "lexicon",
                                                     language: 0,
                                                     sourceOrder: 0, offset: 0)))],
                policy: .known(.behavior), beamWidth: 128, oovTheta: 17,
                suggestionWindow: 3, autoCorrectsOutOfVocabulary: true,
                scoring: .known(.init(weights: ["spatial": 1],
                                      maxKeyCandidates: 8,
                                      candidateCostWindow: 12,
                                      maxConsecutiveOmissions: 1,
                                      sigmaMin: 0.02,
                                      languagePrior: ["tr": 0])),
                calibration: .init(applied: false, strongSamples: 0,
                                   biasX: [], biasY: [],
                                   sigma: .known(.init(x: [], y: []))),
                initialLanguage: nil),
            geometry: .init(layoutID: "tr-q", layoutFingerprint: .known("f1"),
                            boundsX: 0, boundsY: 0,
                            boundsWidth: 393, boundsHeight: 216,
                            frameInScreenX: 0, frameInScreenY: 600,
                            frameInScreenWidth: 393, frameInScreenHeight: 216,
                            safeAreaBottom: 34, screenScale: 3,
                            interfaceOrientation: "portrait",
                            deviceModel: "test", systemVersion: "18"),
            touches: [],
            actions: [.init(actionID: 0, t: 0, kind: .space, touchID: nil,
                            event: .known(.space),
                            effect: .known(.boundary),
                            document: .known(.init(mutations: [.insert(" ")],
                                                   hashAfter: 42)),
                            targetTokenIndex: 0, targetToken: "ev",
                            candidates: nil, shown: nil,
                            commit: .init(
                                kind: .literal, tokenID: TokenID(raw: 1),
                                literal: "ev", displayBefore: "ev",
                                committed: "ev", delta: nil, theta: nil,
                                bestCost: nil, bestWord: nil, language: 0,
                                touchCount: 2, casingApplied: false,
                                literalProtected: false,
                                label: .init(source: .production,
                                             confidence: .weak,
                                             targetWord: "ev",
                                             matchesTarget: true),
                                cursorBefore: .known(0)))],
            finalText: "ev ")
    }
}
