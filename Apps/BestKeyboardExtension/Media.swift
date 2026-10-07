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
        /// Kullanıcının kategorisi ("Komik", "Aile"…); `nil` kategorisiz.
        /// İsteğe bağlı: kategori gelmeden önce yazılmış kayıtlar da okunuyor.
        var category: String? = nil
    }

    // MARK: - Kategoriler

    private static var categoriesURL: URL? { directory?.appendingPathComponent("categories.json") }
    private static var indexURL: URL? { directory?.appendingPathComponent("index.json") }

    static func categories() -> [String] { JSONFile.read([String].self, at: categoriesURL) ?? [] }

    static func addCategory(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        var all = categories()
        guard !all.contains(where: { $0.trEquals(n) }) else { return }
        all.append(n)
        JSONFile.write(all, to: categoriesURL)
    }

    static func setCategory(_ category: String?, for item: Item) {
        save(load().map { var i = $0; if i.id == item.id { i.category = category }; return i })
    }

    /// `nil` = hepsi.
    static func items(kind: Item.Kind? = nil, category: String?) -> [Item] {
        filter(load(), kind: kind, category: category)
    }

    /// Tür ve kategoriye göre süzme — klavye paneli, stüdyo ve Mesajlar aynı kural.
    static func filter(_ items: [Item], kind: Item.Kind? = nil, category: String? = nil) -> [Item] {
        items.filter { (kind == nil || $0.kind == kind) && (category == nil || $0.category == category) }
    }

    static var directory: URL? {
        AppGroup.container?.appendingPathComponent(AppGroup.File.media, isDirectory: true)
    }

    static func item(id: String) -> Item? { load().first { $0.id == id } }

    static func load() -> [Item] { JSONFile.read([Item].self, at: indexURL) ?? [] }

    static func save(_ items: [Item]) { JSONFile.write(items, to: indexURL) }

    /// Yeni öğe ekler — en yenisi başta.
    @discardableResult
    static func add(kind: Item.Kind, data: Data, thumb: UIImage, category: String? = nil) -> Item? {
        guard let dir = directory else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID.short
        let file = "\(id).\(kind == .gif ? "gif" : "png")"
        let thumbName = "\(id)-t.png"
        guard (try? data.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil,
              let t = thumb.scaled(maxSide: 240).pngData(),
              (try? t.write(to: dir.appendingPathComponent(thumbName), options: .atomic)) != nil else { return nil }
        let item = Item(id: id, kind: kind, file: file, thumb: thumbName, category: category)
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

    static func fileURL(_ item: Item) -> URL? {
        directory?.appendingPathComponent(item.file)
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



