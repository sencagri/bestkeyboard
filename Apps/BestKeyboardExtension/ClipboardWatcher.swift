import UIKit

/// Sistem panosuyla klavyenin **tek** bağlantısı: okuma, yazma, geçmiş ve
/// "az önce kopyalanan".
///
/// Önce bu iş denetleyiciye dağılmıştı: panoyu okuyan dört, yazıp sayacı
/// işaretleyen altı ayrı yer vardı ve biri işaretlemeyi unutunca kendi
/// yazdığımız şey geçmişe ve yapay zeka kaynağına geri giriyordu.
@MainActor
final class ClipboardWatcher {
    /// Çubuktaki "son kopyalanan" çipi bu kadar görünür.
    static let chipLifetime: TimeInterval = 120
    /// Bundan yeni kopyalanan metin yapay zeka kartında öne alınıyor (çoğu
    /// zaman karşıdan gelen mesaj).
    static let freshTextAge: TimeInterval = 15 * 60

    private(set) var store = ClipboardStore.load()
    /// Son kopyalanan — çubuktaki önizleme için.
    private(set) var recent: (image: UIImage?, text: String?, at: Date)?
    private var lastTextAt: Date?
    /// Geçmiş değişti (panel listesi ve çip yenilensin).
    var onChange: (() -> Void)?

    private static var local: UserDefaults { KeyboardSettingsStore.local }
    private static let changeCountKey = KeyboardSettingsStore.LocalKey.clipChangeCount

    /// Pano değiştiyse içeriği **bir kez** okur.
    ///
    /// `changeCount` okumak bildirim tetiklemiyor; içerik okumak tetikliyor
    /// ("BestKeyboard … yapıştırdı"). Bu yüzden içerik yalnız sayaç
    /// değiştiğinde okunuyor ve sayaç kalıcı: klavye her açıldığında aynı
    /// panoyu yeniden okuyup bildirimi tekrarlamıyor.
    /// - Parameter allowed: Tam Erişim var ve alan parola alanı değil.
    func check(allowed: Bool) {
        guard allowed else { return }
        let pb = UIPasteboard.general
        let count = pb.changeCount
        guard count != Self.local.integer(forKey: Self.changeCountKey) else { return }
        Self.local.set(count, forKey: Self.changeCountKey)
        // Parola yöneticilerinin gizli işaretlediği içerik okunmuyor.
        guard !Self.isConcealed(pb) else { return }
        if pb.hasImages, let image = pb.image {
            let stored = store.add(image: image)
            recent = (stored ?? image.scaled(maxSide: 256), nil, Date())
        } else if pb.hasStrings, let text = pb.string {
            store.add(text: text)
            lastTextAt = Date()
            recent = (nil, String(text.replacingOccurrences(of: "\n", with: " ").prefix(40)), Date())
        } else {
            return
        }
        store.save()
        onChange?()
    }

    /// Panodaki metin. İzin yoksa (Tam Erişim kapalı, parola alanı) ya da
    /// parola yöneticisinin gizli işaretlediği içerikse `nil` — okuma kuralı
    /// geçmişe almayla aynı.
    func string(allowed: Bool) -> String? {
        let pb = UIPasteboard.general
        guard allowed, pb.hasStrings, !Self.isConcealed(pb) else { return nil }
        return pb.string
    }

    private static func isConcealed(_ pb: UIPasteboard) -> Bool {
        pb.contains(pasteboardTypes: ["org.nspasteboard.ConcealedType"])
    }

    /// Panoda resim var mı (içeriği okumadan).
    func hasImage(allowed: Bool) -> Bool { allowed && UIPasteboard.general.hasImages }

    /// Panodaki metin az önce mi kopyalandı.
    var textIsFresh: Bool {
        lastTextAt.map { Date().timeIntervalSince($0) < Self.freshTextAge } ?? false
    }

    /// Panoya **biz** yazıyoruz: sayaç işaretleniyor ki bu yazım geçmişe ya da
    /// "yeni kopyalanan mesaj" kaynağına geri alınmasın.
    func put(string: String) { write { UIPasteboard.general.string = string } }
    func put(image: UIImage) { write { UIPasteboard.general.image = image } }
    /// Başka bir bileşen panoya yazdı (ör. `MediaStore.copyToPasteboard`).
    func noteOwnWrite() { Self.local.set(UIPasteboard.general.changeCount, forKey: Self.changeCountKey) }

    private func write(_ body: () -> Void) {
        body()
        noteOwnWrite()
    }

    /// Çubukta gösterilecek son kopyalanan; süresi geçtiyse `nil`.
    var chip: (image: UIImage?, text: String?)? {
        guard let c = recent, Date().timeIntervalSince(c.at) < Self.chipLifetime else { return nil }
        return (c.image, c.text)
    }

    /// Çipe dokunuldu: bir kez kullanılıyor.
    func consumeRecent() { recent = nil }

    func clear() {
        store.clear()
        store.save()
        recent = nil
        onChange?()
    }
}
