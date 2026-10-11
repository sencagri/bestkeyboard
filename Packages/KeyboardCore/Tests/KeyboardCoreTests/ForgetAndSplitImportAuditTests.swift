import XCTest
import KBLearning

final class ForgetAndSplitImportAuditTests: XCTestCase {
    func testIdentityForgetAndIndependentPersonalImportChunks() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_FORGET_SPLIT_AUDIT"] else {
            throw XCTSkip("Set KB_FORGET_SPLIT_AUDIT")
        }
        var rows: [[String: String]] = []
        for (stored, forgotten, control) in [
            ("QRmenü", "qrmenü", "başka"),
            ("Smith@INFO.example", "Smith@info.example", "smith@info.example"),
            ("https://INFO.example/Page", "https://info.example/Page", "https://info.example/page"),
            ("+90 (532) 123 45 67", "+905321234567", "+905321234568"),
            ("(0532)1234567", "0532 123 45 67", "05321234568")
        ] {
            var imported = PersonalHistory()
            imported.observe(token: stored, previous: nil)
            imported.observe(token: control, previous: nil)
            var archive = HistoryArchive(history: imported)
            archive.forget(forgotten)
            archive = try HistoryArchive.decode(JSONEncoder().encode(archive))
            var inbox = HistoryImportInbox()
            inbox.append(imported, source: "Metin")
            try HistoryImportTransaction.consume(&archive, inbox: inbox,
                writeArchive: { _ in }, writeInbox: { inbox = $0 })
            rows.append([
                "scenario": "forget_reload_reimport", "stored": stored, "forgotten": forgotten,
                "target_returned": String(archive.history.tokens.values.contains { $0.surface == stored }),
                "control_preserved": String(archive.history.tokens.values.contains { $0.surface == control }),
                "target_in_catalog": String(inbox.sources["Metin"]?.tokens.values.contains { $0.surface == stored } ?? false)
            ])
        }
        for chunks in [[3], [1, 1, 1], [2, 1], [3, 3]] {
            var lexicon = PersonalLexicon()
            for (index, count) in chunks.enumerated() {
                // Distinct surrounding words distinguish these field imports.
                let words = Array(repeating: "qrmenü", count: count) + ["bağlam" + String(index)]
                _ = lexicon.ingest(tokens: words, isKnown: { _ in false })
            }
            rows.append(["scenario": "personal_field_import_chunks",
                         "chunks": chunks.map(String.init).joined(separator: ","),
                         "points": String(lexicon.entries["qrmenü"]?.points ?? 0),
                         "admitted": String(lexicon.isAdmitted("qrmenü"))])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: path))
    }
}
