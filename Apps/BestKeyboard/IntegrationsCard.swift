import SwiftUI
import KBRuntime

struct IntegrationsCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tokenSaved = TodoExport.todoistToken != nil
    @State private var token = ""
    @State private var installed = TodoDestination.installed

    var body: some View {
        BKCard(padding: 16) {
            BKSectionTitle(text: "Bağlantılar", color: BK.accent)
            Text("Hatırlatıcı tuşu maddeleri buralara da gönderebilir.")
                .font(.footnote).foregroundStyle(BK.sub)

            BKDivider()
            BKIconRow(icon: "square.stack.3d.up", tint: BK.pink, title: TodoDestination.todoist.title,
                      subtitle: tokenSaved ? "Token kayıtlı ✓ · Gelen Kutusu" : "Bağlı değil",
                      subtitleColor: tokenSaved ? BK.green.ink : BK.sub, iconSize: 38) {
                if tokenSaved {
                    Button {
                        TodoExport.setTodoistToken(nil)
                        tokenSaved = false
                    } label: { Text("Sil") }
                    .buttonStyle(.bkPill(BK.pink.chip, text: BK.pink.ink))
                }
            }
            if !tokenSaved {
                let formLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 8))
                formLayout {
                    SecureField("API token’ını yapıştır", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .bkField()
                    Button {
                        let t = token.trimmed
                        tokenSaved = TodoExport.setTodoistToken(t)
                        token = ""
                    } label: {
                        Text("Kaydet").font(.subheadline.weight(.bold)).foregroundStyle(BK.onAccent)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(BK.accent, in: RoundedRectangle(cornerRadius: BK.Radius.field))
                    }
                    .buttonStyle(.plain)
                    .disabled(token.trimmed.isEmpty)
                }
                Text("Todoist › Ayarlar › Entegrasyonlar › Geliştirici. Token yalnızca bu telefonun anahtarlığında durur.")
                    .font(.caption).foregroundStyle(BK.sub)
            }

            appRow(.things, note: "Liste adına göre yerleşir", tint: BK.blue)
            appRow(.ticktick, note: "Maddeler tek tek gönderilir", tint: BK.teal)
        }
        .onAppear { installed = TodoDestination.refreshInstalled() }
    }

    private func appRow(_ d: TodoDestination, note: String, tint: BK.Tint) -> some View {
        let ok = installed.contains(d)
        return VStack(spacing: 0) {
            BKDivider()
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(d.title).font(.body.weight(.semibold)).foregroundStyle(BK.ink)
                        Text(note).font(.footnote).foregroundStyle(BK.sub)
                        BKBadge(text: ok ? "Yüklü" : "Yüklü değil", on: ok)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    BKIconRow(icon: "checkmark", tint: ok ? tint : BK.Tint(ink: BK.sub, chip: BK.line),
                              title: d.title, subtitle: note, iconSize: 38) {
                        BKBadge(text: ok ? "Yüklü" : "Yüklü değil", on: ok)
                    }
                }
            }
            .frame(minHeight: 60)
        }
    }
}
