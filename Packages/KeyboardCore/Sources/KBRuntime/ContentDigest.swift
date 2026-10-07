import CryptoKit
import Foundation

/// İçerik kimliği — kayıtta paketlerin ve kişisel kaynağın **aynı** biçimde
/// özetlenmesi (§12.7).
///
/// İki ayrı yazım vardı (paket yükleyici ve kişisel kaynak). Biçimleri
/// ayrışırsa (büyük harf onaltılık, ayraç) aynı içerik iki farklı kimlikle
/// kaydedilir ve replay eşleşen bir paketi "farklı" sanardı.
///
/// `KBFoundation`'da değil: çekirdeğin alt katmanı `CryptoKit`'e bağımlı değil
/// (bkz. `FNV1a`); SHA'ya yalnız kayıt ihtiyaç duyuyor.
public enum ContentDigest {
    /// SHA-256, küçük harf onaltılık.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
