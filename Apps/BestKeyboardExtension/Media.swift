import UIKit
import UniformTypeIdentifiers

/// Stüdyoda yapılan GIF ve çıkartmalar — ortak klasörde (`media/`).
///
/// Uygulama yazıyor, klavye okuyor (Tam Erişimle). Klavye bir öğeye
/// dokununca dosyayı panoya **doğru türle** koyuyor: GIF `com.compuserve.gif`
/// (WhatsApp ve iMessage onu hareketli yapıştırıyor), çıkartma şeffaf PNG.
enum MediaStore {
    struct Item: Codable, Hashable {
        enum Kind: String, Codable { case gif, sticker }
        var id: String
        var kind: Kind
        /// Asıl dosya (`.gif` / `.png`).
        var file: String
        /// Küçük önizleme (`.jpg` / `.png`, 240 px) — klavyede ızgara için;
        /// büyük GIF'i uzantının bellek bütçesinde açmamak için.
        var thumb: String
    }

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardSettingsStore.appGroup)?
            .appendingPathComponent("media", isDirectory: true)
    }

    static func load() -> [Item] {
        guard let url = directory?.appendingPathComponent("index.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    static func save(_ items: [Item]) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
        }
    }

    /// Yeni öğe ekler — en yenisi başta.
    @discardableResult
    static func add(kind: Item.Kind, data: Data, thumb: UIImage) -> Item? {
        guard let dir = directory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.prefix(8).lowercased()
        let file = "\(id).\(kind == .gif ? "gif" : "png")"
        let thumbName = "\(id)-t.png"
        guard (try? data.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil,
              let t = thumb.scaled(maxSide: 240).pngData(),
              (try? t.write(to: dir.appendingPathComponent(thumbName), options: .atomic)) != nil else { return nil }
        let item = Item(id: String(id), kind: kind, file: file, thumb: thumbName)
        save([item] + load())
        return item
    }

    static func remove(_ item: Item) {
        save(load().filter { $0.id != item.id })
        guard let dir = directory else { return }
        for f in [item.file, item.thumb] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }

    static func thumbnail(_ item: Item) -> UIImage? {
        directory.flatMap { UIImage(contentsOfFile: $0.appendingPathComponent(item.thumb).path) }
    }

    static func data(_ item: Item) -> Data? {
        directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent(item.file)) }
    }

    /// Öğeyi panoya doğru türle koyar.
    static func copyToPasteboard(_ item: Item) -> Bool {
        guard let d = data(item) else { return false }
        let type = item.kind == .gif ? UTType.gif.identifier : UTType.png.identifier
        UIPasteboard.general.setItems([[type: d]])
        return true
    }
}

extension UIImage {
    func scaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let k = maxSide / longest
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

