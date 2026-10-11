# Klavye bulguları ve çözüm mimarisi

> Uygulama durumu (10 Ekim 2026): Tasarımın altında kalan metin tarihsel öneridir. Güncel uygulama, test sonuçları ve kurulum durumu `audits/implementation-progress.json` içinde; 140 turun ilgili regresyon aileleri `audits/closure-review-matrix.json` içinde izlenir. Son kontrol, 631 tarihsel girdiyi üç dokunma ofsetinde korudu; kalan `yokunuzdan` eski 46. turda doğrulanmış yazım hatası sayılmayan keşif kontrolüdür. Boşluk onarımı 60/60 geometri denemesinde ve gerçek klavye uzantısında doğrulandı. Fiziksel kurulumun sonucu ilerleme kaydında ayrıca tutulur.

140 tarama turunun sonucunu tek bir çözüm planına bağlıyoruz. Tur sayısı, başarısız örnek sayısı ve bağımsız hata sayısı farklıdır. Bu belge uygulama öncesi tasarımdır; sorunların çözüldüğü anlamına gelmez. Öncelik kullanıcının yazdığını korumak, ardından doğru aday üretmek ve öğrenmeyi güvenilir kılmaktır.

Kanıtların tamamı `audits/` altında kalır. `audits/architecture-review-index.json` her turu çözüm alanlarıyla eşler; ilk turun kanıtı ve tarihsel açıklamalar `docs/00-score-contract.md` §8 içindedir. Çekirdek testi, uygulamadan modellenmiş akış, gerçek simülatör gözlemi ve henüz doğrulanmamış varsayım birbirinin yerine geçmez. Negatif testler ve ürün fırsatları hata olarak sayılmaz.

## Temel karar

Mevcut Swift modülleri, uzamsal decoder, skor sözleşmesi ve replay altyapısı korunarak aşamalı dönüşüm yapılmalı. Baştan yazım veya her kelimeye istisna ekleme önerilmiyor. Sorunun ana ekseni; düzenlenecek metin aralığının, dilsel analiz biriminin ve öğrenilecek olayın bugün farklı yerlerde farklı tanımlanmasıdır.

On dört çalışma alanı vardır; bunlar on dört bağımsız hata demek değildir.

| Alan | Birleştirilen sorunlar | Çözümün sahibi |
|---|---|---|
| Düzenleme yaşam döngüsü | Geri silmede özgün metnin kaybı, ayırıcıdan sonra yalnız ekin değerlendirilmesi, seçimle çevre metnin silinmesi | KBRuntime düzenleme oturumu |
| Seçim ve kayıt | Büyük harf/şapka/sembollü seçimde önerisizlik, yeniden seçim, recorder devrinde durum kaybı | Oturum snapshot ve seçim bağdaştırıcısı |
| Düzeltme politikası | Teknik öneğin ve harf biçiminin kaybolması, bilinmeyen doğru kelimenin değişmesi | Tek karar kapısı |
| Türkçe ek zincirleri | Eksik birleşimler ve tekrar eden kişi/ek-fiil gibi aşırı üretim | KBMorphology |
| Kök verisi | Eksik kökler, yanlış tür/çekim bilgisi, çelişen kayıtlar ve frekanslar | Paket üretimi ve veri doğrulama |
| Ses olayları | Şapkalı ünlüler, ters uyum, ünlü düşmesi, yumuşama, ikizleşme ve bileşik gövdeler | Özellikli gövde dönüşümleri |
| Kişisel öğrenme | Açık seçimin öğrenilmemesi, yeniden commit ile sahte kanıt, kapasitede yeni kelimenin atılması | Öğrenme olayları ve kişisel sözlük |
| Geçmiş ve kimlik | Çift sayım, alan/satır sınırları, birleştirmede sıralama, silmenin kapsamı | Öğrenilmiş varlık deposu |
| İçe aktarma | ZIP sınır taşması, yanlış gönderen, medya/sistem satırı karışması | Format ayrıştırıcıları |
| Kalıcılık | Yazma başarısızlığında veri veya taslak kaybı, yanlış başarı bildirimi | Kalıcı işlem protokolü |
| Teknik metin | URL/e-posta/IP/telefon/yol parçalanması, yanlış normalizasyon | Türü bilen metin analizi |
| Çok kelimeli öneri | Yanlış/eksik boşluk, genişletmelerde bağlamın son kelimeye bağlanmaması | Aday sağlayıcıları ve düzenleme planı |
| Klavye davranışı | Nokta basılı tutma, sayı düzlemi, büyük harf, eksik karakterler | UIKit girdi/yerleşim politikaları |
| Doğrulama | Model testiyle gerçek UI farkı, hedefli kümeyi genel hata oranı sanma | Tekrarlanabilir kabul kapıları |

## Metin ve kanıt modeli

`ComposingSession.literal/display/touches` ayrımı yararlıdır; fakat bütün teknik metni ve farklı kaynakları açıklamaya yetmiyor. Bu yapıya aşağıdaki kavramlar eklenmeli, bütün state aynı anda başka sınıflara kopyalanmamalı.

- `DocumentSnapshot`: görünen önceki/sonraki metin, seçim, yerel revizyon, oturum kimliği, sınır bilgisinin kesinliği. Host gerçek belge başını bildirmiyorsa başlangıç **bilinmiyor** kalır; kısa bağlam tam belge sayılmaz.
- `TextSpan`: özgün yüzey, güncel yüzey, görünen bağlamdaki aralık, sözcük/URL/e-posta/IP/telefon/yol/kod adayı türleri, iç bileşenler. Bütün URL ile en sondaki harf parçası ayrı nesnelerdir.
- `Evidence`: gerçek dokunma, seçili metinden türetilmiş arama girdisi, hazır metin veya bilinmeyen köken. Türetilmiş tuş merkezleri kalibrasyona ve otomatik değiştirme kararına gerçek dokunma olarak giremez.
- `OccurrenceID`: bir yazım örneğinin öğrenme kimliği. Mevcut `TokenID` bir commit kimliği olarak korunabilir; geri açıp tekrar commit etmek yeni öğrenme örneği yaratmaz. Tekrar yazılan bağımsız kelime yeni örnektir.
- `NormalizationView`: yalnız ilgili tüketici için arama görünümü; özgün metnin veya düzenleme aralığının yerine geçmez. Türkçe sözcük anahtarı ile URL yolu ve e-posta yerel kısmı aynı kuralla küçük harfe çevrilmez.

Aralıkların türü açık olmalı: kullanıcı karakterleri grapheme, iOS imleç hareketleri UTF-16 birimidir. Dönüşüm tek yerde yapılır ve emoji/birleşik karakterlerle sınanır. Host global belge ofseti sağlamıyorsa hayalî global konum tutulmaz.

## Tek düzenleme yolu

Öneri, otomatik düzeltme, literal seçimi, kısayol, teknik tamamlama ve iki-kelime onarımı aynı `EditPlan` sözleşmesini üretmeli. Plan; beklenen seçim/sol-sağ bağlamı, değiştirilecek görünür aralığı, eklenecek yüzeyi, kaynak aday kimliğini ve son imleç niyetini taşır.

`InputSession` tek canlı durum sahibidir. Recorder bu durumu gözlemler ve kayda geçirir; dosya devri yeni bir kullanıcı oturumu yaratmaz. İlk aşamada mevcut recorder/fallback yolları ortak snapshot üzerinden eşitlenir; sonra gereksiz ikili sahiplik kaldırılır. Kayıt formatı değişirse sürümlü okuma ve eski fixture'lar korunur.

Uygulama sırası:

1. Adayın üretildiği snapshot ile güncel host bağlamı karşılaştırılır. Bayat plan uygulanmaz, öneri yenilenir.
2. Seçim varsa seçili aralık doğrudan değiştirilir; seçim üstüne karakter sayısı kadar backspace çalıştırılmaz. Aynı metni onaylamanın da seçimi bitirme ve imleç davranışı tanımlıdır.
3. Sol ve sağ devam hesaba katılır. `dev@exa|mple.com` tamamlaması son kısmı tekrarlayamaz. Görünür aralık doğrulanamıyorsa öneri uygulanmaz veya yalnız güvenle doğrulanabilen işlem sunulur.
4. Host sonucu uzlaştırılır; ancak doğrulanmış uygulama öğrenme ve gösterilen başarı durumunu üretir.

`UITextDocumentProxy` atomik karşılaştır-değiştir işlemi veya güvenilir global revizyon vermez. Bu nedenle `EditPlan` host üzerinde gerçek atomiklik iddiası değildir: gözlenen bağlama dayalı önkoşul, kontrollü kendi-düzenleme bölgesi ve ardından uzlaştırma gerekir. Uygulama seçimin davranışını doğrulayamıyorsa çevre metni silmeye devam etmez.

Ayırıcı ekleme/silme geçmişi sınırlı bir düzenleme günlüğünde tutulur. Nokta, emoji, rakam veya ikinci boşluk silindiğinde birleştirilen metin yeniden analiz edilir. Eski dokunmalar konumsal olarak doğrulanabiliyorsa yeniden bağlanır; doğrulanamıyorsa bütün yüzey önerilebilir ama yalnız yeni ekin dokunmalarıyla bütün sözcüğe otomatik düzeltme yapılmaz.

## Aday üretimi ile otomatik değiştirmeyi ayırma

Aday sağlayıcıları aynı sonuç biçimini döndürür: özgün yüzey, dilsel öneri, kişisel sözlük, metin genişletme, geçmiş, teknik tamamlama ve boşluk onarımı. Adayın hangi aralığı değiştirdiği ve hangi kanıta dayandığı zorunludur. Tek bir global skor altında ölçülmemiş geçmiş sayımlarını decoder maliyetlerine eklemeyiz; mevcut skor sözleşmesinin ölçek ve prefix-causality kuralları korunur.

İlk öneride kullanıcının özgün yazımı erişilebilir kalır. Özellikle geri açılmış otomatik düzeltmede `originalSurface` ile düzeltilmiş `displaySurface` karıştırılmaz. Seçilmiş bilinmeyen sözcüğü onaylamak da normal yazım gibi açık öğrenme üretir.

Otomatik düzeltme kapısı bütün `TextSpan`ı, özgün harf biçimini, alanın isteklerini ve kanıt türünü görür. Teknik olduğu belirgin girdiler, aralığı belirsiz metin, sentetik/detached kanıt ve kullanıcının o yazım için reddettiği öneri kendiliğinden değiştirilmez. Belirsiz girdide aday göstermek serbesttir; otomatik uygulama daha güçlü kanıt gerektirir. Doğru OOV ile yazım hatası her zaman kesin ayırt edilemez; sıfır hata garantisi verilmiyor.

Mevcut eşiği topluca artırmak kalıcı çözüm değildir. Önce koruma ve aday doğruluğu düzeltilir, sonra değişmeyen test kümesinde yanlış değiştirme ile gerçek yazım hatasını düzeltme birlikte ölçülerek eşik yeniden değerlendirilir. Kullanıcının bilerek düzelttiği kelime aynı olay içinde tekrar aynı yanlışa çevrilemez.

## Türkçe morfoloji ve kök kalitesi

Morfoloji tanıma ile aday üretimi aynı dilbilgisi kaynağına dayanmalı. Her düzeltme adayının kök, ek dizisi ve ses dönüşümü açıklaması testte görülebilmeli; başka bir düz sözlük girdisinin kabulü, amaçlanan ek yolunun çalıştığı kanıtı sayılmamalı.

Ekler kopyalanıp bazı hedef durumlar çıkarılarak türetilmek yerine, özellikleri belli geçişler olarak tanımlanmalı: sözcük türü, çatı, olumluluk, zaman/kip, kişi, iyelik, hâl, ek-fiil ve türetim evresi. Kişi eki tekrarına yol veren genel bir `afterPerson` döngüsü yerine izinli ek sıraları açık olmalı. Üretken geçerli döngüler de keyfî biçimde kapatılmamalı.

Çözüm listesi; edilgen sonrası zaman/yeterlilik, türemiş gövdede geniş zaman sınıfı, koşul sonrası birleşik çekim, olumsuz/yetersizlik dizileri, soru parçacığı, isim kişi ve iyelik/hâl sonrası ek-fiil, -DIr, sıfat-fiil/isim-fiil/zarf-fiil, -(y)lA, -ca/-ce ve küçültme kapsamını içerir. Her ailenin doğru ve yakın yanlış biçimleri birlikte test edilir.

Ses bilgisi yazıdan son görülen ünlüyü bulmaya indirgenmemeli. Fonolojik uyum tohumu ve yüzey ayrı tutulmalı; şapkalı ünlüler ve sözlüksel ters uyum tanımlanmalı. Ünlü düşmesi ilgili ek sınıfıyla koşullanmalı, düşen ünlünün uyum bilgisi kaybolmamalı. Yumuşama+düşme birlikte uygulanabilmeli. İkizleşme, su, ye/de ve n bağlantılı zamir/bileşik sınıfları açık sözlüksel özellikler olmalı.

Paket üretiminde: her kökün kaynağı, türü, gövdesi, frekans anlamı ve çekim özellikleri izlenir. Yinelenen kimliklerde çelişki raporlanır; çok anlamlı/türlü kayıtlar körlemesine birleştirilmez. Son harfle uyumsuz dönüşüm bayrakları ve mastarın fiil gövdesi sayılması doğrulama kapısına alınır. Frekansı yapay olarak aynı büyük sayıya ayarlamak yerine kaynağın güveni ayrılır. 225 adayın hepsine yumuşama vermek veya bütün düşme bayraklarını silmek yasak bir kestirme olmalı; testler bunların yanlış sonuç üreteceğini gösterdi.

## Öğrenme ve kalıcılık

Açık literal seçimi, pasif tekrar, içe aktarma ve uzamsal kalibrasyon ayrı olay türleridir. Öğrenme olayı kimliğiyle bir kez uygulanır. Aynı kelimeye boşluk sil-ekle yapmak frekansı, kabul puanını veya kalibrasyon örneğini çoğaltamaz; başka alandaki bağımsız yazım engellenemez.

Kişisel sözlük, geçmiş, teknik varlıklar ve öğrenme ekranı tek mantıksal kayıt modelinin farklı görünümleri olmalı. Bu, hepsinin aynı skorla çalışması anlamına gelmez. Kayıt; yüzey, türüne göre eşleme anahtarı, kaynaklar, açık onay, kullanım kanıtı ve silme kapsamını taşır. Açıkça öğretilmiş girdiler pasif adaylarla aynı tahliye yarışına sokulmamalı; kapasite doluyken öğretme işlemi sessizce başarısız olamaz. Sınırsız kalıcılık da vaat edilmez: kapasite ve silme davranışı görünür olur.

Öğrenilmiş kökten ek genellemesi kontrollü ikinci adımdır. `qrmenü` tam yüzeyi hemen korunur; muhtemel isim çekimleri önce öneri olarak üretilebilir. Her yeni kelimeyi koşulsuz fiil/isim kökü sayıp bütün ekleri kabul etmek aşırı üretim yaratır. Güvenilir sınıf yoksa tam-yüzey koruması kalır; bu sınırlama testte açık gösterilir.

Varsayılan silme önerisi: öğrenme ekranında “unut” ilgili kişisel kaydı ve onun kişisel öneri kaynaklarını temizler. Bir kaynak aktarımını kaldırmak yalnız o kaynağın katkısını geri alır. Genel dil sözlüğündeki yaygın bir kelimenin tamamen yasaklanması ayrı davranıştır; “unut” ile gizlice karıştırılmaz. Kullanıcı bu kapsamı uygulama öncesi değiştirebilir.

Mevcut yerel depolar için önce güvenilir işlem protokolü kurulmalı; sırf mimari adına yeni veritabanı bağımlılığı şart değil. Başarısız yazma dirty durumunu temizleyemez. İçe aktarma paketi benzersiz batch kimliğiyle bekleyen/işleniyor/tamamlandı aşamalarına geçer; hedef kayıt ve uygulanmış batch makbuzu aynı sürümlü snapshot içinde kalıcılaşmadan kaynak silinmez. Yeniden açılışta yarım işlem tekrar denenir, daha önce uygulanmış batch tekrar sayılmaz. Çok dosyalı katalog ana veri değil yeniden üretilebilir görünüm olmalı; tek dosya rename ile çok dosyaya atomiklik varmış gibi davranılmamalı.

Uygulama import paketini yayımlar; klavye öğrenilmiş durumun tek yazarı olur. App Group erişimi olmadığında yerel öğrenme çalışır, paylaşım bekler. Başarı bildirimi ancak doğrulanmış sonuçtan çıkar; sıfır öğrenilen öğe ve başarısız yazma farklı sonuçlardır. Hata halinde yapıştırılan taslak açık kalır.

## İçe aktarma ve öğrenme ekranı

WhatsApp/Telegram ayrıştırıcıları format ve sürüm odaklı ayrı adaptörler olmalı. Gönderen kimliği varsa görünen addan ayrılır; sistem olayı mesaj devamı sayılmaz. Medya placeholder'ı tam format eşleşmesiyle tanınır; `omitted` veya `<` içeren her metin atılmaz. Belirsiz satırlar sessizce yanlış kişiye atanmak yerine ayrıştırma raporunda sayılır. ZIP uzunlukları ve sınırları erişimden önce kontrol edilir; açılmış içerik boyutu ve kaynak tüketimi de sınırlanır. Bozuk arşiv testi ayrı süreçte tutulur.

Öğrenme ekranı yalnız ilk birkaç kelimeyi değil arama/sayfalama ile bütün kayıtları gösterir. Elle öğretilen, yazımdan öğrenilen ve WhatsApp/Telegram'dan gelen katkılar ayırt edilir. Kullanım sayısı “aynı olayın tekrar callback sayısı” değildir. Kaynak, öğrenilme durumu, silme işlemi ve başarısız/bekleyen kayıt açık olur.

## Teknik tamamlama ve yanlış boşluk

URL, e-posta, IP, telefon ve dosya yolu için özgün yüzeyi koruyan, tamamlanmamış metni de tanıyabilen analiz gerekir. Dış cümle noktalaması ile token'ın içindeki `()`, `!`, `.`, `;` ayrılır. Belirsizlikte veri kesilmez. URL şema/host ile yol/query ayrı normalizasyon ister; e-posta domain'i Türkçe I dönüşümüne uğramaz, yerel kısmın biçimi korunur. Telefon için ham görünüm ve tanınan gruplar saklanır; bağlam bilinmeden otomatik ülke kodu eklenmez. Bir sayının telefon mu başka bir tanımlayıcı mı olduğu belirsizse sessiz biçimlendirme yapılmaz.

IntelliSense benzeri akış üç aşamada kurulmalı: önce tam ve sağlam kaydedilmiş token tamamlama, sonra birden fazla alternatif, sonra güvenli bileşen yeniden kullanımı. Yeni e-posta yerel kısmında kayıtlı domain önerilebilir; fakat oluşturulan adresin var olduğu iddia edilmez. Şema ve port kendiliğinden değiştirilmez. Yerel dosya yolları yalnız kullanıcının klavyeye sağladığı geçmişten önerilir; klavye telefondaki dosyaları veya başka uygulamaların geçmişini kendiliğinden tarayamaz.

Eksik/yanlış boşluk, ayrı bir iki-kelime aday sağlayıcısı olmalı: birleşik metinde ayırma; boşluk çevresi dokunma kanıtıyla yanlış harfi boşluk olarak yorumlama; iki tarafın sözcük/ek geçerliliğini birlikte değerlendirme. Aday bütün aralık için `EditPlan` üretir. İlk sürüm açık seçime bağlıdır; otomatik bölme için ayrıca yanlış-bölme ve gerçek birleşik kelime kontrolleri gerekir. Teknik metinlerde ve kanıtı belirsiz seçimde bu üretim sınırlandırılır.

## Klavye davranışı

Sayı/harf düzlemi geçişi, fiziksel boşluk ve öneriyle eklenen boşlukta aynı işlem sonucundan türetilmeli. Normal cümlede harflere dönüş ile gruplu telefon/IP girişi farklı bağlamlardır; kullanıcı açıkça düzlem seçtiyse niyeti korunur. Nokta uzun basmasının gecikmesi, iptal/kayma ve parmak sahipliği UI kabul testidir. allCharacters kalıcı host isteği ile one-shot shift ayrılır; alıntı işaretleri içindeki cümle sınırları ayrıca ele alınır.

Ters tırnak, şapkalı harfler ve geliştirici kullanımında Tab için erişim tasarımı gerekir. Var olan yerleşimi rastgele daraltmadan uzun basma veya teknik yardımcı satır seçenekleri kullanılabilir; kesin yerleşim, dokunma geometrisi ve erişilebilirlik testiyle seçilir. Full Access bu çekirdek öneri sorunlarının genel çözümü değildir; paylaşımlı depolama ve ilgili platform yetenekleriyle sınırlı sorumluluğu olmalı.

## Uygulama sırası ve bitiş ölçütleri

| Faz | Yapılacak iş | Geçiş kapısı |
|---|---|---|
| 0 | Mevcut değişiklikleri ve paketleri sabitle, kanıtları kabul testlerine dönüştür, kaynak hash ve profil durumunu kaydet | Aynı girdiler aynı tabanda tekrar üretilebiliyor; test skip veya exporter başarısı ürün başarısı sayılmıyor |
| 1 | ZIP bounds ve yazma hatası/veri kaybı düzeltmeleri; yeni kalıcı işlem protokolünün temeli | Geçerli/bozuk arşiv, her yazım adımında hata ve yeniden açılış testleri; veri kaybı/çift import yok |
| 2 | Snapshot, span, edit plan, tek oturum sahipliği; literal/selection/undo ve koruma kapısı | Yanlış aralık silinmiyor, bayat öneri uygulanmıyor, recorder açık/kapalı aynı belge sonucunu veriyor |
| 3 | Olay kimlikli öğrenme, kapasite/silme/öğrenme ekranı, import semantiği | Açık seçim bir kez öğreniliyor; tekrar commit çoğaltmıyor; kaynak katkıları ve yeniden açılış tutarlı |
| 4 | Morfoloji özellikleri, ses dönüşümleri ve kök verisi düzeltmeleri | Her ailede doğru analiz ve yanlış yakın biçim kontrolü; gerçek yazım korpusu ve yararlı düzeltmeler birlikte geçiyor |
| 5 | Türü bilen teknik tamamlama, çoklu seçenek ve iki-kelime önerileri | Tamamlama çevreyi koruyor; kayıtlı ve bileşenlerden kurulan aday ayrılıyor; yanlış bölme kontrolleri geçiyor |
| 6 | Sayı düzlemi, büyük harf, uzun basma ve karakter erişimi; uçtan uca doğrulama | Gerçek simülatör ve cihazda seçim/geri silme/uygulama geçişi; gecikme, bellek ve erişilebilirlik kapıları |

Fazlar küçük, geri alınabilir değişiklikler olmalı. Morfoloji veri çalışması kavramsal olarak ayrı ilerleyebilir; fakat yeni otomatik uygulama davranışı düzenleme ve koruma temeli tamamlanmadan açılmaz. Tüm değişiklikleri tek büyük PR'a yığmak yerine her PR kendi invariantını ve ilgili tarihsel örnekleri kapatır.

Her değişiklikte dört ölçüm ayrılır: tanıma/analiz doğruluğu, öneri erişimi, otomatik değişim, düzenleme/kalıcılık sonucu. Morfolojik kabul tek başına doğru öneriyi veya güvenli düzenlemeyi kanıtlamaz. Sabit zarar korpusu yanında ayrı tutulan değerlendirme kümesi ve gerçek yazım hataları olmalı; eldeki 2.000 teknik örneğin bir bölümü sayısal varyanttır, 2.000 bağımsız dil olayı değildir.

Başarı kapıları: doğrulanmış bozulma senaryolarında beklenen belge sonucu; kontrol kümesinde yeni zarar olmaması; kalıcılık hata enjeksiyonunda kayıp/çift uygulama olmaması; seçim ve recorder yollarının eşitliği; özellik başına gerçek UI doğrulaması. p50/p95 gecikme ve bellek tabanı Faz 0'da ölçülür, cihaz bazlı bütçe uygulanmadan önce sabitlenir; henüz ölçülmemiş mutlak performans vaat edilmez. Teknik öneriler yalnız ilgili span'da, sınırlı aday sayısıyla çalışır; tuş başına disk veya ağ erişimi yapılmaz.

## Bekleyen kararlar ve çalışma sınırı

Önerilen varsayımlar: teknik tamamlama ve iki-kelime onarımı önce kullanıcı seçimiyle; açıkça öğretilen tam yüzey hemen korunur; “unut” kişisel kaynakları kapsar; yeni sözcüğe morfolojik genelleme temkinli olur. Bunlar uygulama öncesi incelenebilir ürün kararlarıdır, bugün uygulanmış değildir.

Mevcut erken üretim değişiklikleri korunur ve Faz 0'da yeniden doğrulanır; audit boyunca geçen her test “tamamlandı” etiketi almaz. Son simülatör oturumunda yazılım klavyesinin görünmemesi açık UI doğrulama sınırıdır; önceki gerçek UI kanıtları da yeni mimarinin testinin yerine geçmez.

Kullanıcının talebiyle yeni keşif turu ve üretim kodu değişikliği bu değerlendirme sonunda bekletilir. Devam edildiğinde ilk iş Faz 0 ve ardından veri kaybı/metin bütünlüğü düzeltmeleridir; yeni özelliklere doğrudan atlanmaz.


## Uygulamada kesinleşen kararlar

Özgün kelime ilk öneridir; açık seçim hemen öğrenir. Yeni kişisel köklerin yalnız gerçekten yazılmış düzenli isim çekimleri korunur; fiil veya düzensiz kök bilgisi tahmin edilmez. Yanlış/eksik boşluk için iki kelimelik adaylar üretilir ve yalnız seçimle uygulanır. Nokta, sayı düzlemi, seçili metin, geri açma ve genişletme yolları aynı metin bütünlüğü sınırlarına uyar.

Recorder/fallback geçişinde aynı canlı koordinatör devredilir ve bir belge mutasyonunu yalnız etkin sahip yürütür. Çok kelimeli genişletmenin son kelimesi açılırken kısaltmanın dokunmaları o kelimeye atfedilmez: `restoreDerivedToken` bunu kayıt ve doğrulama katmanlarına açık olgu olarak taşır. Eski kayıt biçimleri okunmaya devam eder.

Öğrenme ekranı kendi öğrenilenlerini ve kaynak bazında aktarılanları gösterir. Kaynak silme, yazılan ve diğer kaynaklardan gelen katkıları korur; kalıcı işlem makbuzları kesinti sonrası tekrar uygulamayı engeller. Kaynağı bilinmeyen eski öğrenme başka bir kaynağa mal edilmez. Bozuk depo, kullanıcı başlattığında byte düzeyinde doğrulanmış yedek alındıktan sonra canlı öğrenmeyle yeniden kurulur.

Teknik tamamlama bütün kayıt, e-posta alan adı, şemasız sunucu adı, aynı sunucunun yolu ve açık port bileşenlerini sunar. Yeni oluşturulan adresler için çubukta açıklama vardır; adaylar otomatik uygulanmaz. Orta imleçte sağdaki eşleşen ASCII kuyruk korunur, gözlenemeyen veya uyuşmayan bağlamda teklif uygulanmaz. URL şeması/alan adı ve e-posta alan adı büyük-küçük harften bağımsızdır; URL yolu ve e-posta kullanıcı kısmı değildir.

WhatsApp düz metin dışa aktarımları sabit sohbet/mesaj kimliği sağlamaz. Aynı seçili aktarımın tekrarı engellenir; keyfî kısmi örtüşmenin kusursuz ayırt edildiği iddia edilmez. Telegram kimliği mevcutsa örtüşen aktarımlar mesaj düzeyinde ayrılır. Bu sınır, aynı metni gerçekten tekrar göndermiş kullanıcının verisini yanlışlıkla silmemek için korunur.

Bütün sonuçlar test kapsamıyla sınırlıdır: 140 tur 140 ayrı hata değildir, Mac gecikmesi telefon ölçümü değildir ve Türkçenin denenmemiş tüm biçimleri için sıfır hata garantisi verilmez. Eski tanı raporları değiştirilmez; güncel kapanış kanıtları `closure-*` dosyalarındadır.


## Closure revision: rounds141–147 (2026-10-11)

Latest user requests all recorded findings resolved, including missed-space suggestions. This supersedes the discovery-only phase.

- HistoryArchive owns a persisted logical sequence shared by typed/source contributions. Rebuilding sums all retained source counts before one bounded eviction and preserves observed sequence values. Alphabetical source names no longer create recency. Historical source snapshots lacked a shared clock; their original cross-source chronology cannot be reconstructed retroactively.
- TechnicalTextSpan recognizes grouped phones and quoted email local parts on both sides of the cursor. Completion stores the actual right span, retains separators, and excludes @ inside quoted mailboxes from domain case folding. Existing snapshot guards still gate all replacement.
- HistoryObservation emits an explicit provisional-phone replacement event. Only one typed occurrence is retracted when the same phone grows; independent typed/imported counts remain. Document/context changes revoke that occurrence association.
- PersonalLexicon imports accumulate distinct chunks to the existing admission threshold. Each unadmitted entry retains at most three SHA-256 identities of token arrays; exact retries are idempotent across reload. Store v2 atomically persists words and receipts; v1 remains readable. Old files contain no import identities, so pre-upgrade batch identity cannot be recovered. Forgetting a word removes its receipts.
- Missing/mistapped-space repairs remain explicit suggestions; original surface remains available. No guessed split is silently imposed.

Validation in progress: HistoryClosureRegressionTests plus historical141–147 exporters, full Release suite, production geometry60probes and simulator UI checks. Evidence lives under audits/closure2-*.

Closure2 validation completed:899 core executions and15 simulator keyboard tests passed; all seven remaining round replays pass;60/60 missed-space cases. Latest signed Release installed and launched on physical iPhone. See audits/closure2-summary.json.


## Güncel sözleşme: Round223–224

Kayıt tokenı ile kullanıcıya gösterilen tam kelime aynı kavram değildir. â/î/û sembol komutları kayıt hizalamasında sınır olmaya devam eder; bunlar için harf dokunması uydurulmaz. Kişisel sözlük aktarımı ayrı Unicode harf tokenizer'ını kullanır. Canlı öneride, görünür tam kelime bir host bağlamı görüntüsünden alınır; ilk aday özgün kelime, diğerleri ortak WordBoundaryRepair kurallarından gelen açık iki-kelime önerileridir. Tarama uzunluğu ve aday sayısı sınırlıdır.

Öneri seçimi belge kimliği, önce/sonra/seçim bağlamı ve yeniden hesaplanan adaylarla doğrulanır. Yalnız açık seçimde kayda geçen silme/metin komutları çalışır; tam kelimenin seçilmesi kişisel sözlükte güçlü kanıt olur. İki-kelime seçimi mevcut history replacement yolu üzerinden uzlaştırılır. Otomatik boşluk düzeltmesi ve dokunma kalibrasyonu bu bağlamsal adayları kullanmaz.

Güncel doğrulama ve telefon sürümü audits/turkish-round224-summary.json ile audits/current-request-checklist.json içindedir. Yukarıdaki ilk mimari değerlendirmeye ait bekleme/uygulanmadı ifadeleri tarihsel planı anlatır; güncel teslim durumunu bu kayıtlar belirler.
