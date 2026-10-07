import Foundation

/// Layout'un **içeriğine** dayalı kimliği — plan v8 §2.8.
///
/// ## Neden `id` yetmiyor
///
/// `layoutID` tekil değil: aynı kimlikle tuş **sırası**, geometrisi ve
/// `asciiBase` eşlemesi değişebilir. Replay bir farkı gördüğünde bunu "kod
/// regresyonu" diye sınıflandırıyor; oysa sebep sessizce değişmiş bir layout
/// olabilir. Parmak izi bu iki durumu ayırıyor: parmak izi tutmuyorsa fark
/// **ortam** farkıdır, kod farkı değil.
///
/// ## Neden kanonik gösterim
///
/// Hash'in girdisi platformun `Hashable`'ı değil, elle serileştirilmiş bir
/// dize: `Set`/`Dictionary` sırası çalıştırmalar arasında değişiyor ve
/// `Hasher` sürüm başına tohumlanıyor. İkisi de aynı layout'a farklı parmak
/// izi verir, yani her koşuda sahte bir "ortam değişti" raporu üretirdi.
///
/// Ondalıklar **sabit basamakla** yazılıyor: `Double` metin gösterimi
/// platformlar arasında farklılaşabiliyor ve 0.1 pt'lik bir farkın gerçekten
/// önemli olduğu bir yer yok. 4 basamak, tuş merkezlerini normalize koordinatta
/// ayırt etmeye fazlasıyla yetiyor.
public extension KeyLayout {

    /// Layout'un tüm gözlemlenebilir içeriğinin kanonik metni.
    ///
    /// Hash'in girdisi ayrıca **okunabilir** tutuluyor: parmak izi tutmadığında
    /// iki metni diff'lemek, hangi tuşun kaydığını doğrudan gösteriyor. Yalnız
    /// hash saklasaydık elimizde "farklı" bilgisinden fazlası olmazdı.
    var canonicalDescription: String {
        var out = "layout \(id)\n"
        // Tuş **sırası** anlamlı: `keyIndex` bütün kalibrasyon dizilerinin
        // indeksi. Sıra değişirse sapmalar başka tuşlara uygulanır. O yüzden
        // liste sıralanmadan, olduğu gibi yazılıyor.
        for (i, k) in keys.enumerated() {
            out += String(format: "key %d %@ %.4f %.4f %.4f %.4f\n",
                          i, String(k.char), k.center.x, k.center.y,
                          k.width, k.height)
        }
        // `asciiBase` bir sözlük; sırası tanımsız, o yüzden sıralanıyor.
        for (ch, base) in asciiBase.sorted(by: { $0.key < $1.key }) {
            out += "ascii \(ch) \(base)\n"
        }
        return out
    }

    /// Kanonik metnin FNV-1a 64 özeti, onaltılık.
    ///
    /// FNV-1a seçildi çünkü kriptografik dirence ihtiyaç yok (kimse layout
    /// çakıştırmaya çalışmıyor) ve `KeyboardCore`'un `CryptoKit` bağımlılığı
    /// olmaması bu katmanı platformdan bağımsız tutuyor.
    var fingerprint: String {
        String(format: "%016llx", FNV1a.hash(canonicalDescription.utf8))
    }
}
