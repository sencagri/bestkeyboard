import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

struct LearningView: View {
    let model: KeyboardSettingsModel
    @State private var picking: [UTType]?
    @State private var importURL: URL?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var note: String?

    var body: some View {
        BKScreen("Öğrenme") {
            BKCard {
                BKSectionTitle(text: "Öneriler", color: BK.green.ink)
                BKToggleRow("Sonraki kelimeyi öner", "\"dün\" yazınca \"akşam\" gibi, senin alışkanlığınla", tint: BK.green.ink, isOn: model.binding(\.predictNext))
                BKDivider()
                BKToggleRow("Sık yazdıklarımı hatırla", "IP adresi, e-posta, kullanıcı adı — bir iki kullanımda", tint: BK.green.ink, isOn: model.binding(\.recallTokens))
            }
            BKCard {
                BKSectionTitle(text: "Yazdıklarından öğret", color: BK.green.ink)
                Button { picking = [.zip, .plainText] } label: {
                    importRow("WhatsApp sohbeti", "Sohbet › Dışa aktar › Medyasız › BestKeyboard", "bubble.left.and.bubble.right", BK.green)
                }
                BKDivider()
                Button { picking = [.json] } label: {
                    importRow("Telegram sohbeti", "Telegram Desktop'tan result.json", "paperplane", BK.blue)
                }
                BKDivider()
                Button { pasting = true } label: {
                    importRow("Metin yapıştır", "E-posta, not, ne istersen", "doc.on.clipboard", BK.purple)
                }
                if let note { Text(note).font(.footnote.weight(.semibold)).foregroundStyle(BK.green.ink) }
                Text("Sohbetlerden yalnız **senin** yazdığın satırlar okunur.")
                    .font(.footnote).foregroundStyle(BK.sub)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("Her şey telefonunda kalır", systemImage: "lock.fill")
                    .font(.headline).foregroundStyle(BK.green.ink)
                Text("Saklanan şey kelimeler ve kaç kez yazıldıkları; mesajların kendisi saklanmaz. Parola alanlarında ve 12'den fazla rakamlı şeylerde (kart, IBAN) hiçbir şey öğrenilmez. Kişisel sözlüğün klavyede ⚙︎ panelinde.")
                    .font(.subheadline)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BK.green.chip, in: RoundedRectangle(cornerRadius: BK.Radius.card, style: .continuous))
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking ?? [.data]) { r in
            if case let .success(url) = r { importURL = url }
        }
        .sheet(item: $importURL) { _ in ChatImportFlow(pendingURL: $importURL) }
        .sheet(isPresented: $pasting) {
            NavigationStack {
                TextEditor(text: $pasted).padding()
                    .navigationTitle("Metin yapıştır").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { pasting = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Öğren") {
                                do { try ChatImporter.importText(pasted); note = "Metinden öğrenildi; \(CommonText.keyboardPicksUpNext)." }
                                catch { note = error.localizedDescription }
                                pasted = ""; pasting = false
                            }
                        }
                    }
            }
        }
    }

    private func importRow(_ title: String, _ sub: String, _ icon: String, _ tint: BK.Tint) -> some View {
        HStack(spacing: 12) {
            BKIcon(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold))
                Text(sub).font(.footnote).foregroundStyle(BK.sub)
            }
            Spacer()
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}
