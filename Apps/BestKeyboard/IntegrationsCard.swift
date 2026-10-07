import SwiftUI
import KBRuntime

struct IntegrationsCard: View {
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
                HStack(spacing: 8) {
                    SecureField("API token’ını yapıştır", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .bkField()
                    Button {
                        let t = token.trimmed
                        tokenSaved = TodoExport.setTodoistToken(t)
                        token = ""
                    } label: {
                        Text("Kaydet").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 44)
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
            BKIconRow(icon: "checkmark", tint: ok ? tint : BK.Tint(ink: BK.sub, chip: BK.line),
                      title: d.title, subtitle: note, iconSize: 38) {
                BKBadge(text: ok ? "Yüklü" : "Yüklü değil", on: ok)
            }
            .frame(minHeight: 60)
        }
    }
}
