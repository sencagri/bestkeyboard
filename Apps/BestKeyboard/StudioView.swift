import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

// Stüdyo — tasarım tuvali 13–15. Üretilenler `MediaStore`'a (ortak klasör)
// yazılıyor; klavye 🙂 panelindeki GIF / Çıkartma sekmesinden kopyalıyor.

struct StudioView: View {
    @State private var items = MediaStore.load()
    @State private var waError: String?
    /// `nil` = Tümü.
    @State private var filter: String?
    private var shown: [MediaStore.Item] { MediaStore.filter(items, category: filter) }
    private var stickerCount: Int { shown.filter { $0.kind == .sticker }.count }
    private var gifCount: Int { shown.filter { $0.kind == .gif }.count }
    /// Kodlama sürerken satırda çark: hareketli WebP birkaç saniye sürebilir.
    @State private var busy: String?
    private var waSub: String {
        switch (stickerCount >= WhatsAppStickers.minPack, gifCount >= WhatsAppStickers.minPack) {
        case (true, true): return "Çıkartmalar + GIF'ler hareketli çıkartma"
        case (true, false): return "\(stickerCount) çıkartma · GIF'ler için en az \(WhatsAppStickers.minPack) GIF"
        case (false, true): return "GIF'ler hareketli çıkartma · çıkartma için en az \(WhatsAppStickers.minPack)"
        case (false, false): return "En az \(WhatsAppStickers.minPack) çıkartma ya da \(WhatsAppStickers.minPack) GIF lazım"
        }
    }

    /// Kodlama arka planda (30 hareketli GIF saniyeler sürebilir); pano ve
    /// açılış ana iş parçacığında. Uygulama yoksa hiç kodlanmıyor.
    private func send(_ id: String, to target: WhatsAppStickers.Target,
                      _ prepare: @escaping @Sendable () throws -> WhatsAppStickers.Delivery) {
        guard busy == nil else { return }
        guard WhatsAppStickers.canOpen(target.url) else { waError = CommonText.notInstalled(target.app); return }
        busy = id; waError = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try prepare() }
            await MainActor.run {
                do { try WhatsAppStickers.deliver(result.get()) } catch { waError = error.localizedDescription }
                busy = nil
            }
        }
    }

    private func sendWA(animated: Bool) {
        let snapshot = shown, cat = filter
        send("wa", to: .whatsApp) {
            try WhatsAppStickers.whatsAppPayload(snapshot, category: cat, animated: animated)
        }
    }

    private func target<M: View>(_ mark: String, _ color: String, _ name: String, _ sub: String,
                                 enabled: Bool, busy: Bool, @ViewBuilder menu: () -> M) -> some View {
        HStack(spacing: 12) {
            Text(mark).font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(UIColor(hex: color)), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 16, weight: .semibold))
                Text(sub).font(.caption).foregroundStyle(BK.sub)
            }
            Spacer(minLength: 4)
            if busy { ProgressView().frame(height: 36) }
            else {
                Menu { menu() } label: {
                    Text("Ekle").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Color(UIColor(hex: enabled ? color : "#8B889C")), in: Capsule())
                }
                .disabled(!enabled || self.busy != nil)
            }
        }
        .frame(minHeight: 64)
        .overlay(alignment: .top) { Divider() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    NavigationLink { GifMakerView(category: filter) } label: {
                        bigCard("Videodan GIF", "Kes, hızlandır, yazı ekle", "video", BK.purple.ink)
                    }
                    NavigationLink { StickerMakerView(category: filter) } label: {
                        bigCard("Fotoğraftan çıkartma", "Arka planı kendisi siler", "person.crop.square", BK.pink.ink)
                    }
                }
                .buttonStyle(.plain)

                CategoryPicker(selection: $filter, allowsAll: true, tint: BK.purple)
                BKCard {
                    HStack {
                        Text("Benimkiler").font(.headline)
                        Spacer()
                        Text("Klavyede 🙂 › GIF").font(.footnote).foregroundStyle(BK.sub)
                    }
                    if items.isEmpty {
                        Text("Henüz yok. Yukarıdan bir GIF ya da çıkartma yap.").font(.subheadline).foregroundStyle(BK.sub)
                    } else if shown.isEmpty, let filter {
                        Text("\"\(filter)\" boş. Bu kategori seçiliyken yaptıkların buraya gelir; eskileri taşımak için Tümü'nde basılı tut › Kategori.")
                            .font(.subheadline).foregroundStyle(BK.sub)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(shown, id: \.self) { item in
                            MediaThumb(item: item, height: 96)
                            .contextMenu {
                                if let url = MediaStore.fileURL(item) {
                                    ShareLink(item: url) { Label("Gönder (WhatsApp…)", systemImage: "square.and.arrow.up") }
                                }
                                Menu("Kategori") {
                                    ForEach(MediaStore.categories(), id: \.self) { c in
                                        Button(c) { MediaStore.setCategory(c, for: item); items = MediaStore.load() }
                                    }
                                    Button("Kategorisiz") { MediaStore.setCategory(nil, for: item); items = MediaStore.load() }
                                }
                                // Aktarım sürerken kaynak dosya silinmesin.
                                Button("Sil", role: .destructive) { MediaStore.remove(item); items = MediaStore.load() }
                                    .disabled(busy != nil)
                            }
                        }
                    }
                    Text("Hepsi telefonunda kalır. Klavyede dokununca kopyalanır; mesaj kutusuna basılı tutup Yapıştır de. Silmek için basılı tut.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }

                // Uygulamaların kendi çıkartma paneline ekle — orada tek
                // dokunuşla gönderiliyor (klavye sohbete resim koyamıyor).
                // Tasarım tuvali "Studyo": kategori başına bir paket.
                BKCard {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(filter.map { "\"\($0)\" uygulamalara ekle" } ?? "Uygulamalara ekle").font(.headline)
                        Text("Uygulamanın kendi panelinde durur, tek dokunuşla gider")
                            .font(.footnote).foregroundStyle(BK.sub)
                    }
                    target("WA", "#25D366", WhatsAppStickers.Target.whatsApp.app,
                           waSub, enabled: stickerCount >= WhatsAppStickers.minPack || gifCount >= WhatsAppStickers.minPack, busy: busy == "wa") {
                        if stickerCount >= WhatsAppStickers.minPack { Button("Çıkartmalar (\(min(stickerCount, WhatsAppStickers.maxPack)))") { sendWA(animated: false) } }
                        if gifCount >= WhatsAppStickers.minPack { Button("GIF'ler — hareketli (\(min(gifCount, WhatsAppStickers.maxPack)))") { sendWA(animated: true) } }
                    }
                    target("TG", "#2AABEE", WhatsAppStickers.Target.telegram.app,
                           stickerCount > 0 ? "\(stickerCount) çıkartma · GIF'leri Telegram almıyor" : "Önce çıkartma yap",
                           enabled: stickerCount > 0, busy: busy == "tg") {
                        Button("Çıkartmaları ekle") { send("tg", to: .telegram) { [shown] in try WhatsAppStickers.telegramPayload(shown) } }
                    }
                    if let waError { BKErrorText(waError) }
                    Text("WhatsApp'ta her kategori ayrı paket; tekrar ekleyince güncellenir. Telegram her eklemede yeni set açar.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Stüdyo")
        .onAppear { items = MediaStore.load() }
        #if DEBUG
        .task {
            // `-webpSelfTest`: WhatsApp için WebP kodlamasını dener.
            guard LaunchArgs.has("-webpSelfTest"),
                  let p = Bundle.main.path(forResource: "claude", ofType: "png"),
                  let img = UIImage(contentsOfFile: p), let w = WhatsAppStickers.webp512(img),
                  let dir = MediaStore.directory else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? w.write(to: dir.appendingPathComponent("selftest.webp"))
            if let g = items.first(where: { $0.kind == .gif }), let d = MediaStore.data(g),
               let anim = WhatsAppStickers.animatedWebP512(gif: d) {
                try? anim.write(to: dir.appendingPathComponent("selftest-anim.webp"))
            }
        }
        #endif
    }

    private func bigCard(_ title: String, _ sub: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading) {
            Image(systemName: icon).font(.system(size: 30, weight: .semibold))
            Spacer()
            Text(title).font(.headline.weight(.heavy))
            Text(sub).font(.footnote).opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - GIF

// MARK: - Çıkartma

// MARK: - Kesici
