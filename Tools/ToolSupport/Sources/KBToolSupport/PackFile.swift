import Foundation
import KBLexicon
import KBMorphology

/// Araçların **tek tek** paket okuması — komut satırında yolu verilen bir
/// `.bkt`/`.bkc`/`.bkr`.
///
/// Üretimle aynı motoru kurmak isteyen araç `PackLoader`'ı kullanıyor; bu,
/// bilerek tek bir paketi ölçen yollar (bench'in kendi trie'si, teşhis
/// sondaları) için. Okunamayan ya da geçersiz paket aracı **durdurur**:
/// eksik paketle devam eden bir ölçüm başka bir motoru ölçer.
public enum PackFile {

    /// `path`'teki paketi mmap'ler ve `parse` ile kurar.
    /// - Parameter what: hata mesajındaki ad ("kök paketi", "ikinci dil paketi").
    public static func load<T>(_ path: String, as what: String,
                               _ parse: (Data) throws -> T) -> T {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: .mappedIfSafe) else {
            fail("\(what) okunamadı: \(path)")
        }
        do { return try parse(data) }
        catch { fail("\(what) geçersiz: \(path) — \(error)") }
    }

    public static func formTrie(_ path: String, as what: String = "form paketi") -> FormTrie {
        load(path, as: what) { try FormTrie(data: $0) }
    }

    public static func charModel(_ path: String, as what: String = "karakter modeli") -> CharNGram {
        load(path, as: what) { try CharNGram(packData: $0) }
    }

    public static func roots(_ path: String, as what: String = "kök paketi") -> RootPack {
        load(path, as: what) { try RootPack(data: $0) }
    }
}
