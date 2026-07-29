import Foundation
import KBRuntime

/// Belge metnini mutasyonlardan yeniden kurar — plan v8 §2.7.
///
/// ## Neden tam metin taşınmıyor
///
/// v2 her action'a belgenin **tamamını** yazıyordu: i'nci harfte `O(i)` metin,
/// toplamda `O(n²)`. 200 karakterlik bir denemede yalnız bu alan 20 KB'ye
/// çıkıyordu. Mutasyon + özet aynı doğrulanabilirliği `O(1)` yazmayla veriyor.
///
/// ## Neden özet de gerekiyor
///
/// Mutasyon listesi tek başına doğrulanamaz: yanlış bir mutasyon dizisi de
/// kendi içinde tutarlı görünür. Her action sonrası tam belgenin özeti,
/// türetimin **gerçekten** olanı ürettiğini kanıtlıyor.
public enum DocumentReconstruction {

    /// FNV-1a 64 — `CalibrationStore`'un ve layout parmak izinin kullandığı
    /// sabit tohum. Kriptografik dirence ihtiyaç yok; kimse belge özeti
    /// çakıştırmaya çalışmıyor.
    ///
    /// Girdi **UTF-8 baytları**: `String`'in bellek temsili platforma ve
    /// normalizasyona göre değişebilir, bayt dizisi değişmez.
    public static func hash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h &*= 0x100_0000_01b3
        }
        return h
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Silme, belgede olandan fazlasını istedi.
        case underflow(actionID: Int, requested: Int, available: Int)
        /// Türetilen metnin özeti kayıtlıyla uyuşmadı.
        case hashMismatch(actionID: Int, expected: UInt64, actual: UInt64)
        /// Terminal metin türetilenle uyuşmadı.
        case finalTextMismatch(expected: String, actual: String)

        public var description: String {
            switch self {
            case let .underflow(id, r, a):
                return "action \(id): \(r) silinmek istendi, \(a) var"
            case let .hashMismatch(id, e, a):
                return "action \(id): özet \(e) beklendi, \(a) çıktı"
            case let .finalTextMismatch(e, a):
                return "finalText \"\(e)\" beklendi, \"\(a)\" türetildi"
            }
        }
    }

    /// Bir action'ın mutasyonlarını uygular.
    ///
    /// Silme birimi **`Character`** (grapheme), UTF-16 birimi değil:
    /// `ComposingSession.deleteBackward` öyle sayıyor ve `"\r\n"` Swift'te
    /// **tek** `Character`. UTF-16 saysaydık CRLF'de bir birim fazla silerdik.
    public static func apply(_ mutations: [DocumentMutation],
                             to text: inout String,
                             actionID: Int) throws {
        for m in mutations {
            switch m {
            case let .insert(s):
                text += s
            case let .deleteBackward(count):
                guard text.count >= count else {
                    throw Failure.underflow(actionID: actionID, requested: count,
                                            available: text.count)
                }
                text.removeLast(count)
            }
        }
    }

    /// Yeniden kurulumun sonucu.
    ///
    /// Düz `String` döndürmek çağıranın **tam** metni mi yoksa kesilmiş bir
    /// öneki mi aldığını ayırt etmesini imkânsız kılıyordu: v2'den migrate
    /// edilmiş bir kayıtta türetim ilk bilinmeyen deltada duruyor ve dönen
    /// dize belgenin tamamı değil.
    public enum Reconstruction: Equatable {
        case complete(String)
        /// Belirtilen action'dan itibaren delta bilinmiyor; dize o noktaya
        /// kadarki **önek**.
        case unverifiable(prefix: String, fromAction: Int)

        /// Elde ne varsa — doğrulanabilirliği **umursamayan** çağıran için.
        public var text: String {
            switch self {
            case let .complete(t), let .unverifiable(t, _): return t
            }
        }
    }

    /// Kaydın **tamamını** yeniden kurar ve her adımda özetle doğrular.
    ///
    /// Başlangıç metni **boş dize**: recorder'ın tamponu sıfırdan başlıyor.
    /// Host belgesinde önceden metin varsa o kayda girmiyor ve girmemeli —
    /// kayıt kullanıcının bu denemede yazdığını ölçüyor.
    ///
    /// - Throws: ilk tutarsızlıkta. Sessizce devam etmek, bozuk bir kaydı
    ///   doğrulanmış gibi gösterirdi.
    @discardableResult
    public static func replay(_ session: CanonicalSession) throws
        -> Reconstruction {
        var text = ""
        for action in session.actions {
            // Bilinmeyen delta (v2 migrasyonu) doğrulanamaz; metin türetimi
            // o noktada durur ama bu bir hata değil, bilgi eksikliği.
            guard let delta = action.document.value else {
                return .unverifiable(prefix: text, fromAction: action.actionID)
            }
            try apply(delta.mutations, to: &text, actionID: action.actionID)
            let actual = hash(text)
            guard actual == delta.hashAfter else {
                throw Failure.hashMismatch(actionID: action.actionID,
                                           expected: delta.hashAfter,
                                           actual: actual)
            }
        }
        // `finalText` yalnız terminalde yazılıyor. **Boş olması da bir iddia**:
        // eylemleri `"ev"` üreten tamamlanmış bir kayıt boş `finalText` ile
        // geçiyordu, çünkü boşluk karşılaştırmadan muaf tutulmuştu.
        if session.status != .recording, session.finalText != text {
            throw Failure.finalTextMismatch(expected: session.finalText,
                                            actual: text)
        }
        return .complete(text)
    }
}
