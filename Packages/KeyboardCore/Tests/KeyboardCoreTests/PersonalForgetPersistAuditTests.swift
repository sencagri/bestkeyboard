import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBLearning
@testable import KBRuntime

final class PersonalForgetPersistAuditTests: XCTestCase {
    func testForgetPersistsAndExactReimportCanLearnAgain() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_FORGET_PERSIST_AUDIT"] else { throw XCTSkip("Opt-in personal forget reload audit") }
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
                        let forgot = c.forgetPersonal(forgetSurface)
                        let revoked = !c.boundaryRepairs().contains(target) && !c.isKnownPersonalInflection(form)
                        let othersRetained = roots.filter { $0 != root }.allSatisfy { c.personal.isAdmitted($0) && c.isKnownPersonalInflection($0) }
                        try PersonalLexiconStore.save(c.personal, to: directory)
                        c.replacePersonalLexicon(try PersonalLexiconStore.load(from: directory))
                        let persistedAbsent = !c.personal.isAdmitted(root) && !c.isKnownPersonalInflection(form)
                            && !c.boundaryRepairs().contains(target)
                        let reimport = c.ingestPersonal(tokens: [root, root, root])
                        let readmitted = reimport.admitted.contains(root)
                        try PersonalLexiconStore.save(c.personal, to: directory)
                        c.replacePersonalLexicon(try PersonalLexiconStore.load(from: directory))
                        let restored = c.boundaryRepairs().contains(target) && c.isKnownPersonalInflection(form)
                        rows.append(["persisted_absent": String(persistedAbsent), "readmitted": String(readmitted), "root": root, "form": form, "profile": profile, "forgot_surface": forgetSurface,
                                     "initial_offer": String(before), "forget_changed": String(forgot), "revoked": String(revoked),
                                     "others_retained": String(othersRetained), "restored": String(restored),
                                     "text_unchanged": String(doc.text == form + "baç")])
                    }
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
