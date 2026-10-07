import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

/// Tasarım tuvali "12 · Kısayollar": hazır doldurulmuş **tek liste**;
/// ekle, dokun-düzenle, ⊖ sil, varsayılanlara dön. Açılıp kapanan grup
/// yok — kullanıcı "her insan farklı yazar, ekleyip çıkarayım" dedi.
struct ShortcutsView: View {
    let model: KeyboardSettingsModel
    @State private var tryText = "lol"
    @State private var newTrigger = ""
    @State private var newOutput = ""
    @State private var editing: Int?
    @State private var editTrigger = ""
    @State private var editOutput = ""
    /// Yeni kısayolun çıktısı: emoji/metin, çıkartma ya da GIF (tasarım 12).
    @State private var newKind: OutKind = .text
    @State private var mediaCategory: String?
    @State private var pickedMedia: String?
    @State private var media = MediaStore.load()
    @State private var tryToast: String?

    enum OutKind: Hashable { case text, sticker, gif }
    private var mediaKind: MediaStore.Item.Kind { newKind == .gif ? .gif : .sticker }
    private var shownMedia: [MediaStore.Item] {
        MediaStore.filter(media, kind: mediaKind, category: mediaCategory)
    }
    private func mediaItem(_ id: String) -> MediaStore.Item? { media.first { $0.id == id } }

    private var list: [TextShortcut] { model.settings.shortcuts }

    private var hits: [TextShortcut] {
        ShortcutLibrary.candidates(before: tryText).flatMap { ShortcutLibrary.matches(token: $0, list: list) }
    }

    var body: some View {
        BKScreen("Kısayollar") {
            BKCard {
                Text("Yeni kısayol").font(.headline)
                BKFieldLabel("Yazınca")
                TextField("ör. kedi", text: $newTrigger)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    .bkField()
                BKFieldLabel("Çıktı")
                Picker("Çıktı", selection: $newKind) {
                    Text("Emoji / metin").tag(OutKind.text)
                    Text("Çıkartma").tag(OutKind.sticker)
                    Text("GIF").tag(OutKind.gif)
                }
                .pickerStyle(.segmented)
                .onChange(of: newKind) { _, _ in pickedMedia = nil }
                if newKind == .text {
                    TextField("emoji ya da metin", text: $newOutput)
                        .bkField()
                } else {
                    CategoryPicker(selection: $mediaCategory, allowsAll: true, tint: BK.pink)
                    if shownMedia.isEmpty {
                        HStack(spacing: 4) {
                            Text("Bu kategoride \(newKind == .gif ? "GIF" : "çıkartma") yok —").foregroundStyle(BK.sub)
                            NavigationLink("Stüdyoda yap") { StudioView() }
                        }
                        .font(.subheadline)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(shownMedia, id: \.id) { item in
                            let on = pickedMedia == item.id
                            Button { pickedMedia = item.id } label: {
                                MediaThumb(item: item, height: 72)
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? BK.accent : .clear, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.kind == .gif ? "GIF seç" : "Çıkartma seç")
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                Button {
                    let made = newKind == .text
                        ? TextShortcut.text(trigger: newTrigger, output: newOutput)
                        : pickedMedia.flatMap { TextShortcut.media(trigger: newTrigger, id: $0, gif: newKind == .gif) }
                    guard let sc = made else { return }
                    model.update { $0.shortcuts.insert(sc, at: 0) }
                    tryText = sc.trigger; newTrigger = ""; newOutput = ""; pickedMedia = nil
                } label: { Text("+ Ekle") }
                .buttonStyle(.bkPrimary)
            }

            BKCard {
                Text("Dene").font(.subheadline).foregroundStyle(BK.sub)
                TextField("lol, tr, :D…", text: $tryText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .bkField()
                // Öneri çubuğunun kopyası: ilk yuva kısayol (tasarım 12).
                HStack(spacing: 4) {
                    Button {
                        guard let h = hits.first else { return }
                        if h.isMedia, let item = mediaItem(h.output) {
                            _ = MediaStore.copyToPasteboard(item)
                            tryToast = PasteHint.placed
                        } else {
                            tryToast = "“\(h.trigger)” yerine \(h.output) yazıldı"
                        }
                    } label: {
                        Group {
                            if let h = hits.first {
                                if h.isMedia, let item = mediaItem(h.output) {
                                    MediaThumb(item: item, height: 32, radius: 6).frame(width: 48)
                                } else {
                                    Text(h.output).font(TextShortcut.looksLikeEmoji(h.output) ? .title2 : .subheadline.weight(.bold))
                                        .lineLimit(1)
                                }
                            } else {
                                Text(tryText.isEmpty ? " " : tryText).foregroundStyle(BK.ink)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(hits.isEmpty ? Color.clear : BK.card, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    Text("akşam").frame(maxWidth: .infinity)
                    Text("yarın").frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 4).frame(height: 48)
                .background(Color(UIColor(hex: "#DCDDE3")), in: RoundedRectangle(cornerRadius: 12))
                .environment(\.colorScheme, .light)
                if let tryToast {
                    Text(tryToast).font(.subheadline).foregroundStyle(.white)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(UIColor(hex: "#2C2C2E")), in: RoundedRectangle(cornerRadius: 12))
                        .task(id: tryToast) {
                            try? await Task.sleep(for: .seconds(2.6))
                            self.tryToast = nil
                        }
                }
                Text("Öneri çubuğunun ilk yuvası. Çıkartma ve GIF klavyeden mesaja konamıyor; dokununca panoya kopyalanır.")
                    .font(.caption).foregroundStyle(BK.sub)
            }

            BKCard(padding: 16) {
                HStack {
                    BKSectionTitle(text: "Kısayollarım · \(list.count)", color: BK.pink.ink)
                    Spacer()
                    Button("Varsayılanlara dön") { model.update { $0.shortcuts = ShortcutLibrary.defaultList } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BK.accent)
                }
                if list.isEmpty {
                    Text("Liste boş — yukarıdan ekle ya da varsayılanlara dön.").font(.subheadline).foregroundStyle(BK.sub)
                }
                ForEach(Array(list.enumerated()), id: \.offset) { i, sc in
                    VStack(spacing: 0) {
                        BKDivider()
                        HStack(spacing: 10) {
                            Button {
                                editing = i; editTrigger = sc.trigger; editOutput = sc.output
                            } label: {
                                HStack(spacing: 10) {
                                    Text(sc.trigger).font(.body.monospaced()).foregroundStyle(BK.sub)
                                        .frame(minWidth: 84, alignment: .leading)
                                    Text("→").foregroundStyle(BK.sub)
                                    if sc.isMedia {
                                        if let item = mediaItem(sc.output) {
                                            MediaThumb(item: item, height: 34, radius: 7).frame(width: 48)
                                        }
                                        Text(sc.kind == .gif ? "GIF" : "Çıkartma").font(.footnote).foregroundStyle(BK.sub)
                                    } else {
                                        Text(sc.output).font(TextShortcut.looksLikeEmoji(sc.output) ? .title3 : .subheadline)
                                            .foregroundStyle(BK.ink).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(sc.trigger), \(sc.isMedia ? (sc.kind == .gif ? "GIF" : "çıkartma") : sc.output), düzenle")
                            BKRemoveButton(label: "\(sc.trigger) kısayolunu sil") { model.update { $0.shortcuts.remove(at: i) } }
                        }
                        .frame(minHeight: 52)
                    }
                }
                Text("Dokun: düzenle · ⊖: sil. Kısayol kendiliğinden değişmez; öneri olarak çıkar.")
                    .font(.footnote).foregroundStyle(BK.sub)
            }

            BKCard {
                BKSectionTitle(text: "Çubuktaki uygulamalar", color: BK.accent)
                Text("Seçili metinle ya da panodakiyle açılır. En çok \(KeyboardSettings.maxBarApps).").font(.footnote).foregroundStyle(BK.sub)
                ForEach(AIApp.all, id: \.id) { app in
                    let on = model.settings.aiApps.contains(app.id)
                    Toggle(isOn: Binding(get: { on }, set: { v in
                        model.update { s in
                            if v, !s.aiApps.contains(app.id), s.aiApps.count < KeyboardSettings.maxBarApps { s.aiApps.append(app.id) }
                            if !v { s.aiApps.removeAll { $0 == app.id } }
                        }
                    })) {
                        HStack(spacing: 12) {
                            appIcon(app.icon).frame(width: 34, height: 34)
                            Text(app.name).font(.body.weight(.semibold))
                        }
                    }
                    .tint(BK.accent)
                }
            }
        }
        .onAppear {
            media = MediaStore.load()
            #if DEBUG
            // `-kisayolDemo`: tasarım 12'yi ekran görüntüsüyle karşılaştırmak için.
            if LaunchArgs.has("-kisayolDemo"),
               let st = media.first(where: { $0.kind == .sticker }) {
                if !list.contains(where: { $0.isMedia }) {
                    model.update { $0.shortcuts.insert(TextShortcut(trigger: "kedi", output: st.id, kind: .sticker), at: 0) }
                }
                newKind = .sticker; newTrigger = "miyav"; tryText = "kedi"
                DispatchQueue.main.async { pickedMedia = st.id }
            }
            #endif
        }
        .alert("Kısayolu düzenle", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("yazınca", text: $editTrigger).textInputAutocapitalization(.never)
            // Çıkartma/GIF kısayolunda yalnız tetikleyici düzenleniyor.
            if let i = editing, i < list.count, !list[i].isMedia {
                TextField("çıktı", text: $editOutput)
            }
            Button("Kaydet") {
                if let i = editing, i < list.count, !editTrigger.isEmpty {
                    if list[i].isMedia {
                        model.update { $0.shortcuts[i].trigger = editTrigger.trimmed }
                    } else if let sc = TextShortcut.text(trigger: editTrigger, output: editOutput) {
                        model.update { $0.shortcuts[i] = sc }
                    }
                }
                editing = nil
            }
            Button("Vazgeç", role: .cancel) { editing = nil }
        }
    }
}
