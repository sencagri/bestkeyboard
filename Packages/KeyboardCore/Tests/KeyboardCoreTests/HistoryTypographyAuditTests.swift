import XCTest
import Foundation
import KBLearning

final class HistoryTypographyAuditTests: XCTestCase {
    func testTypographyAndSingleLetterWords() throws {
        guard let path=ProcessInfo.processInfo.environment["KB_HISTORY_TYPOGRAPHY_AUDIT"] else {throw XCTSkip("Set KB_HISTORY_TYPOGRAPHY_AUDIT")}
        let texts=["bana merhaba dedi", "bana \"merhaba\" dedi", "bana “merhaba” dedi",
                   "bana «merhaba» dedi", "bana ‘merhaba’ dedi", "bana (merhaba) dedi",
                   "bu o", "bu odur", "o geldi", "ben o dedim", "ben onu dedim",
                   "İZMİR güzel", "İzmir güzel", "izmir güzel", "IŞIK güzel", "ışık güzel"]
        var rows:[[String:String]]=[]
        for text in texts {
            var history=PersonalHistory();history.observe(text:text)
            rows.append(["input":text,"tokens":PersonalHistory.tokenize(text).joined(separator:" | "),
                "stored_keys":history.tokens.keys.sorted().joined(separator:" | "),
                "after_bana":history.nextWords(after:"bana").joined(separator:" | "),
                "after_merhaba":history.nextWords(after:"merhaba").joined(separator:" | "),
                "after_bu":history.nextWords(after:"bu").joined(separator:" | "),
                "after_ben":history.nextWords(after:"ben").joined(separator:" | "),
                "after_o":history.nextWords(after:"o").joined(separator:" | "),
                "after_izmir":history.nextWords(after:"izmir").joined(separator:" | "),
                "after_isik":history.nextWords(after:"ışık").joined(separator:" | ")])
        }
        var mixed=PersonalHistory()
        mixed.observe(text:"bana merhaba dedi\nbana “merhaba” dedi\nbana \"merhaba\" dedi")
        rows.append(["input":"mixed_quote_variants","stored_keys":mixed.tokens.keys.sorted().joined(separator:" | "),
                     "plain_count":String(mixed.tokens["merhaba"]?.count ?? 0),
                     "curly_count":String(mixed.tokens["“merhaba”"]?.count ?? 0),
                     "curly_recall":mixed.recall(prefix:"“m").joined(separator:" | ")])
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(rows).write(to:URL(fileURLWithPath:path))
        print("HISTORY TYPOGRAPHY AUDIT: \(rows.count) cases")
    }
}
