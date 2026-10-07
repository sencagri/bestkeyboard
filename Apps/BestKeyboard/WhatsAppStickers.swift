import UIKit
import ImageIO
import libwebp

/// Stüdyo çıkartmalarını **WhatsApp'ın kendi çıkartma paneline** ekler.
///
/// Klavye sohbete resim koyamıyor (iOS izin vermiyor); bu yol çıkartmayı
/// WhatsApp'ın içine taşıyor ve orada tek dokunuşla gönderiliyor.
///
/// WhatsApp'ın üçüncü taraf çıkartma protokolü: paket JSON olarak panoya
/// `net.whatsapp.third-party.sticker-pack` türüyle konuyor (yalnız bu
/// cihazda, 60 sn), sonra `whatsapp://stickerPack` açılıyor; WhatsApp
/// "Ekle" diye soruyor. Aynı kimlikle tekrar göndermek paketi güncelliyor.
///
/// Koşullar (WhatsApp): 3–30 çıkartma; her biri 512×512 WebP, ≤100 KB;
/// her birine en az bir emoji; paket simgesi 96×96 PNG, ≤50 KB. iOS
/// görüntü kütüphanesi WebP yazamıyor — `libwebp` bunun için.
enum WhatsAppStickers {
    enum Failure: LocalizedError {
        case tooFew(Int), encode, noApp(String), notAnimated, animTooLarge, tooLarge
        var errorDescription: String? {
            switch self {
            case let .tooFew(n): return "WhatsApp en az \(WhatsAppStickers.minPack) çıkartma istiyor; şu an \(n) tane var."
            case .encode: return "Çıkartmalar hazırlanamadı."
            case let .noApp(n): return CommonText.notInstalled(n)
            case .notAnimated: return "Bir GIF tek kareden oluşuyor; hareketli çıkartma olamaz."
            case .animTooLarge: return "Bir GIF WhatsApp'ın 500 KB sınırına sığmadı; daha kısa kes."
            case .tooLarge: return "Bir çıkartma Telegram'ın 512 KB sınırına sığmadı."
            }
        }
    }

    static let identifier = AppIdentity.id("studio")
    /// WhatsApp paketi: en az / en çok çıkartma; bundan büyük GIF uyarılıyor (KB).
    static let minPack = 3
    static let maxPack = 30
    static let largeGifKB: Double = 4096

    /// Her kategori WhatsApp'ta **ayrı bir paket** (kimlik kategoriden).
    /// `animated`: GIF'ler hareketli çıkartma paketi olarak — WhatsApp bir
    /// pakette durağan ve hareketliyi karıştırmaya izin vermiyor.
    ///
    /// İki parça: `whatsAppPayload` ağır işi (kodlama) yapıyor ve arka planda
    /// çağrılmalı; `deliver` pano + açılış, ana iş parçacığında.
    static func whatsAppPayload(_ items: [MediaStore.Item], category: String? = nil,
                                animated: Bool = false) throws -> Delivery {
        let kind: MediaStore.Item.Kind = animated ? .gif : .sticker
        let stickers = Array(items.filter { $0.kind == kind }.prefix(maxPack))
        guard stickers.count >= minPack else { throw Failure.tooFew(stickers.count) }
        var list: [[String: Any]] = []
        var trayImage: UIImage?
        for item in stickers { try autoreleasepool {
            guard let data = MediaStore.data(item) else { throw Failure.encode }
            let webp: Data?
            if animated {
                webp = animatedWebP512(gif: data)
                if trayImage == nil { trayImage = MediaStore.thumbnail(item) }
            } else {
                let img = UIImage(data: data)
                webp = img.flatMap(webp512)
                if trayImage == nil { trayImage = img }
            }
            guard let webp else {
                guard animated else { throw Failure.encode }
                let frames = CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
                throw frames < 2 ? Failure.notAnimated : Failure.animTooLarge
            }
            list.append(["image_data": webp.base64EncodedString(), "emojis": ["😀"]])
        } }
        guard let tray = trayImage.flatMap(trayPNG) else { throw Failure.encode }
        let json: [String: Any] = [
            "identifier": identifier + "." + slug(category ?? "tumu") + (animated ? ".gif" : ""),
            "name": (category.map { "BestKeyboard · \($0)" } ?? "BestKeyboard") + (animated ? " · GIF" : ""),
            "publisher": "BestKeyboard",
            "tray_image": tray.base64EncodedString(),
            "animated_sticker_pack": animated,
            "ios_app_store_link": "",
            "android_play_store_link": "",
            "stickers": list,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: json) else { throw Failure.encode }
        return Delivery(type: "net.whatsapp.third-party.sticker-pack", payload: payload,
                        url: Target.whatsApp.url, app: Target.whatsApp.app)
    }

    /// Çıkartmaların gittiği uygulama: açılış adresi ve adı — yalnız burada.
    struct Target: Sendable {
        let url: String
        let app: String
        static let whatsApp = Target(url: "whatsapp://stickerPack", app: "WhatsApp")
        static let telegram = Target(url: "tg://importStickers", app: "Telegram")
    }

    struct Delivery: Sendable {
        let type: String, payload: Data, url: String, app: String
    }

    /// Önce uygulama var mı bakılıyor: yoksa kullanıcının panosu boşuna
    /// silinmesin.
    @MainActor static func canOpen(_ url: String) -> Bool {
        URL(string: url).map(URLOpener.canOpen) ?? false
    }

    @MainActor static func deliver(_ d: Delivery) throws {
        guard let url = URL(string: d.url), URLOpener.canOpen(url) else {
            throw Failure.noApp(d.app)
        }
        UIPasteboard.general.setItems([[d.type: d.payload]],
                                      options: [.localOnly: true,
                                                .expirationDate: Date().addingTimeInterval(60)])
        URLOpener.launch(url)
    }

    /// Paket kimliği için: harf/rakam dışını at, Türkçe harfleri sadeleştir.
    static func slug(_ s: String) -> String {
        let folded = s.trFolded.replacingOccurrences(of: "ı", with: "i")
        let out = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        // `hashValue` her açılışta değişiyor; sabit kimlik için skalerlerin
        // toplamı (aynı ad → aynı paket).
        let stable = s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 }
        return out.isEmpty ? "k\(stable)" : String(String.UnicodeScalarView(out)).lowercased()
    }

    // MARK: - Telegram

    /// Telegram'ın "Import Stickers" protokolü: set JSON olarak panoya
    /// `org.telegram.third-party.stickerset` türüyle konuyor (yalnız bu
    /// cihazda, 60 sn) ve `tg://importStickers` açılıyor; Telegram yeni set
    /// adını sorup **yeni** bir set olarak ekliyor (güncelleme yok). Durağan
    /// çıkartmalar 512 px PNG; 512 KB'yi aşan WebP'ye düşüyor.
    ///
    /// Hareketli Telegram çıkartması WEBM (VP9) istiyor; iOS'ta VP9 kodlayıcı
    /// yok, o yüzden GIF'ler buraya girmiyor.
    static func telegramPayload(_ items: [MediaStore.Item]) throws -> Delivery {
        let stickers = Array(items.filter { $0.kind == .sticker }.prefix(120))
        guard !stickers.isEmpty else { throw Failure.tooFew(0) }
        // Sessiz kayıp yok: bir öğe hazırlanamazsa bütün aktarım duruyor.
        let list: [[String: Any]] = try stickers.map { item in
            guard let d = MediaStore.data(item), let img = UIImage(data: d) else { throw Failure.encode }
            if let png = png512(img), png.count <= 512 * 1024 {
                return ["data": png.base64EncodedString(), "mimeType": "image/png", "emojis": ["😀"]]
            }
            guard let webp = webp512(img) else { throw Failure.tooLarge }
            return ["data": webp.base64EncodedString(), "mimeType": "image/webp", "emojis": ["😀"]]
        }
        let json: [String: Any] = ["software": "BestKeyboard", "isAnimated": false, "type": "image", "stickers": list]
        guard let payload = try? JSONSerialization.data(withJSONObject: json) else { throw Failure.encode }
        return Delivery(type: "org.telegram.third-party.stickerset", payload: payload,
                        url: Target.telegram.url, app: Target.telegram.app)
    }

    static func png512(_ image: UIImage) -> Data? {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
        let s = CGSize(width: 512, height: 512)
        return UIGraphicsImageRenderer(size: s, format: f).image { _ in
            image.draw(in: fit(image.size, in: CGRect(x: 16, y: 16, width: 480, height: 480)))
        }.pngData()
    }

    // MARK: - Hareketli WebP

    /// GIF → 512×512 hareketli WebP, ≤500 KB, ≤10 sn (WhatsApp sınırları).
    /// Önce yüksek kalite ve kare hızı deneniyor, sığmazsa ikisi de
    /// kademeli düşüyor.
    static func animatedWebP512(gif: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(gif as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }
        var frames: [(CGImage, Double)] = []
        var total = 0.0
        for i in 0..<n {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let g = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (g?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (g?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            // Sınırı aşan kare atılmıyor, kalan süreye kırpılıyor.
            let delay = min(max(0.02, d), 9.9 - total)
            guard delay > 0.01 else { break }
            frames.append((img, delay)); total += delay
        }
        // Tek kare hareketli değil: libwebp onu durağana indirir, WhatsApp
        // hareketli pakette reddeder.
        guard frames.count >= 2 else { return nil }
        for (fps, q): (Double, Float) in [(12, 70), (10, 60), (8, 50), (6, 40), (5, 30)] {
            if let data = encodeAnimated(frames, fps: fps, quality: q), data.count <= 500 * 1024 { return data }
        }
        return nil
    }

    private static func encodeAnimated(_ frames: [(CGImage, Double)], fps: Double, quality: Float) -> Data? {
        let side: Int32 = 512
        var opts = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&opts) != 0 else { return nil }
        opts.anim_params.loop_count = 0
        guard let enc = WebPAnimEncoderNew(side, side, &opts) else { return nil }
        defer { WebPAnimEncoderDelete(enc) }
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { return nil }
        config.quality = quality
        config.method = 4
        // Kareleri hedef hıza seyrelt: sabit bir zaman çizelgesi (0, step,
        // 2·step…) — her seçimde fazı sıfırlamak hızı yarıya düşürebiliyordu.
        let step = 1.0 / fps
        var t = 0.0, next = 0.0, ms: Int32 = 0, added = 0
        for (img, delay) in frames {
            if t + 1e-9 >= next {
                guard var px = rgbaPixels(UIImage(cgImage: img), side: Int(side), inset: 16) else { return nil }
                var pic = WebPPicture()
                guard WebPPictureInit(&pic) != 0 else { return nil }
                pic.width = side; pic.height = side; pic.use_argb = 1
                let ok = px.withUnsafeMutableBufferPointer { WebPPictureImportRGBA(&pic, $0.baseAddress, side * 4) }
                defer { WebPPictureFree(&pic) }
                guard ok != 0, WebPAnimEncoderAdd(enc, &pic, ms, &config) != 0 else { return nil }
                added += 1
                while next <= t + 1e-9 { next += step }
            }
            t += delay
            ms = Int32((t * 1000).rounded())
        }
        guard added >= 2, WebPAnimEncoderAdd(enc, nil, ms, nil) != 0 else { return nil }
        var out = WebPData()
        WebPDataInit(&out)
        defer { WebPDataClear(&out) }
        guard WebPAnimEncoderAssemble(enc, &out) != 0, let bytes = out.bytes else { return nil }
        return Data(bytes: bytes, count: out.size)
    }

    // MARK: - Kodlama

    /// 512×512 tuvale ortalanmış, şeffaf; kalite 100 KB'ye sığana kadar düşüyor.
    static func webp512(_ image: UIImage) -> Data? {
        let side = 512
        guard let rgba = rgbaPixels(image, side: side, inset: 16) else { return nil }
        for q: Float in [90, 80, 70, 60, 50, 40, 30] {
            var out: UnsafeMutablePointer<UInt8>?
            let size = rgba.withUnsafeBufferPointer { p in
                WebPEncodeRGBA(p.baseAddress, Int32(side), Int32(side), Int32(side * 4), q, &out)
            }
            guard size > 0, let out else { continue }
            defer { WebPFree(out) }
            if size <= 100 * 1024 { return Data(bytes: out, count: size) }
        }
        return nil
    }

    static func trayPNG(_ image: UIImage) -> Data? {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
        let s = CGSize(width: 96, height: 96)
        return UIGraphicsImageRenderer(size: s, format: f).image { _ in
            image.draw(in: fit(image.size, in: CGRect(origin: .zero, size: s)))
        }.pngData()
    }

    /// `WebPEncodeRGBA` **önçarpımsız** RGBA istiyor; CoreGraphics önçarpımlı
    /// veriyor — burada geri açılıyor, yoksa yarı saydam kenarlar kararıyor.
    private static func rgbaPixels(_ image: UIImage, side: Int, inset: CGFloat) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = image.cgImage else { return false }
            let box = CGRect(x: inset, y: inset, width: CGFloat(side) - inset * 2, height: CGFloat(side) - inset * 2)
            ctx.draw(cg, in: fit(image.size, in: box))
            return true
        }
        guard ok else { return nil }
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { px[i + c] = UInt8(min(255, Int(px[i + c]) * 255 / a)) }
        }
        return px
    }

    private static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        let k = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
        let w = size.width * k, h = size.height * k
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}
