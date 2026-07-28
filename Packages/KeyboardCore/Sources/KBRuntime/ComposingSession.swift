import KBGeometry
import KBSpatial

/// Belgeye yazma yeteneği — `UITextDocumentProxy`'nin bu oturumun ihtiyaç
/// duyduğu kadarı.
///
/// Protokol olmasının sebebi test edilebilirlik değil sadece; **metnin sahibi
/// host'tur** (plan §8) ve oturum ona yalnız bu üç kanaldan dokunabilir.
/// Genişlerse §8 uzlaştırmasının kapsamı da genişler — dar tutuluyor.
public protocol DocumentEditor: AnyObject {
    func insertText(_ text: String)
    func deleteBackward()
    var contextBeforeInput: String? { get }
}

/// Yazılmakta olan token'ın durumu + commit edilmiş kelimelerin geri dönüş yığını.
///
/// ## Üç paralel dizi, üç ayrı iş
///
/// | Alan | Ne | Kim tüketir |
/// |---|---|---|
/// | `touches` | uzamsal kanıt | decoder |
/// | `literal` | kullanıcının gerçekte bastığı harfler | `cost(literal)`, `θ` (§8) |
/// | `display` | belgede **şu an duran** karakterler | belge düzenlemeleri |
///
/// Taze yazımda `display == literal`. Otomatik düzeltmeden sonra ayrışırlar:
/// `lslem` yazıldı, belgede `kalem` duruyor. Silme sayısını `literal`'den
/// hesaplamak bu yüzden hataydı — belgeden yanlış sayıda karakter silinirdi.
///
/// ## Değişmez: `touches.count == literal.count`
///
/// Dokunma `i` her zaman literal karakter `i`'nin kanıtıdır. `display` bu
/// eşlemenin dışındadır ve **uzunluğu farklı olabilir**.
///
/// Ayrışmış bir yüzeyin **içinden** silmek bu eşlemeyi kurtarılamaz biçimde
/// bozar: belgede `kalem` dururken hangi dokunmanın `m`'yi ürettiği bilinmez.
/// O anda kanıt **kopar** (`isDetached`) — token'ın kalanı düz klavye gibi
/// çalışır, öneri ve otomatik düzeltme kapanır. Üç diziden körlemesine birer
/// öğe eksiltmek alternatifiydi; o yol decoder'ı başka bir metnin kanıtıyla
/// çalıştırıp yanlış yüzeyi commit ediyordu.
///
/// ## Neden `KBRuntime`'da
///
/// Bu bir kullanıcı arayüzü davranışı değil, **host senkronizasyon durumu**.
/// Uzantı hedefinde dursaydı hiç test edilemezdi; buradaki hâliyle
/// `swift test` altında koşuyor.
public struct ComposingSession: Sendable {

    /// Bir işlemden sonra decoder'ın ne yapması gerektiği.
    ///
    /// Artımlı kod çözme (§11.C.1) yalnız `.appended` durumunda korunur; geri
    /// kalanında beam yeniden kurulur. Bu ayrım tutulmazsa ya her tuşta karesel
    /// maliyet ödenir ya da beam bayat kalır.
    public enum Outcome: Equatable, Sendable {
        /// Hiçbir şey değişmedi.
        case unchanged
        /// Tek dokunma eklendi — beam bir adım uzatılabilir.
        case appended
        /// Dokunma dizisi değişti — beam sıfırdan kurulmalı.
        case rebuilt
        /// Token kapandı — beam sıfırlanmalı.
        case cleared
    }

    /// Boşlukla kapatılmış, geri dönülebilir bir kelime.
    struct Committed: Sendable {
        var touches: [TouchSample]
        var literal: String
        var display: String
    }

    public private(set) var touches: [TouchSample] = []
    public private(set) var literal: String = ""
    public private(set) var display: String = ""

    /// Kanıt koptu: bu token'ın belgedeki yüzeyi ile dokunma dizisi arasında
    /// konumsal eşleme kalmadı. Token kapanana kadar öneri ve otomatik düzeltme
    /// **yapılmaz** — kanıtı olmayan bir düzeltme kullanıcının yazdığını bozardı.
    public private(set) var isDetached = false

    private var history: [Committed] = []

    /// Geri dönüş yığınının derinliği. Sınırsız olamaz: her giriş kendi dokunma
    /// dizisini tutuyor ve uzantı bellek bütçesi dar (§11.D).
    public static let maxHistoryDepth = 8

    public init() {}

    public var isComposing: Bool { !display.isEmpty }

    // MARK: - Yazma

    /// Harf ekler. Literal **anında** yazılır — yazma hissi decoder'ı beklemez.
    ///
    /// Ekleme, ayrışmış bir yüzeyde bile güvenlidir: eşleme yalnız **sondan**
    /// büyür, mevcut karakterlerin kanıtı yerinde kalır. Bozan işlem silmedir.
    public mutating func insertLetter(_ ch: Character,
                                      touch: TouchSample,
                                      into editor: DocumentEditor) -> Outcome {
        editor.insertText(String(ch))
        display.append(ch)
        guard !isDetached else { return .rebuilt }   // kanıtsız token: beam boş kalır
        literal.append(ch)
        touches.append(touch)
        return .appended
    }

    /// Belgede duran token'ı `surface` ile değiştirir (otomatik düzeltme ya da
    /// öneri çubuğundan seçim). `touches`/`literal` **korunur** — kanıt hâlâ
    /// kullanıcının bastığı yerdir, gösterilen yüzey değişse bile.
    ///
    /// Kopuk token'da **hiçbir şey yapmaz** ve `false` döner. "Kopuk token'a
    /// dokunulmaz" kuralı çağıranın nezaketine bırakılamaz: gecikmiş bir öneri
    /// geri çağrısı ya da yeni bir çağrı yolu kuralı sessizce çiğneyebilir.
    @discardableResult
    public mutating func replaceDisplay(with surface: String,
                                        into editor: DocumentEditor) -> Bool {
        guard !isDetached else { return false }
        guard surface != display else { return false }
        for _ in 0..<display.count { editor.deleteBackward() }
        editor.insertText(surface)
        display = surface
        return true
    }

    /// Token'ı kapatır: geçmişe yazar, ayırıcıyı ekler, composing durumunu boşaltır.
    public mutating func finishToken(separator: String,
                                     into editor: DocumentEditor) -> Outcome {
        // Kanıtı kopmuş token geçmişe **yazılmaz**: geri dönüldüğünde yükleyecek
        // bir kanıt yok, ama boş `touches` üzerine yazılan yeni harfler yüzeyin
        // tamamını temsil ediyormuş gibi görünüp yanlış düzeltme üretirdi.
        if !display.isEmpty && !isDetached {
            history.append(Committed(touches: touches, literal: literal, display: display))
            if history.count > Self.maxHistoryDepth { history.removeFirst() }
        }
        if !separator.isEmpty { editor.insertText(separator) }
        clearComposing()
        return .cleared
    }

    // MARK: - Silme

    /// Tek dokunuşla geri silme.
    ///
    /// Token'ın başındayken **bir önceki kelimeye geri döner**: yalnız boşluk
    /// silinir, kelime yerinde kalır ve o kelimenin dokunma kanıtı geri yüklenir.
    /// Böylece kullanıcı geri gelip harf eklediğinde öneriler kaldığı yerden
    /// devam eder — kelimeyi düzeltmek yeniden yazmayı gerektirmez.
    public mutating func backspaceTap(into editor: DocumentEditor) -> Outcome {
        if !display.isEmpty { return deleteOneComposingCharacter(into: editor) }
        if restorePreviousWord(into: editor) { return .rebuilt }
        editor.deleteBackward()
        history.removeAll()
        return .unchanged
    }

    /// Basılı tutma tekrarındaki silme.
    ///
    /// Geri yükleme **bilinçli olarak yok**: kullanıcı toplu siliyor, düzenlemiyor.
    /// Tekrar sırasında her kelime sınırında öneri çubuğunun canlanması hem
    /// gereksiz iş hem görsel gürültü olurdu.
    public mutating func backspaceRepeat(into editor: DocumentEditor) -> Outcome {
        if !display.isEmpty { return deleteOneComposingCharacter(into: editor) }
        editor.deleteBackward()
        history.removeAll()
        return .unchanged
    }

    /// Kelime kelime silme — uzun basma ikinci kademesi.
    ///
    /// Sondaki boşlukları, sonra bir kelimeyi siler. Satır sonunu **geçmez**:
    /// `\n` silme sınırıdır, yoksa tek uzun basma birkaç satırı yutar.
    public mutating func deleteWordBackward(into editor: DocumentEditor) -> Outcome {
        if !display.isEmpty {
            for _ in 0..<display.count { editor.deleteBackward() }
            clearComposing()
            return .cleared
        }

        guard let before = editor.contextBeforeInput, !before.isEmpty else {
            return .unchanged
        }

        var chars = Array(before)

        // Satır sonu bir sınırdır: bu çağrı ya sınıra kadar siler ya **yalnız**
        // sınırı siler. İkisini birden yapmak, 0.22 sn'lik tekrar temposunda tek
        // basılı tutuşla önceki satırın sonunu da yutmak demekti — ve eski
        // koddaki `deleted == 0 → 1` düşüşü tam olarak bunu yapıyordu.
        //
        // `isNewline`, `== "\n"` karşılaştırmasının yerini alıyor: Swift'te
        // `"\r\n"` **tek** bir `Character`, dolayısıyla eşitlik kontrolü CRLF'de
        // sessizce ıskalıyordu. `isNewline` CRLF'yi de, U+2028/U+2029 gibi
        // ayırıcıları da tek silme birimi olarak kapsıyor.
        if chars.last?.isNewline == true {
            editor.deleteBackward()
            history.removeAll()
            return .unchanged
        }

        var deleted = 0
        while let last = chars.last, last == " " || last == "\t" {
            chars.removeLast(); deleted += 1
        }
        while let last = chars.last, !last.isWhitespace {
            chars.removeLast(); deleted += 1
        }
        // Sıra dışı bir boşluk karakteri (satır ayırıcı, bölünemez boşluk) iki
        // döngüyü de durdurabilir; tuş ölü hissettirmesin diye bir karakter.
        if deleted == 0 { deleted = 1 }

        for _ in 0..<deleted { editor.deleteBackward() }

        // Sildiğimiz kelime geçmişin tepesindekiyse yalnız onu düşür; değilse
        // hizayı kaybettik demektir, tamamını at.
        if let last = history.last, !last.display.isEmpty,
           before.trimmingTrailingSpaces().lastToken() == last.display {
            history.removeLast()
        } else {
            history.removeAll()
        }
        return .unchanged
    }

    private mutating func deleteOneComposingCharacter(into editor: DocumentEditor) -> Outcome {
        let wasAligned = !isDetached && display.count == literal.count
        editor.deleteBackward()
        display.removeLast()

        if wasAligned {
            literal.removeLast()
            touches.removeLast()
        } else {
            detachEvidence()
        }
        if display.isEmpty { isDetached = false }   // token bitti, temiz sayfa
        return .rebuilt
    }

    /// Kanıtı düşürür. Yüzey belgede duruyor; hangi dokunmanın hangi karakteri
    /// ürettiği artık bilinmediği için kanıt saklanmaz.
    private mutating func detachEvidence() {
        isDetached = true
        literal = ""
        touches.removeAll(keepingCapacity: true)
    }

    private mutating func restorePreviousWord(into editor: DocumentEditor) -> Bool {
        guard let last = history.last, !last.display.isEmpty,
              let before = editor.contextBeforeInput,
              before.hasSuffix(" ")
        else { return false }

        // **Tam token eşitliği** — sonek kontrolü yetmez. Geçmişte `iki` varken
        // belgede `biriki ` durursa sonek tutar ve `biriki`nin son üç harfine
        // başka bir kelimenin dokunmaları bağlanırdı.
        guard String(before.dropLast()).lastToken() == last.display else { return false }

        editor.deleteBackward()          // yalnız boşluk; kelime yerinde kalıyor
        history.removeLast()
        touches = last.touches
        literal = last.literal
        display = last.display
        isDetached = false
        return true
    }

    // MARK: - Host uzlaştırması (§8)

    /// Belgedeki metin bizim tamponumuzla uyuşuyor mu.
    ///
    /// Tampon **spekülatif bir önbellektir**; host imleci taşımış, metni
    /// dönüştürmüş ya da alan değişmiş olabilir. Uyuşmuyorsa durum atılır —
    /// yanlış yere silme yapmaktansa öneriyi kaybetmek yeğdir.
    ///
    /// Composing boşken `true` dönmek **yetmez**: o durumda bile geri dönüş
    /// yığını host metnine dair bir iddia taşıyor. Doğrulanmazsa host metni
    /// değiştikten sonra sonek tesadüfen tutabilir ve eski bir kelimenin
    /// dokunmaları yepyeni bir konuma bağlanır.
    public func agreesWithHost(_ editor: DocumentEditor) -> Bool {
        guard let before = editor.contextBeforeInput else {
            return display.isEmpty && history.isEmpty
        }
        if !display.isEmpty { return before.hasSuffix(display) }
        guard let last = history.last else { return true }
        return before.hasSuffix(last.display + " ")
    }

    /// Composing durumunu ve geri dönüş yığınını atar.
    public mutating func invalidate() -> Outcome {
        clearComposing()
        history.removeAll()
        return .cleared
    }

    private mutating func clearComposing() {
        literal = ""
        display = ""
        isDetached = false
        touches.removeAll(keepingCapacity: true)
    }
}

private extension String {
    /// Sondaki boşluk ve sekmeler atılmış hâli.
    func trimmingTrailingSpaces() -> String {
        var s = Substring(self)
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return String(s)
    }

    /// Sondaki boşluk olmayan karakter dizisi — belgenin son token'ı.
    func lastToken() -> String {
        String(reversed().prefix { !$0.isWhitespace }.reversed())
    }
}
