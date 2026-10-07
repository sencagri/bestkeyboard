import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Stüdyonun görünümsüz işi: videodan kare, GIF kodlama, üst yazı, seçilen
// fotoğraf/video. Görünümler yalnız durumu gösteriyor.

/// Videodan kare üreticisi — dönüş yönü uygulanmış, uzun kenarı sınırlı.
enum VideoFrames {
    static func generator(_ asset: AVAsset, maxSide: CGFloat, tolerance: CMTime? = nil) -> AVAssetImageGenerator {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        // Sınır **uzun kenar**: dikey video da yatay da aynı sınırda.
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        if let tolerance {
            gen.requestedTimeToleranceBefore = tolerance
            gen.requestedTimeToleranceAfter = tolerance
        }
        return gen
    }

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
}

/// Üst yazı: kalın, siyah kenarlı beyaz — GIF ve çıkartma aynı biçim.
enum Caption {
    static func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        return [.font: UIFont.systemFont(ofSize: fontSize, weight: .black),
                .foregroundColor: UIColor.white, .strokeColor: UIColor.black, .strokeWidth: -6,
                .paragraphStyle: para]
    }

    /// Yazıyı büyük harfe çevirip `rect`'e çizer (çizim bağlamı açıkken).
    static func draw(_ text: String, in rect: CGRect, fontSize: CGFloat) {
        (text.trUppercased as NSString).draw(in: rect, withAttributes: attributes(fontSize: fontSize))
    }

    /// Resmin üstüne yazı (GIF karesi).
    static func onTop(_ text: String, of image: UIImage) -> UIImage {
        guard !text.isEmpty else { return image }
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: f).image { _ in
            image.draw(at: .zero)
            let size = max(14, image.size.width * 0.085)
            draw(text, in: CGRect(x: 8, y: size * 0.4, width: image.size.width - 16, height: size * 2.6), fontSize: size)
        }
    }
}

/// Videonun bir aralığından döngülü GIF.
enum GifEncoder {
    struct Output {
        let data: Data
        let first: UIImage
    }

    /// - Parameters:
    ///   - frames: kare sayısı; her kare `1 / fps` sn gösteriliyor.
    ///   - progress: 0…1, kare başına.
    static func encode(_ asset: AVAsset, start: Double, length: Double, frames count: Int, fps: Double,
                       maxSide: CGFloat, caption: String, progress: (Double) -> Void) async -> Output? {
        let gen = VideoFrames.generator(asset, maxSide: maxSide, tolerance: CMTime(value: 1, timescale: 24))
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, count, nil) else { return nil }
        GIF.setLooping(dest)
        let frameProps = GIF.frameProperties(delay: 1 / fps)
        var first: UIImage?
        for i in 0..<count {
            progress(Double(i) / Double(count))
            let t = VideoFrames.time(start + Double(i) / Double(count) * length)
            guard let cg = try? await gen.image(at: t).image else { continue }
            let img = Caption.onTop(caption, of: UIImage(cgImage: cg))
            if first == nil { first = img }
            if let c = img.cgImage { CGImageDestinationAddImage(dest, c, frameProps) }
        }
        guard CGImageDestinationFinalize(dest), let first else { return nil }
        return Output(data: out as Data, first: first)
    }
}

/// Fotoğraflar'dan seçilen video: dosya geçici klasöre alınıyor.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
            // Taşımak kopyalamaktan çok hızlı (büyük videoda saniyeler);
            // izin vermezse kopyala.
            do { try FileManager.default.moveItem(at: received.file, to: dst) }
            catch { try FileManager.default.copyItem(at: received.file, to: dst) }
            return PickedMovie(url: dst)
        }
    }
}

extension PhotosPickerItem {
    /// Seçilen fotoğraf; `maxSide` verilirse küçültülmüş.
    func loadImage(maxSide: CGFloat? = nil) async -> UIImage? {
        guard let data = try? await loadTransferable(type: Data.self), let img = UIImage(data: data) else { return nil }
        return maxSide.map { img.scaled(maxSide: $0) } ?? img
    }
}
