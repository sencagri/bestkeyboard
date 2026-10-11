import XCTest
import Foundation
import KBLearning

final class TurkishImportAuditTests: XCTestCase {
    func testImportAndHistoryEdges() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_IMPORT_AUDIT"] else {
            throw XCTSkip("Set KB_IMPORT_AUDIT to capture parser diagnostics")
        }
        var rows: [[String: String]] = []
        let messages = [
            ("system_after_message", "[10.10.2026 12:00:00] Ben: selam\n10.10.2026 12:01 - Ayşe gruptan ayrıldı"),
            ("colon_in_name", "[10.10.2026 12:00:00] Ben: selam\n[10.10.2026 12:01:00] İş: Ayşe: bu benim mesajım"),
            ("narrow_space_am_pm", "[10.10.2026 12:00:00] Ben: selam\n[10/10/2026, 1:01:00\u{202F}PM] Ayşe: bu benim mesajım"),
            ("heart_text", "[10.10.2026 12:00:00] Ben: <3 çok sevdim"),
            ("ordinary_omitted_text", "[10.10.2026 12:00:00] Ben: this word was omitted by mistake"),
            ("ordinary_turkish_text", "[10.10.2026 12:00:00] Ben: toplantıya neden dahil edilmedi bilmiyorum"),
            ("multiline_control", "[10.10.2026 12:00:00] Ben: selam\nikinci satır\n[10.10.2026 12:01:00] Ayşe: merhaba")
        ]
        for (name, input) in messages {
            let parsed = ChatExportParser.whatsApp(input)
            rows.append(["case":name,"input":input,"count":String(parsed.count),
                         "parsed":parsed.map { $0.sender + " => " + $0.text }.joined(separator: "\n---\n")])
        }
        let telegram = #"{"messages":[{"from":"Ben","from_id":"user1","text":"birinci kişinin mesajı"},{"from":"Ben","from_id":"user2","text":"ikinci kişinin mesajı"}]}"#
        let parsed = ChatExportParser.telegram(Data(telegram.utf8))
        rows.append(["case":"telegram_same_display_name","input":telegram,
                     "senders":ChatExportParser.senders(parsed).joined(separator:" | "),
                     "selected_Ben_messages":String(parsed.filter { $0.sender == "Ben" }.count)])
        for word in ["ankara'da", "ankara’da", "e-posta", "e‑posta"] {
            var h = PersonalHistory()
            h.observe(text: word + " buluşalım")
            rows.append(["case":"punctuation_classification","input":word,
                         "is_word":String(PersonalHistory.isWord(word)),
                         "next_words":h.nextWords(after: word).joined(separator:" | "),
                         "recall":h.recall(prefix:String(word.prefix(3))).joined(separator:" | ")])
        }
        var old = PersonalHistory(); old.observe(text:"QRmenü")
        var fresh = PersonalHistory(); fresh.observe(text:"qrmenü")
        old.merge(fresh)
        rows.append(["case":"merge_latest_spelling","old":"QRmenü","new":"qrmenü", "output":old.tokens["qrmenü"]?.surface ?? "missing"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
        print("IMPORT AUDIT: \(rows.count) scenarios; \(output)")
    }
}
