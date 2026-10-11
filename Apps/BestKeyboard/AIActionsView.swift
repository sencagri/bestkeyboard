import SwiftUI
import KBRuntime

// Yapay zeka tuşları — tasarım tuvali 20 (liste) ve 21 (düzenleme).

private extension AIAction {
    var tint: BK.Tint {
        switch kind {
        case .image: return BK.orange
        case .reminder: return BK.green
        case .event: return BK.blue
        case .contact: return BK.teal
        case .text: return BK.purple
        }
    }
}

struct AIActionsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: KeyboardSettingsModel
    @State private var connected = AIService.isConnected
    @State private var connecting = false

    private var list: [AIAction] { model.settings.aiActions }

    var body: some View {
        BKScreen(CommonText.aiScreen) {
            serviceCard

            BKCard(padding: 16) {
                adaptiveLayout {
                    BKSectionTitle(text: "Tuşlarım · \(list.count)", color: BK.accent)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Button("Varsayılanlara dön") { model.update { $0.aiActions = AIAction.defaults } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BK.accent)
                }
                if list.isEmpty {
                    Text("Liste boş — aşağıdan yeni tuş ekle ya da varsayılanlara dön.")
                        .font(.subheadline).foregroundStyle(BK.sub)
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                    VStack(spacing: 0) {
                        BKDivider()
                        HStack(spacing: 12) {
                            NavigationLink { AIActionEditor(model: model, actionID: a.id) } label: {
                                if dynamicTypeSize.isAccessibilitySize {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(a.name).font(.subheadline.weight(.semibold))
                                        Text(subtitle(a)).font(.footnote).foregroundStyle(BK.sub)
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    BKIconRow(icon: a.icon, tint: a.tint, title: a.name, subtitle: subtitle(a), iconSize: 38)
                                }
                            }
                            .buttonStyle(.plain)
                            BKRemoveButton(label: "\(a.name) tuşunu sil") { model.update { $0.aiActions.remove(at: i) } }
                        }
                        .frame(minHeight: 60)
                    }
                }
            }

            NavigationLink("+ Yeni tuş") { AIActionEditor(model: model, actionID: nil) }
                .buttonStyle(.bkPrimary)

            IntegrationsCard()

            (Text("Klavyede araç satırındaki ✦ tuşuna bas ya da mesajın sonuna ")
             + Text("/çevir").font(.footnote.monospaced()).foregroundColor(BK.ink)
             + Text(" gibi tuşun adını yaz. Seçili metin yoksa son cümle kullanılır."))
                .font(.footnote).foregroundStyle(BK.sub).padding(.horizontal, 4)
        }
        .sheet(isPresented: $connecting, onDismiss: { connected = AIService.isConnected }) {
            AIConnectSheet()
        }
    }

    private var serviceCard: some View {
        BKCard {
            adaptiveLayout {
                Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(connected ? BK.green.ink : BK.accent, in: RoundedRectangle(cornerRadius: BK.Radius.field))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connected ? "\(AIService.provider.title) bağlı" : "Klavyede sonuç al").font(.headline)
                    Text(connected ? "Çeviri ve düzeltme sohbetten çıkmadan kartta gelir."
                                   : "İsteğe bağlı. Bağlamazsan tuşlar ChatGPT ya da Claude’u açar.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                Button {
                    connecting = true
                } label: { Text(connected ? "Değiştir" : "Bağla") }
                .buttonStyle(.bkPill(connected ? BK.line : BK.accent, text: connected ? BK.ink : BK.onAccent))
            }
        }
    }

    private var adaptiveLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private func subtitle(_ a: AIAction) -> String {
        let kind = a.kind.title + " · "
        // Hatırlatıcı / Takvim / Kişi yalnız klavyedeki kartta çalışıyor.
        if a.kind.isStructured { return kind + (connected ? "Klavyede kart" : "Servis bağlantısı gerekir") }
        if a.target == AIAction.here { return kind + (connected ? "Klavyede sonuç" : "ChatGPT'de açılır") }
        if a.target == AIAction.shortcut { return kind + "Kestirme: \(a.shortcutName ?? "?")" }
        return kind + "\(a.app?.name ?? CommonText.app)'de açılır"
    }
}

// MARK: - Bağlantılar (31)
