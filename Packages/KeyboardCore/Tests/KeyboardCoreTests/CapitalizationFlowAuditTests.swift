import XCTest
import Foundation
import KBRuntime

final class CapitalizationFlowAuditTests: XCTestCase {
    func testControllerCapitalizationOrder() throws {
        guard let path=ProcessInfo.processInfo.environment["KB_CAP_FLOW_AUDIT"] else { throw XCTSkip("Set KB_CAP_FLOW_AUDIT") }
        var rows:[[String:String]]=[]
        for (name,type) in [("allCharacters",ShiftPolicy.Autocapitalization.allCharacters),
                            ("words",.words),("sentences",.sentences),("none",.none)] {
            for locked in [false,true] {
                var shift=ShiftPolicy()
                var text=""
                shift.autoCapitalize(ShiftPolicy.shouldCapitalize(context:text,type:type))
                if locked {shift.tapShift(at:0);shift.tapShift(at:0.1)}
                for ch in "izmir istanbul" {
                    if ch == " " {
                        text.append(ch)
                        shift.didInterruptChain()
                        shift.autoCapitalize(ShiftPolicy.shouldCapitalize(context:text,type:type))
                    } else {
                        // Mirrors controller letter path: letterCommand -> didEmitLetter, no auto update.
                        if case let .letter(_,display,_) = shift.letterCommand(ch) {text += display}
                        shift.didEmitLetter()
                    }
                }
                rows.append(["mode":name,"locked":String(locked),"output":text])
            }
        }
        for context in ["", "Merhaba. ", "Merhaba! ", "Merhaba? ", "Merhaba, ",
                        "Merhaba.\" ", "Merhaba!” ", "Merhaba?» ", "“", "\"", "Merhaba. “", "Merhaba\n"] {
            rows.append(["mode":"sentence_context","context":context,
                         "capitalize":String(ShiftPolicy.shouldCapitalize(context:context,type:.sentences))])
        }
        let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys]
        try e.encode(rows).write(to:URL(fileURLWithPath:path))
        print("CAPITALIZATION FLOW AUDIT: \(rows.count) probes")
    }
}
