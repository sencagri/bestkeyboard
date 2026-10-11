import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import KBLearning
import UniformTypeIdentifiers

struct LearningView: View {
    let model: KeyboardSettingsModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var personal: LearnedWordsSnapshot?
    @State private var imported: [LearnedWordRow] = []
    @State private var history: LearnedWordsSnapshot?
    @State private var picking: [UTType]?
    @State private var importURL: URL?
    @State private var pasting = false
    @State private var pasted = ""
    @State private var pasteError: String?
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
                BKSectionTitle(text: "Öğrenilen kelimeler", color: BK.green.ink)
                wordLink("Kişisel sözlüğüm", rows: personalRows,
                         detail: "Öneriden seçerek veya klavyede öğrettiğin kelimeler", available: personal != nil)
                if let personal {
                    Text("Son eşitleme: \(personal.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(BK.sub)
                } else {
                    Text("Klavye listesini burada görmek için klavyeye Tam Erişim verip bir yazı alanında aç. Öğrendiğin kelimeler klavyede saklanmaya devam eder.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }
                BKDivider()
                wordLink("İçe aktarılanlar", rows: imported,
                         detail: "WhatsApp, Telegram ve yapıştırdığın metinlerden")
                if imported.isEmpty {
                    Text("Henüz görüntülenebilen aktarım yok.").font(.footnote).foregroundStyle(BK.sub)
                }
                if let history, !history.entries.isEmpty {
                    BKDivider()
                    wordLink("Hatırlanan geçmiş", rows: history.entries.map {
                        .init(word: $0.word, source: "Yazma geçmişi", count: $0.count)
                    }, detail: "Eski aktarımlar dahil; önceki kayıtların kaynak bilgisi tutulmuyordu")
                }
                if let message = history?.note {
                    Text(message).font(.footnote).foregroundStyle(BK.orange.ink)
                }
                Text("İçe aktarılan sayımlar sonraki kelime önerileri ve hatırlama içindir. Kişisel sözlükteki kelimeler ayrıca otomatik düzeltmeden korunur.")
                    .font(.footnote).foregroundStyle(BK.sub)
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
                Button { pasteError = nil; pasting = true } label: {
                    importRow("Metin yapıştır", "E-posta, not, ne istersen", "doc.on.clipboard", BK.purple)
                }
                if let note { Text(note).font(.footnote.weight(.semibold)).foregroundStyle(BK.green.ink) }
                Text("Sohbetlerden yalnız **senin** yazdığın satırlar okunur.")
                    .font(.footnote).foregroundStyle(BK.sub)
            }
            BKCallout(title: "Her şey telefonunda kalır", icon: "lock.fill", tint: BK.green) {
                Text("Saklanan şey kelimeler ve kaç kez yazıldıkları; mesajların kendisi saklanmaz. Parola alanlarından öğrenilmez. 12'den fazla rakam içeren girdiler, geçerli IP adresleri ve + ile başlayan telefon numaraları dışında öğrenilmez. Kişisel sözlüğünü burada ve klavyedeki ⚙︎ panelinde görebilirsin.")
            }
        }
        .onAppear(perform: reloadWords)
        .onChange(of: scenePhase) { _, phase in if phase == .active { reloadWords() } }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking ?? [.data]) { r in
            if case let .success(url) = r { importURL = url }
        }
        .sheet(item: $importURL, onDismiss: reloadWords) { _ in ChatImportFlow(pendingURL: $importURL) }
        .sheet(isPresented: $pasting) {
            NavigationStack {
                VStack {
                    if let pasteError { Text(pasteError).foregroundStyle(BK.orange.ink).padding(.horizontal) }
                    TextEditor(text: $pasted).padding()
                }
                    .navigationTitle("Metin yapıştır").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { pasting = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Öğren") {
                                do {
                                    let count = try ChatImporter.importText(pasted)
                                    note = count == 0 ? "Bu metin daha önce aktarıldı; tekrar sayılmadı."
                                        : "Metin aktarım için kaydedildi; \(CommonText.keyboardPicksUpNext)."
                                    pasted = ""; pasting = false; reloadWords()
                                } catch { pasteError = error.localizedDescription }
                            }
                        }
                    }
            }
        }
    }

    private var personalRows: [LearnedWordRow] {
        (personal?.entries ?? []).map { .init(word: $0.word, source: "Kişisel sözlük", count: nil) }
    }

    private func reloadWords() {
        personal = LearnedWordsSnapshot.load(AppGroup.File.learnedWords)
        history = LearnedWordsSnapshot.load(AppGroup.File.learnedHistory)
        imported = ChatImporter.importedHistories.flatMap { source, h in
            h.tokens.values.map { LearnedWordRow(word: $0.surface, source: source, count: $0.count) }
        }.sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
        // Güncelleme öncesinde aktarılmış fakat klavyeye henüz alınmamış dosya.
        if imported.isEmpty,
           let pendingData = AppGroup.file(AppGroup.File.historyImport).flatMap({ try? Data(contentsOf: $0) }),
           let inbox = try? HistoryImportInbox.decode(pendingData) {
            imported = inbox.batches.flatMap { Array($0.history.tokens.values) }.map {
                .init(word: $0.surface, source: "Önceki aktarım", count: $0.count)
            }.sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
        }
    }

    private func wordLink(_ title: String, rows: [LearnedWordRow], detail: String, available: Bool = true) -> some View {
        NavigationLink {
            LearnedWordsList(title: title, rows: rows, onRemoveSource: title == "İçe aktarılanlar" ? { source in
                try ChatImporter.removeSource(source)
                reloadWords()
            } : nil)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(available ? "\(rows.count)" : "—").monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                Text(detail).font(.footnote).foregroundStyle(BK.sub)
                if !rows.isEmpty {
                    Text(rows.prefix(5).map(\.word).joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(BK.green.ink).lineLimit(2)
                }
            }.foregroundStyle(BK.ink).frame(minHeight: 52)
        }
        .disabled(!available)
        .accessibilityIdentifier("learning.\(title)")
    }

    private func importRow(_ title: String, _ sub: String, _ icon: String, _ tint: BK.Tint) -> some View {
        BKIconRow(icon: icon, tint: tint, title: title, subtitle: sub)
            .frame(minHeight: 52)
    }
}

private struct LearnedWordRow: Identifiable {
    let word: String
    let source: String
    let count: Int?
    var id: String { source + ":" + word }
}

private struct LearnedWordsList: View {
    let title: String
    let rows: [LearnedWordRow]
    var onRemoveSource: ((String) throws -> Void)? = nil
    @State private var query = ""
    @State private var source = "Tümü"
    @State private var removedSources: Set<String> = []
    @State private var removalError: String?

    private var sources: [String] { Array(Set(rows.map(\.source)).subtracting(removedSources)).sorted() }
    private var filtered: [LearnedWordRow] {
        rows.filter {
            !removedSources.contains($0.source) && (source == "Tümü" || $0.source == source)
                && (query.isEmpty || $0.word.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                                 locale: Locale(identifier: "tr_TR")) != nil)
        }
    }

    var body: some View {
        List {
            if let onRemoveSource, !sources.isEmpty {
                Section {
                    ForEach(sources, id: \.self) { name in
                        Button("\(name) aktarımını kaldır", role: .destructive) {
                            do {
                                try onRemoveSource(name)
                                removedSources.insert(name)
                                if source == name { source = "Tümü" }
                            } catch { removalError = error.localizedDescription }
                        }
                        .accessibilityIdentifier("learning.remove." + name)
                    }
                    if let removalError { Text(removalError).foregroundStyle(.red) }
                } footer: {
                    Text("Bir sonraki klavye açılışında yalnız bu kaynağın katkısı kaldırılır. Kendi yazdıkların, diğer kaynaklar ve eski sürümlerde kaynağı tutulmamış kayıtlar korunur.")
                }
            }
            if sources.count > 1 {
                Picker("Kaynak", selection: $source) {
                    Text("Tümü").tag("Tümü")
                    ForEach(sources, id: \.self) { Text($0).tag($0) }
                }
            }
            Section {
                ForEach(filtered) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.word).font(.body.weight(.medium))
                            Text(row.source).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let count = row.count {
                            Text("\(count) kez").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine)
                }
            } header: { Text("\(filtered.count) kayıt") }
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Henüz kelime yok" : "Kelime bulunamadı",
                                       systemImage: "text.magnifyingglass")
            }
        }
        .searchable(text: $query, prompt: "Kelime ara")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
