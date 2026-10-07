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
        #if DEBUG
        MakerSelfTest.runIfRequested()
        AIProbe.runIfRequested()
        HandoffSelfTest.runIfRequested()
        AILog.seedDemoIfRequested()
        AILog.prepare()
        ControlRunner.install()
        #if DEBUG
        ControlRunner.runIfRequested()
        #endif
        #endif
        #if DEBUG
        // `-islandDemo`: Dinamik Ada'yı örnek bir dikte durumuyla açar
        // (simülatörde mikrofon olmadan görmek için).
        if ProcessInfo.processInfo.arguments.contains("-islandDemo") {
            let st = DictationAttributes.ContentState(
                listening: true, runStart: Date().addingTimeInterval(-12), elapsed: 12,
                tail: "…Kadıköy'de buluşalım, sonra birlikte", done: false)
            _ = try? Activity.request(attributes: DictationAttributes(),
                                      content: ActivityContent(state: st, staleDate: nil))
        }
        #endif
    }

    /// UI testleri doğrudan tezgaha açılır — Form'da gezinmeye gerek kalmaz.
    private var isUITestHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestHarness")
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

struct ContentView: View {
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Test alanı") {
                    TextField("buraya yaz…", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Kanonik vaka") {
                    LabeledContent("Yazılacak", value: "l s l e m")
                    LabeledContent("Beklenen", value: "kalem")
                    Text("Dokunma sırasına sadık kod çözme, `işlem`'i açık farkla eler: "
                         + "`l→k` ve `s→a` komşu, `l→i` uzak.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Görünüm") {
                    NavigationLink("Klavye ayarları") { SettingsView() }
                    Text("Tema, üst sayı sırası ve ⇧ / ⌫ / boşluk genişliği — "
                         + "canlı önizlemeyle.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Dahili tezgah") {
                    NavigationLink("Klavye tezgahını aç") {
                        HarnessView()
                            .navigationTitle("Tezgah")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    Text("Uzantıyla aynı görünüm ve aynı decoder; metni proxy yerine "
                         + "kendi etiketine yazar. Uzantıyı etkinleştirmeden denemek için. "
                         + "Sağ üstteki ⚙︎ tema ve tuş ölçülerini açar — tezgahın "
                         + "ayarları kendi kopyası, uzantınınkini değiştirmez.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Yazım kaydı") {
                    // **Sorunu yaşadığın anda** kayda geçmenin kısa yolu:
                    // aklındaki cümleyi yaz, kaydet, sonra ne olduğunu anlat.
                    // Korpus akışı sıradaki prompt'u dayatıyor; buradaki dert
                    // sıradaki prompt değil, o an başına gelen şey.
                    NavigationLink("Hızlı kayıt — aklındaki cümle") {
                        QuickRecordingView()
                    }
                    NavigationLink("Kayıt oturumları") { RecordingListView() }
                    Text("Hedef cümleyi yazarken her dokunmanın koordinatı, "
                         + "klavyenin o anki adayları ve commit kararı kaydedilir. "
                         + "Kayıtlar Mac'ten `./Tools/pull-sessions.sh` ile çekilir.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Kurulum") {
                    Text("""
                    1. Ayarlar → Genel → Klavye → Klavyeler
                    2. Yeni Klavye Ekle → BestKeyboard
                    3. Test alanında 🌐 ile klavyeye geç
                    """)
                    .font(.footnote)
                }

                Section("Lisanslar") {
                    NavigationLink("Sözlük verisi lisansları") { LicensesView() }
                    Text("Sözlük verisi CC BY-SA 4.0 kaynaklardan türetilmiştir; "
                         + "atıf ve değişiklik beyanı bu ekranda.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Durum") {
                    LabeledContent("Faz", value: "-1A₁ cihaz PoC")
                    LabeledContent("Tam Erişim", value: "gerekmiyor")
                    Text("Paket uzantı bundle'ından okunuyor. App Group salt-okunur "
                         + "tüketim entitlement gerektirdiği için -1B'ye bırakıldı.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("BestKeyboard")
        }
    }
}
