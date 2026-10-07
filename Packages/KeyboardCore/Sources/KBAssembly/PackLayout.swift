import KBDecoder
import KBRuntime

// MARK: - Dil paketlerinin adları ve düzeni — tek tanım
//
// Paket adları ve uzantıları yükleyicide, `build-packs.sh`'te ve üç araçta ayrı
// ayrı yazılıyordu. Yükleyici bir adı değiştirse araçlar sessizce eski dosyayı
// (ya da hiçbir dosyayı) ölçmeye devam ederdi.

/// Paketlerin yerel ayarı ve decoder'daki dil kimliği.
public enum PackLocale: String, CaseIterable, Sendable {
    case turkish = "tr-TR"
    case english = "en-US"

    public var language: UInt8 {
        switch self {
        case .turkish: return Language.turkish
        case .english: return Language.english
        }
    }

    /// Form listesinin ölçek ofseti `offset_ℓ` (§5b), nat.
    ///
    /// Referans dil Türkçe (0). İngilizce değeri ölçümle geldi
    /// (`kbdiag --scale`): iki listede ortak 12 108 yüzeyde maliyet farkının
    /// medyanı +0.20 nat, çeyrekler arası genişlik 1.39 nat. Yani paketler zaten
    /// uyumlu ölçekte — sıfır bırakmak yerine ölçülen değeri koyuyoruz, ama
    /// büyüklüğü gürültü mertebesinde olduğu için tek başına bir şeyi çevirmez.
    public var lexiconOffset: Double {
        switch self {
        case .turkish: return 0
        case .english: return -0.20
        }
    }
}

public extension PackRole {
    /// Paket dosyasının uzantısı. Kişisel kaynağın diskte dosyası yok (`nil`).
    var fileExtension: String? {
        switch self {
        case .forms:      return "bkt"
        case .roots:      return "bkr"
        case .charModel:  return "bkc"
        case .bigrams:    return "bkg"
        case .expansions: return "bkx"
        case .personal:   return nil
        }
    }
}

/// Depodaki paket ağacı: `LanguagePacks/<yerel>/<yerel>.<uzantı>` ve
/// paketlerin kaynağı `LanguagePacks/<yerel>/wordlist.tsv`.
public enum PackPaths {
    /// Paket ağacının kökü — depo köküne göreli.
    public static let root = "LanguagePacks"

    /// `tr-TR.bkt`
    public static func fileName(_ locale: PackLocale, _ role: PackRole) -> String {
        guard let ext = role.fileExtension else {
            preconditionFailure("\(role) rolünün paket dosyası yok")
        }
        return "\(locale.rawValue).\(ext)"
    }

    /// `LanguagePacks/tr-TR` — bir yerel ayarın paketleri ve kaynakları.
    public static func directory(_ locale: PackLocale, root: String = root) -> String {
        "\(root)/\(locale.rawValue)"
    }

    /// `LanguagePacks/tr-TR/tr-TR.bkt`
    public static func file(_ locale: PackLocale, _ role: PackRole,
                            root: String = root) -> String {
        "\(directory(locale, root: root))/\(fileName(locale, role))"
    }

    /// `LanguagePacks/tr-TR/wordlist.tsv` — form listesinin ve karakter
    /// modelinin kaynağı; araçların varsayılan kelime listesi.
    public static func wordlist(_ locale: PackLocale, root: String = root) -> String {
        "\(directory(locale, root: root))/wordlist.tsv"
    }
}
