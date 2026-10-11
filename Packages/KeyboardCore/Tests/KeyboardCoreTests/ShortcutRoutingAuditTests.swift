import XCTest
import Foundation
import KBRuntime
import KBGeometry

/// UI routing model: production candidates implementation copied verbatim below;
/// application follows closeComposition -> deleteTrailing -> insertAtBoundary.
/// Not an on-device UI test.
final class ShortcutRoutingAuditTests: XCTestCase {
    func testRoutingEdges() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_SHORTCUT_AUDIT"] else {
            throw XCTSkip("Set KB_SHORTCUT_AUDIT to export observations")
        }
        var rows: [[String:String]] = []
        for (text, selected, trigger, output) in [
            ("tr", "", "tr", "🇹🇷"),
            ("trXYZ", "XYZ", "tr", "🇹🇷"),
            ("önce trXYZ", "XYZ", "tr", "🇹🇷"),
            ("iyi ki doğdun", "", "iyi ki doğdun", "🎂"),
            ("iyi  ki doğdun", "", "iyi ki doğdun", "🎂"),
            ("iyi\nki doğdun", "", "iyi ki doğdun", "🎂"),
            ("iyi\tki doğdun", "", "iyi ki doğdun", "🎂"),
            ("iyi\u{00A0}ki doğdun", "", "iyi ki doğdun", "🎂")
        ] {
            let doc = FakeDocument(); doc.hostRewrites(to:text)
            var c = InputCoordinator(layout:TurkishQ.layout())
            if !selected.isEmpty { doc.hostSelects(selected); c.handleSelection(doc.selectedText, into:doc) }
            let offered = AuditShortcutCandidates.candidates(before:doc.contextBeforeInput ?? "").contains(trigger)
            var applied = false
            if offered {
                c.invalidateComposing() // InputSession.closeComposition, no document mutation
                if doc.contextBeforeInput?.hasSuffix(trigger) == true {
                    for _ in 0..<trigger.count { c.backspaceTap(into:doc) }
                    c.insertText(output, into:doc)
                    applied = true
                }
            }
            rows.append(["input":text,"selected":selected,"trigger":trigger,
                         "offered":String(offered),"applied":String(applied),"output":doc.text])
        }
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(rows).write(to:URL(fileURLWithPath:path))
        print("SHORTCUT AUDIT: \(rows.count) scenarios")
    }
}
private enum AuditShortcutCandidates {
    static func candidates(before context: String) -> [String] {
        let words = context.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let last = words.last, !context.hasSuffix(" "), !context.hasSuffix("\n") else { return [] }
        var out = [String(last)]
        if words.count >= 2 { out.append(words.suffix(2).joined(separator: " ")) }
        if words.count >= 3 { out.append(words.suffix(3).joined(separator: " ")) }
        return out
    }
}
