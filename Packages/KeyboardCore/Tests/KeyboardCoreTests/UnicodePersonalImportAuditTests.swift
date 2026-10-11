import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
import KBSessions
@testable import KBRuntime

final class UnicodePersonalImportAuditTests: XCTestCase {
    func testEquivalentUnicodeImportAndForget() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_UNICODE_PERSONAL_IMPORT_AUDIT"] else {
            throw XCTSkip("Opt-in Unicode personal import audit")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let tokenize: (String) -> [String] = { PersonalLexicon.importTokens(from: $0, layout: layout) }
        let locale = Locale(identifier: "tr_TR")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unicode-personal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rows: [[String: String]] = []
        for word in ["qrmenü", "qrçağrı", "qrışık", "qröğüş", "qripek", "qrgöl"] {
            let upper = word.uppercased(with: locale)
            let variants = [word, word.decomposedStringWithCanonicalMapping, upper, upper.decomposedStringWithCanonicalMapping]
            for (initialIndex, initial) in variants.enumerated() {
                for (forgetIndex, forget) in variants.enumerated() {
                    var c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    _ = c.ingestPersonal(tokens: tokenize( initial))
                    let first = c.personal
                    var sameTokens = true
                    for repeated in variants {
                        sameTokens = sameTokens && tokenize( repeated) == [word]
                        _ = c.ingestPersonal(tokens: tokenize( repeated))
                    }
                    let deduplicated = c.personal == first && c.personal.entries[word]?.points == 1
                    let notAdmitted = !c.personal.isAdmitted(word)
                    _ = c.ingestPersonal(tokens: tokenize( [initial, initial, initial].joined(separator: " ")))
                    let admittedOnce = c.personal.admitted == [word] && c.personal.entries.count == 1
                    try PersonalLexiconStore.save(c.personal, to: directory)
                    c.replacePersonalLexicon(try PersonalLexiconStore.load(from: directory))
                    let knownReloaded = variants.allSatisfy { c.personal.isAdmitted($0) } && c.engine!.literalChannel.score(word).isInVocabulary
                    let forgotten = c.forgetPersonal(forget)
                    try PersonalLexiconStore.delete(from: directory)
                    c.replacePersonalLexicon(PersonalLexiconStore.loadOrEmpty(from: directory))
                    let absent = c.personal.entries.isEmpty && !c.engine!.literalChannel.score(word).isInVocabulary
                    let checks = ["tokens_canonical": sameTokens, "repeat_deduplicated": deduplicated,
                                  "single_not_admitted": notAdmitted, "admitted_once": admittedOnce,
                                  "known_after_reload": knownReloaded, "forget_changed": forgotten, "absent_after_reload": absent]
                    for (name, passed) in checks { XCTAssertTrue(passed, "\(word) \(initialIndex)/\(forgetIndex): \(name)") }
                    var row = checks.mapValues(String.init)
                    row["word"] = word; row["initial_variant"] = String(initialIndex); row["forget_variant"] = String(forgetIndex)
                    rows.append(row)
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
