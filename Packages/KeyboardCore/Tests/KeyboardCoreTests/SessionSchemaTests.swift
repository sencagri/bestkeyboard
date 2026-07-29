import Foundation
import Testing
@testable import KBRuntime
@testable import KBSessions

/// Şema v3 ve v2 migrasyonu — plan v8 §2.2.
///
/// İki iddia birden sınanıyor ve ikisi de gerekli:
///
/// 1. **Bilinmeyen, bilinen gibi kaydedilmiyor.** v2'nin taşımadığı her olgu
///    `.unknown` çıkmalı; nöbetçi bir değer (`-1`, `""`, `[:]`) çıkarsa
///    tüketici onu yasal veri sanar.
/// 2. **Bilinen düşürülmüyor.** Migrasyon her şeyi `.unknown`'a çevirerek
///    "güvenli" davransaydı eski kayıtlar tamamen değersizleşirdi.
///
/// Fixture'ın her yaprağına **ayırt edici** bir değer veriliyor. Boş dize,
/// `nil`, `0` ve `[]` ile kurulmuş bir fixture alan kaybını göremez: düşen alan
/// zaten varsayılanına eşit çıkar.
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

    /// `{"state":"unknown","value":7}` **çelişkili**: bilinmediği söylenen bir
    /// olgunun değeri var. Sessizce atmak, yazan tarafın hatasını okuyan
    /// tarafta görünmez yapardı.
    @Test("Çelişkili Epistemic reddediliyor")
    func epistemicContradictionRejected() {
        for state in ["unknown", "notApplicable"] {
            let data = Data("{\"state\":\"\(state)\",\"value\":7}".utf8)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(Epistemic<Int>.self, from: data)
            }
        }
    }

    // MARK: - Sürüm-önce okuma

    /// Probe matrisi. Dördü de farklı hatalar ve tek `nil`'e indirilirse
    /// bozuk bir kayıt "eski kayıt" diye sınıflanır.
    @Test("Şema alanı: yok / null / yanlış tip / nesne değil")
    func schemaProbeMatrix() {
        #expect(SessionReader.read(Data(#"{"attemptID":"x"}"#.utf8))
                == .failure(.missingSchema))
        #expect(SessionReader.read(Data(#"{"schema":null}"#.utf8))
                == .failure(.nullSchema))
        #expect(SessionReader.read(Data(#"[1,2,3]"#.utf8))
                == .failure(.notAnObject))
        #expect(SessionReader.read(Data("bozuk".utf8)).isUnreadable)

        for bad in [#"{"schema":"3"}"#, #"{"schema":3.5}"#, #"{"schema":true}"#] {
            #expect(SessionReader.read(Data(bad.utf8)).isSchemaNotAnInteger,
                    "tamsayı olmayan şema sessizce yuvarlanmamalı: \(bad)")
        }
    }

    @Test("Bilinmeyen ileri sürüm reddediliyor")
    func futureSchemaRejected() {
        #expect(SessionReader.read(Data(#"{"schema":4}"#.utf8))
                == .failure(.unsupportedSchema(4)))
    }

    /// **Asıl mesele bu.** Blanket `decodeIfPresent` kullansaydık, eksik alanlı
    /// bozuk bir v3 sessizce default'a düşer ve "eski kayıt" gibi işlenirdi.
    @Test("Eksik alanlı v3 sessizce default'a düşmüyor")
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

    /// **Blocker regresyonu.** `SessionCodec.decoder` bir ara kendini
    /// çağırıyordu (sonsuz özyineleme); testler `SessionReader`'ın kendi
    /// decoder'ını kullandığı için bunu hiç görmüyordu. Fabrikanın kendisi
    /// doğrudan sınanmalı.
    @Test("SessionCodec çifti kendi başına çalışıyor")
    func codecPairWorksDirectly() throws {
        let original = Self.canonicalSample()
        let data = try SessionCodec.encoder.encode(original)
        let back = try SessionCodec.decoder.decode(CanonicalSession.self, from: data)
        #expect(back == original)
    }

    /// `schema` `var` olduğu sürece v3 biçimli bir nesne `schema: 2` ile encode
    /// edilebiliyordu; okuyucu onu v2 sanıp migrate etmeye kalkardı.
    @Test("Şema alanı inşa edilebilir değil, daima 3")
    func schemaIsConstant() throws {
        var s = Self.canonicalSample()
        s.sourceSchema = 2                       // bu serbest, gerçek bir olgu
        let obj = try #require(try JSONSerialization.jsonObject(
            with: try SessionCodec.encode(s)) as? [String: Any])
        #expect(obj["schema"] as? Int == 3)
        #expect(obj["sourceSchema"] as? Int == 2)
    }

    // MARK: - v2 → kanonik: bilinmeyenler

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

        let e = try #require(s.engine.value)
        #expect(e.policy.feedbackVisible.isUnknown,
                "görünürlük condition'dan TÜRETİLMEMELİ")
        #expect(e.policy.suggestionsVisible.isUnknown)
        #expect(e.policy.correction.isUnknown)
        #expect(e.scoring.isUnknown)
        #expect(e.build.provenance.isUnknown)
        #expect(e.calibration.sigma.isUnknown)
        #expect(e.packs.allSatisfy { $0.topology.isUnknown })
        #expect(s.actions.allSatisfy { $0.document.isUnknown })

        let commit = try #require(s.actions.compactMap(\.commit).first)
        #expect(commit.tokenID.isUnknown,
                "actionID'den türetmek deterministik olurdu ama olgu yapmazdı")
        #expect(commit.cursorBefore.isUnknown, "geri açma yapılamaz demek")
    }

    /// Yazıcının kendi nöbetçileri de olguya çevrilmemeli.
    @Test("Yazıcı nöbetçileri (unknown revision, hesaplanmayan hash) .unknown")
    func writerSentinelsAreUnknown() throws {
        var v2 = Self.v2Session()
        v2.engine.codeRevision = "unknown"
        v2.engine.packs = [.init(name: "tr-TR.bkt", sha256: "hesaplanmadı",
                                 bytes: 42)]
        let s = try Self.migrate(v2)
        let e = try #require(s.engine.value)
        #expect(e.build.codeRevision.isUnknown)
        #expect(e.packs[0].sha256.isUnknown)
        #expect(e.packs[0].bytes == 42, "bilinen alan yine de korunmalı")
    }

    /// v2 yazıcısı oturum başında paketler yüklenmeden bir yer tutucu yazıyor.
    /// Onu gerçek konfigürasyon diye taşımak, `beamWidth`'i sıfır olan bir
    /// motoru olgu gibi kaydetmek olurdu.
    @Test("Kurulmamış motor yer tutucusu .unknown")
    func placeholderEngineIsUnknown() throws {
        var v2 = Self.v2Session()
        v2.engine = .init(buildConfiguration: "Debug", appVersion: "0.1",
                          packs: [], beamWidth: 0, oovTheta: 0,
                          suggestionWindow: 0, autoCorrectsOutOfVocabulary: false,
                          calibration: .init(applied: false, strongSamples: 0,
                                             globalX: 0, globalY: 0,
                                             rowX: [], rowY: [], keyX: [],
                                             keyY: [], biasX: [], biasY: []),
                          learningFrozen: true, codeRevision: "abc",
                          initialLanguage: nil)
        #expect(try Self.migrate(v2).engine.isUnknown)
    }

    // MARK: - v2 → kanonik: bilinenler

    /// Fixture'ın her yaprağı ayırt edici; düşen bir alan burada görünür.
    @Test("v2'nin taşıdığı olgular korunuyor")
    func knownV2FactsSurvive() throws {
        let s = try Self.migratedV2()

        #expect(s.attemptID == "deneme-7")
        #expect(s.participantID == "katılımcı-3")
        #expect(s.protocolVersion == 1)
        #expect(s.sessionOrdinal == 5)
        #expect(s.condition == .calibrationReplay)
        #expect(s.promptID == "p-9")
        #expect(s.promptText == "kalem ev")
        #expect(s.promptSource == .manual)
        #expect(s.split == "holdout")
        #expect(s.alignmentSource == .sequential)
        #expect(s.posture.hands == .twoThumbs)
        #expect(s.posture.mobility == .walking)
        #expect(s.finalText == "kalem ev ")
        #expect(s.legacy.value?.hadBackspace == true,
                "v2'nin kalibrasyon dışlama olgusu düşürülemez")

        #expect(s.geometry.layoutID == "tr-q-v2")
        #expect(s.geometry.boundsWidth == 393.5)
        #expect(s.geometry.deviceModel == "iPhone17,1")

        let e = try #require(s.engine.value)
        #expect(e.buildConfiguration == "Release")
        #expect(e.appVersion == "0.9.1")
        #expect(e.build.codeRevision.value == "abc123def456")
        #expect(e.beamWidth == 96)
        #expect(e.oovTheta == 17.5)
        #expect(e.suggestionWindow == 3.25)
        #expect(e.autoCorrectsOutOfVocabulary)
        #expect(e.initialLanguage == 1)
        #expect(e.policy.learning.value == .frozen,
                "§12.3 şart koştuğu için v2 bunu GERÇEKTEN biliyordu")
        #expect(e.packs.map(\.name) == ["tr-TR.bkt", "en-US.bkt"])
        #expect(e.packs[1].sha256.value == "beef02")
        #expect(e.calibration.applied)
        #expect(e.calibration.strongSamples == 42)
        #expect(e.calibration.biasX == [0.11, 0.12])
        #expect(e.calibration.hierarchical.globalY == -0.02,
                "hiyerarşik ayrışım v2'de vardı, düşürülemez")
        #expect(e.calibration.hierarchical.keyX == [0.001, 0.002])

        #expect(s.touches.count == 2)
        #expect(s.touches[0].outcome == .committed)
        #expect(s.touches[0].keyIndex == 3)
        #expect(s.touches[1].outcome == .neverHit,
                "neverHit ile leftBounds ayrımı korunmalı")
        #expect(s.touches[1].majorRadiusTolerance == 1.5)

        let space = try #require(s.actions.first { $0.kind == .space })
        #expect(space.event.value == .space, "space belirsizlik taşımaz")
        #expect(space.targetTokenIndex == 0)
        #expect(space.targetToken == "kalem")
        #expect(space.legacy.value?.alignmentDiverged == true,
                "§12.4 sapma bayrağı düşürülemez")
        #expect(space.legacy.value?.textAfter == "kalem ",
                "v2'de doğrulanabilirliğin tek kaynağı bu metin")

        let commit = try #require(space.commit)
        #expect(commit.kind == .autocorrect)
        #expect(commit.literal == "kslem")
        #expect(commit.displayBefore == "kslem")
        #expect(commit.committed == "kalem")
        #expect(commit.delta == 4.5)
        #expect(commit.theta == 2.25)
        #expect(commit.bestCost == 11.75)
        #expect(commit.bestWord == "kalem")
        #expect(commit.language == 0)
        #expect(commit.touchCount == 5)
        #expect(commit.casingApplied == false)
        #expect(commit.literalProtected == false)
        #expect(commit.label.source == .protocol)
        #expect(commit.label.confidence == .strong)
        #expect(commit.label.targetWord == "kalem")
        #expect(commit.label.matchesTarget == false)
    }

    /// v2 `suggestions` iki ayrı olgu taşıyordu: ham aday listesi ve
    /// kullanıcının **fiilen gördüğü** yüzeyler. İkisi de düşürülemez.
    @Test("v2 önerileri aday + gösterilen olarak korunuyor")
    func suggestionsSurvive() throws {
        let s = try Self.migratedV2()
        let space = try #require(s.actions.first { $0.kind == .space })

        let cands = try #require(space.candidates.value)
        #expect(cands.map(\.word) == ["kalem", "kalen"])
        #expect(cands[0].cost == 11.75)
        #expect(cands[1].source == 1)
        #expect(cands[1].language == 1)
        #expect(cands[0].id.isUnknown, "v2 aday kimliği taşımıyordu")
        #expect(cands[0].emitCount.isUnknown)

        let shown = try #require(space.shown.value)
        #expect(shown.map(\.surface) == ["kalem"],
                "yalnız shown bayrağı olanlar gösterilmişti")
        #expect(shown[0].origin.isUnknown, "köken üyelikten çıkarılamaz")
    }

    /// `nil` = anlık görüntü **alınmadı**; `[]` = alındı ve boştu. İkisini tek
    /// değere indirmek "öneri yoktu" ile "bakılmadı"yı karıştırırdı.
    @Test("Alınmayan aday görüntüsü ile boş görüntü ayrı")
    func candidateSnapshotAbsenceIsDistinct() throws {
        let s = try Self.migratedV2()
        let letter = try #require(s.actions.first { $0.kind == .letter })
        #expect(letter.candidates == .notApplicable)
        #expect(letter.shown == .notApplicable)

        var v2 = Self.v2Session()
        v2.actions = [.init(actionID: 0, t: 0, kind: "space", touchID: nil,
                            targetWordIndex: nil, targetWord: nil,
                            suggestions: [], commit: nil, textAfter: nil)]
        let empty = try Self.migrate(v2)
        #expect(empty.actions[0].candidates == .known([]))
    }

    /// Hedef düzlem kind string'inde **açıkça kayıtlı**; üçünü tek `.planeChange`
    /// değerine çökertmek kayıtta duran bir olguyu atmak olurdu.
    @Test("Düzlem değişiminin hedefi korunuyor, shift ise bilinmiyor")
    func planeAndShiftEvents() throws {
        var v2 = Self.v2Session()
        v2.actions = ["plane.numbers", "plane.symbols", "plane.letters", "shift"]
            .enumerated().map { i, k in
                .init(actionID: i, t: Double(i), kind: k, touchID: nil,
                      targetWordIndex: nil, targetWord: nil,
                      suggestions: nil, commit: nil, textAfter: nil)
            }
        let s = try Self.migrate(v2)
        #expect(s.actions[0].event.value == .planeChange("numbers"))
        #expect(s.actions[1].event.value == .planeChange("symbols"))
        #expect(s.actions[2].event.value == .planeChange("letters"))
        #expect(s.actions[3].kind == .shift)
        #expect(s.actions[3].event.isUnknown,
                "shift bir olay; ama v2 SONUÇ durumunu kaydetmiyordu")
    }

    /// Eskiden `.interrupted` yapılıyordu; bu bir yargıydı ve `endedAt == nil`
    /// olan terminal bir durum üretiyordu.
    @Test("Yarım kalmış kayıt kesintiye çevrilmiyor")
    func inProgressStaysRecording() throws {
        var v2 = Self.v2Session()
        v2.status = .inProgress
        v2.endedAt = nil          // yarım kalmış kaydın gerçek hâli
        let s = try Self.migrate(v2)
        #expect(s.status == .recording)
        // Terminal duruma çevirmek `endedAt == nil` olan bir "kesinti"
        // üretiyordu; tutarsızlığı yaratan tam olarak o yargıydı.
        #expect(s.endedAt == nil)
    }

    /// `tokenID` artık türetilmiyor, ama migrasyon yine de deterministik olmalı:
    /// aynı veriyi iki kez okumak aynı sonucu vermeli, yoksa golden sahte fark
    /// üretir.
    @Test("Migrasyon deterministik")
    func migrationIsDeterministic() throws {
        let data = try Self.v2Data()
        let a = try #require(try? SessionReader.read(data).get())
        let b = try #require(try? SessionReader.read(data).get())
        #expect(a == b)
    }

    // MARK: - Bozuk kapalı kümeler

    /// Kapalı bir değer kümesinde tanınmayan değer eksik olgu **değil**,
    /// bozukluktur. Yasal bir değere düşürmek onu sessizce yutmak olurdu.
    @Test("Tanınmayan kapalı-küme değerleri bozukluk sayılıyor",
          arguments: [("actions", "kind", "zıpla"),
                      ("touches", "phase", "havada"),
                      ("touches", "outcome", "belki")])
    func unknownClosedSetValues(container: String, key: String, bad: String) throws {
        var obj = try #require(try JSONSerialization.jsonObject(
            with: try Self.v2Data()) as? [String: Any])
        var items = try #require(obj[container] as? [[String: Any]])
        items[0][key] = bad
        obj[container] = items

        let data = try JSONSerialization.data(withJSONObject: obj)
        switch SessionReader.read(data) {
        case let .failure(.malformed(schema, detail)):
            #expect(schema == 2)
            #expect(detail.contains(bad))
        case let other: Issue.record("beklenen malformed, gelen: \(other)")
        }
    }

    @Test("Tanınmayan commit alanları bozukluk sayılıyor",
          arguments: ["kind", "confidence", "labelSource"])
    func unknownCommitValues(key: String) throws {
        var obj = try #require(try JSONSerialization.jsonObject(
            with: try Self.v2Data()) as? [String: Any])
        var actions = try #require(obj["actions"] as? [[String: Any]])
        let i = try #require(actions.firstIndex { $0["commit"] != nil })
        var commit = try #require(actions[i]["commit"] as? [String: Any])
        commit[key] = "zıpla"
        actions[i]["commit"] = commit
        obj["actions"] = actions

        let data = try JSONSerialization.data(withJSONObject: obj)
        switch SessionReader.read(data) {
        case let .failure(.malformed(schema, detail)):
            #expect(schema == 2)
            #expect(detail.contains("zıpla"))
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

    /// Her yaprağa **ayırt edici** değer. Varsayılanla kurulmuş bir fixture,
    /// düşen alanı varsayılanına eşit gördüğü için kaybı gizler.
    private static func v2Session() -> TypingSession {
        var s = TypingSession(
            attemptID: "deneme-7", participantID: "katılımcı-3",
            sessionOrdinal: 5, condition: .calibrationReplay,
            promptID: "p-9", promptText: "kalem ev", promptSource: .manual,
            split: "holdout", alignmentSource: .sequential,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            posture: .init(hands: .twoThumbs, mobility: .walking),
            engine: .init(
                buildConfiguration: "Release", appVersion: "0.9.1",
                packs: [.init(name: "tr-TR.bkt", sha256: "beef01", bytes: 1024),
                        .init(name: "en-US.bkt", sha256: "beef02", bytes: 2048)],
                beamWidth: 96, oovTheta: 17.5, suggestionWindow: 3.25,
                autoCorrectsOutOfVocabulary: true,
                calibration: .init(applied: true, strongSamples: 42,
                                   globalX: 0.01, globalY: -0.02,
                                   rowX: [0.1, 0.2], rowY: [0.3, 0.4],
                                   keyX: [0.001, 0.002], keyY: [0.003, 0.004],
                                   biasX: [0.11, 0.12], biasY: [0.13, 0.14]),
                learningFrozen: true, codeRevision: "abc123def456",
                initialLanguage: 1),
            geometry: .init(layoutID: "tr-q-v2", boundsX: 1, boundsY: 2,
                            boundsWidth: 393.5, boundsHeight: 216.5,
                            frameInScreenX: 3, frameInScreenY: 600.5,
                            frameInScreenWidth: 393.5, frameInScreenHeight: 216.5,
                            safeAreaBottom: 34.5, screenScale: 3,
                            interfaceOrientation: "portrait",
                            deviceModel: "iPhone17,1", systemVersion: "26.1"))
        s.endedAt = Date(timeIntervalSince1970: 1_700_000_060)
        s.finalText = "kalem ev "
        s.hadBackspace = true
        s.touches = [
            .init(touchID: 0, phase: "ended", outcome: "committed",
                  rawX: 10.5, rawY: 20.5, normX: 0.11, normY: 0.22,
                  decoderX: 0.12, decoderY: 0.23, timestamp: 1.5,
                  majorRadius: 5.5, majorRadiusTolerance: 1.25,
                  plane: "letters", shift: "off",
                  hitKind: "letter", key: "k", keyIndex: 3),
            // Kullanıcının "boşluk bazen çalışmıyor" gözleminin iki
            // sebebinden biri: `touchesBegan` hiçbir tuşa denk gelmedi.
            .init(touchID: 1, phase: "began", outcome: "neverHit",
                  rawX: 99.5, rawY: 5.5, normX: nil, normY: nil,
                  decoderX: nil, decoderY: nil, timestamp: 2.5,
                  majorRadius: 6.5, majorRadiusTolerance: 1.5,
                  plane: "letters", shift: "locked",
                  hitKind: nil, key: nil, keyIndex: nil),
        ]
        s.actions = [
            .init(actionID: 0, t: 0.5, kind: "letter", touchID: 0,
                  targetWordIndex: 0, targetWord: "kalem",
                  suggestions: nil, commit: nil, textAfter: "k"),
            .init(actionID: 1, t: 1.5, kind: "space", touchID: nil,
                  targetWordIndex: 0, targetWord: "kalem",
                  suggestions: [
                    .init(word: "kalem", cost: 11.75, source: 0,
                          language: 0, shown: true),
                    .init(word: "kalen", cost: 13.25, source: 1,
                          language: 1, shown: false),
                  ],
                  commit: .init(kind: "autocorrect", literal: "kslem",
                                displayBefore: "kslem", committed: "kalem",
                                delta: 4.5, theta: 2.25, bestCost: 11.75,
                                bestWord: "kalem", language: 0, touchCount: 5,
                                casingApplied: false, literalProtected: false,
                                labelSource: "protocol", confidence: "strong",
                                targetWord: "kalem", matchesTarget: false),
                  textAfter: "kalem ", alignmentDiverged: true),
            .init(actionID: 2, t: 2.5, kind: "backspace", touchID: nil,
                  targetWordIndex: 1, targetWord: "ev",
                  suggestions: nil, commit: nil, textAfter: "kalem"),
        ]
        return s
    }

    private static func v2Data() throws -> Data {
        try SessionCodec.encoder.encode(v2Session())
    }

    private static func migrate(_ s: TypingSession) throws -> CanonicalSession {
        try SessionReader.read(try SessionCodec.encoder.encode(s)).get()
    }

    private static func migratedV2() throws -> CanonicalSession {
        try migrate(v2Session())
    }

    private static func canonicalSample() -> CanonicalSession {
        CanonicalSession(
            attemptID: "v3", participantID: "p", sessionOrdinal: 1,
            condition: .behavior, status: .completed,
            promptID: "p1", promptText: "ev", promptSource: .builtin,
            split: "train", promptTokens: .known(["ev"]),
            alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: .known(.init(
                buildConfiguration: "Release", appVersion: "1.0",
                build: .init(codeRevision: .known("abc"),
                             provenance: .known(.init(
                                sourceTree: .dirty(digest: "d1"),
                                swiftVersion: "6.0",
                                targetTriple: "ios17.0", arch: "arm64",
                                optimization: "-O", xcodeVersion: "2660"))),
                packs: [.init(name: "tr", sha256: .known("d"), bytes: 1,
                              topology: .known(.init(role: "lexicon",
                                                     language: 0,
                                                     sourceOrder: 0, offset: 0)))],
                policy: .init(.behavior), beamWidth: 128, oovTheta: 17,
                suggestionWindow: 3, autoCorrectsOutOfVocabulary: true,
                scoring: .known(.init(decoderWeights: ["wLex": 1],
                                      literalChannelWeights: ["wLex": 1],
                                      cUnk: 6.5, sigmaMin: 0.02,
                                      languagePrior: ["0": 0],
                                      languagePrevious: nil)),
                calibration: .init(applied: false, strongSamples: 0,
                                   biasX: [], biasY: [],
                                   hierarchical: .init(globalX: 0, globalY: 0,
                                                       rowX: [], rowY: [],
                                                       keyX: [], keyY: []),
                                   sigma: .known(.init(x: [], y: []))),
                initialLanguage: nil)),
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
                            candidates: .known([]), shown: .known([]),
                            commit: .init(
                                kind: .literal, tokenID: .known(TokenID(raw: 1)),
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

private extension Result where Failure == SessionReader.ReadError {
    var isUnreadable: Bool {
        if case .failure(.unreadable) = self { return true }
        return false
    }
    var isSchemaNotAnInteger: Bool {
        if case .failure(.schemaNotAnInteger) = self { return true }
        return false
    }
}
