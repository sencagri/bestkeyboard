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
            HStack(spacing: 12) {
                BKIcon(systemName: "square.stack.3d.up", tint: BK.pink, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Todoist").font(.body.weight(.semibold))
                    Text(tokenSaved ? "Token kayıtlı ✓ · Gelen Kutusu" : "Bağlı değil")
                        .font(.footnote).foregroundStyle(tokenSaved ? BK.green.ink : BK.sub)
                }
                Spacer()
                if tokenSaved {
                    Button {
                        TodoExport.setTodoistToken(nil)
                        tokenSaved = false
                    } label: {
                        Text("Sil").font(.subheadline.weight(.bold)).foregroundStyle(BK.pink.ink)
                            .padding(.horizontal, 14).frame(height: 36).background(BK.pink.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !tokenSaved {
                HStack(spacing: 8) {
                    SecureField("API token’ını yapıştır", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    Button {
                        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        tokenSaved = TodoExport.setTodoistToken(t)
                        token = ""
                    } label: {
                        Text("Kaydet").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 44)
                            .background(BK.accent, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            HStack(spacing: 12) {
                BKIcon(systemName: "checkmark", tint: ok ? tint : BK.Tint(ink: BK.sub, chip: BK.line), size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.title).font(.body.weight(.semibold))
                    Text(note).font(.footnote).foregroundStyle(BK.sub)
                }
                Spacer()
                Text(ok ? "Yüklü" : "Yüklü değil").font(.footnote.weight(.bold))
                    .foregroundStyle(ok ? BK.green.ink : BK.sub)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(ok ? BK.green.chip : BK.line, in: Capsule())
            }
            .frame(minHeight: 60)
        }
    }
}
