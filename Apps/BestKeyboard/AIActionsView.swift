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
    let model: KeyboardSettingsModel
    @State private var connected = AIService.isConnected
    @State private var connecting = false

    private var list: [AIAction] { model.settings.aiActions }

    var body: some View {
        BKScreen(CommonText.aiScreen) {
            serviceCard

            BKCard(padding: 16) {
                HStack {
                    BKSectionTitle(text: "Tuşlarım · \(list.count)", color: BK.accent)
                    Spacer()
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
                                HStack(spacing: 12) {
                                    BKIcon(systemName: a.icon, tint: a.tint, size: 38)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(a.name).font(.body.weight(.semibold)).foregroundStyle(BK.ink)
                                        Text(subtitle(a)).font(.footnote).foregroundStyle(BK.sub)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
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
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(connected ? BK.green.ink : BK.accent, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(connected ? "\(AIService.provider.title) bağlı" : "Klavyede sonuç al").font(.headline)
                    Text(connected ? "Çeviri ve düzeltme sohbetten çıkmadan kartta gelir."
                                   : "İsteğe bağlı. Bağlamazsan tuşlar ChatGPT ya da Claude’u açar.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }
                Spacer(minLength: 4)
                Button {
                    connecting = true
                } label: {
                    Text(connected ? "Değiştir" : "Bağla").font(.subheadline.weight(.bold))
                        .foregroundStyle(connected ? BK.ink : .white)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(connected ? BK.line : BK.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
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
