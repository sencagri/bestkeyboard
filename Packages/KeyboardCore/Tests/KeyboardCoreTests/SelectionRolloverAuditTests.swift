import Foundation
import Testing
import KBRuntime
import KBSessions

@MainActor
@Suite("Selection rollover audit")
struct SelectionRolloverAuditTests {
    private typealias Support = RecordingTestSupport
    private func descriptor(_ id: String) -> CanonicalSession {
        CanonicalSession(
            attemptID: id, participantID: "p", sessionOrdinal: 0,
            // Üretimde **hedef yok**: hizalama `none`, dolayısıyla kalibrasyon
            // kapısı bu kayıtları zaten eliyor.
            condition: .behavior, status: .recording,
            promptID: "production", promptText: "", promptSource: .manual,
            // **Hedef yok**, boş hedef değil.
            split: "none", promptTokens: .notApplicable,
            alignmentSource: .none,
            startedAt: Date(timeIntervalSince1970: 0),
            engine: Support.unconfigured(policy: .behavior),
            geometry: .init(layoutID: Support.layout.id,
                            layoutFingerprint: .known(Support.layout.fingerprint),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
    }


    @Test func selectionSurvivesUntilRollover() throws {
        guard let path = ProcessInfo.processInfo.environment["KB_SELECTION_ROLLOVER_AUDIT"] else { return }
        var rows: [[String: String]] = []
        for word in ["kitap", "qrmenü", "sokaktaydım"] {
            let doc = FakeDocument()
            doc.hostRewrites(to: word)
            doc.hostSelects(word)
            let recorder = try ProductionRecorder(
                makeDescriptor: { self.descriptor($0) },
                build: { writer in
                    RecordingEngine(writer: writer,
                        coordinator: InputCoordinator(layout: Support.layout), layout: Support.layout)
                },
                configure: { try Support.configure($0) },
                baseline: { (doc.contextBeforeInput ?? "") + (doc.contextAfterInput ?? "") })
            for cycle in 1...2 {
                let beforeEngine = recorder.engine
                let result = try recorder.engine.selectionChanged(doc.selectedText, into: doc)
                let before = recorder.engine.suggestionSurfaces()
                let flagged = recorder.engine.stateChangedOutsideTheLog
                // Exact ordering used by InputSession.selectionChanged: notify then rollover.
                try recorder.rollOverIfNeeded()
                let after = recorder.engine.suggestionSurfaces()
                rows.append(["input": word, "cycle": String(cycle),
                    "selection_result": result ?? "nil", "suggestions_before_rollover": before.joined(separator: " | "),
                    "suggestions_after_rollover": after.joined(separator: " | "),
                    "outside_log": String(flagged), "engine_replaced": String(beforeEngine !== recorder.engine),
                    "host_selected_after": doc.selectedText ?? "nil", "rollovers": String(recorder.rollovers)])
                #expect(before.first == word)
                #expect(doc.selectedText == word)
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(rows).write(to: URL(fileURLWithPath: path))
        print("SELECTION ROLLOVER AUDIT: \(rows.count) transitions")
    }
}
