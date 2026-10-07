/// Commit edilmiş token'ların **belgedeki** karşılığı — plan v8 §2.1.
///
/// ## Neden geri dönüş yığını yetmiyor
///
/// Silinen aralığı token'a bağlamak için `history` kullanmak iki yerde
/// yanlış olguyu **doğrulanmış gibi** yazıyordu:
///
/// 1. Eşleşme **yüzey eşitliğiyle** yapılıyordu. İmleç belgedeki başka bir
///    `kalem ` örneğine taşınırsa eski kimlik yeni konuma bağlanıyordu.
/// 2. `history` sekiz girişle sınırlı (bellek bütçesi) ve **geri açılamaz**
///    token'ları hiç taşımıyor. Dokuzuncu token silinince atıf kayboluyor
///    ama kod yine de bir kimlik yazabiliyordu.
///
/// Defter ise yazdığımız metnin **tamamını** sırayla tutuyor: silinen
/// karakter sayısı sondan geriye yürütülerek hangi token'ların hangi kısmı
/// gittiği **sayılıyor**, tahmin edilmiyor.
///
/// ## Neden ayrı bir tip
///
/// `ComposingSession`'ın içinde bir dizi ve ona dokunan beş yöntemdi; defterin
/// değişmezleri (yalnız sondan büyür, pencereye indirilir, silme sonrası hâli
/// atıfla aynı anda güncellenir) oturumun composing durumuyla iç içe
/// okunuyordu. Burada defter yalnız kendi kurallarını taşıyor; oturum ona
/// "ne yazdım, ne sildim" diyor.
struct DeletionLedger: Sendable {

    /// Belgeye yazdığımız bir parça.
    ///
    /// Ayırıcıyı token'ın **alanı** olarak tutmak yetmiyordu: `insertSymbol`
    /// sembolü `finishToken`'dan **sonra**, doğrudan editöre yazıyor ve token
    /// açık değilken de yazabiliyor. O metin deftere girmeyince defter belgeyle
    /// ayrışıyor, doğrulama her sembolde defteri atıyor ve atıf sonsuza dek
    /// `.unattributed`'a düşüyordu.
    enum Segment: Sendable {
        case token(TokenID, String)
        /// Hiçbir token'a ait olmayan metin: boşluk, satır sonu, noktalama,
        /// hazır metin.
        case separator(String)

        var text: String {
            switch self {
            case let .token(_, t), let .separator(t): return t
            }
        }
    }

    private(set) var segments: [Segment] = []

    var isEmpty: Bool { segments.isEmpty }

    /// Defterin anlattığı belge öneki.
    var text: String { segments.reduce(into: "") { $0 += $1.text } }

    mutating func append(token id: TokenID, _ text: String) {
        segments.append(.token(id, text))
    }

    mutating func append(separator text: String) {
        guard !text.isEmpty else { return }
        segments.append(.separator(text))
    }

    /// "Bu noktadan öncesini bilmiyorum" — yürüyüş defteri aşınca dürüstçe
    /// `.unattributed` üretiyor.
    mutating func removeAll() { segments.removeAll() }

    // MARK: - Doğrulama

    /// Defteri belgeye karşı **doğrular**; uyuşmuyorsa atar.
    ///
    /// Sonek karşılaştırması: host'ta biz başlamadan önce metin olabilir.
    ///
    /// Uyuşmazlıkta defteri atmak, `ledgerValid` gibi kalıcı bir bayrak
    /// tutmaktan doğru: bayrak bir kez düşünce sonraki **yeni** token'lar da
    /// sonsuza dek atfedilemez olurdu. Defteri boşaltmak ise "bu noktadan
    /// öncesini bilmiyorum" demek — yürüyüş defteri aşınca zaten
    /// `.unattributed` üretiyor.
    ///
    /// ## Sonek eşleşmesi **konumu kanıtlamıyor**
    ///
    /// Karşı örnek: belgede zaten `"a "` varken klavye ikinci bir `"a "` yazıyor
    /// (`id=0`), sonra imleç **ilk** `"a "`nın sonuna taşınıyor. `contextBefore`
    /// artık `"a "` ve sonek kontrolü geçiyor — defter yabancı metni kendi
    /// token'ı sanıyor ve `restoreToken(0)` yazıyor.
    ///
    /// Bu deliği sonek kontrolü **hiçbir biçimde** kapatamaz: klavye imleç
    /// konumunu göremiyor, host da bize hareket bildirmiyor. Tek dürüst çözüm
    /// imlecin oynamış **olabileceği** her noktada konumsal atfı bırakmak
    /// (`ComposingSession.invalidatePositionalAttribution`). Sonek kontrolü o
    /// yüzden burada kalıyor ama artık **tek** savunma değil: host'un yazdığı
    /// metni yakalamaya çalışıyor, imleç hareketini değil.
    ///
    /// ## Bağlam penceresi defterden **kısa** olabilir
    ///
    /// `UITextDocumentProxy.documentContextBeforeInput` belgenin tamamını
    /// vermek zorunda değil. Uzun bir denemede pencere defterin anlattığı
    /// önekten kısa kalıyor ve sonek kontrolü **doğru** bir defteri reddediyor:
    /// atıf o noktadan sonra sonsuza dek `.unattributed`'a düşüyor ve bunu
    /// hiçbir şey raporlamıyor. Yani özellik uzun oturumlarda — tam da ölçmek
    /// istediğimiz yerde — sessizce kapanıyor.
    ///
    /// Çözüm defteri **pencereye indirmek**: görünen sonek defterin bir soneki
    /// ise, pencerenin tamamen kapsadığı segmentler korunur, kapsamadıkları
    /// atılır. Kısmen görünen bir token'ın metni doğrulanamıyor, dolayısıyla
    /// kimliği de kullanılamaz. Defterin ötesine uzanan silme zaten
    /// `.unattributed` üretiyor — yani kaybedilen bilgi kayda **olgu olarak**
    /// giriyor, uydurulmuyor.
    ///
    /// - Parameter pending: henüz commit edilmemiş, belgede defterin **ardından**
    ///   duran yüzey.
    mutating func verify(contextBefore before: String?, pending: String) {
        guard !segments.isEmpty else { return }
        // Boş bağlam kanıt değil: `hasSuffix("")` her defteri geçirirdi.
        guard let before, !before.isEmpty else {
            segments.removeAll()
            return
        }
        let believed = text + pending
        if before.hasSuffix(believed) { return }
        // Pencere kısa mı, yoksa belge gerçekten farklı mı: ikisini ayıran şey
        // inandığımız metnin görüneni **içermesi**.
        guard believed.hasSuffix(before) else {
            segments.removeAll()
            return
        }
        trim(toWindowOf: before.count - pending.count)
    }

    /// Defteri, pencerenin **tamamen** kapsadığı segmentlere indirir.
    ///
    /// - Parameter budget: pencerenin deftere düşen kısmı (bekleyen yüzey
    ///   henüz commit edilmedi, deftere ait değil).
    private mutating func trim(toWindowOf budget: Int) {
        var budget = budget
        guard budget > 0 else {
            segments.removeAll()
            return
        }
        var kept: [Segment] = []
        for segment in segments.reversed() {
            let n = segment.text.count
            // Kısmen görünen segment: metnini doğrulayamıyoruz, kimliğini
            // kullanmak da uydurma olur. Burada duruyoruz — öncesi de görünmez.
            if n > budget { break }
            budget -= n
            kept.append(segment)
        }
        segments = kept.reversed()
    }

    // MARK: - Silme atfı

    /// Sondan `count` karakter silindiğinde hangi token'ların hangi kısmının
    /// gittiğini **sayar**.
    ///
    /// Defteri de silme sonrası hâline getiriyor: atıf ile defterin ayrışması,
    /// bir sonraki silmenin yanlış token'ı işaretlemesi demekti.
    ///
    /// - Returns: **belgedeki sıraya** göre (eskiden yeniye), kanonik.
    mutating func attributeDeletion(of count: Int) -> [DeletedSpan] {
        guard count > 0 else { return [] }
        var remaining = count
        var spans: [DeletedSpan] = []          // yeniden eskiye toplanıyor

        while remaining > 0, let segment = segments.last {
            segments.removeLast()

            switch segment {
            case let .separator(text):
                let n = min(remaining, text.count)
                remaining -= n
                spans.append(.separator)
                if n < text.count {
                    segments.append(.separator(String(text.dropLast(n))))
                }

            case let .token(id, text):
                if remaining >= text.count {
                    remaining -= text.count
                    spans.append(.removedToken(id))
                } else {
                    // Token'ın **bir kısmı** silindi; kalanı belgede duruyor.
                    segments.append(.token(id, String(text.dropLast(remaining))))
                    remaining = 0
                    spans.append(.editedToken(id))
                }
            }
        }

        if remaining > 0 {
            // Defterin öncesine uzanıyor: bizim yazmadığımız metin ya da
            // host'un değiştirdiği bir bölge. Kimlik uydurmuyoruz.
            spans.append(.unattributed)
        }
        return DeletedSpan.canonical(spans.reversed())
    }

    // MARK: - Geri açma

    /// Defterin sonu **token + ayırıcı** mı — geri açılabilecek kuyruk.
    var restorableTail: (id: TokenID, text: String, separator: String)? {
        guard segments.count >= 2,
              case let .separator(sep) = segments[segments.count - 1],
              case let .token(id, text) = segments[segments.count - 2]
        else { return nil }
        return (id, text, sep)
    }

    /// Geri açılan token'ı ve ayırıcısını defterden çıkarır.
    ///
    /// Token artık **açık**: metni composing yüzeyine geçiyor. Defterde
    /// bırakmak, aynı karakterlerin hem commit edilmiş hem bekleyen sayılması
    /// demekti.
    mutating func popRestorable() {
        guard restorableTail != nil else { return }
        segments.removeLast(2)
    }
}
