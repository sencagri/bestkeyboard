import Foundation

/// Dosya yayımlama — **geçici dosya + atomik değiştirme**, tek yerde.
///
/// Kalibrasyon deposu, kişisel sözlük ve paket üreticisi aynı adımları ayrı
/// ayrı yazıyordu ve kopyalardan biri (paket üreticisi) hedef dosya yokken
/// `replaceItemAt`'in başarısız olduğunu bilmiyordu: ilk üretim, var olmayan
/// bir paketi "değiştirmeye" çalışıp düşüyordu.
public enum AtomicFile {

    /// `data`'yı `target`'a atomik olarak yayımlar.
    ///
    /// Yazma ortasında çökme eski sürümü bozmaz: önce aynı dizinde geçici
    /// dosya, sonra değiştirme. Hedef yoksa `replaceItemAt` başarısız olur; o
    /// durumda taşımak yeterli. Dizin yoksa oluşturulur.
    public static func publish(_ data: Data, to target: URL) throws {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(target.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: target)
        }
    }

    /// Kişisel veri koruması: yedeğe gitmez ve cihaz kilitliyken de okunabilir
    /// kalır (klavye kilit ekranında da açılır).
    ///
    /// Dokunma koordinatları ve kullanıcının yazdığı kelimeler kişisel veridir;
    /// iki deponun ayrı ayrı yazdığı aynı koruma, birinde gevşetilince diğeriyle
    /// sessizce ayrışırdı.
    public static func protectPersonalData(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try u.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        #endif
    }

    /// Dosya varsa siler; yoksa sessizce geçer (silme **sonucu** zaten sağlanmış).
    public static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
