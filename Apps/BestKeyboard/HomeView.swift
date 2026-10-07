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
                                .clipShape(RoundedRectangle(cornerRadius: BK.Radius.thumb, style: .continuous))
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
                            .background(BK.card, in: RoundedRectangle(cornerRadius: BK.Radius.button, style: .continuous))
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        ForEach(AppScreen.allCases) { screen in
                            tile(screen.title, screen.subtitle, screen.icon, screen.tint) { screen.destination(model) }
                        }
                    }

                    VStack(spacing: 0) {
                        NavigationLink { DeveloperView() } label: { linkRow("Geliştirici araçları") }
                        BKDivider()
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
                if let screen = AppScreen(rawValue: id) { screen.destination(model) } else { route(id) }
            }
        }
        .tint(BK.accent)
    }

    /// Ana sayfa bölümü olmayan adresler (`-bkScreen`): kurulum, düzenleyiciler, geliştirici ekranları.
    @ViewBuilder private func route(_ id: String) -> some View {
        switch id {
        case "kurulum": SetupView()
        case "tezgah": HarnessView()
        case "tema": ThemeEditorView(model: model)
        case "gif": GifMakerView()
        case "cikartma": StickerMakerView()
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

/// Ana sayfanın bölümleri — karo ve `-bkScreen <ad>` adresi aynı listeden
/// (önce iki ayrı listeydi: karo ve yönlendirme).
enum AppScreen: String, CaseIterable, Identifiable {
    case themes = "temalar", layout = "duzen", delete = "silme", learning = "ogrenme"
    case sound = "ses", shortcuts = "kisayol", studio = "studyo", ai = "yz"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .themes: return "Temalar"
        case .layout: return "Klavye düzeni"
        case .delete: return "Silme tuşu"
        case .learning: return "Öğrenme"
        case .sound: return "Ses ve titreşim"
        case .shortcuts: return "Kısayollar"
        case .studio: return "Stüdyo"
        case .ai: return "Yapay zeka"
        }
    }

    var subtitle: String {
        switch self {
        case .themes: return "\(ThemeSpec.presets.count) hazır tema, kendi fotoğrafın"
        case .layout: return "Tuş boyları, sayı satırı"
        case .delete: return "Basılı tutunca nasıl silsin"
        case .learning: return "Kelimelerin ve önerilerin"
        case .sound: return "Basışta ses ve titreşim"
        case .shortcuts: return "tr → 🇹🇷, lol → 😂, uygulamalar"
        case .studio: return "Videodan GIF, fotoğraftan çıkartma"
        case .ai: return "Çevir, düzelt, resim üret"
        }
    }

    var icon: String {
        switch self {
        case .themes: return "paintpalette"
        case .layout: return "keyboard"
        case .delete: return "delete.left"
        case .learning: return "lightbulb"
        case .sound: return "speaker.wave.2"
        case .shortcuts: return "bolt"
        case .studio: return "face.smiling"
        case .ai: return "sparkles"
        }
    }

    var tint: BK.Tint {
        switch self {
        case .themes, .shortcuts: return BK.pink
        case .layout: return BK.teal
        case .delete: return BK.orange
        case .learning: return BK.green
        case .sound, .ai: return BK.blue
        case .studio: return BK.purple
        }
    }

    @MainActor @ViewBuilder
    func destination(_ model: KeyboardSettingsModel) -> some View {
        switch self {
        case .themes: ThemesView(model: model)
        case .layout: LayoutSettingsView(model: model)
        case .delete: DeleteSettingsView(model: model)
        case .learning: LearningView(model: model)
        case .sound: SoundSettingsView(model: model)
        case .shortcuts: ShortcutsView(model: model)
        case .studio: StudioView()
        case .ai: AIActionsView(model: model)
        }
    }
}
