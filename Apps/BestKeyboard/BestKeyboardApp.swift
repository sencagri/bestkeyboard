import SwiftUI
import ActivityKit

@main
struct BestKeyboardApp: App {
    init() {
        // Uygulama ortak depoyu her zaman kullanabilir; izin (App Group)
        // bağlı değilse depo kendiliğinden yerel kalıyor.
        KeyboardSettingsStore.sharingAllowed = true
        Notifier.shared.install()
        URLOpener.open = { await UIApplication.shared.open($0) }
        URLOpener.canOpen = { UIApplication.shared.canOpenURL($0) }
        // Üretim kurulumu — **DEBUG bloğunun dışında** (önceden içinde kalmıştı:
        // yayın sürümünde Kontrol Merkezi düğmesi uygulamaya hiç bağlanmıyordu).
        AILog.prepare()
        ControlRunner.install()
        #if DEBUG
        MakerSelfTest.runIfRequested()
        AIProbe.runIfRequested()
        HandoffSelfTest.runIfRequested()
        AILog.seedDemoIfRequested()
        ControlRunner.runIfRequested()
        #endif
        #if DEBUG
        // `-islandDemo`: Dinamik Ada'yı örnek bir dikte durumuyla açar
        // (simülatörde mikrofon olmadan görmek için).
        if LaunchArgs.has("-islandDemo") {
            let st = DictationAttributes.ContentState(
                listening: true, runStart: Date().addingTimeInterval(-12), elapsed: 12,
                tail: "…Kadıköy'de buluşalım, sonra birlikte", done: false)
            _ = try? Activity.request(attributes: DictationAttributes(),
                                      content: ActivityContent(state: st, staleDate: nil))
        }
        #endif
    }

    /// Uygulama öne geldi: klavyenin ve düğmelerin bıraktıkları burada
    /// toplanıyor — öne gelişte yapılan her şey tek yerde.
    @MainActor static func didBecomeActive() {
        // Klavyenin "uygun listeyi seç"i için liste adları (izin varsa).
        Task { await ReminderMaker.refreshListNames() }
        EventMaker.refreshCalendarNames()
        Handoff.purge()
        ControlRunner.requestPhotosIfNeeded()
        ControlRunner.runPendingIfAny()
        BestKeyboardShortcuts.updateAppShortcutParameters()
        TodoDestination.refreshInstalled()
    }

    /// UI testleri doğrudan tezgaha açılır — Form'da gezinmeye gerek kalmaz.
    private var isUITestHarness: Bool {
        LaunchArgs.has("-uiTestHarness")
    }

    var body: some Scene {
        WindowGroup {
            if isUITestHarness {
                HarnessView().ignoresSafeArea(.keyboard)
            } else {
                HomeView()
            }
        }
    }
}
