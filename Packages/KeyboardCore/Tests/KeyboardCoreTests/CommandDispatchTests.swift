import Foundation
import Testing
@testable import KBAssembly
@testable import KBGeometry
@testable import KBLearning
@testable import KBRuntime
@testable import KBSessions
import KBSpatial

/// `InputCoordinator.perform(_:)` — komutu motora çeviren **tek** dağıtım.
///
/// Aynı `switch` üç kopyadaydı (kaydedici, golden, uzantının yedek yolu) ve
/// kopyalar ayrışmıştı. Buradaki testler ayrışmanın ürettiği somut hataları
/// sabitliyor.
@MainActor
@Suite("Komut dağıtımı")
struct CommandDispatchTests {

    private typealias Support = RecordingTestSupport
    private var layout: KeyLayout { Support.layout }

    private func sample(_ ch: Character) -> TouchSample {
        TouchSample(down: layout.keys[layout.keyIndex(for: ch)!].center)
    }

    // MARK: - Doğrulama mutasyondan önce

    /// `Character(baseKey)` çok grapheme'li dizide **çöküyordu**; şemanın kendi
    /// doğrulayıcısı (`baseCharacter`) hiç kullanılmıyordu.
    @Test("Çok grapheme'li baseKey hata fırlatıyor, hiçbir şey yazılmıyor")
    func malformedBaseKeyThrowsWithoutMutation() {
        var c = InputCoordinator(layout: layout)
        let doc = Support.Doc()
        #expect(throws: InputCoordinator.CommandError.baseKeyNotSingleGrapheme("ab")) {
            try c.perform(.letter(baseKey: "ab", display: "ab", shifted: false),
                          touch: sample("a"), into: doc)
        }
        #expect(throws: InputCoordinator.CommandError.baseKeyNotSingleGrapheme("")) {
            try c.perform(.letter(baseKey: "", display: "", shifted: false),
                          touch: sample("a"), into: doc)
        }
        #expect(doc.text.isEmpty)
        #expect(!c.session.isComposing)
    }

    @Test("Dokunmasız harf ve boş metin reddediliyor")
    func missingPayloadThrows() {
        var c = InputCoordinator(layout: layout)
        let doc = Support.Doc()
        #expect(throws: InputCoordinator.CommandError.letterWithoutTouch) {
            try c.perform(.letter(baseKey: "a", display: "a", shifted: false),
                          touch: nil, into: doc)
        }
        #expect(throws: InputCoordinator.CommandError.emptyText) {
            try c.perform(.text(""), touch: nil, into: doc)
        }
        #expect(doc.text.isEmpty)
    }

    /// Kaydedici bozuk komutu reddediyor ve **kimlik tüketmiyor**: eskiden
    /// `actionID` komut doğrulanmadan artırılıyordu ve reddedilen komut kayıtta
    /// bir delik bırakıyordu.
    @Test("Kaydedici bozuk baseKey'i reddediyor, kayıt bütün kalıyor")
    func recorderRejectsMalformedBaseKey() throws {
        let writer = InMemoryJournalWriter()
        let engine = RecordingEngine(writer: writer,
                                     coordinator: InputCoordinator(layout: layout),
                                     layout: layout)
        try engine.begin(Support.descriptor(prompt: ["ev"]), at: 0)
        try Support.configure(engine)
        let doc = Support.Doc()
        try engine.record(Support.touch(0, char: "e", t: 0.1))
        #expect(throws: RecordingEngine.IngressError.self) {
            try engine.perform(.init(command: .letter(baseKey: "👨‍👩‍👧x",
                                                      display: "x", shifted: false),
                                     touchID: 0, timestamp: 0.1), into: doc)
        }
        #expect(doc.text.isEmpty)
        // Dokunma tüketilmedi: geçerli komut aynı dokunmaya bağlanabiliyor ve
        // ilk eylemin kimliği 0.
        let a = try engine.perform(.init(command: .letter(baseKey: "e", display: "e",
                                                          shifted: false),
                                         touchID: 0, timestamp: 0.1), into: doc)
        #expect(a.actionID == 0)
        #expect(doc.text == "e")
    }

    // MARK: - Genişletme

    /// Golden genişletme seçimini `.suggestion` diye oynatıyordu: komutun
    /// `origin`'i atlanıyordu ve kayıttaki `.expansion` ile her seferinde sahte
    /// fark çıkıyordu.
    @Test("Genişletme seçimi golden'da genişletme olarak oynatılıyor")
    func expansionPickReplaysAsExpansion() throws {
        let data = try Support.record(prompt: ["selam"]) { s in
            try s.type("slm")
            let pick = try #require(
                s.engine.visibleSuggestions().first { $0.origin.isExpansion },
                "slm için genişletme önerisi bekleniyordu")
            #expect(pick.surface == "selam")
            try s.command(.suggestionPick(id: pick.id, surface: pick.surface,
                                          origin: pick.origin))
        }
        let session = try Support.session(from: data)
        let commit = try #require(session.actions.compactMap(\.commit).first)
        #expect(commit.kind == .expansion)

        let report = try GoldenReplay.run(session, layout: layout,
                                          packs: Support.packSource)
        #expect(report.divergences.isEmpty, "\(report.divergences)")
        #expect(report.compared == 1)
    }

    // MARK: - Satır sonu öğreniyor

    /// Satır sonu sınır yolları arasında öğrenmeyi çağırmayan **tek** yoldu;
    /// sembolle kapatılan aynı token öğreniliyordu.
    @Test("Satır sonu sembol gibi kalibrasyon örneği topluyor")
    func newlineLearnsLikeSymbol() throws {
        func samples(closingWith close: ReplayCommand) throws -> Int {
            var c = InputCoordinator(layout: layout)
            let doc = Support.Doc()
            for ch in "ev" {
                try c.perform(.letter(baseKey: String(ch), display: String(ch),
                                      shifted: false),
                              touch: sample(ch), into: doc)
            }
            try c.perform(close, touch: nil, into: doc)
            return c.calibration.sampleCount
        }
        #expect(try samples(closingWith: .symbol(".")) == 2)
        #expect(try samples(closingWith: .newline) == 2)
    }

    // MARK: - Büyük harf olgusu

    /// `pickSuggestion` olguyu `committed != word` ile hesaplıyordu; diğer
    /// sınır yolları `casingApplied(committed:literal:)` ile. Aynı yazım
    /// boşlukta ve öneri seçiminde farklı olgu üretiyordu.
    @Test("Öneri seçimi büyük harf olgusunu ortak kuralla hesaplıyor")
    func pickCasingUsesSharedRule() throws {
        func pick(_ typed: String, shifted: Bool, choose word: String)
            throws -> InputCoordinator.TokenCommitReport {
            var c = InputCoordinator(layout: layout)
            let doc = Support.Doc()
            for (i, ch) in typed.enumerated() {
                let shift = shifted && i == 0
                try c.perform(.letter(baseKey: String(ch),
                                      display: shift ? TurkishText.uppercased(ch)
                                                     : String(ch),
                                      shifted: shift),
                              touch: sample(ch), into: doc)
            }
            let r = try c.perform(.suggestionPick(id: word, surface: word,
                                                  origin: .candidate(id: word)),
                                  touch: nil, into: doc)
            guard case let .boundary(report) = r else {
                Issue.record("sınır raporu bekleniyordu"); return .empty()
            }
            return report
        }
        // Yalnız büyük harf farklı: `Ali` ↔ `ali`.
        let same = try pick("ali", shifted: true, choose: "ali")
        #expect(same.committed == "Ali")
        #expect(same.casingApplied)
        // Düzeltme + büyük harf: boşluktaki otomatik düzeltmeyle **aynı** olgu
        // (`committed` literal'den yalnız büyük harfte ayrışmıyor).
        let corrected = try pick("kslem", shifted: true, choose: "kalem")
        #expect(corrected.committed == "Kalem")
        #expect(!corrected.casingApplied)
        // Türkçe harf: locale'siz karşılaştırma `İ`'de yanılıyordu.
        let turkish = try pick("istanbul", shifted: true, choose: "istanbul")
        #expect(turkish.committed == "İstanbul")
        #expect(turkish.casingApplied)
    }

    // MARK: - Hazır metin

    /// Uzantı pano/dikte/tahmin metnini `.symbol(metin)` diye gönderiyordu:
    /// kaydedici reddediyor (metin yazılmıyordu), yedek yol ilk karakteri
    /// yazıyordu.
    @Test("Metin komutu açık token'ı kapatıp metnin tamamını yazıyor")
    func textClosesTokenAndWritesAll() throws {
        var c = InputCoordinator(layout: layout)
        let doc = Support.Doc()
        for ch in "ev" {
            try c.perform(.letter(baseKey: String(ch), display: String(ch),
                                  shifted: false),
                          touch: sample(ch), into: doc)
        }
        let text = " 👨‍👩‍👧 güzel gün"
        let r = try c.perform(.text(text), touch: nil, into: doc)
        guard case let .boundary(report) = r else {
            Issue.record("sınır raporu bekleniyordu"); return
        }
        #expect(report.kind == .literal)
        #expect(report.committed == "ev")
        #expect(report.tokenID == TokenID(raw: 0))
        #expect(report.delta == nil && report.theta == nil)
        #expect(doc.text == "ev" + text)
        #expect(!c.session.isComposing)
        // Metin dokunma kanıtı değil: yalnız kapanan token'ın iki dokunması.
        #expect(c.calibration.sampleCount == 2)

        // Metne giren silme **hiçbir token'a** atfedilmiyor: metin ayırıcı.
        let effect = c.backspaceTap(into: doc).value
        #expect(effect?.deleted == [.separator])
    }

    /// Tek grapheme'lik metin bir semboldür ve sembol kuralını alıyor.
    @Test("Tek grapheme'lik metin sembolle aynı")
    func singleGraphemeTextIsSymbol() throws {
        func run(_ cmd: ReplayCommand) throws -> (String, InputCoordinator.CommandResult) {
            var c = InputCoordinator(layout: layout)
            let doc = Support.Doc()
            try c.perform(.letter(baseKey: "e", display: "e", shifted: false),
                          touch: sample("e"), into: doc)
            let r = try c.perform(cmd, touch: nil, into: doc)
            return (doc.text, r)
        }
        let a = try run(.text("👍🏽"))
        let b = try run(.symbol("👍🏽"))
        #expect(a.0 == b.0)
        #expect(a.1 == b.1)
    }

    /// Kayıt → okuma → golden: çok grapheme'li metin **tek** eylem, belge
    /// zinciri tutarlı, replay farksız.
    @Test("Metin komutu kaydediliyor ve farksız replay ediliyor")
    func textRecordsAndReplays() throws {
        let texts = ["👨‍👩‍👧‍👦 ", "Çağrı'nın ışığı söndü. ", "ğüşiöç İĞÜŞÖÇ"]
        let data = try Support.record(prompt: ["ev", "el"]) { s in
            try s.type("ev")
            try s.command(.text(texts[0]))
            try s.type("el")
            try s.command(.space)
            try s.command(.text(texts[1]))
            try s.command(.text(texts[2]))
        }
        let session = try Support.session(from: data)
        let textActions = session.actions.filter { $0.kind == .text }
        #expect(textActions.count == 3)
        #expect(textActions.allSatisfy { $0.effect == .known(.boundary) })
        #expect(session.finalText == "ev" + texts[0] + "el " + texts[1] + texts[2])

        #expect(SessionValidator.validate(session, layout: layout).isEmpty,
                "\(SessionValidator.validate(session, layout: layout))")
        #expect(try DocumentReconstruction.replay(session)
                == .complete(session.finalText))
        let state = SessionEventReducer.reduce(session)
        #expect(state.tokens.map(\.committed) == ["ev", "el"])
        #expect(state.violations.isEmpty)

        let report = try GoldenReplay.run(session, layout: layout,
                                          packs: Support.packSource)
        #expect(report.divergences.isEmpty, "\(report.divergences)")
        #expect(report.unverifiable.isEmpty)
    }

    /// Boş metin replay edilemez; validator kaydı bozuk sayıyor.
    @Test("Boş metin komutu validator bulgusu")
    func emptyTextIsFinding() throws {
        var s = try Support.session(from: try Support.record(prompt: ["ev"]) { s in
            try s.type("ev")
            try s.command(.text("!?"))
        })
        let i = try #require(s.actions.firstIndex { $0.kind == .text })
        s.actions[i].event = .known(.text(""))
        #expect(SessionValidator.validate(s).contains {
            $0.kind == .payloadKindMismatch && $0.actionID == i
        })
    }
}
