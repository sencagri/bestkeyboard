import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBSpatial
import KBRuntime

/// Authored conversation probes. An exported mismatch is a finding to review,
/// not proof that every plausible correction should be applied automatically.
final class EverydayTypingAuditTests: XCTestCase {
    func testAccidentalBoundariesAtEveryInteriorPosition() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_INTERIOR_BOUNDARY_AUDIT"] else {
            throw XCTSkip("Set KB_INTERIOR_BOUNDARY_AUDIT to export interior boundary probes")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let words = ["sevgilim", "özledim", "seviyorum", "buluşalım", "görüşelim", "geliyorum",
                     "mühendislik", "veritabanı", "bağlantısını", "başlattım", "sunucularımız",
                     "gardaş", "napıyon", "uşağum", "nörüyon", "geliyom",
                     "başvurumun", "değerlendirilmesini", "saygılarımla", "gereğinin", "yapılmasını",
                     "otobüsteyim", "randevumuz", "eczanelerden", "alışverişe", "çocuklarımızı"]
        var rows: [[String: String]] = []
        for word in words {
            for offset in [-0.18, 0.0, 0.18] {
                func run(_ input: String) throws -> (String, [String], [String]) {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    let doc = FakeDocument()
                    for ch in input {
                        switch ch {
                        case " ": c.space(into: doc)
                        case "\n": c.newline(into: doc)
                        case "\u{8}": c.backspaceTap(into: doc)
                        default:
                            let index = try XCTUnwrap(layout.keyIndex(for: ch))
                            let key = layout.keys[index]
                            c.insertLetter(ch, touch: .init(down: .init(x: key.center.x + offset * key.width,
                                                                       y: key.center.y + offset * key.height)), into: doc)
                        }
                    }
                    c.space(into: doc)
                    return (doc.text, c.personal.entries.keys.sorted(), c.personal.admitted.sorted())
                }
                let baseline = try run(word)
                let chars = Array(word)
                for position in 1..<chars.count {
                    for boundary in [" ", "\n"] {
                        let sequence = String(chars[..<position]) + boundary + "\u{8}" + String(chars[position...])
                        let result = try run(sequence)
                        rows.append(["word": word, "position": String(position), "boundary": boundary == " " ? "space" : "enter",
                                     "offset": String(offset), "baseline": baseline.0, "actual": result.0,
                                     "same_text": String(result.0 == baseline.0),
                                     "extra_learning": Set(result.1).subtracting(baseline.1).sorted().joined(separator: " | "),
                                     "admitted": result.2.joined(separator: " | ")])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
        print("INTERIOR BOUNDARY AUDIT: \(rows.count) observations; \(rows.filter { $0["same_text"] == "false" }.count) text divergences")
    }

    func testMissingSpaceRepairPrecedesUnrelatedSingleWordAndSurvivesEditing() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for input in ["seniseviyorum", "senibseviyorum", "Senibseviyorum", "SENİBSEVİYORUM"] {
            for limit in [2, 3, 5] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in input {
                    let lower = Character(String(ch).lowercased(with: Locale(identifier: "tr_TR")))
                    let index = try XCTUnwrap(layout.keyIndex(for: lower))
                    let touch = TouchSample(down: layout.keys[index].center)
                    if ch.isUppercase { c.insertUppercaseLetter(lower, uppercase: String(ch), touch: touch, into: doc) }
                    else { c.insertLetter(ch, touch: touch, into: doc) }
                }
                let expected = input == "SENİBSEVİYORUM" ? "SENİ SEVİYORUM"
                    : input.hasPrefix("S") ? "Seni seviyorum" : "seni seviyorum"
                let suggestions = c.suggestions(limit: limit)
                XCTAssertEqual(suggestions.first?.surface, input)
                XCTAssertEqual(suggestions.dropFirst().first?.surface, expected,
                               "A one-boundary repair must precede an unrelated whole-word guess: \(input)")
                let repair = try XCTUnwrap(suggestions.first { $0.surface == expected })
                try c.perform(.suggestionPick(id: repair.id, surface: repair.surface, origin: repair.origin), touch: nil, into: doc)
                XCTAssertEqual(doc.text, expected + " ")
                c.newline(into: doc)
                c.backspaceTap(into: doc)
                XCTAssertEqual(doc.text, expected + " ")
                c.backspaceTap(into: doc)
                c.space(into: doc)
                XCTAssertEqual(doc.text, expected + " ")
                XCTAssertFalse(c.personal.isAdmitted(input), "Repairing a space typo must not teach the typo")
            }
        }
    }

    func testNewConversationMissingSpacesRemainSelectableAfterUndo() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        for phrase in ["seni özledim", "yarın görüşürüz", "sunucu hazır",
                         "erişim reddedildi", "bilgi bekliyorum", "gardaş geliyom",
                         "arz ederim", "rica ederim", "talep ediyorum", "teşekkür ederim"] {
            let turkish = Locale(identifier: "tr_TR")
            let upper = phrase.uppercased(with: turkish)
            let title = String(phrase.prefix(1)).uppercased(with: turkish) + phrase.dropFirst()
            for expected in [phrase, title, upper] {
                for separator in ["", "b"] {
                    let input = expected.replacingOccurrences(of: " ", with: expected == upper ? separator.uppercased() : separator)
                    for offset in [-0.18, 0.0, 0.18] {
                        var c = InputCoordinator(layout: layout)
                        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                        let doc = FakeDocument()
                        for ch in input {
                            let lower = Character(String(ch).lowercased(with: turkish))
                            let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: lower))]
                            let touch = TouchSample(down: .init(x: key.center.x + offset * key.width,
                                                              y: key.center.y + offset * key.height))
                            if ch.isUppercase {
                                c.insertUppercaseLetter(lower, uppercase: String(ch), touch: touch, into: doc)
                            } else {
                                c.insertLetter(ch, touch: touch, into: doc)
                            }
                        }
                        XCTAssertTrue(c.suggestionSurfaces().contains(expected),
                                      "\(input), offset=\(offset): \(c.suggestionSurfaces())")
                        c.space(into: doc)
                        c.newline(into: doc)
                        c.backspaceTap(into: doc)
                        c.backspaceTap(into: doc)
                        let suggestion = try XCTUnwrap(c.suggestions().first { $0.surface == expected },
                                                      "Reopened \(input), offset=\(offset)")
                        try c.perform(.suggestionPick(id: suggestion.id, surface: suggestion.surface,
                            origin: suggestion.origin), touch: nil, into: doc)
                        XCTAssertEqual(doc.text, expected + " ")
                        XCTAssertNil(c.personal.entries[input.lowercased(with: turkish)], "Discarded joined form must not be learned")
                    }
                }
            }
        }
    }

    func testMixedRepeatedBoundaryCancellation() throws {
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let words = ["sevgilim", "özledim", "mühendislik", "bağlantısını", "nörüyon", "uşağum",
                     "değerlendirilmesini", "saygılarımla", "randevumuz", "otobüsteyim", "eczanelerden", "çocuklarımızı"]
        let interruptions = ["  ", "\n\n", " \n", "\n ", " \n "]
        var probes = 0
        for word in words {
            func run(_ input: String) throws -> (String, [String: Int]) {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                // Repeat independently: a surviving cancelled fragment must
                // not quietly reach admission on the third occurrence.
                for _ in 0..<3 {
                    for ch in input {
                        switch ch {
                        case " ": c.space(into: doc)
                        case "\n": c.newline(into: doc)
                        case "\u{8}": c.backspaceTap(into: doc)
                        default:
                            let key = layout.keys[try XCTUnwrap(layout.keyIndex(for: ch))]
                            c.insertLetter(ch, touch: .init(down: key.center), into: doc)
                        }
                    }
                    c.space(into: doc)
                }
                return (doc.text, c.personal.entries.mapValues(\.points))
            }
            let baseline = try run(word)
            let chars = Array(word)
            for position in 1..<chars.count {
                for interruption in interruptions {
                    let input = String(chars[..<position]) + interruption
                        + String(repeating: "\u{8}", count: interruption.count) + String(chars[position...])
                    let actual = try run(input)
                    let label = "\(word), position \(position), boundaries \(interruption.debugDescription)"
                    XCTAssertEqual(actual.0, baseline.0, label)
                    XCTAssertEqual(actual.1, baseline.1, "Cancelled fragment evidence: " + label)
                    probes += 1
                }
            }
        }
        print("MIXED BOUNDARY AUDIT: \(probes) sequences, each repeated three times")
    }

    func testConversationsAndAccidentalControlKeys() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_EVERYDAY_AUDIT"] else {
            throw XCTSkip("Set KB_EVERYDAY_AUDIT to export conversation probes")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let cases: [(String, String, String)] = [
            ("romantic", "canım seni çok özledim ", "canım seni çok özledim "),
            ("romantic_typo", "canım seni çok özledşm ", "canım seni çok özledim "),
            ("romantic", "iyi ki varsın sevgilim ", "iyi ki varsın sevgilim "),
            ("romantic", "akşam buluşalım mı ", "akşam buluşalım mı "),
            ("engineer", "sunucu yanıt vermiyor ", "sunucu yanıt vermiyor "),
            ("engineer", "bağlantı zaman aşımına uğradı ", "bağlantı zaman aşımına uğradı "),
            ("engineer", "veritabanı bağlantısını yeniden başlattım ", "veritabanı bağlantısını yeniden başlattım "),
            ("dialect", "gardaş napıyon hele bi gel ", "gardaş napıyon hele bi gel "),
            ("dialect", "ula uşağum çaylar soğudi ", "ula uşağum çaylar soğudi "),
            ("dialect", "nörüyon la gardaş ", "nörüyon la gardaş "),
            ("formal", "Sayın Yetkili\nGereğinin yapılmasını arz ederim.\nSaygılarımla ", "Sayın Yetkili\nGereğinin yapılmasını arz ederim.\nSaygılarımla "),
            ("formal", "Başvurumun değerlendirilmesini rica ederim ", "Başvurumun değerlendirilmesini rica ederim "),
            ("shopping", "iki kilo domates bir ekmek alır mısın ", "iki kilo domates bir ekmek alır mısın "),
            ("travel", "otobüs durağında bekliyorum ", "otobüs durağında bekliyorum "),
            ("appointment", "yarın saat 14:30 uygun mu ", "yarın saat 14:30 uygun mu "),
            ("double_space", "seni  seviyorum ", "seni  seviyorum "),
            ("space_undo", "seni  \u{8}seviyorum ", "seni seviyorum "),
            ("premature_space", "sev \u{8}iyorum ", "seviyorum "),
            ("premature_space", "mühen \u{8}dislik ", "mühendislik "),
            ("premature_enter", "sev\n\u{8}iyorum ", "seviyorum "),
            ("premature_enter", "mühen\n\u{8}dislik ", "mühendislik "),
            ("wrong_letter_delete", "seni seviyorun\u{8}m ", "seni seviyorum "),
            ("accidental_delete", "seni seviyoru\u{8}um ", "seni seviyorum "),
            ("enter_after_space", "seni \n\u{8}seviyorum ", "seni seviyorum "),
            ("blank_lines", "Sayın Yetkili\n\nMerhaba ", "Sayın Yetkili\n\nMerhaba "),
            ("delete_blank_lines", "Sayın Yetkili\n\n\u{8}\u{8} merhaba ", "Sayın Yetkili merhaba "),
            ("missing_space", "seniseviyorum ", "seni seviyorum "),
            ("space_hit_b", "senibseviyorum ", "seni seviyorum "),
            ("space_hit_n", "sunucunyanıt ", "sunucu yanıt "),
            ("technical", "https://example.com/api?q=ışık ", "https://example.com/api?q=ışık "),
            ("technical", "dev@example.com ", "dev@example.com ")
        ]
        var rows: [[String: String]] = []
        for (group, input, expected) in cases {
            for offset in [-0.18, 0.0, 0.18] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                var changes: [String] = []
                var offers: [String] = []
                for ch in input {
                    switch ch {
                    case " ":
                        offers = c.suggestions().map(\.surface)
                        let report = c.space(into: doc)
                        if report.committed != report.displayBefore {
                            changes.append(report.displayBefore + " → " + report.committed)
                        }
                    case "\n": c.newline(into: doc)
                    case "\u{8}": c.backspaceTap(into: doc)
                    default:
                        let lower = String(ch).lowercased(with: Locale(identifier: "tr_TR"))
                        if let letter = lower.first, let index = layout.keyIndex(for: letter) {
                            let key = layout.keys[index]
                            let touch = TouchSample(down: .init(x: key.center.x + offset * key.width,
                                                               y: key.center.y + offset * key.height))
                            if ch.isUppercase {
                                c.insertUppercaseLetter(letter, uppercase: String(ch), touch: touch, into: doc)
                            } else { c.insertLetter(ch, touch: touch, into: doc) }
                        } else { c.insertSymbol(ch, into: doc) }
                    }
                }
                rows.append(["group": group, "input": input, "expected": expected,
                             "offset": String(offset), "actual": doc.text,
                             "exact": String(doc.text == expected), "changes": changes.joined(separator: " | "),
                             "offers": offers.joined(separator: " | "),
                             "admitted": c.personal.admitted.sorted().joined(separator: " | ")])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
        print("EVERYDAY AUDIT: \(rows.count) observations, \(rows.filter { $0["exact"] == "false" }.count) review findings")
    }
}
