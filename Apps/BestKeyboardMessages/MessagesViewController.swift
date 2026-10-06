import Messages
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Mesajlar'daki BestKeyboard çekmecesi — tasarım tuvali "18 · Mesajlar".
///
/// Stüdyo'nun ortak klasördeki (`media/`) GIF ve çıkartmaları burada
/// **gerçek iMessage çıkartması**: dokununca gider, basılı tutup sürükleyince
/// bir mesajın üstüne yapışır. Klavyeden farklı olarak kopyala-yapıştır yok.
/// Liste her açılışta diskten okunuyor; stüdyoda yapılan hemen görünür.
final class MessagesViewController: MSMessagesAppViewController, MSStickerBrowserViewDataSource {
    private let browser = MSStickerBrowserView(frame: .zero, stickerSize: .small)
    private let chipBar = UIScrollView()
    private let chipRow = UIStackView()
    private let empty = UILabel()
    private var stickers: [MSSticker] = []
    /// `nil` = Tümü.
    private var category: String?
    private static let accent = UIColor(red: 0x5B / 255, green: 0x3F / 255, blue: 0xD0 / 255, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        browser.dataSource = self
        browser.backgroundColor = .clear
        chipBar.showsHorizontalScrollIndicator = false
        chipRow.axis = .horizontal
        chipRow.spacing = 6
        empty.numberOfLines = 0
        empty.textAlignment = .center
        empty.font = .systemFont(ofSize: 14)
        empty.textColor = .secondaryLabel
        empty.text = "Henüz yok — BestKeyboard › Stüdyo'da GIF ya da çıkartma yap."
        for v in [chipBar, browser, empty] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chipBar.addSubview(chipRow)
        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            chipBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            chipBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            chipBar.heightAnchor.constraint(equalToConstant: 34),
            chipRow.topAnchor.constraint(equalTo: chipBar.contentLayoutGuide.topAnchor, constant: 2),
            chipRow.leadingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.leadingAnchor),
            chipRow.trailingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.trailingAnchor),
            chipRow.bottomAnchor.constraint(equalTo: chipBar.contentLayoutGuide.bottomAnchor),
            browser.topAnchor.constraint(equalTo: chipBar.bottomAnchor, constant: 4),
            browser.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: browser.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: browser.centerYAnchor),
            empty.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -48),
        ])
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        let cats = MediaStore.categories()
        if let c = category, !cats.contains(c) { category = nil }
        buildChips(cats)
        reload()
    }

    private func buildChips(_ cats: [String]) {
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chipBar.isHidden = cats.isEmpty
        for c in ([nil] as [String?]) + cats.map(Optional.some) {
            let on = c == category
            var cfg = UIButton.Configuration.filled()
            cfg.title = c ?? "Tümü"
            cfg.cornerStyle = .capsule
            cfg.baseBackgroundColor = on ? Self.accent : .secondarySystemFill
            cfg.baseForegroundColor = on ? .white : .label
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
            cfg.titleTextAttributesTransformer = .init { a in
                var a = a; a.font = .systemFont(ofSize: 13, weight: .bold); return a
            }
            let b = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in
                self?.category = c
                self?.buildChips(cats)
                self?.reload()
            })
            b.accessibilityTraits = on ? [.button, .selected] : .button
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            chipRow.addArrangedSubview(b)
        }
    }

    private func reload() {
        let items = MediaStore.load().filter { category == nil || $0.category == category }
        stickers = items.compactMap { item in
            guard let url = StickerFile.url(for: item) else { return nil }
            return try? MSSticker(contentsOfFileURL: url,
                                  localizedDescription: item.kind == .gif ? "GIF" : "Çıkartma")
        }
        empty.isHidden = !stickers.isEmpty
        if category != nil { empty.text = "Bu kategoride henüz yok." }
        browser.reloadData()
    }

    func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int { stickers.count }

    func stickerBrowserView(_ stickerBrowserView: MSStickerBrowserView, stickerAt index: Int) -> MSSticker {
        stickers[index]
    }
}

/// iMessage çıkartması dosyası ≤500 KB olmalı. Stüdyo GIF'leri bunu
/// aşabiliyor; o zaman uzantının önbelleğinde küçültülmüş bir kopya
/// yapılıyor (kaynak değişmezse bir kez).
enum StickerFile {
    static let limit = 500 * 1024

    static func url(for item: MediaStore.Item) -> URL? {
        guard let src = MediaStore.fileURL(item),
              let size = (try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        if size <= limit { return src }
        guard item.kind == .gif,
              let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let out = cache.appendingPathComponent("\(item.id)-\(size).gif")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        for side in [320, 240, 180] {
            if let d = shrinkGIF(src, maxSide: side), d.count <= limit,
               (try? d.write(to: out, options: .atomic)) != nil { return out }
        }
        return nil
    }

    /// Her kareyi küçültüp gecikmeleriyle yeniden yazar.
    private static func shrinkGIF(_ url: URL, maxSide: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        let data = NSMutableData()
        guard n > 0, let dst = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, n, nil) else { return nil }
        CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary
        for i in 0..<n {
            autoreleasepool {
                guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts) else { return }
                let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                let g = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = (g?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                CGImageDestinationAddImage(dst, img, [kCGImagePropertyGIFDictionary:
                                                        [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
        }
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }
}
