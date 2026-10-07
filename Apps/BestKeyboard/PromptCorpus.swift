import Foundation
import KBGeometry
import KBSessions
import KBFoundation

/// Hedef cümle korpusu — sözleşme §12.8.
///
/// ## Neden elle küratörlü, rastgele değil
///
/// Faz 3'ün ince katmanı tuş başına `n >= 20`, satır başına `n >= 30` örnek
/// istiyor (§8.6). Doğal Türkçe Zipf dağılımlıdır: rastgele cümlelerle `j`, `f`,
/// `ğ`, `ö`, `ç` gibi tuşlar o eşiğe **hiç ulaşmayabilir** ve o tuşların
/// kalibrasyon katmanı hiç açılmaz. Korpus bu yüzden kapsayış hedefiyle
/// kuruldu: nadir harfleri taşıyan cümleler bilerek eklendi.
///
/// Ölçülen kapsayış (76 cümle, 477 kelime): aşağıdaki üç istisna dışında
/// **her harf >= 20**.
///
/// ## `q`, `w`, `x` — kapatılamayan boşluk
///
/// Bu üç harf Türkçede yoktur. Depo bunu zaten kabul ediyor: `wordlist.tsv`
/// üretilirken *"q, w, x içeren formlar çıkarıldı (neredeyse tamamı altyazı
/// kaynaklı yabancı özel ad)"* (LICENSES.md). Yabancı sözcük ve marka içeren
/// birkaç cümle eklendi ama sayılar yine de eşiğin altında (q=4, x=6, w=9).
///
/// **Sonuç kabul ediliyor ve kayda geçiyor:** bu üç tuşun `d_c` katmanı
/// açılmaz, satır ve global katmandan beslenirler. Doğru davranış budur —
/// ampirik Bayes zaten örneklenmemiş birimi kendiliğinden kapatır (§8.6).
///
/// ## Split veri görülmeden sabit
///
/// §12.8: *"oturum sonucuna bakılarak atanamaz"*. Atama indeksle
/// deterministik (`i % 5`), içerikten bağımsız. Bir deneme = bir prompt
/// olduğu için prompt-ayrık split aynı zamanda **oturum-ayrık**tır.
enum PromptCorpus {

    struct Prompt: Identifiable, Hashable {
        enum Split: String { case train, dev, test }
        let id: String
        let text: String
        let split: Split

        /// Kelime kelime gösterim için — `calibrationReplay` hizalamayı
        /// buradan kuruyor (§12.4).
        ///
        /// Kural **`KBSessions.PromptTokenizer`'da** (plan v8 §2.3). Burada
        /// yaşarken yalnız boşluktan bölüp uç noktalamayı sıyırıyordu:
        /// `Wi-Fi şifresi` tek token sayılıp `-` tuşuna basıldığında hizalama
        /// deliniyor, `Ali` hedefi çıkarıcıda `keyIndex("A") == nil` yüzünden
        /// tamamen düşüyor ve boş hedef denemeyi hiçbir şey ölçmeden `completed`
        /// yapıyordu. Kayıt zincirinin doğruladığı dizi ile UI'ın gösterdiği
        /// dizinin aynı olması ancak tek kaynak varsa garanti.
        func words(layout: KeyLayout) -> [String] {
            PromptTokenizer(layout: layout).tokens(of: text)
        }
    }

    static let all: [Prompt] = [
        Prompt(id: "p000", text: "Ali atlara bakmaktan zevk alır.", split: .train),
        Prompt(id: "p001", text: "Bu yüzden sürekli bakar, yanlarına gidip onları sever.", split: .train),
        Prompt(id: "p002", text: "Yağmur yağınca ağaçların altında bekledik.", split: .train),
        Prompt(id: "p003", text: "Öğle vakti çiftlikteki fırından sıcak ekmek aldık.", split: .dev),
        Prompt(id: "p004", text: "Çocuklar bahçede top oynarken köpek havlamaya başladı.", split: .test),
        Prompt(id: "p005", text: "Gözlüğümü masanın üstünde unutmuşum galiba.", split: .train),
        Prompt(id: "p006", text: "Kızım pencereden bakıp güneşin batışını izledi.", split: .train),
        Prompt(id: "p007", text: "Yeni telefonun ekranı eskisinden çok daha parlak.", split: .train),
        Prompt(id: "p008", text: "Balkondaki çiçekleri sulamayı yine unuttum.", split: .dev),
        Prompt(id: "p009", text: "Akşam yemeğinden sonra kısa bir yürüyüşe çıktık.", split: .test),
        Prompt(id: "p010", text: "Sabah erkenden kalkıp otobüse yetişmeye çalıştım.", split: .train),
        Prompt(id: "p011", text: "Kitabı bitirdikten sonra arkadaşıma ödünç verdim.", split: .train),
        Prompt(id: "p012", text: "Havuzun kenarında oturup kavun yedik.", split: .train),
        Prompt(id: "p013", text: "Davul sesi vadinin öbür yakasından duyuluyordu.", split: .dev),
        Prompt(id: "p014", text: "Evin duvarlarını açık renge boyamaya karar verdik.", split: .test),
        Prompt(id: "p015", text: "Vapur iskeleye yanaşırken vardiyası biten işçiler indi.", split: .train),
        Prompt(id: "p016", text: "Valizimi hazırlarken vitamin haplarını da koydum.", split: .train),
        Prompt(id: "p017", text: "Jandarma barajın yanındaki garaja doğru ilerledi.", split: .train),
        Prompt(id: "p018", text: "Müjdeli haberi duyunca jetonlarımı masaya bıraktım.", split: .dev),
        Prompt(id: "p019", text: "Plajda jeneratör bozulunca müzik birden sustu.", split: .test),
        Prompt(id: "p020", text: "Jülide jimnastik salonunda jaguar posterini asmış.", split: .train),
        Prompt(id: "p021", text: "Bu projede jeoloji mühendisi olarak görev aldı.", split: .train),
        Prompt(id: "p022", text: "Genç garson gazozları getirirken tepsiyi düşürdü.", split: .train),
        Prompt(id: "p023", text: "Cuma günü cami avlusunda cemaat toplanmıştı.", split: .dev),
        Prompt(id: "p024", text: "Zeytinyağlı sarma ile zerdeli tatlıyı çok sevdim.", split: .test),
        Prompt(id: "p025", text: "Gemi limandan ayrılırken güvertede gitar çalıyordu.", split: .train),
        Prompt(id: "p026", text: "Cezve ocakta unutulunca kahve taştı.", split: .train),
        Prompt(id: "p027", text: "Zamanla gözlerim karanlığa alıştı ve gölgeleri seçtim.", split: .train),
        Prompt(id: "p028", text: "Öğretmen tahtaya yazdığı soruyu tekrar açıkladı.", split: .dev),
        Prompt(id: "p029", text: "Köyün ortasındaki çeşmeden gürül gürül su akıyordu.", split: .test),
        Prompt(id: "p030", text: "Görevli önümüzdeki bölümü göstererek yolu tarif etti.", split: .train),
        Prompt(id: "p031", text: "Üzüm bağının üstünden serin bir rüzgar esiyordu.", split: .train),
        Prompt(id: "p032", text: "Bütün gün süren toplantıdan sonra herkes yorgundu.", split: .train),
        Prompt(id: "p033", text: "Sürücü dörtlüleri yakıp güvenli bir yere çekildi.", split: .dev),
        Prompt(id: "p034", text: "Postacı paketi kapıya bırakıp zili çaldı.", split: .test),
        Prompt(id: "p035", text: "Şoför virajı dönerken hızını iyice düşürdü.", split: .train),
        Prompt(id: "p036", text: "Şehrin şantiyesinde çalışan işçiler şapkalarını taktı.", split: .train),
        Prompt(id: "p037", text: "Fırtına çıktığı için plajdaki şemsiyeleri topladılar.", split: .train),
        Prompt(id: "p038", text: "Fotoğraf makinesinin flaşı fazla parlak geldi.", split: .dev),
        Prompt(id: "p039", text: "Hafta sonu hastaneye hemşire arkadaşımı ziyarete gittim.", split: .test),
        Prompt(id: "p040", text: "Halının üstüne serilen hasır sandalyeye oturdum.", split: .train),
        Prompt(id: "p041", text: "Pazar sabahı pastaneden poğaça ve peynirli börek aldık.", split: .train),
        Prompt(id: "p042", text: "Sağlık ocağına giderken eczaneye de uğradım.", split: .train),
        Prompt(id: "p043", text: "Düğün için sağdıcın takım elbisesini beğendik.", split: .dev),
        Prompt(id: "p044", text: "Çayı demlerken çaydanlığın kapağı çatladı.", split: .test),
        Prompt(id: "p045", text: "Ağabeyim değirmenin yanındaki bağa doğru yürüdü.", split: .train),
        Prompt(id: "p046", text: "Çorbayı içerken çatalı yanlışlıkla yere düşürdüm.", split: .train),
        Prompt(id: "p047", text: "Bebek beşikte uyurken bahçeden bülbül sesi geliyordu.", split: .train),
        Prompt(id: "p048", text: "Yolun ortasında yatan yorgun köpek yavaşça doğruldu.", split: .dev),
        Prompt(id: "p049", text: "Otobüs durağında oturup otuz dakika bekledim.", split: .test),
        Prompt(id: "p050", text: "Bakkaldan bir bardak ayran ve biraz bisküvi aldım.", split: .train),
        Prompt(id: "p051", text: "Yaz boyunca yaylada yoğurt ve bal yedik.", split: .train),
        Prompt(id: "p052", text: "Doktor reçeteyi yazdıktan sonra dinlenmemi söyledi.", split: .train),
        Prompt(id: "p053", text: "Kalem kutusunda kırmızı kalemi bulamadım.", split: .dev),
        Prompt(id: "p054", text: "Lambanın ışığı kitabın sayfalarına düşüyordu.", split: .test),
        Prompt(id: "p055", text: "Marketten makarna, mercimek ve mısır aldım.", split: .train),
        Prompt(id: "p056", text: "Nehrin kenarında nilüferler açmıştı.", split: .train),
        Prompt(id: "p057", text: "Rüzgar rafta duran resmi devirdi.", split: .train),
        Prompt(id: "p058", text: "Sokakta susuz kalan saksıları suladım.", split: .dev),
        Prompt(id: "p059", text: "Tren istasyonuna tam zamanında vardık.", split: .test),
        Prompt(id: "p060", text: "Isıtıcıyı açınca ılık bir hava odayı doldurdu.", split: .train),
        Prompt(id: "p061", text: "Wi-Fi şifresini bulmak için kutunun arkasına baktık.", split: .train),
        Prompt(id: "p062", text: "Taksi şoförü Oxford Caddesi'ne gitmek istediğimi anladı.", split: .train),
        Prompt(id: "p063", text: "Yeni laptopta Windows kurulumu epey uzun sürdü.", split: .dev),
        Prompt(id: "p064", text: "Quiz yarışmasında Xerox marka fotokopi makinesi hediye edildi.", split: .test),
        Prompt(id: "p065", text: "Web sitesinin adresini WhatsApp üzerinden yolladım.", split: .train),
        Prompt(id: "p066", text: "Qatar Airways uçuşunu web sitesinden sorguladım.", split: .train),
        Prompt(id: "p067", text: "Excel dosyasını Word belgesine kopyalayıp kaydettim.", split: .train),
        Prompt(id: "p068", text: "Taxi uygulamasında qr kodu okutunca indirim çıktı.", split: .dev),
        Prompt(id: "p069", text: "Wikipedia'da xilofon maddesini okurken quiz sorusunu hatırladım.", split: .test),
        Prompt(id: "p070", text: "Jokey jübile töreninde jaketini giydi.", split: .train),
        Prompt(id: "p071", text: "Bej rengi jile ile jarse eteği birlikte aldı.", split: .train),
        Prompt(id: "p072", text: "Fen dersinde fizik formüllerini defterime yazdım.", split: .train),
        Prompt(id: "p073", text: "Futbolcu faul yapınca hakem faul düdüğünü çaldı.", split: .dev),
        Prompt(id: "p074", text: "Fabrikanın filtresi bozulunca fanlar durdu.", split: .test),
        Prompt(id: "p075", text: "Jimnastikçi jüri önünde jeste benzer bir hareket yaptı.", split: .train),
    ]

    /// Bir prompt kümesinin tuş kapsayışı: tuş indeksi -> görülme sayısı.
    ///
    /// UI bunu gösteriyor ki hangi tuşun eksik kaldığı **ölçülerek** bilinsin,
    /// tahmin edilmesin.
    static func coverage(_ prompts: [Prompt], layout: KeyLayout) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for p in prompts {
            for ch in TurkishText.lowercased(p.text) {
                guard let k = layout.keyIndex(for: ch) else { continue }
                counts[k, default: 0] += 1
            }
        }
        return counts
    }

    /// Faz 3 eşiğinin (`minKeySamples = 20`) altında kalan tuşlar.
    static func underCovered(_ prompts: [Prompt], layout: KeyLayout,
                             threshold: Int = 20) -> [Character] {
        let c = coverage(prompts, layout: layout)
        return layout.keys.indices
            .filter { (c[$0] ?? 0) < threshold }
            .map { layout.keys[$0].char }
    }

    /// Hedefin tamamı bu layout'ta yazılabiliyor mu.
    ///
    /// Elle girilen hedefte zorunlu: yazılamayan tek karakter, o token'ın
    /// kalibrasyona hiç girmemesine yol açar — `CalibrationLearner.observe`
    /// tek eşlenemeyen karakterde **token'ın tamamını** reddediyor.
    static func unsupportedCharacters(in text: String, layout: KeyLayout) -> [Character] {
        var out: [Character] = []
        for ch in TurkishText.lowercased(text) where ch != " " {
            if layout.keyIndex(for: ch) != nil { continue }
            if SymbolPlanes.numbers.keys.contains(where: { $0.char == ch }) { continue }
            if SymbolPlanes.symbols.keys.contains(where: { $0.char == ch }) { continue }
            out.append(ch)
        }
        return out
    }
}
