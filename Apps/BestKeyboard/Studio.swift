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
        switch (stickerCount >= 3, gifCount >= 3) {
        case (true, true): return "Çıkartmalar + GIF'ler hareketli çıkartma"
        case (true, false): return "\(stickerCount) çıkartma · GIF'ler için en az 3 GIF"
        case (false, true): return "GIF'ler hareketli çıkartma · çıkartma için en az 3"
        case (false, false): return "En az 3 çıkartma ya da 3 GIF lazım"
        }
    }

    /// Kodlama arka planda (30 hareketli GIF saniyeler sürebilir); pano ve
    /// açılış ana iş parçacığında. Uygulama yoksa hiç kodlanmıyor.
    private func send(_ id: String, to target: WhatsAppStickers.Target,
                      _ prepare: @escaping @Sendable () throws -> WhatsAppStickers.Delivery) {
        guard busy == nil else { return }
        guard WhatsAppStickers.canOpen(target.url) else { waError = "\(target.app) açılamadı. Yüklü mü?"; return }
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
                            ZStack(alignment: .bottomLeading) {
                                Group {
                                    if let t = MediaStore.thumbnail(item) {
                                        Image(uiImage: t).resizable().scaledToFill()
                                    } else { BK.line }
                                }
                                .frame(height: 96).frame(maxWidth: .infinity).clipped()
                                .background(item.kind == .sticker ? BK.ground : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                if item.kind == .gif {
                                    Text("GIF").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6)).padding(6)
                                }
                            }
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
                           waSub, enabled: stickerCount >= 3 || gifCount >= 3, busy: busy == "wa") {
                        if stickerCount >= 3 { Button("Çıkartmalar (\(min(stickerCount, 30)))") { sendWA(animated: false) } }
                        if gifCount >= 3 { Button("GIF'ler — hareketli (\(min(gifCount, 30)))") { sendWA(animated: true) } }
                    }
                    target("TG", "#2AABEE", WhatsAppStickers.Target.telegram.app,
                           stickerCount > 0 ? "\(stickerCount) çıkartma · GIF'leri Telegram almıyor" : "Önce çıkartma yap",
                           enabled: stickerCount > 0, busy: busy == "tg") {
                        Button("Çıkartmaları ekle") { send("tg", to: .telegram) { [shown] in try WhatsAppStickers.telegramPayload(shown) } }
                    }
                    if let waError { Text(waError).font(.footnote).foregroundStyle(BK.orange.ink) }
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
            guard ProcessInfo.processInfo.arguments.contains("-webpSelfTest"),
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

struct GifMakerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pick: PhotosPickerItem?
    @State private var asset: AVURLAsset?
    @State private var duration: Double = 0
    @State private var strip: [UIImage] = []
    @State private var poster: UIImage?
    @State private var start: Double = 0
    @State private var length: Double = 3
    @State private var speed = 1
    @State private var size = 1
    @State private var caption = ""
    @State private var working = false
    @State private var done: String?
    @State private var made: MediaStore.Item?
    @State private var category: String?
    @State private var loadingVideo = false

    /// Stüdyoda seçili kategori baştan seçili gelsin: "kedişko" süzgecindeyken
    /// yapılan GIF oraya düşmeli, kategorisiz değil.
    init(category: String? = nil) { _category = State(initialValue: category) }
    /// 0…1 — video yüklenirken ve GIF yapılırken.
    @State private var progress: Double = 0
    @State private var loadError: String?

    private let speeds: [(String, Double)] = [("0,5×", 0.5), ("1×", 1), ("2×", 2)]
    private let sizes: [(String, CGFloat)] = [("Küçük", 240), ("Orta", 360), ("Büyük", 480)]
    private let fps = 12.0

    private var estimateKB: Double {
        let long = sizes[size].1
        let w = aspect > 1 ? long / aspect : long, h = w * aspect
        return Double(w * h) * (length / speeds[speed].1 * fps) * 0.07 / 1024
    }
    private var aspect: CGFloat {
        guard let p = poster, p.size.width > 0 else { return 0.66 }
        return p.size.height / p.size.width
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if asset == nil {
                    // `.current`: video olduğu gibi geliyor. Varsayılan
                    // (`.automatic`) HEVC'yi uyumlu biçime **yeniden kodluyordu**
                    // ve uzun bir videoda dakikalarca hiçbir şey olmuyordu.
                    PhotosPicker(selection: $pick, matching: .videos, preferredItemEncoding: .current) {
                        VStack(spacing: 10) {
                            if loadingVideo {
                                ProgressView(value: progress).tint(BK.purple.ink).frame(width: 200)
                                Text("Video hazırlanıyor… %\(Int(progress * 100))").font(.headline).monospacedDigit()
                                Text("iCloud'daysa önce iniyor").font(.footnote).foregroundStyle(BK.sub)
                            } else {
                                Image(systemName: "video.badge.plus").font(.system(size: 40))
                                Text("Video seç").font(.headline)
                                if let loadError { Text(loadError).font(.footnote).foregroundStyle(BK.orange.ink) }
                            }
                        }
                        .foregroundStyle(BK.purple.ink)
                        .frame(maxWidth: .infinity, minHeight: 230)
                        .background(BK.purple.chip, in: RoundedRectangle(cornerRadius: 18))
                    }
                } else {
                    // Kare sığdırılıyor (kırpılmıyor): GIF'te ne varsa önizlemede o;
                    // yazı da GIF'teki gibi karenin üstünde.
                    Group {
                        if let poster {
                            Image(uiImage: poster).resizable().scaledToFit()
                                .overlay(alignment: .top) {
                                    if !caption.isEmpty {
                                        Text(caption.trUppercased)
                                            .font(.system(size: 24, weight: .black)).foregroundStyle(.white)
                                            .shadow(color: .black, radius: 0, x: 2, y: 2)
                                            .shadow(color: .black, radius: 0, x: -2, y: -2)
                                            .padding(.top, 10).padding(.horizontal, 8)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(height: 260).frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))

                    if let asset {
                        GifTrimmer(asset: asset, duration: duration, start: $start, length: $length,
                                   onCommit: updatePoster)
                    }
                    BKCard {
                        Text("Hız").font(.headline)
                        Picker("Hız", selection: $speed) { ForEach(0..<3) { Text(speeds[$0].0).tag($0) } }.pickerStyle(.segmented)
                        Text("Boyut").font(.headline)
                        Picker("Boyut", selection: $size) { ForEach(0..<3) { Text(sizes[$0].0).tag($0) } }.pickerStyle(.segmented)
                        Text("Kategori").font(.headline)
                        CategoryPicker(selection: $category, allowsAll: false, tint: BK.purple)
                        TextField("Üst yazı (ör. BU AKŞAM)", text: $caption)
                            .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack {
                        Text("Tahmini dosya").foregroundStyle(BK.sub)
                        Spacer()
                        Text("~" + SettingsFormat.fileSize(kb: estimateKB) + (estimateKB > 4096 ? " — WhatsApp için büyük" : ""))
                            .bold().foregroundStyle(estimateKB > 4096 ? BK.orange.ink : BK.ink)
                    }
                    .font(.subheadline).padding(.horizontal, 4)
                    Button { Task { await make() } } label: {
                        Group {
                            if working {
                                HStack(spacing: 10) {
                                    ProgressView().tint(.white)
                                    Text("GIF yapılıyor… %\(Int(progress * 100))").font(.headline).monospacedDigit()
                                }
                            }
                            else { Text(done ?? "GIF oluştur").font(.headline) }
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 52)
                        .background(BK.purple.ink, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(working)
                    if let made, let url = MediaStore.fileURL(made) {
                        ShareLink(item: url) {
                            Label("Gönder — WhatsApp, Mesajlar…", systemImage: "square.and.arrow.up")
                                .font(.headline).foregroundStyle(BK.purple.ink)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(BK.purple.chip, in: RoundedRectangle(cornerRadius: 14))
                        }
                        Text("Ya da klavyede 🙂 › GIF'ten kopyalayıp yapıştır.").font(.footnote).foregroundStyle(BK.sub)
                    }
                }
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Videodan GIF")
        .onChange(of: pick) { _, item in Task { await load(item) } }
        #if DEBUG
        // Simülatörde seçiciye dokunulamıyor: `-gifSelfTest <video>` üretim
        // yolunu uçtan uca koşturuyor.
        .task {
            let a = ProcessInfo.processInfo.arguments
            guard let i = a.firstIndex(of: "-gifSelfTest"), i + 1 < a.count else { return }
            await load(url: URL(fileURLWithPath: a[i + 1]))
            caption = "test"; start = min(5, max(0, duration - 3))
            await make()
        }
        #endif
    }


    private struct Movie: Transferable {
        let url: URL
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
                let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
                // Taşımak kopyalamaktan çok hızlı (büyük videoda saniyeler);
                // izin vermezse kopyala.
                do { try FileManager.default.moveItem(at: received.file, to: dst) }
                catch { try FileManager.default.copyItem(at: received.file, to: dst) }
                return Movie(url: dst)
            }
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loadingVideo = true; loadError = nil
        defer { loadingVideo = false }
        progress = 0
        // Tamamlama işleyicili sürüm bir `Progress` döndürüyor; yüzde ondan.
        let movie: Movie? = await withCheckedContinuation { c in
            let p = item.loadTransferable(type: Movie.self) { c.resume(returning: try? $0.get()) }
            Task { @MainActor in
                while !p.isFinished && !p.isCancelled {
                    progress = p.fractionCompleted
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
        }
        progress = 1
        guard let movie else {
            loadError = "Video açılamadı, başka bir video dene."
            return
        }
        await load(url: movie.url)
    }

    private func load(url: URL) async {
        let a = AVURLAsset(url: url)
        let d = (try? await a.load(.duration)).map(CMTimeGetSeconds) ?? 0
        // Ekran hemen açılıyor; şerit arkadan doluyor.
        asset = a; duration = d; strip = []
        length = min(3, d); start = 0; done = nil
        updatePoster()
        // Kare şeridini kesici (`GifTrimmer`) görünen aralık için kendisi çıkarıyor.
    }

    private func updatePoster() {
        guard let asset else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 800, height: 800)
        let t = CMTime(seconds: start, preferredTimescale: 600)
        Task { if let cg = try? await gen.image(at: t).image { poster = UIImage(cgImage: cg) } }
        done = nil; made = nil
    }

    private func make() async {
        guard let asset else { return }
        working = true
        defer { working = false }
        let w = sizes[size].1
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // Boyut seçimi **uzun kenar**: dikey video da yatay da aynı sınırda.
        gen.maximumSize = CGSize(width: w, height: w)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 24)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 24)
        let count = max(2, Int(length / speeds[speed].1 * fps))
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var first: UIImage?
        let text = caption.trUppercased
        progress = 0
        for i in 0..<count {
            progress = Double(i) / Double(count)
            let t = CMTime(seconds: start + Double(i) / Double(count) * length, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image else { continue }
            let img = Self.draw(caption: text, on: UIImage(cgImage: cg))
            if first == nil { first = img }
            if let c = img.cgImage { CGImageDestinationAddImage(dest, c, frameProps) }
        }
        guard CGImageDestinationFinalize(dest), let first,
              let item = MediaStore.add(kind: .gif, data: out as Data, thumb: first, category: category) else {
            done = "Kaydedilemedi"
            return
        }
        made = item
        done = "Hazır ✓ — " + SettingsFormat.fileSize(kb: Double(out.length) / 1024)
    }

    /// Üst yazı: kalın, siyah kenarlı beyaz — tasarımdaki gibi.
    static func draw(caption: String, on image: UIImage) -> UIImage {
        guard !caption.isEmpty else { return image }
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: f).image { _ in
            image.draw(at: .zero)
            let size = max(14, image.size.width * 0.085)
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size, weight: .black),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -6,
                .paragraphStyle: para,
            ]
            (caption as NSString).draw(in: CGRect(x: 8, y: size * 0.4, width: image.size.width - 16, height: size * 2.6),
                                       withAttributes: attrs)
        }
    }
}

// MARK: - Çıkartma

struct StickerMakerView: View {
    @State private var pick: PhotosPickerItem?
    @State private var original: UIImage?
    @State private var cutout: UIImage?
    @State private var removeBackground = true
    @State private var outline = true
    @State private var caption = ""
    @State private var saved = false
    @State private var savedItem: MediaStore.Item?
    @State private var category: String?
    @State private var error: String?

    init(category: String? = nil) { _category = State(initialValue: category) }

    private var result: UIImage? {
        guard let base = removeBackground ? cutout : original else { return nil }
        return StickerRenderer.compose(base, outline: outline && removeBackground, caption: caption)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Checkerboard().clipShape(RoundedRectangle(cornerRadius: 18))
                    if let result {
                        Image(uiImage: result).resizable().scaledToFit().padding(16)
                    } else {
                        PhotosPicker(selection: $pick, matching: .images) {
                            VStack(spacing: 10) {
                                Image(systemName: "photo.badge.plus").font(.system(size: 40))
                                Text("Fotoğraf seç").font(.headline)
                            }
                            .foregroundStyle(BK.pink.ink)
                        }
                    }
                }
                .frame(height: 300)
                if let error { Text(error).font(.footnote).foregroundStyle(BK.orange.ink) }

                BKCard {
                    Toggle(isOn: $removeBackground) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Arka planı sil").font(.body.weight(.semibold))
                            Text("iPhone kişiyi ya da nesneyi kendisi ayırır").font(.footnote).foregroundStyle(BK.sub)
                        }
                    }.tint(BK.pink.ink)
                    Toggle(isOn: $outline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Beyaz kenar").font(.body.weight(.semibold))
                            Text("Çıkartma gibi dursun").font(.footnote).foregroundStyle(BK.sub)
                        }
                    }.tint(BK.pink.ink)
                    Text("Kategori").font(.body.weight(.semibold))
                    CategoryPicker(selection: $category, allowsAll: false, tint: BK.pink)
                    TextField("Yazı (ör. NAPIYON)", text: $caption)
                        .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 10) {
                    PhotosPicker(selection: $pick, matching: .images) {
                        Text("Başka fotoğraf").font(.headline).foregroundStyle(BK.pink.ink)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(BK.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button {
                        guard let r = result, let png = r.pngData() else { return }
                        savedItem = MediaStore.add(kind: .sticker, data: png, thumb: r, category: category)
                        saved = savedItem != nil
                    } label: {
                        Text(saved ? "Kaydedildi ✓" : "Kaydet").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(BK.pink.ink, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(result == nil)
                }
                if saved, let item = savedItem, let url = MediaStore.fileURL(item) {
                    ShareLink(item: url) {
                        Label("Gönder — WhatsApp, Mesajlar…", systemImage: "square.and.arrow.up")
                            .font(.headline).foregroundStyle(BK.pink.ink)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(BK.pink.chip, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Fotoğraftan çıkartma")
        .onChange(of: pick) { _, item in Task { await load(item) } }
        #if DEBUG
        .task {
            let a = ProcessInfo.processInfo.arguments
            guard let i = a.firstIndex(of: "-stickerSelfTest"), i + 1 < a.count,
                  let img = UIImage(contentsOfFile: a[i + 1]) else { return }
            original = img; caption = "napıyon"
            cutout = await StickerRenderer.cutout(img)
            if cutout == nil { error = "Fotoğrafta ayrılacak bir kişi ya da nesne bulunamadı."; removeBackground = false }
            if let r = result, let png = r.pngData() { saved = MediaStore.add(kind: .sticker, data: png, thumb: r) != nil }
        }
        #endif
        .onChange(of: caption) { _, _ in saved = false }
        .onChange(of: outline) { _, _ in saved = false }
        .onChange(of: removeBackground) { _, _ in saved = false }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let data = try? await item?.loadTransferable(type: Data.self),
              let img = UIImage(data: data)?.scaled(maxSide: 1024) else { return }
        original = img; saved = false; error = nil
        cutout = await StickerRenderer.cutout(img)
        if cutout == nil { error = "Fotoğrafta ayrılacak bir kişi ya da nesne bulunamadı."; removeBackground = false }
    }
}

enum StickerRenderer {
    /// Vision ile ön planı ayırıp şeffaf, sıkıca kırpılmış bir resim üretir.
    static func cutout(_ image: UIImage) async -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        return await Task.detached {
            let req = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
            guard (try? handler.perform([req])) != nil, let obs = req.results?.first,
                  let buf = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler,
                                                         croppedToInstancesExtent: true) else { return nil }
            let ci = CIImage(cvPixelBuffer: buf)
            guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: out)
        }.value
    }

    /// Beyaz kenar (resmin kendisi sekiz yönde beyaza boyanıp altına) ve yazı.
    static func compose(_ base: UIImage, outline: Bool, caption: String) -> UIImage {
        let pad: CGFloat = outline ? max(6, base.size.width * 0.025) : 0
        let textH: CGFloat = caption.isEmpty ? 0 : base.size.width * 0.18
        let size = CGSize(width: base.size.width + pad * 2, height: base.size.height + pad * 2 + textH)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
        return UIGraphicsImageRenderer(size: size, format: f).image { ctx in
            let rect = CGRect(x: pad, y: pad, width: base.size.width, height: base.size.height)
            if outline {
                let white = base.withTintColor(.white, renderingMode: .alwaysOriginal)
                for k in 0..<16 {
                    let a = Double(k) / 16 * 2 * .pi
                    white.draw(in: rect.offsetBy(dx: cos(a) * pad, dy: sin(a) * pad))
                }
            }
            base.draw(in: rect)
            if !caption.isEmpty {
                let para = NSMutableParagraphStyle(); para.alignment = .center
                let fs = textH * 0.62
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fs, weight: .black),
                    .foregroundColor: UIColor.white, .strokeColor: UIColor.black, .strokeWidth: -6,
                    .paragraphStyle: para,
                ]
                (caption.trUppercased as NSString)
                    .draw(in: CGRect(x: 0, y: size.height - textH, width: size.width, height: textH), withAttributes: attrs)
            }
            _ = ctx
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { c, s in
            let n: CGFloat = 12
            for y in stride(from: 0, to: s.height, by: n) {
                for x in stride(from: 0, to: s.width, by: n) where (Int(x / n) + Int(y / n)) % 2 == 0 {
                    c.fill(Path(CGRect(x: x, y: y, width: n, height: n)), with: .color(BK.line))
                }
            }
        }
        .background(BK.card)
    }
}


// MARK: - Kesici

/// Tasarım tuvali "14 · GIF yapıcı": yakınlaşan kare şeridi, iki kalın
/// tutamaç (uçtan çek = başlangıç/bitiş) ve ortadan sürükleme (pencereyi
/// kaydır). Şerit yalnız görünen aralığı gösteriyor; iki parmakla ya da
/// −/+ ile yakınlaşıyor. Uzun videoda 3 saniyelik seçim ince bir çizgi
/// olmasın diye açılışta seçimin çevresindeki 20 saniye görünüyor.
struct GifTrimmer: View {
    let asset: AVURLAsset
    let duration: Double
    @Binding var start: Double
    @Binding var length: Double
    var onCommit: () -> Void

    @State private var view: Double = 0
    @State private var span: Double = 20
    @State private var frames: [UIImage] = []
    @State private var drag: (mode: Mode, start0: Double, len0: Double)?
    @State private var pinchSpan: Double?

    enum Mode { case start, end, body }
    private let handle: CGFloat = 22
    private let maxLen = 6.0, minLen = 1.0


    var body: some View {
        BKCard {
            HStack {
                Text("Hangi kısım").font(.headline)
                Spacer()
                zoomButton("minus", "Uzaklaştır") { setSpan(span * 2) }
                Text("\(Int(span.rounded())) sn görünüyor").font(.footnote).foregroundStyle(BK.sub)
                    .frame(minWidth: 96).monospacedDigit()
                zoomButton("plus", "Yakınlaştır") { setSpan(span / 2) }
            }
            GeometryReader { g in
                let W = g.size.width - handle * 2
                let x = { (t: Double) in handle + CGFloat((t - view) / span) * W }
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 2) {
                        ForEach(Array(frames.enumerated()), id: \.offset) { i, im in
                            let t = view + (Double(i) + 0.5) / Double(max(frames.count, 1)) * span
                            Image(uiImage: im).resizable().scaledToFill()
                                .frame(maxWidth: .infinity).frame(height: 64).clipped()
                                .brightness(t >= start && t <= start + length ? 0 : -0.35)
                        }
                    }
                    .frame(width: W, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .offset(x: handle, y: 4)

                    // Pencere gövdesi — ortadan sürükleyince kayar.
                    Rectangle().fill(Color.white.opacity(0.001))
                        .overlay(Rectangle().stroke(BK.purple.ink, lineWidth: 4).padding(.vertical, 2))
                        .frame(width: max(0, x(start + length) - x(start)), height: 72)
                        .offset(x: x(start))
                        .gesture(dragGesture(.body, width: W))
                        .accessibilityHidden(true)

                    grip(left: true).offset(x: x(start) - handle).gesture(dragGesture(.start, width: W))
                    grip(left: false).offset(x: x(start + length)).gesture(dragGesture(.end, width: W))
                }
                .contentShape(Rectangle())
                .simultaneousGesture(MagnifyGesture().onChanged { v in
                    if pinchSpan == nil { pinchSpan = span }
                    setSpan((pinchSpan ?? span) / v.magnification)
                }.onEnded { _ in pinchSpan = nil })
            }
            .frame(height: 72)
            HStack {
                Text(SettingsFormat.seconds(start, digits: 1)).bold().foregroundStyle(BK.purple.ink)
                Spacer()
                Text("uçlardan çek · ortadan kaydır").font(.caption).foregroundStyle(BK.sub)
                Spacer()
                Text(SettingsFormat.seconds(start + length, digits: 1)).bold().foregroundStyle(BK.purple.ink)
            }
            .font(.footnote).monospacedDigit()
        }
        .onAppear {
            span = min(duration, 20)
            view = clampView(start + length / 2 - span / 2)
        }
        .task(id: "\(Int(view * 10))-\(Int(span * 10))") { await loadFrames() }
    }

    private func grip(left: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: left ? 10 : 0, bottomLeadingRadius: left ? 10 : 0,
                               bottomTrailingRadius: left ? 0 : 10, topTrailingRadius: left ? 0 : 10)
            .fill(BK.purple.ink)
            .overlay(Capsule().fill(.white.opacity(0.85)).frame(width: 4, height: 26))
            .frame(width: handle, height: 72)
            // Dokunma alanı görünenden geniş: 44 pt.
            .contentShape(Rectangle().inset(by: -11))
            .accessibilityElement()
            .accessibilityLabel(left ? "Başlangıç" : "Bitiş")
            .accessibilityValue(SettingsFormat.seconds(left ? start : start + length, digits: 1))
            .accessibilityAdjustableAction { dir in
                let d = dir == .increment ? 0.1 : -0.1
                if left { moveStart(to: start + d) } else { length = min(maxLen, max(minLen, length + d)) }
                onCommit()
            }
    }

    private func zoomButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.headline.weight(.bold)).foregroundStyle(BK.purple.ink)
                .frame(width: 36, height: 36).background(BK.purple.chip, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func dragGesture(_ mode: Mode, width W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil { drag = (mode, start, length) }
                guard let d = drag else { return }
                let dt = Double(v.translation.width / W) * span
                switch d.mode {
                case .body:
                    start = min(max(0, d.start0 + dt), duration - length)
                case .start:
                    let end = d.start0 + d.len0
                    let s = min(max(0, d.start0 + dt), end - minLen)
                    start = max(s, end - maxLen); length = end - start
                case .end:
                    length = min(max(minLen, d.len0 + dt), min(maxLen, duration - d.start0))
                }
                followSelection()
            }
            .onEnded { _ in drag = nil; onCommit() }
    }

    private func moveStart(to s: Double) {
        let end = start + length
        start = max(0, min(s, end - minLen)); length = end - start
    }

    /// Seçim görünen aralığın dışına çıkarsa şerit onunla kayıyor.
    private func followSelection() {
        if start < view { view = clampView(start) }
        if start + length > view + span { view = clampView(start + length - span) }
    }

    private func setSpan(_ s: Double) {
        let newSpan = min(duration, max(4, s))
        let mid = start + length / 2
        span = newSpan
        view = clampView(mid - newSpan / 2)
    }

    private func clampView(_ v: Double) -> Double { max(0, min(v, duration - span)) }

    private func loadFrames() async {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 120, height: 120)
        let tol = CMTime(seconds: max(0.05, span / 30), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let n = 10
        let times = (0..<n).map { CMTime(seconds: view + (Double($0) + 0.5) / Double(n) * span, preferredTimescale: 600) }
        var out: [UIImage] = []
        for await r in gen.images(for: times) {
            if Task.isCancelled { return }
            if let cg = try? r.image { out.append(UIImage(cgImage: cg)) }
        }
        frames = out
    }
}


/// Kategori çipleri + "+ Kategori". `allowsAll`: süzgeçte "Tümü" var;
/// yapıcılarda yok (seçilmezse kategorisiz).
struct CategoryPicker: View {
    @Binding var selection: String?
    let allowsAll: Bool
    let tint: BK.Tint
    @State private var categories = MediaStore.categories()
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if allowsAll { chip("Tümü", on: selection == nil) { selection = nil } }
                ForEach(categories, id: \.self) { c in
                    chip(c, on: selection == c) { selection = (selection == c && !allowsAll) ? nil : c }
                }
                Button { adding = true } label: {
                    Text(allowsAll ? "+ Kategori" : "+ Yeni").font(.subheadline.weight(.bold))
                        .foregroundStyle(tint.ink).padding(.horizontal, 12).frame(height: 34)
                        .overlay(Capsule().strokeBorder(tint.ink, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }
                .buttonStyle(.plain)
            }
        }
        .alert("Yeni kategori", isPresented: $adding) {
            TextField("ör. Komik, Aile, İş", text: $newName)
            Button("Ekle") {
                MediaStore.addCategory(newName)
                categories = MediaStore.categories()
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { selection = categories.first { $0.caseInsensitiveCompare(n) == .orderedSame } }
                newName = ""
            }
            Button("Vazgeç", role: .cancel) { newName = "" }
        }
        .onAppear { categories = MediaStore.categories() }
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .white : tint.ink)
                .padding(.horizontal, 14).frame(height: 34)
                .background(on ? tint.ink : tint.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
