import XCTest
import KBAssembly
import KBGeometry
import KBRuntime
import KBLearning

final class ConversationHistoryConsistencyTests: XCTestCase {
    func testDirectNewlineUndoRestoresSuggestionsAndCleanLearning() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (input, corrected) in [("kannı", "kanı"), ("gelemeyeceğimm", "gelemeyeceğim"),
                                  ("başlatt", "başlat"), ("gardaşşım", "gardaşım"),
                                  ("saygılarımm", "saygılarım"), ("fedakkar", "fedakar")] {
            func run(_ newlines: Int) throws -> (String, [String: Int], [String: Int]) {
                let doc = HistoryTrackingDocument()
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                for ch in input {
                    let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                    c.insertLetter(ch, touch: .init(down: key.center), into: doc)
                    doc.refresh()
                }
                let originalOffers = c.suggestionSurfaces()
                for _ in 0..<newlines { c.newline(into: doc); doc.boundary() }
                if newlines > 0 {
                    XCTAssertNil(c.engine?.context.word)
                }
                for _ in 0..<newlines { c.backspaceTap(into: doc); doc.refresh() }
                XCTAssertEqual(doc.text, input)
                if newlines > 0 {
                    XCTAssertTrue(c.session.isReopened, input)
                    XCTAssertEqual(c.suggestionSurfaces(), originalOffers, input)
                }
                let choice = try XCTUnwrap(c.suggestions().first { $0.surface == corrected }, input)
                try c.perform(.suggestionPick(id: choice.id, surface: choice.surface, origin: choice.origin),
                              touch: nil, into: doc)
                doc.boundary()
                let saved = try HistoryArchive.decode(JSONEncoder().encode(doc.archive))
                return (doc.text, c.personal.entries.mapValues { Int($0.points) },
                        saved.history.tokens.mapValues(\.count))
            }
            let clean = try run(0)
            for count in [1, 2, 3] {
                let edited = try run(count)
                XCTAssertEqual(edited.0, corrected + " ")
                XCTAssertEqual(edited.0, clean.0)
                XCTAssertEqual(edited.1, clean.1, input)
                XCTAssertEqual(edited.2, clean.2, input)
            }
        }
    }

    func testCancelledFragmentsMatchCleanMessageInBothLearningStores() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for message in ["canım seni çoook özledim", "mühendislik ekibi veritabanı bağlantısını yeniden başlattı",
                        "ula uşağum gardaş geliyom çay içek", "sayın yetkili başvurumun değerlendirilmesini rica ederim",
                        "otobüsteyim randevumuz için geliyorum", "çocuklarımızı okuldan alıp alışverişe gidelim",
                        "deploy sonrası logları kontrol ediyorum", "docker servisini yeniden başlatıyorum",
                        "cache temizlendi commit hazır", "branch üzerinde testleri çalıştırıyorum",
                        "iyi ki varsın", "ben de seni çok seviyorum",
                        "her şey çok güzel", "bir şey sorabilir miyim",
                        "naber kanks napıyon", "bi çay içek sonra gidek",
                        "tmm gelcem sen bekle", "slm bugün napcaz",
                        "aşkım eve varınca haber ver", "yarın seni görünce sarılacağım",
                        "sunucu günlüklerinde bağlantı zaman aşımı var",
                        "talebimin sonucunu tarafıma bildirmenizi rica ederim",
                        "hele gardaş bi soluklan sonra konuşak",
                        "kargoyu komşuya bırakır mısınız",
                        "napıyosun biz de geliyoz",
                        "aşkım fısıl fısıl konuş bebeğimiz uyuyor",
                        "kalbim pıtır pıtır atıyor seni bekliyorum",
                        "derleyici doğrulayıcının sonucunu bekliyor",
                        "ula gardaş homur homur söylenme çay içek",
                        "talebinize binaen sonuçları tarafınıza bildiriyoruz",
                        "şıkır şıkır giyinip tıpış tıpış geldim"] {
            for offset in [-0.18, 0.0, 0.18] {
                func run(_ mode: Int) throws -> (String, [String: Int], [String: Int], [String: [String: Int]]) {
                    let doc = HistoryTrackingDocument()
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    func letter(_ ch: Character) throws {
                        let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                        c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                            y: key.center.y + offset * key.height)), into: doc)
                        doc.refresh()
                    }
                    for word in message.split(separator: " ") {
                        for (i, ch) in word.enumerated() {
                            if (mode == 6 || mode == 10) && i == word.count / 2 {
                                // Substitute the intended key, rather than append
                                // an extra key after it, then repair after a boundary.
                                let origin = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                                let adjacent = layout.keys.filter { $0.char != ch }.min {
                                    $0.center.squaredDistance(to: origin.center) < $1.center.squaredDistance(to: origin.center)
                                }!
                                try letter(adjacent.char)
                            } else {
                                try letter(ch)
                            }
                            if mode > 0 && (i == word.count / 2 || (mode == 3 && (i == 0 || i == word.count - 1))) {
                                let origin = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                                let adjacent = layout.keys.filter { $0.char != ch }.min {
                                    $0.center.squaredDistance(to: origin.center) < $1.center.squaredDistance(to: origin.center)
                                }!
                                if mode == 1 { try letter(adjacent.char) }
                                if mode == 3 || mode == 9 { try letter(ch) }
                                if mode == 7 {
                                    // Delete the correct letter before accidentally committing
                                    // its shortened prefix; restore it after undoing boundaries.
                                    c.backspaceTap(into: doc); doc.refresh()
                                }
                                // Direct Enter interruptions used to discard the
                                // just-typed word's touch history. Cover plain,
                                // doubled and substituted letters independently
                                // of the already-tested SPACE+ENTER path.
                                if mode < 8 { c.space(into: doc); doc.boundary() }
                                c.newline(into: doc); doc.boundary()
                                if mode == 4 {
                                    c.space(into: doc); doc.boundary()
                                    c.newline(into: doc); doc.boundary()
                                    c.space(into: doc); doc.boundary()
                                }
                                let deletes = mode >= 8 ? (mode == 8 ? 1 : 2)
                                    : (mode == 4 ? 5 : (mode == 2 || mode == 7 ? 2 : 3))
                                for _ in 0..<deletes { c.backspaceTap(into: doc); doc.refresh() }
                                // An accidental extra delete removes a correct letter; restore it
                                // before continuing the word and compare both learning stores.
                                if mode == 5 || mode == 6 || mode == 7 || mode == 10 { try letter(ch) }
                            }
                        }
                        c.space(into: doc); doc.boundary()
                    }
                    return (doc.text, c.personal.entries.mapValues { Int($0.points) },
                            doc.archive.history.tokens.mapValues(\.count),
                            doc.archive.history.pairs.mapValues { $0.mapValues(\.count) })
                }
                let clean = try run(0)
                XCTAssertEqual(clean.0, message + " ")
                for mode in 1...10 {
                    let edited = try run(mode)
                    let label = "message=\(message), offset=\(offset), mode=\(mode)"
                    XCTAssertEqual(edited.0, clean.0, label)
                    XCTAssertEqual(edited.1, clean.1, "Personal lexicon: " + label)
                    XCTAssertEqual(edited.2, clean.2, "History tokens: " + label)
                    XCTAssertEqual(edited.3, clean.3, "History pairs: " + label)
                }
            }
        }
    }

    func testRemovingLatestRepeatedWordPreservesEarlierOccurrences() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (prefix, removed, replacement) in [
            ("canım canım ", "canım", "seni seviyorum"),
            ("veritabanı bağlantısı ", "bağlantısı", "yenilendi"),
            ("ula gardaş ", "gardaş", "geliyom"),
            ("sayın yetkili ", "yetkili", "başvurum hazır"),
            ("çocuklarımızı okuldan ", "okuldan", "alalım"),
            ("seviyorum seviyorum ", "seviyorum", "seni")
        ] {
            for offset in [-0.18, 0.0, 0.18] {
                func run(_ mode: Int) throws -> (String, [String: Int], [String: Int], [String: [String: Int]]) {
                    let doc = HistoryTrackingDocument()
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    func type(_ text: String) throws {
                        for ch in text {
                            if ch == " " { c.space(into: doc); doc.boundary() }
                            else {
                                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                                c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                                    y: key.center.y + offset * key.height)), into: doc)
                                doc.refresh()
                            }
                        }
                    }
                    try type(prefix)
                    if mode > 0 {
                        try type(removed + " ")
                        if mode == 3 { c.deleteWord(into: doc); doc.refresh() }
                        else {
                            for _ in 0...removed.count {
                                if mode == 1 { c.backspaceTap(into: doc) }
                                else { c.backspaceRepeat(into: doc) }
                                doc.refresh()
                            }
                        }
                        XCTAssertEqual(doc.text, prefix)
                    }
                    try type(replacement + " ")
                    let persisted = try HistoryArchive.decode(JSONEncoder().encode(doc.archive))
                    return (doc.text, c.personal.entries.mapValues { Int($0.points) },
                        persisted.history.tokens.mapValues(\.count),
                        persisted.history.pairs.mapValues { $0.mapValues(\.count) })
                }
                let clean = try run(0)
                XCTAssertEqual(clean.0, prefix + replacement + " ")
                for mode in [1, 2, 3] {
                    let edited = try run(mode), label = "removed=\(removed), offset=\(offset), mode=\(mode)"
                    XCTAssertEqual(edited.0, clean.0, label)
                    XCTAssertEqual(edited.1, clean.1, "Personal lexicon: " + label)
                    XCTAssertEqual(edited.2, clean.2, "History tokens: " + label)
                    XCTAssertEqual(edited.3, clean.3, "History pairs: " + label)
                }
            }
        }
    }

    func testReplacingMistypedCompletedWordAfterNewlineMatchesCleanHistory() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for (prefix, removed, replacement) in [
            ("canım canım ", "özledimm", "seni seviyorum"),
            ("veritabanı bağlantısı ", "yenilendii", "yenilendi"),
            ("ula gardaş ", "geliyomm", "geliyom"),
            ("sayın yetkili ", "başvurumm", "başvurum hazır"),
            ("çocuklarımızı okuldan ", "alalımm", "alalım"),
            ("seviyorum seviyorum ", "çokkk", "seni"),
            ("canım ", "seni çok özledim", "yarın seni göreceğim"),
            ("sunucu ", "veritabanı bağlantısını yeniden başlattı", "yanıt vermiyor"),
            ("ula ", "gardaş çay içek", "uşağum geliyom"),
            ("sayın yetkili ", "başvurumu geri çekiyorum", "bilgi rica ederim"),
            ("bugün ", "çocukları okuldan ben alırım", "eve erken geliyorum"),
            ("canım seni ", "seni seni seviyorum", "çok özledim"),
            ("randevumuz ", "21.455", "21.45 saatinde"),
            ("toplam ", "12500 lira", "1250 lira"),
            ("sunucu adresi ", "192.168.1.100", "192.168.1.10"),
            ("yeni sürüm ", "v2.11", "v2.1 hazır"),
            ("toplantı ", "14:300", "14:30 saatinde"),
            ("ödeme ", "125,500 lira", "125,50 lira"),
            ("teslim tarihi ", "24.10.20266", "24.10.2026"),
            ("indirim ", "%155", "%15 olacak"),
            ("canım\n\n", "seni özledimm", "seni özledim"),
            ("sayın yetkili\n", "başvurumm", "başvurum hazır"),
            ("sunucu hazır\n\n", "bağlantı kapalı", "bağlantı açık"),
            ("ula gardaş\n", "geliyomm", "geliyom"),
            ("servis adresi ", "https://example.com/apii", "https://example.com/api"),
            ("iletişim ", "devv@example.com", "dev@example.com"),
            ("dosya ", "raporr.txt", "rapor.txt"),
            ("yarın ", "ankara'yaa", "ankara'ya gidiyorum"),
            ("aşkım ", "19.300 gibi", "19.30 gibi geliyorum"),
            ("bakım aralığı ", "02:000 03:00", "02:00 03:00"),
            ("başvuru tarihi ", "25/100/2026", "25/10/2026"),
            ("ula gardaş ", "saat 88 oldu", "saat 8 oldu"),
            ("sunucu ", "güncelleştirmeyi yükleyemedi", "güncelleştirmeyi yükledi"),
            ("canım ", "seni bekleyemiyorum", "seni bekliyorum"),
            ("ula gardaş ", "bugün gelemiyom", "yarın geliyom"),
            ("sayın yetkili ", "talebimi iptal ediyorum", "talebimin incelenmesini istiyorum"),
            ("canım seni ", "yarın arayacağım", "bugün arayacağım"),
            ("sunucu ", "yeniden başlatıldı", "yeniden başlatılmadı"),
            ("ula gardaş ", "bugün buluşak", "yarın buluşak"),
            ("bilgilerinize ", "arz ederim", "rica ederim"),
            ("canım ", "üşütme", "dinlen"),
            ("yeni sürüm ", "doğrulayıcının sonucunu bekliyor", "derleyicinin sonucunu bekliyor"),
            ("başvurunuza ", "binaen iptal edildi", "binaen kabul edildi"),
            ("ula gardaş ", "kıkır kıkır gülüyom", "gümbür gümbür geliyom"),
            ("odadaki eşya ", "eciş bücüş kaldı", "tertemiz oldu"),
            ("su ", "şırıl şırıl akıyor", "artık akmıyor")
        ] {
            for offset in [-0.18, 0.0, 0.18] {
                func run(_ mode: Int) throws -> (String, [String: Int], [String: Int], [String: [String: Int]]) {
                    let doc = HistoryTrackingDocument()
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    func type(_ text: String) throws {
                        for ch in text {
                            if ch == " " { c.space(into: doc); doc.boundary() }
                            else if ch.isNewline { c.newline(into: doc); doc.boundary() }
                            else if ch.isLetter {
                                let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                                c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                                    y: key.center.y + offset * key.height)), into: doc)
                                doc.refresh()
                            } else {
                                c.insertSymbol(ch, into: doc); doc.refresh()
                            }
                        }
                    }
                    try type(prefix)
                    if mode > 0 {
                        try type(removed + " ")
                        c.newline(into: doc); doc.boundary()
                        if mode == 3 {
                            // The first command only removes the newline barrier.
                            c.deleteWord(into: doc); doc.refresh()
                            XCTAssertFalse(doc.text.hasSuffix("\n"))
                            XCTAssertGreaterThan(doc.text.count, prefix.count)
                            for _ in removed.split(separator: " ") {
                                c.deleteWord(into: doc); doc.refresh()
                            }
                        }
                        else {
                            // Automatic correction can change length. Follow actual
                            // visible content, as a person deleting to the prior word.
                            for _ in 0..<(removed.count + 8) {
                                if doc.text.count <= prefix.count { break }
                                if mode == 1 { c.backspaceTap(into: doc) }
                                else { c.backspaceRepeat(into: doc) }
                                doc.refresh()
                            }
                        }
                        XCTAssertEqual(doc.text, prefix)
                    }
                    try type(replacement + " ")
                    let persisted = try HistoryArchive.decode(JSONEncoder().encode(doc.archive))
                    return (doc.text, c.personal.entries.mapValues { Int($0.points) },
                        persisted.history.tokens.mapValues(\.count),
                        persisted.history.pairs.mapValues { $0.mapValues(\.count) })
                }
                let clean = try run(0)
                XCTAssertEqual(clean.0, prefix + replacement + " ")
                for mode in [1, 2, 3] {
                    let edited = try run(mode), label = "removed=\(removed), offset=\(offset), mode=\(mode)"
                    XCTAssertEqual(edited.0, clean.0, label)
                    XCTAssertEqual(edited.1, clean.1, "Personal lexicon: " + label)
                    XCTAssertEqual(edited.2, clean.2, "History tokens: " + label)
                    XCTAssertEqual(edited.3, clean.3, "History pairs: " + label)
                }
            }
        }
    }

}

/// Mirrors the native bridge: witness each delete before the proxy operation,
/// refresh history after a command, and observe completion at token boundaries.
private final class HistoryTrackingDocument: DocumentEditor {
    private let doc = FakeDocument()
    private var observation = HistoryObservation()
    private let id = UUID()
    var archive = HistoryArchive()
    init() { refresh() }
    var text: String { doc.text }
    var contextBeforeInput: String? { doc.contextBeforeInput }
    var contextAfterInput: String? { doc.contextAfterInput }
    var selectedText: String? { doc.selectedText }
    func insertText(_ text: String) {
        observation.expectInsertion(text, before: doc.contextBeforeInput ?? "", after: doc.contextAfterInput, documentID: id)
        drain()
        doc.insertText(text)
    }
    func deleteBackward() {
        observation.expectBackwardDeletion(before: doc.contextBeforeInput ?? "", after: doc.contextAfterInput, documentID: id)
        drain()
        doc.deleteBackward()
    }
    private func drain() { archive.retract(observation.takeCancelledOccurrences()) }
    func refresh() {
        observation.changed(before: doc.contextBeforeInput ?? "", documentID: id, after: doc.contextAfterInput)
        drain()
    }
    func boundary() {
        if let event = observation.completed(before: doc.contextBeforeInput ?? "", documentID: id, after: doc.contextAfterInput) {
            archive.observe(event)
        }
        drain()
        refresh()
    }
}
