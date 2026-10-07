import SwiftUI
import KBRuntime

/// `bestkeyboard://kestirme-sonuc?result=…` — Kestirme bitti; sonuç panoya.
struct ShortcutResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let result: String?
    let failed: Bool
    /// Kestirmeler'in `x-error` ile eklediği açıklama.
    var errorMessage: String? = nil
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                BKCard {
                    Text(failed ? "Kestirme çalışmadı" : (result?.isEmpty == false ? "Sonuç panoya kondu" : "Kestirme bitti"))
                        .font(.headline)
                    if failed {
                        if let errorMessage, !errorMessage.isEmpty {
                            Text(errorMessage).font(.subheadline).foregroundStyle(BK.orange.ink)
                        }
                        Text("Kestirmenin adını Kestirmeler uygulamasındakiyle aynı yazdığından emin ol: \(CommonText.aiScreen) › tuş › Kestirmenin adı.")
                            .font(.footnote).foregroundStyle(BK.sub)
                    } else if let result, !result.isEmpty {
                        Text(result).font(.subheadline).foregroundStyle(BK.sub).lineLimit(6)
                        Text("\(CommonText.backToChat); mesaj kutusuna \(PasteHint.howTo).")
                            .font(.footnote).foregroundStyle(BK.sub)
                    } else {
                        Text("Kestirme bir sonuç döndürmedi. \(CommonText.backToChat).")
                            .font(.footnote).foregroundStyle(BK.sub)
                    }
                }
                Spacer()
            }
            .padding(16)
            .foregroundStyle(BK.ink)
            .bkScreen("Kestirme")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
        }
        .onAppear { if let result, !result.isEmpty, !failed { UIPasteboard.general.string = result } }
    }
}

struct ShortcutResultPayload: Identifiable {
    let id = UUID()
    let result: String?
    let failed: Bool
    var errorMessage: String? = nil
}
