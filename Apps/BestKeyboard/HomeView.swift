import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

// Ana uygulamanın ekranları — tasarım tuvali "BestKeyboard Uygulama
// Ekranları" ile birebir. Her bölümün kendi rengi var (tema pembe, düzen
// turkuaz, silme turuncu, öğrenme yeşil, ses mavi); gri yerine gruplanmış
// beyaz kartlar. Her ekran kendi dosyasında.

struct HomeView: View {
    @State private var model = KeyboardSettingsModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    /// WhatsApp'ın paylaşım menüsünden gelen sohbet dosyası.
    @State private var sharedFile: URL?
    /// Klavyedeki 🎤 → `bestkeyboard://dikte`.
    @State private var dictating = false
    /// ✦ kartından hatırlatıcı (`bestkeyboard://hatirlatici`).
    @State private var reminder: ReminderHandoff?
    /// ✦ kartından Takvim etkinliği / kişi (`bestkeyboard://etkinlik`, `…://kisi`).
    @State private var event: EventHandoff?
    @State private var contact: ContactHandoff?
    /// Kestirme sonucu (`bestkeyboard://kestirme-sonuc`).
    @State private var shortcutResult: ShortcutResultPayload?
    /// Ekran görüntüsü ve UI testi için: `-bkScreen silme` o ekranı açar.
    @State private var path: [String] = LaunchArgs.value("-bkScreen").map { [$0] } ?? []

    /// Klavye eklenmiş mi. iOS bunu doğrudan sormuyor; uygulamanın kendi
    /// ayar alanında görünen `AppleKeyboards` listesi yaygın kullanılan yol.
    private var keyboardAdded: Bool {
        let list = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] ?? []
        return list.contains { $0.hasPrefix(AppIdentity.bundlePrefix) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Logo tasarımı (B tuşu): simge + "Best" kalın, "Keyboard" normal.
                        HStack(spacing: 12) {
                            Image("Logo").resizable().frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityHidden(true)
                            (Text("Best").font(.system(size: 34, weight: .heavy))
                             + Text("Keyboard").font(.system(size: 34, weight: .medium)))
                                .tracking(-0.5)
                                .accessibilityLabel("BestKeyboard")
                        }
                        Text("Türkçe için akıllı klavye").foregroundStyle(BK.sub)
                    }
                    .padding(.horizontal, 4)

                    BKCard {
                        HStack {
                            Text("Klavye durumu").font(.headline)
                            Spacer()
                            NavigationLink("Kurulum") { SetupView() }.font(.subheadline.weight(.semibold))
                        }
                        statusRow(ok: keyboardAdded,
                                  title: keyboardAdded ? "Klavye eklendi" : "Klavye eklenmedi",
                                  detail: keyboardAdded ? "Uygulamalarda 🌐 ile seçebilirsin"
                                                        : "Kurulum'daki adımları izle")
                        statusRow(ok: nil, title: "Tam Erişim",
                                  detail: "Ses, titreşim, pano ve kendi temaların için açık olmalı")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        BKSectionTitle(text: "Dene", color: BK.sub).padding(.horizontal, 4)
                        TextField("Buraya yazıp klavyeyi dene…", text: $text, axis: .vertical)
                            .lineLimit(2...6)
                            .padding(14)
                            .background(BK.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        tile("Temalar", "11 hazır tema, kendi fotoğrafın", "paintpalette", BK.pink) { ThemesView(model: model) }
                        tile("Klavye düzeni", "Tuş boyları, sayı satırı", "keyboard", BK.teal) { LayoutSettingsView(model: model) }
                        tile("Silme tuşu", "Basılı tutunca nasıl silsin", "delete.left", BK.orange) { DeleteSettingsView(model: model) }
                        tile("Öğrenme", "Kelimelerin ve önerilerin", "lightbulb", BK.green) { LearningView(model: model) }
                        tile("Ses ve titreşim", "Basışta ses ve titreşim", "speaker.wave.2", BK.blue) { SoundSettingsView(model: model) }
                        tile("Kısayollar", "tr → 🇹🇷, lol → 😂, uygulamalar", "bolt", BK.pink) { ShortcutsView(model: model) }
                        tile("Stüdyo", "Videodan GIF, fotoğraftan çıkartma", "face.smiling", BK.purple) { StudioView() }
                        tile("Yapay zeka", "Çevir, düzelt, resim üret", "sparkles", BK.blue) { AIActionsView(model: model) }
                    }

                    VStack(spacing: 0) {
                        NavigationLink { DeveloperView() } label: { linkRow("Geliştirici araçları") }
                        Divider().overlay(BK.line)
                        NavigationLink { LicensesView() } label: { linkRow("Lisanslar") }
                    }
                    .background(BK.card, in: RoundedRectangle(cornerRadius: BK.Radius.card, style: .continuous))
                }
                .padding(16)
            }
            .background(BK.ground.ignoresSafeArea())
            .foregroundStyle(BK.ink)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.reload()
                    BestKeyboardApp.didBecomeActive()
                }
            }
            .onChange(of: model.settings.aiActions) { _, _ in
                // Tuş eklenip silinince Siri'nin tanıdığı liste de değişsin.
                BestKeyboardShortcuts.updateAppShortcutParameters()
            }
            .onOpenURL { url in
                switch AppRoute(url) {
                case let .sharedFile(f): sharedFile = f
                case .dictation: dictating = true
                case let .reminder(r): reminder = r
                case let .event(e): event = e
                case let .contact(c): contact = c
                case let .tickTickReturned(u): TodoRouter.tickTickReturned(u)
                case let .shortcutResult(r): shortcutResult = r
                case nil: break
                }
            }
            .sheet(item: $reminder) { r in ReminderSheet(handoff: r) }
            .sheet(item: $event) { e in EventSheet(handoff: e) }
            .sheet(item: $contact) { c in ContactSheet(handoff: c) }
            .sheet(item: $shortcutResult) { r in
                ShortcutResultSheet(result: r.result, failed: r.failed, errorMessage: r.errorMessage)
            }
            .fullScreenCover(isPresented: $dictating) { DictationView(model: model) }
            .sheet(item: $sharedFile) { _ in ChatImportFlow(pendingURL: $sharedFile) }
            .navigationDestination(for: String.self) { id in
                switch id {
                case "kurulum": SetupView()
                case "temalar": ThemesView(model: model)
                case "duzen": LayoutSettingsView(model: model)
                case "silme": DeleteSettingsView(model: model)
                case "ogrenme": LearningView(model: model)
                case "ses": SoundSettingsView(model: model)
                case "kisayol": ShortcutsView(model: model)
                case "tezgah": HarnessView()
                case "tema": ThemeEditorView(model: model)
                case "studyo": StudioView()
                case "gif": GifMakerView()
                case "cikartma": StickerMakerView()
                case "yz": AIActionsView(model: model)
                case "yzbagla": Color.clear.sheet(isPresented: .constant(true)) { AIConnectSheet() }
                case "yztus": AIActionEditor(model: model, actionID: "cevir")
                case "yzhat":
                    AIActionEditor(model: model, actionID: "hatirlatici")
                        .onAppear {
                            if !model.settings.aiActions.contains(where: { $0.id == "hatirlatici" }),
                               let r = AIAction.defaults.first(where: { $0.id == "hatirlatici" }) {
                                model.update { $0.aiActions.append(r) }
                            }
                        }
                #if DEBUG
                case "yzkart": AIPanelThemePreview()
                case "yzgunluk": AILogView()
                case "dikte": DictationView(model: model)
                case "yzbaglanti": ScrollView { IntegrationsCard().padding(16) }.background(BK.ground)
                case "yzetkinlik", "yzkisi":
                    // Düzenleme sayfaları örnek veriyle (ekran görüntüsü).
                    Color.clear.sheet(isPresented: .constant(true)) {
                        if id == "yzetkinlik" { EventSheet(handoff: .sample) } else { ContactSheet(handoff: .sample) }
                    }
                #endif
                default: DeveloperView()
                }
            }
        }
        .tint(BK.accent)
    }

    private func statusRow(ok: Bool?, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            let tint = ok == true ? BK.green : BK.orange
            Image(systemName: ok == true ? "checkmark" : (ok == false ? "xmark" : "exclamationmark"))
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(tint.ink)
                .frame(width: 32, height: 32)
                .background(tint.chip, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(BK.sub)
            }
        }
    }

    private func tile<D: View>(_ title: String, _ sub: String, _ icon: String, _ tint: BK.Tint,
                               @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink(destination: dest) {
            VStack(alignment: .leading, spacing: 10) {
                BKIcon(systemName: icon, tint: tint, size: 40)
                Spacer(minLength: 0)
                Text(title).font(.headline).foregroundStyle(BK.ink)
                Text(sub).font(.footnote).foregroundStyle(BK.sub).multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .background(BK.card, in: RoundedRectangle(cornerRadius: BK.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func linkRow(_ title: String) -> some View {
        HStack {
            Text(title).foregroundStyle(BK.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(BK.sub)
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
    }
}
