import SwiftUI

@main
struct BestKeyboardApp: App {
    /// UI testleri doğrudan tezgaha açılır — Form'da gezinmeye gerek kalmaz.
    private var isUITestHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestHarness")
    }

    var body: some Scene {
        WindowGroup {
            if isUITestHarness {
                HarnessView().ignoresSafeArea(.keyboard)
            } else {
                ContentView()
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

                Section("Dahili tezgah") {
                    NavigationLink("Klavye tezgahını aç") {
                        HarnessView()
                            .navigationTitle("Tezgah")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    Text("Uzantıyla aynı görünüm ve aynı decoder; metni proxy yerine "
                         + "kendi etiketine yazar. Uzantıyı etkinleştirmeden denemek için.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Yazım kaydı") {
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
