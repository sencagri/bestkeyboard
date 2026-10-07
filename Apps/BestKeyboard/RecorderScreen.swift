import SwiftUI
import UIKit
import KBGeometry
import KBSpatial
import KBDecoder
import KBAssembly
import KBRuntime
import KBLearning
import KBSessions

/// SwiftUI çubuğunun VC'ye uzanan tutamağı.
///
/// Ekranı kapatan iki eylem (`Vazgeç`, `Kaydet`) motorun sahibi olan VC'de
/// yaşıyor ve orada kalmalı: terminal frame'i yazan, dosyayı kapatan ve
/// tamamlanma koşulunu ölçen o. Çubuğun SwiftUI'da olması gerekiyor çünkü
/// `NavigationStack` sarmalanan VC'nin `navigationItem`'ını okumuyor.
@MainActor
final class RecorderHandle: ObservableObject {
    fileprivate weak var controller: RecorderViewController?

    /// Kullanıcı kapatmak istedi; **not sorulacak**.
    ///
    /// Kapatma iki adım: önce niyet, sonra not. Notu terminalden sonra yazmak
    /// mümkün değil (append-only günlükte terminal son frame), dolayısıyla
    /// deneme not alınana kadar açık kalıyor.
    @Published fileprivate(set) var pendingReason: RecordingEngine.TerminalReason?

    func requestAbort() { pendingReason = .aborted }
    func requestComplete() { pendingReason = .completed }

    /// Not alındı — deneme şimdi kapanıyor.
    func confirm(note: String) {
        guard let reason = pendingReason else { return }
        pendingReason = nil
        switch reason {
        case .aborted:  controller?.abort(note: note)
        case .completed: controller?.complete(note: note)
        case .invalid, .interrupted, .captured: break
        }
    }
}

struct RecorderView: UIViewControllerRepresentable {
    let prompt: PromptCorpus.Prompt
    let condition: CanonicalSession.Condition
    let posture: CanonicalSession.Posture
    let participantID: String
    let sessionOrdinal: Int
    let onFinish: () -> Void
    let handle: RecorderHandle

    func makeUIViewController(context: Context) -> RecorderViewController {
        let vc = RecorderViewController(
            prompt: prompt, condition: condition, posture: posture,
            participantID: participantID, sessionOrdinal: sessionOrdinal,
            onFinish: onFinish)
        handle.controller = vc
        return vc
    }
    func updateUIViewController(_ vc: RecorderViewController, context: Context) {}
}

/// Kayıt ekranı ve **çubuğu**.
///
/// Tutamak burada `@StateObject`: her sunum kendi tutamağını alıyor, yoksa
/// ikinci bir kayıt ilkinin VC'sine bağlı kalırdı.
struct RecorderScreen: View {
    let prompt: PromptCorpus.Prompt
    let condition: CanonicalSession.Condition
    let posture: CanonicalSession.Posture
    let participantID: String
    let sessionOrdinal: Int
    let onFinish: () -> Void

    @StateObject private var handle = RecorderHandle()
    @State private var note = ""

    var body: some View {
        RecorderView(prompt: prompt, condition: condition, posture: posture,
                     participantID: participantID,
                     sessionOrdinal: sessionOrdinal,
                     onFinish: onFinish, handle: handle)
            .ignoresSafeArea(.keyboard)
            .navigationTitle(condition == .calibrationReplay
                             ? "Kalibrasyon kaydı" : "Davranış kaydı")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { handle.requestAbort() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Tamamlanma koşulunu **motor** ölçüyor; düğme yalnız
                    // niyeti bildiriyor.
                    Button("Kaydet") { handle.requestComplete() }.bold()
                }
            }
            // Not **kapatmadan önce** alınıyor: append-only günlükte terminal
            // son frame ve sonrasına yazılamıyor.
            .sheet(isPresented: .init(get: { handle.pendingReason != nil },
                                      set: { if !$0 { handle.confirm(note: note) } })) {
                RecordingNoteSheet(note: $note) { handle.confirm(note: note) }
                    .interactiveDismissDisabled()
            }
    }
}
