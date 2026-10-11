import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class ForgottenSuggestionCallbackAuditTests: XCTestCase {
    func testForgottenSuggestionCallback() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_FORGOTTEN_CALLBACK_AUDIT"] else { throw XCTSkip("Opt-in personal forget reload audit") }
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
                        for ch in form + "baç" {
                            let index = try XCTUnwrap(layout.keyIndex(for: ch))
                            c.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: doc)
                        }
                        let target = form + " aç"
                        let before = c.boundaryRepairs().contains(target) && c.isKnownPersonalInflection(form)
                        let stale = try XCTUnwrap(c.suggestions().first { $0.surface == target })
                        let forgot = c.forgetPersonal(forgetSurface)
                        let revoked = !c.boundaryRepairs().contains(target) && !c.isKnownPersonalInflection(form)
                        let othersRetained = roots.filter { $0 != root }.allSatisfy { c.personal.isAdmitted($0) && c.isKnownPersonalInflection($0) }
                        // Mirror the extension's fresh surface lookup before dispatch.
                        let resolved = c.suggestions().first { $0.surface == stale.surface }
                        if let current = resolved {
                            try c.perform(.suggestionPick(id: current.id, surface: current.surface, origin: current.origin), touch: nil, into: doc)
                        }
                        let staleRejected = resolved == nil && doc.text == form + "baç"
                        c.replacePersonalLexicon(try PersonalLexiconStore.load(from: directory))
                        let restored = c.boundaryRepairs().contains(target) && c.isKnownPersonalInflection(form)
                        let current = try XCTUnwrap(c.suggestions().first { $0.surface == target })
                        try c.perform(.suggestionPick(id: current.id, surface: current.surface, origin: current.origin), touch: nil, into: doc)
                        rows.append(["stale_callback_rejected": String(staleRejected), "restored_pick_exact": String(doc.text == target + " "),"root": root, "form": form, "profile": profile, "forgot_surface": forgetSurface,
                                     "initial_offer": String(before), "forget_changed": String(forgot), "revoked": String(revoked),
                                     "others_retained": String(othersRetained), "restored": String(restored),
                                     "literal_source": stale.surface])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
