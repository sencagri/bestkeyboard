import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

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
        BKScreen("Fotoğraftan çıkartma") {
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
            if let error { BKErrorText(error) }

            BKCard {
                BKToggleRow("Arka planı sil", "iPhone kişiyi ya da nesneyi kendisi ayırır", tint: BK.pink.ink, isOn: $removeBackground)
                BKToggleRow("Beyaz kenar", "Çıkartma gibi dursun", tint: BK.pink.ink, isOn: $outline)
                Text("Kategori").font(.body.weight(.semibold))
                CategoryPicker(selection: $category, allowsAll: false, tint: BK.pink)
                TextField("Yazı (ör. NAPIYON)", text: $caption)
                    .bkField()
            }
            HStack(spacing: 10) {
                PhotosPicker(selection: $pick, matching: .images) { Text("Başka fotoğraf") }
                    .buttonStyle(.bkCard(BK.pink.ink))
                Button {
                    guard let r = result, let png = r.pngData() else { return }
                    savedItem = MediaStore.add(kind: .sticker, data: png, thumb: r, category: category)
                    saved = savedItem != nil
                } label: { Text(saved ? "Kaydedildi ✓" : "Kaydet") }
                .buttonStyle(.bkPrimary(BK.pink.ink))
                .disabled(result == nil)
            }
            if saved, let item = savedItem, let url = MediaStore.fileURL(item) {
                SendLink(url: url, tint: BK.pink)
            }
        }
        .onChange(of: pick) { _, item in Task { await load(item) } }
        #if DEBUG
        .task {
            guard let path = LaunchArgs.value("-stickerSelfTest"), let img = UIImage(contentsOfFile: path) else { return }
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
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in
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
        }
    }
}
