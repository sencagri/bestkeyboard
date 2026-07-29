import Foundation

/// Binary'yi tanımlayan derleme olguları — plan v8 §2.8.
///
/// ## Neden commit yetmiyor
///
/// Temiz bir commit **tekil binary tanımlamıyor**: aynı kaynak farklı Swift
/// sürümü, target triple, mimari ya da optimizasyon seviyesinde farklı sonuç
/// verebilir. Replay o farkı görüp "kod regresyonu" diye raporlardı.
///
/// Optimizasyon seviyesi özellikle: `-Onone` ile `-O` arasında **13 kat**
/// gecikme farkı ölçüldü. Bir kaydın hangisiyle alındığını bilmeden zamanlama
/// verisi karşılaştırılamaz.
///
/// ## Neden okunabilir, üretilebilir değil
///
/// Değerler `Tools/inject-build-manifest.sh` tarafından derleme sırasında
/// paketin içine yazılıyor. Çalışma anında `git` çağırmak mümkün değil (uygulama
/// kaynak ağacını görmüyor) ve çağrılabilseydi bile **yanlış** olurdu: kaydın
/// sorusu "şu an depo ne durumda" değil, "bu binary neyden çıktı".
public struct BuildManifest: Equatable, Sendable {
    public var codeRevision: String
    public var dirty: Bool
    /// Kirli ağaçta değişen kaynakların özeti; temizse boş.
    public var sourceDigest: String
    public var swiftVersion: String
    public var targetTriple: String
    public var arch: String
    public var optimization: String
    public var xcodeVersion: String

    public init(codeRevision: String, dirty: Bool, sourceDigest: String,
                swiftVersion: String, targetTriple: String, arch: String,
                optimization: String, xcodeVersion: String) {
        self.codeRevision = codeRevision
        self.dirty = dirty
        self.sourceDigest = sourceDigest
        self.swiftVersion = swiftVersion
        self.targetTriple = targetTriple
        self.arch = arch
        self.optimization = optimization
        self.xcodeVersion = xcodeVersion
    }

    /// Pakete gömülü manifesti okur.
    ///
    /// Dosya yoksa `nil` — ve çağıran bunu `.unknown` olarak kaydeder.
    /// Boş bir manifest **uydurmak**, derleme kimliğini bildiğimizi iddia etmek
    /// olurdu; oysa manifest yoksa build fazı koşmamış demektir.
    public init?(bundle: Bundle) {
        guard let url = bundle.url(forResource: "BuildManifest",
                                   withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: String]
        else { return nil }
        self.init(codeRevision: dict["codeRevision"] ?? "unknown",
                  // Anahtar yoksa **kirli** sayılıyor: temiz olduğunu iddia
                  // etmek, doğrulanmamış bir olguyu olgu diye kaydetmektir.
                  dirty: dict["dirty"] != "false",
                  sourceDigest: dict["sourceDigest"] ?? "",
                  swiftVersion: dict["swiftVersion"] ?? "",
                  targetTriple: dict["targetTriple"] ?? "",
                  arch: dict["arch"] ?? "",
                  optimization: dict["optimization"] ?? "",
                  xcodeVersion: dict["xcodeVersion"] ?? "")
    }
}
