import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class ForgottenPhraseReopenAuditTests: XCTestCase {
    func testForgottenRootDoesNotReappearDuringPhraseReopen() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_FORGOTTEN_REOPEN_AUDIT"] else { throw XCTSkip("Opt-in personal forget reload audit") }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let roots = ["qrmenü", "mavilo", "zepnuk"]
        let locale = Locale(identifier: "tr_TR")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("personal-forget-audit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rows: [[String: String]] = []
        for (root, forms) in [("qrmenü", ["qrmenü", "qrmenüden", "qrmenüler", "qrmenümüzde"]),
                              ("mavilo", ["mavilo", "mavilodan", "mavilolar", "mavilomuzda"]),
                              ("zepnuk", ["zepnuk", "zepnuktan", "zepnuklar", "zepnukumuzda"])] {
            for profile in ["accepted", "imported"] {
                for forgetSurface in [root, root.uppercased(with: locale), root.prefix(1).uppercased(with: locale) + root.dropFirst()] {
                    for form in forms {
                        var c = InputCoordinator(layout: layout)
                        c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                        var personal = PersonalLexicon()
                        for other in roots where other != root { personal.observe(other, confidence: .strong) }
                        if profile == "accepted" { personal.observe(root, confidence: .strong) }
                        c.replacePersonalLexicon(personal)
                        if profile == "imported" { _ = c.ingestPersonal(tokens: [root, root, root]) }
                        try PersonalLexiconStore.save(c.personal, to: directory)
                        let doc = FakeDocument()
                        for ch in "açb" + form {
                            let index = try XCTUnwrap(layout.keyIndex(for: ch))
                            c.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: doc)
                        }
                        let target = "aç " + form
                        let pick = try XCTUnwrap(c.suggestions().first { $0.surface == target })
                        try c.perform(.suggestionPick(id: pick.id, surface: pick.surface, origin: pick.origin), touch: nil, into: doc)
                        c.backspaceTap(into: doc)
                        let reopened = c.session.display == form && c.session.isReopened
                        let forgot = c.forgetPersonal(forgetSurface)
                        var absent = true, literalVisible = true, exact = true
                        for _ in 0..<4 {
                            literalVisible = literalVisible && c.suggestions().contains { $0.surface == form }
                            c.space(into: doc)
                            absent = absent && !c.personal.isAdmitted(root) && !c.isKnownPersonalInflection(form)
                            exact = exact && doc.text == target + " "
                            c.backspaceTap(into: doc)
                            exact = exact && doc.text == target && c.session.display == form
                        }
                        try PersonalLexiconStore.save(c.personal, to: directory)
                        c.replacePersonalLexicon(try PersonalLexiconStore.load(from: directory))
                        let persistedAbsent = !c.personal.isAdmitted(root) && !c.isKnownPersonalInflection(form)
                        rows.append(["root": root, "form": form, "profile": profile, "forgot_surface": forgetSurface,
                                     "reopened": String(reopened), "forgot": String(forgot), "absent": String(absent),
                                     "literal_visible": String(literalVisible), "exact": String(exact),
                                     "persisted_absent": String(persistedAbsent),
                                     "remaining_points": String(c.personal.entries[root]?.points ?? 0)])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
