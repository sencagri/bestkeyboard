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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    NavigationLink { GifMakerView() } label: {
                        bigCard("Videodan GIF", "Kes, hızlandır, yazı ekle", "video", Color(UIColor(hex: "#5B3FD0")))
                    }
                    NavigationLink { StickerMakerView() } label: {
                        bigCard("Fotoğraftan çıkartma", "Arka planı kendisi siler", "person.crop.square", Color(UIColor(hex: "#B3264E")))
                    }
                }
                .buttonStyle(.plain)

                BKCard {
                    HStack {
                        Text("Benimkiler").font(.headline)
                        Spacer()
                        Text("Klavyede 🙂 › GIF").font(.footnote).foregroundStyle(BK.sub)
                    }
                    if items.isEmpty {
                        Text("Henüz yok. Yukarıdan bir GIF ya da çıkartma yap.").font(.subheadline).foregroundStyle(BK.sub)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(items, id: \.self) { item in
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
                                Button("Sil", role: .destructive) { MediaStore.remove(item); items = MediaStore.load() }
                            }
                        }
                    }
                    Text("Hepsi telefonunda kalır. Klavyede dokununca kopyalanır; mesaj kutusuna basılı tutup Yapıştır de. Silmek için basılı tut.")
                        .font(.footnote).foregroundStyle(BK.sub)
                }
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Stüdyo")
        .onAppear { items = MediaStore.load() }
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
                    PhotosPicker(selection: $pick, matching: .videos) {
                        VStack(spacing: 10) {
                            Image(systemName: "video.badge.plus").font(.system(size: 40))
                            Text("Video seç").font(.headline)
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
                                        Text(caption.uppercased(with: Locale(identifier: "tr")))
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

                    BKCard {
                        Text("Hangi kısım").font(.headline)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                HStack(spacing: 2) {
                                    ForEach(Array(strip.enumerated()), id: \.offset) { i, im in
                                        let t = (Double(i) + 0.5) / Double(max(strip.count, 1)) * duration
                                        Image(uiImage: im).resizable().scaledToFill()
                                            .frame(maxWidth: .infinity).frame(height: 48).clipped()
                                            .opacity(t >= start && t <= start + length ? 1 : 0.35)
                                    }
                                }
                                RoundedRectangle(cornerRadius: 10).strokeBorder(BK.purple.ink, lineWidth: 3)
                                    .frame(width: g.size.width * length / max(duration, 0.1), height: 48)
                                    .offset(x: g.size.width * start / max(duration, 0.1))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .frame(height: 48)
                        BKSliderRow(title: "Başlangıç", value: sec(start), tint: BK.purple.ink,
                                    x: Binding(get: { start }, set: { start = min($0, max(0, duration - length)); updatePoster() }),
                                    range: 0...max(0.1, duration - 1), step: 0.1)
                        BKSliderRow(title: "Uzunluk", value: sec(length), tint: BK.purple.ink,
                                    x: Binding(get: { length }, set: { length = $0; start = min(start, max(0, duration - $0)) }),
                                    range: 1...max(1.1, min(6, duration)), step: 0.1)
                    }
                    BKCard {
                        Text("Hız").font(.headline)
                        Picker("Hız", selection: $speed) { ForEach(0..<3) { Text(speeds[$0].0).tag($0) } }.pickerStyle(.segmented)
                        Text("Boyut").font(.headline)
                        Picker("Boyut", selection: $size) { ForEach(0..<3) { Text(sizes[$0].0).tag($0) } }.pickerStyle(.segmented)
                        TextField("Üst yazı (ör. BU AKŞAM)", text: $caption)
                            .padding(12).background(BK.ground, in: RoundedRectangle(cornerRadius: 12))
                    }
                    HStack {
                        Text("Tahmini dosya").foregroundStyle(BK.sub)
                        Spacer()
                        Text("~" + kb(estimateKB) + (estimateKB > 4096 ? " — WhatsApp için büyük" : ""))
                            .bold().foregroundStyle(estimateKB > 4096 ? BK.orange.ink : BK.ink)
                    }
                    .font(.subheadline).padding(.horizontal, 4)
                    Button { Task { await make() } } label: {
                        Group {
                            if working { ProgressView().tint(.white) }
                            else { Text(done ?? "GIF oluştur").font(.headline) }
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 52)
                        .background(BK.purple.ink, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(working)
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

    private func sec(_ v: Double) -> String { String(format: "%.1f sn", v).replacingOccurrences(of: ".", with: ",") }
    private func kb(_ v: Double) -> String { v >= 1024 ? String(format: "%.1f MB", v / 1024).replacingOccurrences(of: ".", with: ",") : "\(Int(v)) KB" }

    private struct Movie: Transferable {
        let url: URL
        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
                let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
                try FileManager.default.copyItem(at: received.file, to: dst)
                return Movie(url: dst)
            }
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let movie = try? await item?.loadTransferable(type: Movie.self) else { return }
        await load(url: movie.url)
    }

    private func load(url: URL) async {
        let a = AVURLAsset(url: url)
        let d = (try? await a.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let gen = AVAssetImageGenerator(asset: a)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        var frames: [UIImage] = []
        for i in 0..<12 {
            let t = CMTime(seconds: (Double(i) + 0.5) / 12 * d, preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image { frames.append(UIImage(cgImage: cg)) }
        }
        asset = a; duration = d; strip = frames
        length = min(3, d); start = 0; done = nil
        updatePoster()
    }

    private func updatePoster() {
        guard let asset else { return }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 800, height: 800)
        let t = CMTime(seconds: start, preferredTimescale: 600)
        Task { if let cg = try? await gen.image(at: t).image { poster = UIImage(cgImage: cg) } }
        done = nil
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
        let text = caption.uppercased(with: Locale(identifier: "tr"))
        for i in 0..<count {
            let t = CMTime(seconds: start + Double(i) / Double(count) * length, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image else { continue }
            let img = Self.draw(caption: text, on: UIImage(cgImage: cg))
            if first == nil { first = img }
            if let c = img.cgImage { CGImageDestinationAddImage(dest, c, frameProps) }
        }
        guard CGImageDestinationFinalize(dest), let first,
              MediaStore.add(kind: .gif, data: out as Data, thumb: first) != nil else {
            done = "Kaydedilemedi"
            return
        }
        done = "Hazır ✓ — " + kb(Double(out.length) / 1024)
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
    @State private var error: String?

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
                        saved = MediaStore.add(kind: .sticker, data: png, thumb: r) != nil
                    } label: {
                        Text(saved ? "Kaydedildi ✓" : "Kaydet").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(BK.pink.ink, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(result == nil)
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
                (caption.uppercased(with: Locale(identifier: "tr")) as NSString)
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
