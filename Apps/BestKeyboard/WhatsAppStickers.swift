import UIKit
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
        case tooFew(Int), encode, noWhatsApp
        var errorDescription: String? {
            switch self {
            case let .tooFew(n): return "WhatsApp en az 3 çıkartma istiyor; şu an \(n) tane var."
            case .encode: return "Çıkartmalar hazırlanamadı."
            case .noWhatsApp: return "WhatsApp açılamadı. Yüklü mü?"
            }
        }
    }

    static let identifier = "com.sencagri.bestkeyboard.studio"

    /// Her kategori WhatsApp'ta **ayrı bir paket** (kimlik kategoriden).
    static func addToWhatsApp(_ items: [MediaStore.Item], category: String? = nil) throws {
        let stickers = Array(items.filter { $0.kind == .sticker }.prefix(30))
        guard stickers.count >= 3 else { throw Failure.tooFew(stickers.count) }
        var list: [[String: Any]] = []
        var trayImage: UIImage?
        for item in stickers {
            guard let data = MediaStore.data(item), let img = UIImage(data: data),
                  let webp = webp512(img) else { throw Failure.encode }
            if trayImage == nil { trayImage = img }
            list.append(["image_data": webp.base64EncodedString(), "emojis": ["😀"]])
        }
        guard let tray = trayImage.flatMap(trayPNG) else { throw Failure.encode }
        let json: [String: Any] = [
            "identifier": identifier + "." + slug(category ?? "tumu"),
            "name": category.map { "BestKeyboard · \($0)" } ?? "BestKeyboard çıkartmalarım",
            "publisher": "BestKeyboard",
            "tray_image": tray.base64EncodedString(),
            "animated_sticker_pack": false,
            "ios_app_store_link": "",
            "android_play_store_link": "",
            "stickers": list,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: json) else { throw Failure.encode }
        UIPasteboard.general.setItems([["net.whatsapp.third-party.sticker-pack": payload]],
                                      options: [.localOnly: true,
                                                .expirationDate: Date().addingTimeInterval(60)])
        guard let url = URL(string: "whatsapp://stickerPack"), UIApplication.shared.canOpenURL(url) else {
            throw Failure.noWhatsApp
        }
        UIApplication.shared.open(url)
    }

    /// Paket kimliği için: harf/rakam dışını at, Türkçe harfleri sadeleştir.
    static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr"))
            .replacingOccurrences(of: "ı", with: "i")
        let out = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        // `hashValue` her açılışta değişiyor; sabit kimlik için skalerlerin
        // toplamı (aynı ad → aynı paket).
        let stable = s.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 }
        return out.isEmpty ? "k\(stable)" : String(String.UnicodeScalarView(out)).lowercased()
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
