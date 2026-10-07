import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

struct GifMakerView: View {
    @State private var pick: PhotosPickerItem?
    @State private var asset: AVURLAsset?
    @State private var duration: Double = 0
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
        BKScreen("Videodan GIF") {
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
                            if let loadError { BKErrorText(loadError) }
                        }
                    }
                    .foregroundStyle(BK.purple.ink)
                    .frame(maxWidth: .infinity, minHeight: 230)
                    .background(BK.purple.chip, in: RoundedRectangle(cornerRadius: BK.Radius.card))
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
                            .clipShape(RoundedRectangle(cornerRadius: BK.Radius.field))
                    }
                }
                .frame(height: 260).frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: BK.Radius.card))

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
                        .bkField()
                }
                HStack {
                    Text("Tahmini dosya").foregroundStyle(BK.sub)
                    Spacer()
                    Text("~" + SettingsFormat.fileSize(kb: estimateKB) + (estimateKB > WhatsAppStickers.largeGifKB ? " — WhatsApp için büyük" : ""))
                        .bold().foregroundStyle(estimateKB > WhatsAppStickers.largeGifKB ? BK.orange.ink : BK.ink)
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
                        else { Text(done ?? "GIF oluştur") }
                    }
                }
                .buttonStyle(.bkPrimary(BK.purple.ink))
                .disabled(working)
                if let made, let url = MediaStore.fileURL(made) {
                    SendLink(url: url, tint: BK.purple)
                    Text("Ya da klavyede 🙂 › GIF'ten kopyalayıp yapıştır.").font(.footnote).foregroundStyle(BK.sub)
                }
            }
        }
        .onChange(of: pick) { _, item in Task { await load(item) } }
        #if DEBUG
        // Simülatörde seçiciye dokunulamıyor: `-gifSelfTest <video>` üretim
        // yolunu uçtan uca koşturuyor.
        .task {
            guard let path = LaunchArgs.value("-gifSelfTest") else { return }
            await load(url: URL(fileURLWithPath: path))
            caption = "test"; start = min(5, max(0, duration - 3))
            await make()
        }
        #endif
    }


    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loadingVideo = true; loadError = nil
        defer { loadingVideo = false }
        progress = 0
        // Tamamlama işleyicili sürüm bir `Progress` döndürüyor; yüzde ondan.
        let movie: PickedMovie? = await withCheckedContinuation { c in
            let p = item.loadTransferable(type: PickedMovie.self) { c.resume(returning: try? $0.get()) }
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
        asset = a; duration = d
        length = min(3, d); start = 0; done = nil
        updatePoster()
        // Kare şeridini kesici (`GifTrimmer`) görünen aralık için kendisi çıkarıyor.
    }

    private func updatePoster() {
        guard let asset else { return }
        let gen = VideoFrames.generator(asset, maxSide: 800)
        let t = VideoFrames.time(start)
        Task { if let cg = try? await gen.image(at: t).image { poster = UIImage(cgImage: cg) } }
        done = nil; made = nil
    }

    private func make() async {
        guard let asset else { return }
        working = true
        defer { working = false }
        let count = max(2, Int(length / speeds[speed].1 * fps))
        progress = 0
        guard let gif = await GifEncoder.encode(asset, start: start, length: length, frames: count, fps: fps,
                                                maxSide: sizes[size].1, caption: caption, progress: { progress = $0 }),
              let item = MediaStore.add(kind: .gif, data: gif.data, thumb: gif.first, category: category) else {
            done = "Kaydedilemedi"
            return
        }
        made = item
        done = "Hazır ✓ — " + SettingsFormat.fileSize(kb: Double(gif.data.count) / 1024)
    }
}
