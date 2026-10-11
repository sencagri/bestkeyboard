import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
import KBRuntime

final class PersonalPersistenceAuditTests: XCTestCase {
    func testLearnSaveForgetReload() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_PERSONAL_PERSIST_AUDIT"] else { throw XCTSkip("Set KB_PERSONAL_PERSIST_AUDIT") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bestkeyboard-personal-audit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        var rows: [[String: String]] = []
        for word in ["qrmenü", "cepmenü", "pikselköy", "bulutnot"] {
            for forgetForm in [word, word.uppercased(with: Locale(identifier: "tr_TR")), word.decomposedStringWithCanonicalMapping] {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                let doc = FakeDocument()
                for ch in word {
                    let i = try XCTUnwrap(layout.keyIndex(for: ch))
                    c.insertLetter(ch, touch: .init(down: layout.keys[i].center), into: doc)
                }
                let original = try XCTUnwrap(c.suggestions().first)
                try c.perform(.suggestionPick(id: original.id, surface: original.surface, origin: original.origin), touch: nil, into: doc)
                XCTAssertTrue(c.personal.isAdmitted(word))
                try PersonalLexiconStore.save(c.personal, to: dir)
                let reloaded = try PersonalLexiconStore.load(from: dir)
                var next = InputCoordinator(layout: layout)
                next.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                next.replacePersonalLexicon(reloaded)
                let knownAfterReload = next.engine!.literalChannel.score(word).isInVocabulary
                let forgotten = next.forgetPersonal(forgetForm)
                // InputSession.savePersonal takes this branch after forgetting final word.
                if next.personal.isEmpty { try PersonalLexiconStore.delete(from: dir) }
                else { try PersonalLexiconStore.save(next.personal, to: dir) }
                let afterForget = PersonalLexiconStore.loadOrEmpty(from: dir)
                var restarted = InputCoordinator(layout: layout)
                restarted.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                restarted.replacePersonalLexicon(afterForget)
                let leaked = restarted.personal.isAdmitted(word)
                let knownAfterForget = restarted.engine!.literalChannel.score(word).isInVocabulary
                rows.append(["word": word, "forget_form": forgetForm,
                             "forget_scalars": forgetForm.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "),
                             "known_after_reload": String(knownAfterReload), "forgotten": String(forgotten),
                             "file_exists_after_last_delete": String(FileManager.default.fileExists(atPath: dir.appendingPathComponent(PersonalLexiconStore.fileName).path)),
                             "readmitted_after_reload": String(leaked), "known_after_forget": String(knownAfterForget)])
                XCTAssertTrue(knownAfterReload)
                XCTAssertTrue(forgotten)
                XCTAssertFalse(leaked)
                XCTAssertFalse(knownAfterForget)
            }
        }
        let words = ["qrmenü", "cepmenü", "pikselköy", "bulutnot"]
        for target in words {
            var personal = PersonalLexicon()
            for word in words { personal.observe(word, confidence: .strong) }
            var c = InputCoordinator(layout: layout)
            c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
            c.replacePersonalLexicon(personal)
            XCTAssertTrue(c.forgetPersonal(target))
            try PersonalLexiconStore.save(c.personal, to: dir)
            let reloaded = try PersonalLexiconStore.load(from: dir)
            let expected = words.filter { $0 != target }.sorted()
            XCTAssertEqual(reloaded.admitted.sorted(), expected)
            rows.append(["scenario": "one_of_four_deleted", "word": target,
                         "remaining": reloaded.admitted.sorted().joined(separator: " | "),
                         "other_words_preserved": String(reloaded.admitted.sorted() == expected)])
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
        print("PERSONAL PERSISTENCE AUDIT: \(rows.count) round trips")
    }
}
