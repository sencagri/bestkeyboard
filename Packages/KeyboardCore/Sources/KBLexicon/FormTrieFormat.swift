import Foundation
import KBGeometry

/// Form listesi binary formatı — **açık byte offset'leri, little-endian**.
///
/// Skor sözleşmesi §4.2 gereği form listesi bir **trie**'dir, minimize edilmiş
/// DAWG değil: trie'de düğüm öneki tekil belirlediği için `surfaceId ≡ node`
/// olur ve farklı yüzey öneklerinin yanlış birleşmesi yapısal olarak imkânsızdır.
///
/// Ortak çerçeve (magic, sürüm, checksum) ve okuyucu/yazıcı `KBGeometry`'de
/// (`BinaryContainer`, `ByteReader`, `ByteWriter`); burada yalnız alanlar.
///
/// ```
/// Başlık (32 bayt)
///   0  magic          u32   "BKT1"
///   4  version        u16
///   6  flags          u16
///   8  nodeCount      u32
///  12  arcCount       u32
///  16  alphabetSize   u16
///  18  maxSurfaceLen  u16
///  20  reserved       u32
///  24  checksum       u64   FNV-1a, yük üzerinden
///
/// Yük (sırayla, hizalama yok)
///   alphabet     : alphabetSize × u32   (Unicode skaler; sembol kimliği = indeks)
///   arcOffset    : (nodeCount+1) × u32
///   arcSymbol    : arcCount × u16
///   arcTarget    : arcCount × u32
///   arcLexDelta  : arcCount × f32       ham F_lex deltası (maliyet itmeli, §7.1)
///   nodeFlags    : nodeCount × u8       bit0 = terminal
///   nodeTermExtra: nodeCount × f32      terminal ise L(w) − bound(node), değilse 0
/// ```
public enum FormTrieFormat {
    public static let container = BinaryContainer(
        magic: 0x314B_5442,  // "BTK1" little-endian olarak "BKT1"
        version: 1, headerSize: 32)
}
