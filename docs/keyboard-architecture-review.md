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

## Günlük yazışma taraması — 2026-10-24, sürüyor

Simülatörde gerçek uzantı tuşlarıyla sevgiliye mesaj, teknik sohbet, şiveli
konuşma ve resmî metin denendi. Üretim paketleriyle 93 konuşma koşusu ve
26 kelimenin içindeki bütün sınırlarda yanlış boşluk/Enter, geri silme ve
devam etme için 1.380 koşu ayrıca kaydedildi.

Boşluk onarımları, alakasız köklerden türetilen adayların önüne alındı
(`senibseviyorum`: `seni seviyorum`, sonra `webinarcıydım`). Sözlükte kayıtlı
kazanan korunur (`lslem`: `kalem`, sonra `ls lem`); otomatik bölme yapılmaz.
Yanlış boşlukta düzeltilen yarım kelime geri açılıp tamamlandığında, özgün
harfler bilinen bir kelime oluşturuyorsa eski otomatik değişiklik geri alınır.
Bu, `mühendisleik`, `değerlendirilmezini`, `eczanelereen` bozulmalarını giderdi.
Kullanıcının açık öneri seçimi bu geri alma yoluna girmez.

İptal edilen yarım kelimenin zayıf öğrenme gözlemi artık son kelime kimliğiyle
izlenir. Geri açılan kelimenin harfleri değişince veya kelime silinince yalnız
eşleşen gözlem geri alınır. Bağımsız kullanımlar, içe aktarılan kanıt ve açık
seçimler korunur. İzleme bellekte ve son sekiz kelimeyle sınırlıdır; eski
kalıcı kayıtların kaynağı tahmin edilmez. 1.380 koşuda fazladan öğrenilmiş
parça görülen 100 durum sıfıra indi. Önceden kalan 10 şive farkı değişmedi.
Gerçek uzantıda `müh` dört, `seviyoru` ve `değerl` üçer kez yanlış boşlukla
yazılıp tamamlandı; metin doğru, bu parçalar kalıcı sözlükte yok.

Güncel tam test turu: 705 XCTest (92 isteğe bağlı tanı testi atlandı),
406 Swift Testing testi; hata yok. Kayıt doğrulama ve yeniden oynatma
kontrolleri de dahil. Telefon güncellenmedi; yeni sürüm simülatörde doğrulandı.
Şive koruması ve anlamsız kalan adaylar hâlâ açık bulgulardır. Ayrıntı ve
sonraki adımlar `audits/everyday-20261024-progress.json` içindedir; bu tur
genel hedefin tamamlandığı anlamına gelmez.


### Tek seçimle yanlış öğrenme — devam eden günlük tarama

Literal seçimi artık bir kullanım puanı verir; üç puanlık tek-adım güçlü
öğrenme yolunu çağırmaz. Aynı token geri açılıp seçilince makbuz yeni kimliğe
taşınır ve puan çoğalmaz. Sonradan değiştirilen/silinen seçim, zayıf gözlem
kurallarıyla geri alınır. Gerçekten ayrı tekrarlar mevcut üç-puan kabul
eşiğini doldurabilir. Seçili/şapkalı tam kelime onaylarında token kimliği yoksa
aynı token dönemi içinde aynı kanonik yüzey yalnız bir kez sayılır; en çok
sekiz böyle yüzey izlenir. Bu sınırlı bellek, uygulama yeniden başlatmaları
arasında aynı belge kelimesinin kimliğini kanıtlamaz. Eski kalıcı kayıtların
kabul durumu bu değişiklikle kendiliğinden düşürülmez.

Bu güncel kural, yukarıdaki tarihsel tek seçim/güçlü öğrenme ifadelerinin
yerine geçer. Doğrudan `PersonalLexicon.observe(.strong)` iç API'si test
fikstürleri ve açık güçlü kanıt için korunur; öneri seçimi bu API'yi kullanmaz.


Tek seçim değişikliği sonrası 705 XCTest (92 opt-in atlama) ve 406 Swift
Testing testi hatasız geçti. Sekiz gerçek telefon yazım hatası tek seçim ve
dört yeniden açma döngüsünde kabul edilmedi; 33 özel kelime üç farklı dokunma
ofsetinde üç kullanım sonrası öğrenilip yeni koordinatörde korundu. Native
uzantıda `şimdş` tek seçimde 1 puan kaldı, `şimdi` ile değiştirilince silindi.
`bulutnot` üç ayrı seçimde 3 puan oldu; dördüncü normal boşlukta korundu.
Simülatör derlemesi başarılı; fiziksel telefon bu tur güncellenmedi.


### Mevcut kelimenin tekrar sayılması

Token kimliğinin ilerlemesi yeni kullanım için yeterli değildi: host'tan
aynı kelimeyi yeniden devralıp kabul etmek ve gözlenmiş kelimeyi metinden
seçmek puan artırabiliyordu. Dört odaklı testte 12 başarısız doğrulama bunu
kanıtladı. Tekrar süzgeci artık token dönemine değil, gerçek yeni harf
girişine bağlıdır; normal/büyük harf ve sembol düzlemindeki harfler süzgeci
sıfırlar. Otomatik gözlem ve açık seçim aynı sınırlı süzgeci paylaşır.
Önceki bölümdeki token dönemi kuralının yerini bu kural alır. Uzantı yeniden
başlatmaları arasında belge kimliği taşınmaz; bu sınır hâlâ geçerlidir.

709 XCTest (92 opt-in atlama), 406 Swift Testing testi hatasız. Native
uzantıda bir kez yazılıp kabul edilen `şimdş` üç kez daha metinden seçilip
kabul edildi; diskten okunan puan 1 kaldı. Şiveli merkez-dokunma sohbeti ve
teknik metindeki yanlış boşluk/Enter sonrası devam denemeleri de korundu.


### Konuşma dili kapsamı

32 konuşma dili/şive biçimi × 3 dokunma ofsetinde tek bozulma vardı:
`uşağum → uşağım` (+0.18). Aynısı native uzantıda tuş merkezinden +9px/+14px
kaymış tıklamalarla doğrulandı. `informal.tsv` listesine 26 elle seçilmiş
biçim, mevcut düşük 800 göreli ağırlıkla eklendi ve Türkçe form paketi yeniden
üretildi. Bu sayı korpus sıklığı değildir. 96 stil denemesinde artık bozulma
yok; 36 kontrolün çıktısı değişmedi. Yeni daimi test, bu yüzeylerin sözlükte
olduğunu, kaymış dokunmalarda korunduğunu ve kişisel puan üretmediğini denetler.
711 XCTest (93 opt-in atlama) ve 406 Swift Testing testi hatasız geçti.
Native aynı kaymış dokunmalarla `uşağum gardaş geliyom` korunurken `şimdş seni
özledşm` → `şimdi seni özledim` oldu. Kapsam listedeki biçimlerdir; bütün
şivelerin tanındığı iddia edilmez.

Kontrolde `patstes` üç ofsette de otomatik düzelmedi. `patates` önerisi var;
`pats tes` bölmesi de çıkıyor. `correctionDecision`, herhangi bir bölme varsa
kararı atladığından bu anlamsız parçalı öneri gerçek düzeltmeyi de engelliyor.
Bu, önceki `ls lem` bulgusunun işlevsel etkisidir ve sonraki inceleme konusudur.


### Seyrek kısa parça bölmeleri

`ls lem` ve `pats tes` sözlükteki kısa, seyrek parçalardan üretiliyordu.
Her iki parça en çok dört harf olduğunda toplam ham leksikal maliyeti 23'ü
aşan korpus bölmeleri artık gösterilmiyor. Kişisel kök/ekli biçim maliyetini
sağlayan çağıran bu sınıra tabi değil. Eşik öneri filtresidir; dilbilgisi
modeli veya otomatik düzeltme eşiği değildir. 43 Türkçe/İngilizce/teknik kısa
ifadenin eksik boşluk ve alt-sıra `b` denemeleri korunuyor; zaten bilinen
bitişik kelimeler bölünmüyor. Geçerli ama seyrek kısa çiftleri kaçırma sınırı
vardır; bütün anlamsız önerilerin çözüldüğü iddia edilmez.

714 XCTest (93 opt-in atlama) ve 406 Swift Testing testi hatasız. Ek taramada
1.380 iç sınır denemesinde metin farkı ve fazladan öğrenme sıfır; 576 şapkalı
kelime/imleç denemesi de geçti. Native temiz derleme `patstes | patates` ve
`lslem | kalem | özlem` gösterdi; iki doğru öneri seçilerek uygulandı. İlk
simülatör gözleminde üçüncü eski öneri görünmüş ama dokununca uygulanmamıştı;
yeni süreçte tanı ölçümü ve ardından tanı kodu kaldırılmış temiz derleme
aynı iki öneriyi verdi. Bu geçici farkın kaynağı belirlenmedi; UI için ayrıca
bir düzeltme yapılmadı, kalıcı bir sorun olarak yeniden üretilemedi.

`patstes` artık normal düzeltme hesabına giriyor (üç ofsette Δ≈11.63–13.40),
ama mevcut 14.60 eşiğinin altında kalıp aynen yazılıyor. `patates` erişilebilir
öneridir. `subiç → su iç` korunur; üçüncü sıradaki `sub iç` gibi karışık dilli
alternatiflerin bağlamsal uygunluğu sonraki açık incelemedir.


### Boşluk onarımı yanında alakasız türetilmiş adaylar

`senibseviyorum` için `webinarcıydım` kalan yuvayı dolduruyordu. Sınır
onarımı varsa türetilmiş alternatifler kanonik harf uzaklığıyla süzülüyor:
Levenshtein sınırı max(2, yazılan uzunluk / 4). Sözlük adayları ve hazır
genişletmeler korunuyor. Bu yalnız sunum filtresidir; decoder puanı veya
otomatik düzeltme kararı değişmez. Uzak ama geçerli türetilmiş düzeltmeleri
kaçırabilir; genel anlamsal doğruluk iddiası yoktur.

İki odaklı test geçti: alakasız adayın kaldırılması ve yakın `evdem`
türetilmiş alternatiflerinin korunması. Tam çalışma 716 XCTest
(93 opt-in atlama), 406 Swift Testing testi; sıfır hata. Simülatörde ikinci
bağımsız yazım yalnız literal ve `seni seviyorum` gösterdi; öneri seçimi
uygulandı. Şive, mühendislik ve resmî değerlendirilmesini örneklerinde
yanlış boşluk/Enter ardından silip devam etme doğru metin verdi.

İlk görüntüde eski üçüncü aday kısa süre göründü, dokununca uygulanmadan
kayboldu. Önceki kısa-parça turundaki gözlem tekrarlandı; görüntü yakalama
gecikmesi veya çizim gecikmesi ayrıştırılmadı. UI değişikliği yapılmadı.


### Art arda boşluk ve Enter iptali

12 kelimenin bütün iç konumlarında beş ayırıcı dizisi (iki boşluk, iki
Enter, boşluk+Enter, Enter+boşluk, boşluk+Enter+boşluk) eklenip aynı
sayıda geri silindi. 580 dizi üçer bağımsız tekrar ile metin ve kişisel
puanlar açısından kesintisiz yazımla karşılaştırıldı. Önce 60 assertion
başarısızdı: `sevg`, `müh` gibi iptal edilmiş parçalar kabul eşiğine
ulaşıyor; bazı konumlarda `mühendisleik` gibi metin bozuluyordu.

Boş token'da Enter geçmişi ve konum defterini atıyordu. Bu yolda artık
doğrulanmış geçmiş korunuyor; dil bağlamı yine kesiliyor. Geri açma mevcut
defter/kimlik/host metni kontrollerinden geçiyor. Dolu token'ın satır sonu
kuralı değişmedi. 580 dizinin üçer tekrarında sıfır fark; tam testte
717 XCTest (93 opt-in atlama) ve 406 Swift Testing testi hatasız.

Native önce `mühendisleik`, sonra aynı girişle `mühendislik` doğrulandı.
`sevg` + boşluk/Enter/boşluk + üç silme + `ilim` üç kez yazıldı; metin
`sevgilim` kaldı ve kalıcı simülatör sözlüğünde `sevg` puanı sıfırdı.
Kullanıcının eklediği çift basım/fazladan harf kapsamı önceki açık bulgulara
eklenmiştir; önceki öğrenme ve öneri araştırmaları iptal edilmemiştir.


### Oturumlar arasında eski kelimeyi yeniden onaylama

Aynı `qrmâvi` yüzeyi kopuk devralma, seçili metin ve tam-kelime onayı
yollarında dört yeni koordinatör oturumunda sınandı. Her turda gerçek
PersonalLexiconStore dosyası kaydedilip yeniden yüklendi. Önce puanlar
çoğaldı: beş testlik başlangıç koşusunda 15 assertion başarısızdı.

Eski metin onayı artık yalnız henüz bulunmayan bir yazımı tek zayıf kanıtla
başlatabilir. Mevcut kişisel kaydın puanını artırmaz. Kopuk/sentetik literal
onayı gerçek yazım token'ı gibi sayılmıyor. Bağımsız, gerçek tuş girdisi
ayrı sayılmaya devam eder; iki puanlı kayıt için eski metin onayı iki puanda
kalırken yeni koordinatörde gerçekten yazıp seçmek üçe ulaştırır. Bu
politika farklı belgelerdeki aynı eski yüzeyi seçerek öğrenmeyi de kısıtlar:
yeni kullanım kimliği kanıtlanmadığı için bunun bağımsızlık iddiası yapılmaz.
Yeni dosya biçimi, metin parmak izi veya belgenin saklanması gerekmedi.

17 odaklı test hatasız geçti. Simülatör derlemesi başarılı; bu oturumlar
arası davranış için kanıt diskli çekirdek testidir. Yeni sürüm test
simülatörüne kuruldu ancak Device Hub başka QA penceresine geçtiği için
native yeniden başlatma doğrulaması yapılmış sayılmadı. Tarihî telefondaki
kabul edilmiş hatalı kayıtlar bu düzeltmeyle kendiliğinden silinmez.

Tam doğrulama: 720 XCTest (94 opt-in atlama) ve 406 Swift Testing testi hatasız.


### Native yeniden başlatma ve kısa bölme alternatifleri

Test cihazı Device Hub'dan ayrı pencereye alındı (iPhone 17 Pro,
2219EC8E-73BE-4E32-8A92-ECF2C045A789). Başka bir QA cihazının eşzamanlı
çalışması nedeniyle önceki pencere ayırma denemesi zaman aşımına uğramıştı;
yeniden gözlemle bu kez ayrı pencere doğrulandı. Pencereler ayrı olsa da
macOS aktif UI girdisi ortak kalır.

Native fixture ile önceden yazılmış `qrpembe` seçilip literal önerisi
onaylandı. Uzantı süreçleri 60665 → 61369 → 61861 olarak gerçekten
yeniden oluşturuldu; her oturumdan sonra kalıcı kişisel kayıtta puan 1
kaldı. Böylece üç eski metin onayı admission'a ulaşmadı. Bu native kontrol
seçili metin yoludur; diğer onay yolları diskli çekirdek testleriyle sınandı.

`subiç` için `su iç` ham maliyeti 16.43, `sub iç` 19.09 idi. İkinci
kısa bölme artık en iyi kısa bölmenin ham leksikal maliyetinden 2'den fazla
gerideyse eleniyor. Sıralamadaki tek harflik boşluk hatası cezası bu
karşılaştırmaya katılmıyor. Kişisel biçimler ve uzun ifadeler muaf; en iyi
aday korunur. Bu filtre bağlamsal dilbilgisi değildir; daha seyrek ama
geçerli ikinci kısa ifadeler de elenebilir. 43 kısa ifade × iki sınır
girdisi ve mevcut kişisel biçim kontrolleri geçti.

Native `subiç | sybil | su iç` gösterdi; `su iç` seçildi. `logbaç` için
`log aç` korunup seçildi. Sözlük kökenli `sybil` ve `loyal` adaylarının
Türkçe bağlama uygunluğu hâlâ açık bulgudur. `senibseviyorum` yeniden
yazımında yalnız literal ve `seni seviyorum` göründü; geçici eski üçüncü
yuvanın kök nedeni bu kontrolle kanıtlanmış değildir.

Tam test: 721 XCTest (94 opt-in atlama), 406 Swift Testing; hata yok.
File → New Window üzerinden ikinci pencere de açıldı; Window menüsünde
BestKeyboard Onboarding QA ve iPhone 17 Pro birlikte doğrulandı. Diğer QA
penceresi önde bırakıldı, onun cihaz içi durumuna müdahale edilmedi.

### 2026-10-24 — Dictionary winner versus boundary repair

A dictionary winner now precedes a one-boundary repair only within one canonical letter edit, including adjacent transposition. Distant guesses remain available in spare slots; decoder scores and automatic correction are unchanged. Actual-pack subiç/logbaç ranking failed four assertions before the change and passed afterward; nearby evdem→evden and kalme→kalem controls remain first. Four focused tests passed; full validation: 723 XCTest (94 skipped), zero failures, and 406 Swift Testing tests passed. Native iPhone 17 Pro verified subiç | su iç | sybil and successful su iç selection. Both separate simulator windows remain open; other Onboarding QA device was not installed or manipulated. Transient stale-slot finding remains open; duplicate-key expansion remains queued behind earlier work.

### 2026-10-24 — Duplicate plus mixed-boundary deletion

Historical stale third-slot event was not reproduced in current native build: senibseviyorum had two slots, remained correct after final-letter delete/retype, and blank-slot tap did not alter the document. Retain as monitored, cause unproven; no speculative UI patch. Duplicate baseline review: immediate undo 0/585 mismatches, mixed-boundary undo 98/585, intentional repeat 2/24 (çoook→look). Focused duplicate-boundary regression reproduced 14 failed assertions. Restore original typed surface before deleting a trailing duplicated character only when reopened from automatic correction; explicit picks excluded. Focused 2 tests now pass; full audit and native build pending in logs recorded in progress JSON.

### 2026-10-24 — Expressive runs and completed duplicate deletion validation

Duplicate mixed-boundary deletion passed full suite (724 XCTest/406 Swift Testing), and native sevgii / sevgilii + SPACE ENTER + three deletes + continuation produced sevgilim. Native software keyboard was hidden; Device > Keyboard > Toggle Software Keyboard restored it. Only own simulator was rebooted and installed.

Expressive panel (7 forms × 3 offsets) initially failed 10 assertions; native çoook became look at space. CorrectionPolicy now preserves runs of three or more identical letters at automatic correction, while leaving suggestions available. All 21 cases pass. Native after: çoook stays literal and explicit çok selection succeeds. Full suite: 725 XCTest (93 opt-in skipped), zero failures, 406 Swift Testing passed. Re-exported 1779 probes changed exactly two outcomes, both erroneous çoook→look, now preserved. Ordinary extra-letter outcomes unchanged; immediate and mixed-boundary undo remain 0/585 mismatches each. Conservative tradeoff: accidental triple taps also require explicit correction. Next investigate missing intended extra-letter suggestions, especially two boundary repairs crowding out whole-word candidates.

### 2026-10-24 — Duplicate correction crowded out by phrase repairs

Eight actual-pack examples had intended targets in shown decoder candidates but not in three visible slots. Reserve one alternative for a shown candidate formed by removing exactly one adjacent duplicate; keep a phrase alternative. Full shown set is inspected before truncation, covering alışverişşe whose intended target was third. Five focused tests pass; native buluşallım and başvurummun show and apply correct targets. Re-export: missing intended targets fell from 64/585 to 2/585; all 1779 committed-text outcomes unchanged. Remaining shifted-touch cases: başvuruumun and çocuklarımızzı at -0.18. Full suite running in logged session; no completion claim yet.

### 2026-10-24 — Shifted duplicate visibility and remaining automatic harm

At -0.18 offset başvurumun was decoder rank 4 within normal score window; çocuklarımızı was rank 3 without phrase alternatives, truncated by the literal slot. Bounded top-8 lookup for adjacent repeats now retains the duplicate-removal candidate within the unchanged score window and promotes it with/without phrase repairs. Known literal forms are exempt. Six focused tests pass; full suite completed exit 0. All 585 intended direct-duplicate targets are visible; 1779 committed-text results unchanged. Native shifted çocuklarımızzı offers/selects çocuklarımızı.

Further classification: 360 direct duplicates auto-correct as intended, 217 stay literal, eight auto-correct to another word. These are NOT solved by suggestion visibility: başşvurumun/başvuurumun→başvurunun, değerlendirrilmesini→değerlendirtilmesini, çocuklarımızzı→çocuklarımızdı, alışveriişe→alışverişle at listed offsets in audit. Next address this decision issue without weakening previous safeguards.

### 2026-10-24 — Ambiguous duplicate automatic correction

Focused actual-pack cases reproduced eight wrong replacements and preserved three positive ssevgilim controls. Before Δ/θ decision, abstain when a different near-scoring shown candidate exactly removes one adjacent repeat. This preserves input for explicit choice instead of applying a competing morphological change; winning duplicate repairs keep normal policy. Eighteen focused cases pass. Re-export: correct automatic results stay 360/585, preserved literals rise 217→225, wrong replacements fall 8→0, target visibility stays 585/585. Exactly eight document outcomes changed. Immediate/mixed undo and expressive controls remain clean. Native before reproduced çocuklarımızzı→çocuklarımızdı; new build installed, but native after remains unverified because CUA clicks return noWindowsAvailable although AX/screenshot remain readable. Full suite running in recorded progress session.

### 2026-10-24 — Native ambiguity verification and full-message interruptions

Native verification recovered after CUA access failures: in main DeviceHub own simulator, çocuklarımızzı SPACE stays literal; backspace then selecting çocuklarımızı inserts correct text. User confirmed Mac screen was open; no verified root cause for tool failure.

New ConversationInterruptionTests runs six complete messages across romantic, engineer, dialect, formal multiline, travel and family contexts at three touch offsets. Every word receives an extra midpoint character, SPACE ENTER and three backspaces before continuing. Clean and same-key duplicate variants pass all 18 pairs, including personal-entry equality. A different nearest neighboring extra key exposes three expressive-prefix failures: çoook becomes çıkok (-0.18), çook (0/+0.18). Other messages and learning comparisons pass. Regression currently failing; no fix yet. This extends beyond the finite duplicate panel and remains open.

### 2026-10-24 — Reopened automatic correction: arbitrary extra-key cancellation

Complete-message tests exposed a gap in the previous duplicate-tail-only restoration. Six messages (romantic, technical, dialect, formal, travel, family) at three touch offsets compare clean typing with duplicate and nearest-neighbor interruptions: insert extra key, space, Enter, delete three times, continue. Neighbor interruption corrupted expressive `çoook` at all three offsets; canceled fragments did not change learning.

Editing inside a just-reopened automatic correction now restores original typing before deleting the final original character regardless of whether it duplicates its predecessor. Explicitly selected suggestions retain their selected surface. Focused controls cover both paths, including a length-changing correction. All message outputs and personal-learning maps now match clean controls.

Native verification on dedicated iPhone 17 Pro: `çooı SPACE ENTER BS×3 ok` gave `loook` before the patch and `çoook` after rebuilding/installing. Explicitly choosing `çok` then deleting twice gives `ço`, confirming that selected suggestions are not restored to the original typo. The initial p-neighbor native probe did not trigger autocorrection and was not used as proof of this fix.

Validation: 730 XCTest (93 opt-in skipped), zero failures; 406 Swift Testing cases pass. Re-exported 1,779 duplicate probes have unchanged outcomes vs ambiguity checkpoint: both undo variants 0/585 mismatches, intentional repetitions 0/24; all 585 direct duplicate targets offered. Direct duplicates retain 225 literal results, not incorrect substitute words. Build succeeded. Evidence: `audits/everyday-20261024-duplicates-after-original-edit.json`, `audits/everyday-20261024-core-tests.log`. Physical phone and other task simulator untouched.

### 2026-10-24 — Punctuated complete-message cancellation controls

Expanded ConversationInterruptionTests with six punctuated messages in romantic, engineering, dialect, formal, travel and family contexts. Three touch offsets and four variants (clean; nearest extra letter followed by period/space/newline, comma/space/newline, or two spaces/newline, then four deletes) give 72 new complete-message executions. All final text and personal-learning maps match clean typing. The previous 54 clean/duplicate/neighbor message executions also pass. No production change was needed. Focused test log: `audits/everyday-20261024-punctuated-messages.log`.

Native on dedicated simulator: `canım seni çooı` plus accidental period/space/Enter, four deletes and `ok özledim.` yields `canım seni çoook özledim.`. A formal multiline message with `başvurumm` plus two spaces/Enter, four deletes and `un` yields `başvurumun`; subsequent text remains intact. Other task simulator and physical phone were not modified.

### 2026-10-24 — Accidental deletion and retyping, including held repeats

Added complete-word controls for 12 romantic, technical, dialect, formal and daily words, three touch offsets, and five modes: clean, composing tap deletion, tap deletion after space/newline, composing held-repeat deletion, and held-repeat deletion across space/newline. Each run repeats the word three times to test admission/learning behavior. All 180 runs (540 word occurrences) have final text and personal-point maps matching clean typing. Focused test passed; no production changes needed. Evidence: `audits/everyday-20261024-held-deletion.log`.

Native simulator controls: after `mühendis SPACE ENTER`, four single taps produce `mühend`; retyping `islik` and completing the full engineering message preserves correct text. Separate 610 ms holds crossed separators then removed `is`; retyping `islik SPACE` also produced `mühendislik `. Native hold duration was not treated as an exact deletion count; text was observed after each hold. Physical phone and other simulator untouched.

### 2026-10-24 — Case, apostrophe and dialect continuation

Expanded punctuated complete-message controls from six to twelve messages, adding Turkish uppercase İ/I, proper names, API/SQL and straight/curly apostrophes. Letter input uses explicit shifted-key commands with the appropriate Turkish lowercase key. All 144 runs (12 messages × 3 touch offsets × 4 modes) preserve expected text and personal learning. Focused log: `audits/everyday-20261024-uppercase-messages.log`. Test harness initially missed the KBSpatial import for TouchSample; fixed before successful execution. No production changes.

Native dedicated-simulator verification: duplicate `uşağumm` with space/Enter then three deletes completes to `ula uşağum gardaş geliyom çay içek.`; duplicate apostrophe suffix `İstanbul'aa` with the same cancellation completes to `İstanbul'a geliyorum.`; `Işıll` becomes `Işıl bugün geliyor.`. Targeted read-only personal.bkp inspection found zero points for canceled `uşağumm`, `ışıll`, `çooı`, `çoop`. This is simulator evidence, not a physical-phone cleanup.

### 2026-10-24 — Cancelled occurrences in separate typing history

Numeric/emoji expansion passes 252 complete-message runs (144 previous plus 108 new): times, dates, amounts, versions, IPs and simple/ZWJ emoji interruption boundaries preserve text and coordinator personal points. Native typing nevertheless exposed a separate learning defect: `18.300 SPACE ENTER BS×3` correctly displayed `18.30`, but recall still offered the removed `18.300`. Completing `18.30'da` and dismissing the keyboard persisted both values in history.json. This is independent of the previously fixed personal lexicon.

HistoryObservation had discarded an edited occurrence's receipt without retracting its contribution. It now queues bounded cancellation receipts only after an expected keyboard backward deletion is confirmed by matching before/after context. Removing separators alone keeps the occurrence. Unknown host edits, cursor moves, document changes and selection snapshots cannot authorize retraction. PersonalHistory applies each receipt once; HistoryArchive adjusts only the live unassigned contribution, retaining independently imported source data. TypingHistory drains these cancellations whenever observation advances and marks the archive for saving. No historical guess-based cleanup or migration is performed.

Regression before: 12 failed assertions for numeric, dialect and URL values with zero/two prior uses, including reload. After: 23 focused history tests pass, covering independent/imported evidence, repeated stale-proxy deletions, idempotence and uncertain-context controls. Full suite: 735 XCTest, 94 opt-in skipped, zero failures; 406 Swift Testing cases pass. Native build succeeds and git diff --check is clean.

Native after: fresh `19.455 SPACE ENTER BS×3` displays `19.45` with no old recall candidate. After completing the message and closing the keyboard, disk history has no `19.455`, valid `19.45` has count 1, and prepatch `18.300` remains count 1. Other task simulator and physical phone untouched. Evidence: `audits/everyday-20261024-history-cancel-before.log`, `audits/everyday-20261024-history-cancel-after.log`, `audits/everyday-20261024-core-tests.log`, `audits/everyday-20261024-numeric-emoji-messages.log`.

### 2026-10-24 — Combined coordinator and history consistency

Added ConversationHistoryConsistencyTests with a document adapter that mirrors native history bridge ordering: register backward deletion before the proxy operation, refresh after commands, observe completion at boundaries, drain confirmed cancellations. Six complete romantic/technical/dialect/formal/daily messages at three offsets compare clean and neighbor-key/space/Enter/three-delete variants. All 36 runs match in text, personal-lexicon points, history token counts and history pair counts. This closes the coverage gap where coordinator-only checks could pass while recall history accumulated errors. No production changes in this checkpoint.

Native: `selamq SPACE ENTER` auto-corrected to `selama`. Three deletes restore `selam`, then `canım` completes the phrase. Repeated three times in the same document; disk after dismissal contains `selam` count 3 and zero `selama`/`selamq`. Personal lexicon also has no wrong forms. Evidence: `audits/everyday-20261024-history-message-consistency.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Boundary-only continuation and expressive restoration

Expanded combined coordinator/history message controls with SPACE + ENTER + two deletes, without an extra letter. Before patch: 37 failed assertions: half-word token/pair history survived in all 18 comparisons, plus `çoook` became `çokok` at +0.18. Native `seni sev SPACE ENTER BS×2 iyorum` confirmed the history gap: `sev` increased 1→2 while `seviyorum` increased 9→10.

HistoryObservation now retains a reopened occurrence after a confirmed delete reaches exactly its body. The native insertion bridge registers actual text insertion; matching resulting context with a letter/number continuation retracts only that receipt. Simply reopening and restoring the separator preserves evidence. Unknown edits, mismatched insertions and document changes do not authorize retraction. No old records are purged. Expressive triple-letter protection is shared with automatic-prefix restoration so continued emphasis returns to the original typed form. Explicitly chosen suggestions remain distinct.

After patch: all 54 complete-message runs match in text, personal points, history tokens and pairs. Full 737 XCTest (94 opt-in skipped), zero failures; 406 Swift Testing pass. Native build succeeded. Native repetition left `sev` at 2 and increased `seviyorum` to 11; shifted `çoo SPACE ENTER` became `çok`, then `BS×2 ok SPACE` yielded `çoook`. Final source-only follow-up clarified comments; no executable behavior changed after validation. Evidence: `audits/everyday-20261024-history-boundary-only-before.log`, `audits/everyday-20261024-history-boundary-only-after.log`, `audits/everyday-20261024-core-tests.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Latest repeated occurrence cancellation

Added six romantic, technical, dialect, formal and everyday repeated-word contexts at three touch offsets. Clean writing is compared with typing an extra repeated word then deleting it through individual taps, held-repeat events or whole-word deletion before replacement. All 72 runs match in final text, personal points, and serialized/reloaded history token/pair counts. No production change needed.

Native: starting with zero recorded `merhaba`, typed three occurrences, deleted the last occurrence and its separator with eight taps, then typed `canım`. Final `merhaba merhaba canım ` has exactly two `merhaba` occurrences in disk history. Evidence: `audits/everyday-20261024-repeated-word-removal.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Technical punctuation continuation after accidental boundaries

A reopened prefix only tracked letter/number continuation, so punctuation could leave obsolete IP, URL, email, identifier and Turkish proper-name history. Even `kalem SPACE BS . SPACE` counted the same normalized word twice. Sixteen clean/interrupted comparisons produced 24 failed token/pair assertions before the patch. Confirmed non-whitespace insertion now retracts the reopened receipt; the next boundary records the resulting token once, including punctuation whose normalized spelling stays unchanged. Whitespace-only reclosing still retains the original evidence.

Native before: `192.168 SPACE ENTER BS×2 .1.10 SPACE` stored both the partial and full IP (0→1 each). After patch, repeating the exact keys kept partial `192.168` at 1 while full `192.168.1.10` increased 1→2. Adding `kalem SPACE BS . SPACE` increased kalem only 1→2. Values checked in persisted history after keyboard dismissal; existing records were not purged.

Seven focused tests pass. Full 739 XCTest (94 opt-in skipped), zero failures; 406 Swift Testing cases in 54 suites pass. Simulator build succeeds; diff whitespace check clean. Evidence: `audits/everyday-20261024-technical-continuation-before.log`, `audits/everyday-20261024-technical-continuation-after.log`, `audits/everyday-20261024-core-tests.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Repeated punctuation continuation and undo

Added 36 clean/interrupted history comparisons: nine prose, proper-name, IP, URL, email, identifier and emoji cases, with suffix either completed or uncompleted before deletion and ultimately retained or removed. Each interrupted case repeats SPACE/ENTER removal, suffix insertion and suffix deletion three times. An independent earlier stem occurrence must survive. All serialized/reloaded token and pair counts equal clean typing. No production change needed.

Native: typed kalem, repeated `SPACE ENTER BS×2 . SPACE ENTER BS×3` three times, then SPACE. Final `kalem ` persisted exactly one additional occurrence (2→3). Evidence: `audits/everyday-20261024-punctuation-undo.log`. Previous full suite remains 739 XCTest (94 skipped) plus 406 Swift Testing; only this new test was added afterward. Other simulator and physical phone untouched.

### 2026-10-24 — Replace a mistyped completed word after Enter

Added six romantic, technical, dialect, formal and daily contexts at three offsets with clean, tap-delete, repeat-delete and whole-word-delete modes (72 runs). Type an extra-letter word, SPACE and ENTER, delete it, and write a different ending. Final text, personal points and serialized/reloaded history tokens/pairs match clean typing. The initial harness incorrectly expected one word-delete command to cross the newline; source intentionally removes only the newline barrier first, so the harness now verifies that intermediate state and issues a second command. No production change.

Native `canım özledimm SPACE ENTER` followed by ten deletes returned to `canım `; completing `seni seviyorum SPACE` persisted özledimm=0, previous özledim=3 unchanged and seviyorum 11→12. Personal lexicon also retains zero özledimm points. Evidence: `audits/everyday-20261024-replace-mistyped-word.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Native mixed formal-message mistakes

Typed the entire message through real keyboard taps: `sayın yetkilii SPACE ENTER` auto-corrected to yetkili; three deletes and space retained the intended word. `başvuru SPACE ENTER BS×2 mu SPACE` completed başvurumu without retaining the partial form. `değerlendirmenizzi BS×2 i` repaired the extra interior z. Finished `rica ederim. SPACE`. Final text was exactly `sayın yetkili başvurumu değerlendirmenizi rica ederim. `.

Persisted history after keyboard dismissal shows each final word incremented once. yetkilii and değerlendirmenizzi are absent from history and have zero personal points; başvuru is absent; unrelated old başvurumm remains 1. No production changes. Evidence: `audits/everyday-20261024-native-formal-mixed.json`. Other simulator and physical phone untouched.

### 2026-10-24 — Multiple interruptions within the same word

Expanded combined conversation/history controls with duplicate first, middle and last characters of every word. Each duplicate is followed by SPACE, ENTER and three deletes before typing continues. Six complete messages at three offsets add 18 executions (72 total including existing modes). Final text, personal points, history token counts and pair counts match clean writing. Focused test passes; no production changes.

Native `ula gardaş geliyom ` survived three duplicate/boundary interruptions at g, i and m in geliyom. Persisted geliyom increased 2→3; gg, gelii and geliyomm are absent from history and have zero personal points. Evidence: `audits/everyday-20261024-multiple-interruptions.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Replace a complete multiword phrase

Expanded replacement controls with six additional romantic, engineering, dialect, formal and daily phrases, including repeated words. Three offsets and clean/tap/repeat/whole-word modes add 72 runs (144 replacement runs total). Whole-word deletion explicitly crosses the newline first, then deletes each word. All final text, personal points and serialized history token/pair counts match clean typing. No production changes.

Native `canım seni çok özledim SPACE ENTER` followed by 18 deletes returned to `canım `. Typed `yarın seni göreceğim SPACE`. Persisted çok and özledim remained 3 each, while canım 9→10, seni 13→14, yarın 2→3 and göreceğim 0→1 reflect only the final message. Evidence: `audits/everyday-20261024-phrase-replacement.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Numeric and technical replacement

Added time, amount, IP and version cases to combined replacement controls, routing numeric/punctuation keys through insertSymbol. Three offsets and four modes add 48 runs (192 replacement runs total). All text, personal points and serialized history token/pair counts match clean input. No production changes.

Native `toplam 12500 lira SPACE ENTER` followed by 12 deletes returned to `toplam `. Typed `1250 lira SPACE`; persisted history after dismissal contains no 12500, with 1250, lira and toplam each exactly 1 from zero. Evidence: `audits/everyday-20261024-numeric-replacement.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Preserve intentional paragraph boundaries

Added four single/double-newline prefixes to combined replacement tests. Three offsets and four modes add 48 runs (240 replacement runs total). Intended paragraph breaks survive deletion/replacement; final text, personal points and serialized history tokens/pairs equal clean writing. No production changes.

Native `canım ENTER ENTER seni özledimm SPACE ENTER BS×3 SPACE` retains the intentional blank line and corrects the final word. Persisted canım→seni stayed at 3 (no cross-paragraph increment); seni→özledim increased 2→3 and seni→özledimm remained 0. Evidence: `audits/everyday-20261024-paragraph-replacement.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Delayed insertion snapshots

Found a history bug under repeated insertion commands sharing a stale host context: expectInsertion overwrote the expected continuation with only the newest chunk. Later combined host output did not match, leaving the reopened prefix in history. New regression uses sev→seviyorum, 192.168→192.168.1.10 and Ankara→Ankara'ya, with one independent earlier occurrence and mismatching-output controls. Before fix: six failed assertions.

Accumulate consecutive insertion chunks only for the same document and identical before/after snapshot. A later full match retracts exactly the reopened occurrence; mismatches retain evidence. Tracking is abandoned beyond 128 continuation characters. Ten focused tests pass. Full 742 XCTest (94 opt-in skipped), zero failures; 406 Swift Testing in 54 suites pass. Native build succeeds; diff check clean.

Installed only to the dedicated simulator. Native ordinary `seni sev SPACE ENTER BS×2 iyorum SPACE` yields `seni seviyorum `, leaves existing sev=2 unchanged and increments seviyorum 12→13. This is ordinary native regression evidence; the delayed-host condition is deterministically reproduced in the unit test, not claimed to be forced through simulator taps. Evidence: `audits/everyday-20261024-delayed-insertion-before.log`, `audits/everyday-20261024-delayed-insertion-after.log`, `audits/everyday-20261024-core-tests.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Intermediate host acknowledgements

Extended delayed-insertion regression with a partial host acknowledgement before the complete resulting text. Before patch, all three prefixes lost their witness and left obsolete history (six failed assertions). Observation now retains a witness while the reported text is between its original context and expected result; additional actual insertions after partial acknowledgement extend that same result. Only a full match authorizes retraction.

Expanded controls cover full, intermediate, continued-intermediate, mismatch, changed right context, changed document and selection snapshots for all three prefixes (21 cases). Ten focused tests pass; full 742 XCTest (94 opt-in skipped), zero failures; 406 Swift Testing in 54 suites pass. Build succeeds, diff check clean. Native ordinary `21.4 SPACE ENTER BS×2 5 SPACE` yields 21.45, persisted 21.4=0 and 21.45=1. Delayed/intermediate callback order is deterministic unit-test evidence; it was not forced on the native simulator. Logs: `audits/everyday-20261024-intermediate-insertion-before.log`, `audits/everyday-20261024-intermediate-insertion-after.log`, `audits/everyday-20261024-core-tests.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Mixed engineering vocabulary

Expanded combined message checks with deploy, docker, cache, commit and branch inside four Turkish engineering messages. Three offsets and four clean/interrupted modes add 48 executions (120 full-message runs total). Literal technical words, final text, personal points and history token/pair counts match clean typing. Focused test passes; no production changes.

Native `deployy SPACE ENTER BS×3 SPACE` followed by `sonrası logları kontrol ediyorum. SPACE` produced the intended sentence. Persisted deploy increased 0→1, deployy remained 0. Evidence: `audits/everyday-20261024-mixed-engineering.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Short words and separately written particles

Added four complete-message controls: iyi ki varsın; ben de seni çok seviyorum; her şey çok güzel; bir şey sorabilir miyim. Three offsets/four clean and interrupted modes add 48 executions (168 message runs total). Text, personal points and history token/pair counts match clean writing. No production changes.

Native duplicated each final character in iyi, ki and varsın, followed by SPACE ENTER BS×3 SPACE. Final `iyi ki varsın ` preserved all separate words. Persisted valid counts each increased 0→1; iyii, kii and varsınn remain absent from history with zero personal points. Evidence: `audits/everyday-20261024-short-function-words.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Colloquial abbreviations

Added four colloquial message controls covering naber, kanks, napıyon, bi, tmm, gelcem, slm and napcaz. Three offsets/four clean and interrupted modes add 48 executions (216 message runs total). Intentional informal text and both learning stores match clean writing. No production changes.

Native `naber kanks napıyonn SPACE ENTER BS×3 SPACE` produced `naber kanks napıyon `. Persisted naber and kanks increased 0→1, napıyon 1→2, and napıyonn stayed 0. Evidence: `audits/everyday-20261024-chat-abbreviations.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Repeated mixed separators

Added a fifth complete-message mode: SPACE ENTER SPACE ENTER SPACE at every word midpoint, followed by five deletes and continued typing. Eighteen messages at three offsets add 54 runs (270 message executions total). Text, personal points and history token/pair counts match clean writing. No production changes.

Native typed gel, repeated the five-separator/five-delete sequence three times, then iyorum SPACE. Final geliyorum is correct; persisted gel stayed 2 while geliyorum increased 0→1. Evidence: `audits/everyday-20261024-multiple-separators.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Intermediate deletion acknowledgements

Repeated delete commands followed by an intermediate host snapshot discarded the remaining deletion witness, retaining cancelled tokens in history. The initial regression produced 12 failed assertions. Keep the witness while reported context lies between the original and expected deletion result; additional commands extend the pending deletion. Cancellation is emitted once, including when an intermediate acknowledgement already removes a letter.

Twelve cases cover numeric, dialect and URL tokens, separator-only/letter-removing intermediate acknowledgements and continued deletion. Independent earlier occurrences survive. Eleven focused tests pass; full 743 XCTest (94 opt-in skipped), zero failures; 406 Swift Testing in 54 suites pass. Native build succeeds; diff check clean.

Native ordinary `23.455 SPACE ENTER BS×3 SPACE` produces `23.45 `; persisted wrong token stays 0 and correct token increases 0→1. Intermediate callback ordering is deterministic unit-test evidence, not claimed to be forced through UI taps. Evidence: `audits/everyday-20261024-intermediate-deletion-before.log`, `audits/everyday-20261024-intermediate-deletion-after.log`, `audits/everyday-20261024-native-intermediate-deletion.json`, `audits/everyday-20261024-core-tests.log`. Other simulator and physical phone untouched.

### 2026-10-24 — Restore an accidentally deleted correct letter

Added a sixth complete-message mode: at each word midpoint, SPACE ENTER BS×3 removes both boundaries and a correct letter, then the same letter is restored before continuing. Eighteen messages and three offsets add 54 runs (324 message executions total). Final text, personal points and history token/pair counts match clean writing. Focused regression passes; no production changes.

Native `seni seviyo SPACE ENTER BS×3` leaves `seni seviy`; restoring o and typing rum SPACE yields `seni seviyorum `. Persisted seni increased 16→17, seviyorum 13→14 and seviyo remained 0. Evidence: `audits/everyday-20261024-restored-letter.log`, `audits/everyday-20261024-native-restored-letter.json`. Other simulator and physical phone untouched.

### 2026-10-24 — Formatted values in messages

Added time, decimal-comma amount, dotted date and percentage replacement contexts: 14:300→14:30, 125,500→125,50, 24.10.20266→24.10.2026 and %155→%15. Three offsets and four modes add 48 executions (288 replacement runs total). Final text, personal points and serialized history token/pair counts match clean writing. Focused regression passes; no production changes.

Native `24.10.20266 SPACE ENTER BS×3 SPACE` yields `24.10.2026 `. Persisted wrong date remains 0, correct date increases 0→1. Evidence: `audits/everyday-20261024-formatted-values.log`, `audits/everyday-20261024-native-date-correction.json`. Other simulator and physical phone untouched.

### 2026-10-24 — Keep exact duplicate repairs visible outside general window

A new four-word formal audit found başvurunuzzun at -0.18 touch offset missing başvurunuzun. Decoder ranked the intended word third, but its cost gap of 3.235 exceeded the general 3.0 presentation window. A permanent regression failed before the fix. Suggestion presentation now retains the exact removal of a single repeated key from the bounded top-eight decoder results, preserving source identity and score. General alternatives retain the normal window; the automatic winner is not promoted.

Formal audit: 519 runs; all 165 raw-double targets offered (previously 164), 84 automatically corrected, zero unrelated outputs; all 330 undo cases exact; all 24 intentional repeats preserved. Original audit: 1779 runs; all 585 raw-double targets offered, 360 exact automatic outputs, zero unrelated outputs; all 1170 undo cases exact and 24 intentional repeats preserved. Full 743 XCTest (94 opt-in skipped), zero failures; 406 Swift Testing in 54 suites pass. Native build succeeds, diff check clean.

Native offset taps produce başvurunuzzun with başvurunuzun in the middle slot. Picking it yields correct text and persisted correct=1, wrong=0. Earlier gereğininn test also confirmed explicit correction retracts the wrong occurrence. Third-slot splits gereğin inn and başvurunuz un remain a suggestion-quality follow-up; neither was automatically applied. Artifacts: formal-missing-before, formal-duplicates-before/after, duplicate-window-regression and native-formal-duplicate-fix under audits/everyday-20261024-*. Other simulator and physical phone untouched.

### 2026-10-24 — Match competing splits to the duplicate boundary

Exact double-key corrections no longer receive unrelated split padding such as gereğin inn or başvurunuz un. Preserve a split at the same repeated pair with all typed letters retained (annemmi → annemi / annem mi), plus the supported o-pronoun boundary when concatenation matches the duplicate correction. Full validation caught an initial ozzaman regression; the final rule preserves o zaman across casing and shifted taps. Existing tests that required any phrase padding now assert a matching repeated boundary; the explicit annem mi control verifies selection.

Final 745 XCTest (95 opt-in skipped), zero failures; 406 Swift Testing in 54 suites pass. Build succeeds, diff check clean. Native gereğininn shows gereğinin without gereğin inn. annem mi remains selectable and persists each word once, with annemmi absent. Final build ozzaman offers o zaman, selecting it persists o=1 and zaman=1 with ozzaman=0. Evidence: duplicate-split-evidence-before/after logs, native-duplicate-split.json and core-tests.log in audits/everyday-20261024-*.

Open quality follow-ups: same-boundary rare fragments (saygılarım mla, bağlantısın nı, alışveriş şe, etc.) are not solved by the structural rule. Diagnostic bellimi offers belkimi but no belli mi; investigate the vocabulary gate and reproduce natively. No physical phone or other simulator changes.

### 2026-10-24 — Question-particle offer and replacement history acknowledgement

The whole-form vocabulary gate hid belli mi for bellimi because a generated morphology match counted as a protected surface. For generated-only whole forms, offer a vowel-harmonic question particle split when the stem is directly listed. Listed and personal whole words retain protection. Six casing/spelling controls and negative controls pass; native bellimi now offers and selects belli mi.

The native selection exposed a separate learning error: coalesced delete/insert callbacks lost the old occurrence receipt. Pending replacements now retain their captured receipts through intermediate snapshots and retract only upon a matching final result. Tests cover 21 cases across three tokens, including mismatched document, right context, selection and unrelated edits. An additional phrase completion test covers coalesced and partial acknowledgements.

Core-only changes passed tests but still failed natively (bellimi 1→2). The UIKit bridge skipped insertion registration when deleting the sole word produced nil context. It now accepts an empty prefix only when hasText=false proves the document is empty. Final native test passes: belli 2→3, mi 3→4, bellimi remains 2. Existing historical evidence is preserved. Final text is belli mi with trailing space.

Validation: 748 XCTest (95 opt-in skipped), zero failures; 406 Swift Testing in 54 suites pass. Subsequent focused 10-test learning suite passes; final native build succeeds. Evidence: replacement-ack-full.log, phrase-ack-regression.log, native-replacement-ack.json under audits/everyday-20261024-*. Rare-fragment split quality remains open. Other simulator and physical phone untouched.

### 2026-10-24 — Lexical evidence for competing duplicate-boundary splits

Native saygılarımmla reproduced the third-slot fragment saygılarım mla. The same-boundary structural rule also retained eczan nelerden, bağlantısın nı, randevum muz and alışveriş şe. Their summed lexical costs exceed the exact duplicate correction by 8.5–16.4 units. Ordinary question controls are substantially closer. Presentation now requires joint lexical cost within eight units of the exact duplicate correction, after the existing structural check. This is an empirical offer-quality cutoff, not a grammatical model or an autocorrection change.

Expanded controls cover twelve inputs across three offsets and limits three/five. Negative cases require no split; positive cases require the intended phrase to remain selectable. Initial testing exposed an independent pre-existing dedemmi/-0.18 omission of dedemi while dede mi and dedem mi remain visible. The phrase-preservation assertion does not claim that separate duplicate target is fixed; it is tracked for follow-up.

Final native build shows saygılarımmla and saygılarımla only; choosing the correction persists saygılarımla=3, wrong=0. annemmi still offers annemi and annem mi; phrase selection succeeds and wrong count stays zero. Initial full validation caught uppercase Ozzaman/OZZAMAN filtering; Turkish canonicalization of both phrase components and the duplicate target repairs it. Final native Ozzaman offers and selects O zaman. Final full validation: 749 XCTest (95 opt-in skipped), zero failures; 406 Swift Testing in 54 suites pass. Final build succeeds. Evidence: audits/everyday-20261024-fragment-split-final.log and native-fragment-split.json. Additional source-quality findings: wordlist.tsv directly lists tamammı, varmı, yokmu and öylemi. These have not been removed or repaired in this batch.

### 2026-10-24 — Explicit corrections for listed joined questions

Native tamammı showed tamammı/tamammış/tamamım, with no tamam mı. The corpus lists tamammı, varmı, yokmu and öylemi, so whole-word protection suppresses general boundary repair. Added four manually curated mappings to the existing explicit expansion channel. Corpus membership is retained for literal typing; this change offers the spaced spelling without forcing it or globally splitting legitimate suffix forms.

Rebuilt only tr-TR.bkx: 32 entries, 622 bytes; serialization round-trip and deterministic build pass; SHA-256 448a5834827cb8a3624c258309edbb1db5325a9cad7bd6893af83bf6fd9bbb65. The test helper now routes uppercase characters through insertUppercaseLetter, matching the actual Shift path; initial raw-uppercase helper failures were not native findings.

Focused suite: 11 tests, one opt-in skipped, zero failures. Thirty-six scenarios span four expressions, three casing styles and three offsets, checking visible offer, literal SPACE behavior, BS reopening, selection and subsequent deletion. Native tamammı SPACE BS pick tamam mı records tamam=1, mı=1, tamammı=0. Native ÖYLEMİ picks ÖYLE Mİ with casing intact; öyle 0→1, mi 5→6, öylemi remains zero. Full suite passes: 750 XCTest (95 opt-in skipped), zero failures; 406 Swift Testing in 54 suites pass. Native build succeeds and diff check is clean. Full evidence: audits/everyday-20261024-listed-questions-full.log. Evidence: listed-questions-before/after/pack.log and native-listed-questions.json under audits/everyday-20261024-*.

### 2026-10-24 — Exact duplicate repair beyond rank eight

A permanent regression reproduces dedemmi at -0.18 offset: dedemi exists at rank nine (cost -4.994) but the eight-result retrieval excluded it. The presenter now searches all already-computed terminal results for the best exact repeated-letter removal. Decoder results already scores and sorts the bounded terminal frontier before its top-K truncation, so this neither widens the beam nor launches a second decoding search. General visible alternatives retain their normal three slots/window; the retained repair keeps its decoder identity and score.

Focused regression passes across three offsets. Phrase controls now again require both duplicate targets and intended phrases, including dedemi/dedem mi. Native physical offsets (-10,-13) already showed both options before the fix, so they are not claimed as a reproduction of the precise failing numeric geometry. Updated native dedemmi SPACE ENTER BS BS pick dedemi produces dedemi with trailing space; history correct=1, wrong=0. Full suite passes: 750 XCTest (95 opt-in skipped), zero failures; 406 Swift Testing in 54 suites pass. Native build succeeds. Duplicate audit: 1779 runs, all 585 raw-double targets offered, 360 exact automatic corrections, zero unrelated outputs, all 1170 undo cases exact, all 24 intentional repeats preserved. Logs: terminal-duplicate-full.log and terminal-duplicate-audit.json/log under audits/everyday-20261024-*. Evidence: dedemi-before/after.log and native-terminal-duplicate.json under audits/everyday-20261024-*.

### 2026-10-24 — Additional complete-message learning consistency

Added six authored contexts: aşkım eve varınca haber ver; yarın seni görünce sarılacağım; sunucu günlüklerinde bağlantı zaman aşımı var; talebimin sonucunu tarafıma bildirmenizi rica ederim; hele gardaş bi soluklan sonra konuşak; kargoyu komşuya bırakır mısınız. Three offsets and six modes add 108 executions, bringing this test to 432 message runs. Edited final text, personal points, history token counts and history pair counts all match clean typing. Focused regression passes in 50.7 seconds. Test-only change; no production change and no redundant full-suite rerun.

Native aşkk SPACE ENTER BS×3 leaves aşk; finishing ım eve varınca haber ver yields aşkım eve varınca haber ver with trailing space. Persisted full words each count one, aşkk and aşk remain absent. Evidence: expanded-dialogue.log and native-expanded-dialogue.json under audits/everyday-20261024-*. Other simulator and physical phone untouched.

### 2026-10-24 — Punctuated technical tokens in replacement messages

Added URL, mailbox, file-name and Turkish apostrophe contexts to the completed-word replacement test. https://example.com/apii→https://example.com/api, devv@example.com→dev@example.com, raporr.txt→rapor.txt and ankara'yaa→ankara'ya gidiyorum cover punctuation-bearing tokens after SPACE/ENTER, followed by ordinary deletion, held deletion or delete-word replacement. Four contexts × three offsets × four modes add 48 executions; total 336 replacement executions. Final text, personal points and serialized history token/pair counts match clean typing. Focused regression passes in 19.4 seconds. Test-only change; production remains unchanged.

Native rapor.txtt SPACE ENTER BS×3 SPACE produces rapor.txt with trailing space. Persisted wrong token remains zero, correct token increases to one. Evidence: technical-message-replacement.log and native-file-extension-undo.json under audits/everyday-20261024-*. Other simulator and physical phone untouched.


### 2026-10-24 — Exact duplicate repair outside the completed beam

The additional 20-word audit exposed `sarıılacağım` → `sarkılacağım` at +0.18 touch offset. This was reproduced through native keyboard taps (+9/+13 pixels) and SPACE. The completed beam no longer contained `sarılacağım`, so retaining all terminal candidates could not recover it. A bounded lexical lookup now considers exact single-repeat removals for unknown, attached letter tokens and offers supported forms explicitly. It supplies no invented decoder score and does not turn the fallback into an automatic winner. An alternative supported removal also prevents an unrelated automatic winner. Expressive triple runs are excluded from this fallback; existing known and personal word protections remain.

The competing-duplicate regression now includes `sarıılacağım` and `sarrılacağım` at all three offsets: before the fix it had three failures; after the fix it passes. Native before/after confirms that SPACE preserves the typed token, ENTER plus two backspaces reopens it, and selecting `sarılacağım` works. Title-case `Sarıılacağım` offers and commits `Sarılacağım`. Persisted history after both trials: correct form 2, both wrong forms 0. Full regression and new-word audit results are recorded separately below once completed. The four other new vocabulary/colloquial coverage findings remain open; this change does not claim those are fixed.

Validation completed: 750 XCTest cases (94 opt-in skips), zero failures; 406 Swift Testing cases in 54 suites pass. The 1788-run audit restores both missing `sarılacağım` offers: 498/588 targets offered, 249 exact automatic corrections, 1176/1176 undo cases exact, and 24/24 intentional repeats preserved. The remaining 90 missing offers concern `gardaşım`, `soluklan`, `konuşak`, and `geliver`; eight unrelated automatic outputs in the first/third groups remain open. See `audits/everyday-20261024-new-word-duplicates-after.json` and `audits/everyday-20261024-pruned-duplicate-full.log`.


### 2026-10-24 — Bare verb imperative recognition

`soluklan` was present in `roots.tsv`, but `TurkishMorphotactics.isAccepting` still excluded `verbRoot` under the original spike assumption that bare verbs were outside scope. Plain verb roots now terminate as second-person singular imperatives. The automaton still rejects softened/contracted intermediate root variants unless their required suffix follows; this does not loosen those constraints or add a new suffix cycle. The old test asserting that `gel` was absent now requires the correct imperative. Two duplicate cases (`ssoluklan`, `solukklan`) at three touch offsets failed six offer assertions before the change and pass afterward; the `gel` morphology assertion also fails before and passes after.

Native center taps reproduce the missing offer before the change (`ssoluklan`, `solulan`, `solulman`). Afterward the keyboard offers `ssoluklan`, `soluklan`, `solulan`. SPACE preserves the typed word, ENTER plus two backspaces reopens it, and tapping the correct suggestion produces `soluklan `. Persisted history has `ssoluklan` 0 and `soluklan` 1, with no personal points for either. Full regression and audit validation follow below. Other colloquial and productive verb coverage findings remain open.

Validation completed: 750 XCTest cases (94 opt-in skips), zero failures; 406 Swift Testing cases in 54 suites pass. In the 1788-run new-word audit all 24 `soluklan` duplicate probes now offer the correct form. Overall 522/588 targets are offered, 249 automatically correct, 1176/1176 undo probes exact, and 24/24 intentional repeats preserved. The remaining 66 missing offers and eight unrelated automatic outputs concern the other three open words. Evidence: `audits/everyday-20261024-imperative-full.log`, `audits/everyday-20261024-imperative-duplicates.json`, and native before/after artifact.


### 2026-10-24 — Colloquial possessive and optative coverage

Added authored `gardaşım` and `konuşak` to the existing informal surface list at its established relative weight 800 (not a corpus frequency). Rebuilt only `tr-TR.bkt`: 59 informal entries, 70068 total forms, round-trip and I2 checks passed; SHA-256 `6064ba6341ca966fc4e5abe21442d848f06f0f5e9fc1809dd987a61794a48719`. This covers the specified colloquial surfaces rather than claiming productive support for every dialectal inflection.

The permanent conversational-form preservation test now includes both forms; the competing-duplicate test adds `gardaşşım`, `garddaşım`, `gardaşıım`, `kkonuşak` at all three offsets. The two focused tests failed 22 assertions before and pass afterward. Native `gardaşşım SPACE` previously produced `vardığım ` and now produces `gardaşım `. The core `kkonuşak` wrong automatic output did not reproduce at native center taps before the change; after the change native offers and completes `konuşak`. The complete native sequence, including `solu SPACE ENTER BACKSPACE BACKSPACE + klan`, finishes as `gardaşım bi soluklan sonra konuşak `. History records the correct forms while `gardaşşım`, `solu`, and `kkonuşak` have zero occurrences. One pre-existing weak personal point for `kkonuşak` remains unchanged, not purged. Full regression results follow below.

Validation completed: 750 XCTest cases (94 opt-in skips), zero failures; 406 Swift Testing cases/54 suites pass. The 1788-run audit now offers 567/588 double-key targets, including all 45 restored `gardaşım`/`konuşak` probes. There are 273 exact automatic corrections and zero unrelated automatic outputs. All 1176 undo probes and 24 intentional repeats remain exact. The remaining 21 missing offers concern `geliver`; that productive-verb and fragment-offer issue remains open. Evidence is in `audits/everyday-20261024-colloquial-possessive-full.log` and the corresponding duplicate/native JSON artifacts.


### 2026-10-24 — Productive -(y)Iver compounds

The `geliver` missing-offer finding came from absent morphology, rather than a missing common-word surface alone. Added a distinct accepting `afterHastive` continuation for root + harmonic -(y)Iver, with ordinary inflection after the fixed auxiliary `ver` and its -Ir aorist. It does not return to verbRoot or reopen voice/causative derivation; ability copying excludes the new hastive entry to prevent a cycle. This bounded stage currently enters from verbRoot; other ordering combinations are not claimed as covered. The existing relative derivation cost 2.8 is used, not presented as a measured frequency. Form-list packs are unchanged.

Grammar reference: the [EBA Turkish dictionary entry for tezlik eylemi](https://f.eba.gov.tr/flippingbook/05-sozlukler/05-sozlukler-tu-rkc-e-so-zlu-k/files/assets/basic-html/page603.html) describes the harmonic vowel plus vermek construction; authored controls cover geliver, bakıver, alıver, okuyuver and görüver. The new morphology test checks 40 valid imperative/tense/negative/infinitive/converb/person surfaces and 17 invalid missing-buffer, wrong-aorist, repeated-compound/person forms. Two geliver duplicate probes at three offsets join the existing regression. Before the change these checks had 46 failures; the focused run passes after the change. The final rule-copy source excludes duplicate copies of the existing coverage additions.

Native `ggeliver` previously offered only `gelirce`/`gelir` besides the literal. It now offers and automatically commits `geliver`; persisted counts are wrong 0, correct 1, personal points 0. A second native sequence `mesajını SPACE okuyu SPACE ENTER BACKSPACE BACKSPACE verdim SPACE` finishes as `mesajını okuyuverdim `. History records mesajını and okuyuverdim once, while the cancelled okuyu fragment and its personal points remain zero. Final full regression and audit results follow below.

Final validation: 751 XCTest cases (94 opt-in skips), zero failures; 406 Swift Testing cases/54 suites pass. All 588 double-key targets in the 20-word audit are now offered, with 279 exact automatic corrections and zero unrelated automatic outputs. All 1176 undo cases and 24 intentional repeats remain exact. No geliver duplicate variant has a split phrase offer. All four remaining word-coverage findings from this batch are now closed; this does not claim exhaustive real-world Turkish coverage, and the ongoing typing goal remains active. Evidence: `audits/everyday-20261024-hastive-full.log`, duplicate JSON, and native JSON.


### 2026-10-24 — Date/time replacement across conversational styles

Expanded completed-word replacement regression from 28 to 32 contexts: romantic `19.300` → `19.30 gibi geliyorum`, engineering `02:000 03:00` → `02:00 03:00`, formal `25/100/2026` → `25/10/2026`, dialect `saat 88 oldu` → `saat 8 oldu`. The 384 runs compare clean typing against tap deletion, repeat deletion and whole-word deletion after space/newline, at three touch offsets. Final text, personal learning, persisted history token counts and pair counts match. Focused debug test passed in 305.681 seconds with zero failures; no runtime change was needed.

Own iPhone 17 Pro native keyboard: typed `aşkım 19.300`, space/newline, three backspaces, continued to `aşkım 19.30 gibi geliyorum `. Repeated with `ula gardaş saat 88` and corrected to `ula gardaş saat 8 oldu `. Numeric fragments were absent from both learning stores, and retained word history counts each increased once. Evidence: `audits/everyday-20261024-native-datetime-replacement.json` and `audits/everyday-20261024-datetime-replacement.log`. Other simulators were untouched. Continuous goal remains active.


### 2026-10-24 — Duplicate ambiguity in generated valid words

A new 20-word audit produced 1905 cases. Before the change, 550/627 duplicate inputs offered the intended word; 1254 undo cases and 24 intentional-repeat controls were exact. Missing targets were `güncelleştirmeyi` (48), `napıyosun` (27) and `marketin` (2). The 21 automatic deviations all normalized the conversational `napıyosun` to `napıyorsun`; they are style changes, not unrelated meanings. The first two coverage findings remain open.

`markettin` is accepted as a generated inflection but is not a listed surface. Its plausible single-repeat alternative `marketin` was lost at center/right touch offsets and on the native keyboard. Presentation now permits a listed duplicate-removal alternative for an unlisted generated literal. It preserves the literal as the first choice and does not change automatic correction policy, decoder scores, listed words or personal-word protection. Triple expressive runs remain excluded. The new regression failed twice before the fix and passes afterward; the focused duplicate suite passes.

Native verification on the owned iPhone 17 Pro changed offers from `markettin / markettim / marketstin` to `markettin / marketin / markettim`. Space, newline, two backspaces and selecting `marketin` yielded `marketin `. History retained only one `marketin` occurrence; `markettin` and both personal entries remained zero. See `audits/everyday-20261024-native-known-duplicate.json`.

Validation completed: 752 XCTest tests (94 opt-in skips), zero failures; 406 Swift Testing tests across 54 suites pass. The 1905-row audit restores both missing `marketin` offers (552/627 total targets); 1254 undo cases and 24 intentional-repeat controls remain exact. Automatic output behavior is unchanged. `güncelleştirmeyi` and conversational `napıyosun` remain open; continuous goal remains active.


### 2026-10-24 — Preserve conversational napıyosun during duplicate correction

The new duplicate audit found all 27 `napıyosun` variants missing their target; 21 were normalized to `napıyorsun`. The native keyboard also reproduced `napıyyosun` → `napıyorsun` before the fix. Added the intentional conversational surface `napıyosun` to the existing informal list with weight 800 and rebuilt only `tr-TR.bkt` (SHA-256 `dd9a4a92ffb97881eb996c906b19d84a1154360fbc855743bb1bc0b6ca991b2c`). Pack round-trip and I2 checks passed. This is a curated surface addition, not a general colloquial grammar rule.

Regression coverage adds the surface to the three-offset preservation/learning test, two duplicate inputs at three offsets, and `napıyosun biz de geliyoz` to the cancelled-fragment comparison. The focused pre-change tests failed with 16 assertions. Native post-change offers were `napıyyosun / napıyosun`; space produced `napıyosun`. Continued with `biz de geli`, accidental space/newline, two backspaces and `yoz`, yielding `napıyosun biz de geliyoz `. History counts of the four retained words increased once, while `napıyyosun` and `geli` stayed absent. Pre-existing `napıyorsun` count remained one. Personal entries remained absent. Evidence is in `audits/everyday-20261024-native-napiyosun.json`.

Post-change validation: 752 XCTest (94 opt-in skips), zero failures; 406 Swift Testing across 54 suites pass. All 27 `napıyosun` duplicate variants now offer and automatically produce the target. Across 1905 audit rows, 579/627 duplicate targets are offered, 279 automatically produce the intended word, and no unrelated automatic substitutions remain. All 1254 undo and 24 intentional-repeat controls remain exact. The 48 missing `güncelleştirmeyi` variants remain open; the continuous goal is active.


### 2026-10-24 — Technical update verb family

The root dictionary lacked `güncelleştir`. Its use is attested in Microsoft's Turkish Windows support text: https://support.microsoft.com/tr-tr/windows/deployment/updates-lifecycle/troubleshoot-problems-updating-windows . Added the derived verb stem as a lexical root, with explicit `-Ir` aorist and `-t` causative class, using the existing `güncelle` weight (3859) as a calibration choice, not a newly measured corpus count. Existing inflection rules produce the forms; general derivational cycles remain disabled. Only `tr-TR.bkr` was rebuilt (50223 roots, round-trip passed; SHA-256 `30cdb6038a61c59c3a9288d6c6e1b3b0f8f3e0a17c429028dcce1da38892baaf`).

Before the addition, all ten tested production forms and six duplicate suggestions failed. Afterward, the ten forms (imperative, infinitive, nominal cases, progressive, past, future, passive/evidential, ability and aorist) and the duplicate regressions pass. Native `güncelleştirrmeyi` previously offered only `güncelleyivermeyi` besides the literal; afterward it offers `güncelleştirmeyi` and `güncelleştirtmeyi`. Space preserved the literal; after newline/two backspaces, choosing the correct proposal yielded `güncelleştirmeyi `. The discarded literal had history count zero, the selected word one, and both personal entries zero. Evidence: `audits/everyday-20261024-native-update-verb.json`.

Full validation: 753 XCTest (94 opt-in skips), zero failures; 406 Swift Testing across 54 suites pass. All 627 duplicate targets in the 1905-row audit are offered (310 exact automatic outputs, no unrelated automatic outputs), including all 48 previously missing update-verb variants. All 1254 undo cases and 24 intentional-repeat controls are exact. The current audit group has no remaining open findings; the user’s continuous testing goal remains active.


### 2026-10-24 — Wrong-key substitution before cancelled boundaries

Extended the cancelled-fragment comparison with a distinct substitution mode: at each word midpoint, type the nearest other key instead of the intended key, then space/newline, three backspaces and the correct letter. This differs from appending an extra wrong key after a correct one. Across 25 messages, three touch offsets and seven modes, all 525 runs pass (75 new substitution runs). Final text, personal entries, history tokens and history pairs equal clean typing. Focused release regression passed in 60.564 seconds; no runtime fix was needed.

Native keyboard: `yaru`, space/newline, three backspaces and `ın seni bekliyorum ` produced `yarın seni bekliyorum `. Discarded `yaru` stayed absent; each retained word gained exactly one history occurrence and no personal entry. Evidence: `audits/everyday-20261024-native-substituted-fragment.json` and `audits/everyday-20261024-substituted-fragment.log`. Other simulators were not touched; the continuous goal remains active.


### 2026-10-24 — Revised intent after completed messages

Expanded completed-word replacement from 32 to 36 contexts with romantic, engineering, dialect and formal revisions: `seni bekleyemiyorum` → `seni bekliyorum`, `güncelleştirmeyi yükleyemedi` → `güncelleştirmeyi yükledi`, `bugün gelemiyom` → `yarın geliyom`, and `talebimi iptal ediyorum` → `talebimin incelenmesini istiyorum`. All 432 runs (three offsets; clean typing, tap deletion, repeat deletion, word deletion) match final text, personal entries and persisted token/pair history. Focused release test passed in 26.115 seconds with zero failures.

Native keyboard revisions: `canım seni bekleyemiyorum` → `canım seni bekliyorum` and `sunucu kapalı` → `sunucu açık`, each after space/newline and backspacing the replaced portion. Discarded words stayed absent and retained words gained one history count, including the retyped `seni`. All inspected personal entries remained absent. Evidence: `audits/everyday-20261024-native-revised-intent.json` and `audits/everyday-20261024-revised-intent.log`. No runtime change was needed. Continuous goal remains active.


### 2026-10-24 — New romantic, technical and formal duplicate corpus

Audited every duplicate-key position at three touch offsets for `sevgilime`, `gülüşünü`, `özleyeceğim`, `konuşuruz`, `önbelleğini`, `doğrulamasını`, `senkronizasyon`, `bağımlılıkları`, `başvurularınız`, `değerlendirmeye`, `iletilmesini`, `beklemekteyim`. All 429 duplicate inputs offer their target; 248 automatically produce it and the rest preserve the literal. No unrelated automatic substitutions. All 858 direct/boundary undo variants and 24 intentional-repeat controls are exact (1311 rows total). Export completed successfully in 29.958 seconds.

Native `gülüşşünü` offered `gülüşünü`; after space/newline and two backspaces, selecting it yielded `gülüşünü `. Wrong history count remained zero, correct count became one, and both personal entries stayed absent. Evidence: `audits/everyday-20261024-third-words.json`, matching log and `audits/everyday-20261024-native-third-words.json`. No runtime changes were needed; continuous goal remains active.


### 2026-10-24 — Missing spaces in new conversational pairs

Added a production regression for six pairs (`seni özledim`, `yarın görüşürüz`, `sunucu hazır`, `erişim reddedildi`, `bilgi bekliyorum`, `gardaş geliyom`) at three touch offsets. Each joined input must offer its split, retain it after space/newline and two backspaces, produce exact split text when selected, and remove the discarded joined personal entry. All 18 cases pass; focused test took 0.585 seconds.

Native `erişimreddedildi` offered `erişim reddedildi`; the same reopen/select sequence produced the correct text. Joined history count remained zero, each split word became one, and all inspected personal entries stayed absent. Evidence: `audits/everyday-20261024-new-missing-space.log` and `audits/everyday-20261024-native-new-missing-space.json`. No runtime changes were needed; continuous goal remains active.


### 2026-10-24 — Extra key at an omitted word boundary

Extended the six-pair missing-space regression to include `b` replacing the intended space. All 36 cases (two boundary variants, three offsets) pass, including initial offers, reopening after space/newline, exact selection result, and removal of the discarded joined personal entry. Focused release test passed in 1.088 seconds; no runtime change was needed.

Native `gardaşbgeliyom` offered `gardaş geliyom`. After space/newline, two backspaces and explicit selection, text was correct; joined history stayed zero, each retained word gained one occurrence, and personal entries remained absent. Evidence: `audits/everyday-20261024-boundary-extra-letter.log` and `audits/everyday-20261024-native-boundary-extra-letter.json`. Other simulators untouched; continuous goal remains active.


### 2026-10-24 — Suppress weaker generated deletion alternatives to exact splits

Native missing-space testing exposed `erişi reddedildi` beside the correct `erişim reddedildi` for `erişimreddedildi`. The former unnecessarily removes `m` and relies on a generated unlisted form, while both exact-split words are listed. Boundary-repair candidates now retain their edit type and listed-word support. A deletion candidate is omitted only when it lacks full listed support, is not personal, and a better-ranked exact split consists of two listed words. This is an explicit-offer filter; automatic correction is unchanged. Listed deletion alternatives, stronger deletion repairs, personal words and genuine mistaps without the stronger exact explanation remain available.

The regression failed once before the change and passes afterward, together with the short-split suite and 36 new missing-space/mistap cases. It checks the rejected alternative, retained `senibseviyorum` repair, and personal-word override. Native after-change suggestions contain only the literal and correct split. Reopening after space/newline and selecting the split remains correct; joined history stays zero, each correct token gains one count and personal entries remain absent. Evidence: `audits/everyday-20261024-native-split-deletion.json` and focused before/after logs.

Full validation completed: 755 XCTest tests (95 opt-in skips), zero failures; 406 Swift Testing tests across 54 suites pass. The new suggestion-quality fix is verified; continuous goal remains active.


### 2026-10-24 — Turkish casing in boundary repairs

Expanded the six-pair missing-space/mistap regression to lowercase, title case and Turkish uppercase. Real uppercase insertion APIs are used, and personal-entry checks normalize with the Turkish locale. All 108 cases pass (72 added): three touch offsets, empty boundary or wrong `b`, initial and reopened repair offers, exact selected text, no discarded joined personal entry. Focused release test passed in 3.073 seconds.

Native Shift-plus-letter typing produced `BİLGİBBEKLİYORUM`; space/newline, two backspaces and selecting the repair yielded `BİLGİ BEKLİYORUM `. Turkish dotted İ and uppercase were preserved. Joined history remained zero, correct tokens gained one occurrence, and all inspected personal entries stayed absent. Evidence: `audits/everyday-20261024-cased-boundary.log` and `audits/everyday-20261024-native-cased-boundary.json`. No runtime changes; continuous goal remains active.


### 2026-10-24 — Fourth conversational duplicate corpus

Audited 15 valid word targets across romantic, household, technical and formal use: kalbimdesin, yanındayım, kavuşacağız, özlemişim, mutfaktayım, bulaşıkları, kargomuz, teslimatını, bağlanamıyorum, yapılandırmasını, sertifikasını, başlatılmasını, muvafakatname, gereğinin, bilgilerinize. All 522 duplicate variants offer the intended word; 283 automatically produce it, with no unrelated automatic outputs. All 1044 undo variants and 24 intentional-repeat controls remain exact (1590 valid rows). The raw 1671-row export also includes 81 rows with an incorrectly authored joined target `arzederim`; those are excluded from word-target metrics because the intended phrase is `arz ederim`. Missing the joined target is not classified as a product defect. Raw evidence remains available for inspection.

Native `kalbbimdesin` offered `kalbimdesin`; after space/newline/two backspaces, selecting the correction produced `kalbimdesin `. Discarded history stayed zero, correct history increased from zero to one, and both personal entries stayed absent. Evidence: `audits/everyday-20261024-fourth-words.json`, matching log and `audits/everyday-20261024-native-fourth-words.json`. No runtime change was needed. Other simulator untouched; continuous goal remains active.


### 2026-10-24 — Formal phrase boundaries

Expanded the missing-space regression from six to ten phrases with `arz ederim`, `rica ederim`, `talep ediyorum`, `teşekkür ederim`. All 180 cases pass (72 added): lowercase/titlecase/Turkish uppercase, omitted space or substituted b, three touch offsets, initial/reopened offer and exact selection without discarded personal entry. Focused release run passed in 5.014 seconds.

Native `arzederim` offered `ar ederim` before `arz ederim`; after space/newline/two backspaces, choosing the third slot produced `arz ederim `. Discarded history remained zero, correct tokens each gained one count, personal entries stayed absent. The target and learning checks pass, but the inferior phrase ranking is recorded as an open finding. Current boundary ranking uses summed unigram costs plus a one-point mistap penalty; no ranking change is claimed yet. Evidence: `audits/everyday-20261024-formal-boundaries.log` and `audits/everyday-20261024-native-formal-boundaries.json`. Continuous goal remains active.


### 2026-10-24 — Prefer exact listed splits to unnecessary deletions

Fixed the native `arzederim` ranking finding. After existing credibility filters, if the leading repair deletes a boundary letter and is not personal, the strongest surviving exact split with two listed words moves ahead of it. This avoids unigram frequency favoring `ar ederim` over `arz ederim`. Alternatives remain available; actual mistaps without a credible exact split and a leading personal alternative retain their preference. Automatic correction scoring is unchanged.

The new regression failed on `arzederim` before the change and passed after. Seven focused tests pass, including the 180-case boundary regression and short-phrase controls (`subiç` → `su iç`, `senibseviyorum` → `seni seviyorum`). Native offers now read `arzederim / arz ederim / ar ederim`. Space/newline/two backspaces and selecting the middle proposal yield `arz ederim `. Wrong history stays zero; correct tokens each gain one count; personal entries stay absent. Evidence: `audits/everyday-20261024-exact-rank-before.log`, matching after/build logs and `audits/everyday-20261024-native-exact-rank.json`.

The first full run exposed a regression: promotion displaced the `o zaman` repair for `ozzaman` in three casing styles (six assertions). Refined the rule to preserve a deletion winner when the removed boundary letter repeats its immediate neighbor, a direct double-press signal. All eight focused tests now pass, including the existing shifted-space regression. Latest native `ozzaman` offers `o zaman`; reopening and selecting it leaves wrong history zero and increments each correct token once. See `audits/everyday-20261024-native-exact-rank-duplicate.json`.

Final full validation passes: 756 XCTest tests (95 opt-in skips), zero failures, plus 406 Swift Testing tests across 54 suites. The ranking finding is closed with the repeated-boundary protection in place. Continuous goal remains active.


### 2026-10-24 — Overlapping words in revised messages

Expanded completed-message replacement from 36 to 40 contexts: `yarın arayacağım` → `bugün arayacağım`, `yeniden başlatıldı` → `yeniden başlatılmadı`, `bugün buluşak` → `yarın buluşak`, and `arz ederim` → `rica ederim`. These exercise shared words in discarded and replacement phrases. All 480 runs (three touch offsets, clean/tap/repeat/word deletion) match clean final text, personal learning, persisted token history and pair history. Focused release regression passed in 28.796 seconds; no runtime change needed.

Native `bilgilerinize arz ederim ` plus newline, eleven backspaces to the prefix, then `rica ederim ` yielded the intended revised message. Removed `arz` history remained at its previous count of two; retained tokens each gained one occurrence. In particular, twice-typed `ederim` gained only one count. Personal entries stayed absent. Evidence: `audits/everyday-20261024-overlapping-replacement.log` and `audits/everyday-20261024-native-overlapping-replacement.json`. Other simulator untouched; continuous goal remains active.


### 2026-10-24 — Fifth conversational duplicate corpus

Audited every duplicate position at three offsets for kahvaltıdayım, hazırlanıyorum, anahtarlarımı, bırakmışım, gülümsemeni, unutamıyorum, yönlendiriciyi, yenileyebiliriz, bağlantılarımızı, inceleyebilir, başvurduğumuz, onaylamanızı. All 468 duplicate targets are offered, with 311 exact automatic outputs and zero unrelated automatic substitutions. All 936 undo variants and 24 intentional-repeat controls remain exact (1428 rows total).

Native `hazırlannıyorum` offered `hazırlanıyorum`; space/newline/two backspaces and selection yielded the intended word. Discarded history stayed zero, correct history became one, and both personal entries stayed absent. Evidence: `audits/everyday-20261024-fifth-words.json`, matching log and `audits/everyday-20261024-native-fifth-words.json`. No runtime changes; continuous goal remains active.


### 2026-10-24 — Correct-letter deletion before accidental boundaries

Added a distinct cancelled-fragment mode: delete the correct midpoint letter before accidentally committing the shortened prefix with space/newline, undo both boundaries, restore the letter and continue. The existing extra-delete mode removes the letter after undoing boundaries; this new order exercises a different committed fragment. All 600 runs (25 messages, three offsets, eight modes; 75 added) match clean text, personal entries, persisted token counts and pair counts. Focused release test passed in 71.224 seconds.

Native `sunu`, backspace, space/newline, two backspaces and `ucu ` produced `sunucu `. Cancelled `sun` history stayed zero; `sunucu` rose from four to five; both personal entries remained absent. Evidence: `audits/everyday-20261024-delete-before-boundary.log` and `audits/everyday-20261024-native-delete-before-boundary.json`. No runtime change needed; continuous goal remains active.


### 2026-10-24 — Missing dryer noun and systematic root coverage request

The sixth 12-word duplicate corpus (1293 rows) exposed 33 missing `kurutucudan` targets and ten unrelated automatic outputs, including `kurutuşçudan` and `kuruttuğuysan`. Native `kuurutucudan` likewise lacked the correct proposal. The lexical noun `kurutucu` was absent. Added it with weight 11000 calibrated to existing `kurutma` (not an observed frequency), using existing noun inflections. Rebuilt only `tr-TR.bkr`; round-trip passed, SHA-256 `fa313ed02636a949b98ad7c99a5a6c87364e3c68ddf7ca30b9e944c782d03240`. Six noun forms and two duplicate variants at three offsets failed 16 assertions before and pass afterward.

Native after-change offers `kuurutucudan / kurutucudan`; space produces `kurutucudan `. Wrong and unrelated history stay zero, correct history becomes one, personal entries remain absent. Full validation: 757 XCTest, 94 opt-in skips, zero failures; 406 Swift Testing tests across 54 suites pass. All 423 duplicate targets in the sixth corpus are now offered, 259 exact automatic outputs, zero unrelated automatic outputs; all 846 undo and 24 intentional-repeat controls remain exact. Evidence: dryer before/after/pack/build/full logs, sixth-words before/after JSON and native-dryer JSON in `audits/everyday-20261024-*`.

The user additionally requested comprehensive Turkish root coverage. Retrieved the three original Zemberek dictionary sources at the repository's recorded pinned revision into `Data/raw/root-coverage-20261024`, with URL/hash manifest. Initial lemma/POS inventory is in `audits/turkish-root-source-coverage-20261024.json`. POS-only differences must not be called missing words: 2385 of 2387 supported-POS missing rows already have a root surface under another POS. Compound and unsupported-POS rows need runtime recognition and attribute review; 827 compound rows lack a matching full root surface, but some can be generated from existing stems. Added an opt-in production literal-channel coverage exporter to measure actual recognition before any mass import. This source scope is not a claim of all Turkish roots. Continuous testing and root expansion remain active.

The runtime exporter tested 31,511 unique single-word source lemmas and found 2,007 unrecognized surfaces. Raw results are in `audits/turkish-root-runtime-coverage-20261024.json`; exporter passed in 1.387 seconds. Missing entries include circumflex-preserving spellings whose folded roots exist, compounds requiring lexical features, and excluded word classes. This is a real recognition-gap inventory, not 2,007 proven independent missing roots. Next work is reviewed import/attribute mapping plus coverage tests, and additional sources for lexical derivatives absent from the initial dictionary. Comprehensive coverage is not yet complete.


### 2026-10-24 — Canonical source spellings and ordinary unaccented use

Added 895 missing canonical circumflex root aliases, matched to a unique existing folded root/POS and unique pinned source entry. Existing unaccented roots remain present. Explicit source mappings, ambiguous rows and unsupported ImplicitPlural/NoQuote attributes are deferred. Weights are copied calibration values, not fresh corpus measurements. Restored 23 explicit InverseHarmony and two NoVoicing attributes on the new canonical rows. Plan and exclusions: `audits/turkish-circumflex-root-plan-20261024.json`. Pack has 51,119 roots and passes binary round-trip. Full suite and post-import runtime inventory are in progress.

The user's explicit preference is to preserve everyday unaccented spelling. Six root words at three offsets remain literal after space; `fedakkar` offers unaccented `fedakar`. Native space/newline/reopen/selection yields `fedakar `; discarded `fedakkar` and accented `fedakâr` history stay zero, chosen `fedakar` becomes one, and all personal entries remain absent. Evidence: unaccented-initial log and native-unaccented JSON. The isolated canonical `helâl` rejects `helâlın`; a global rejection would be invalid because independent `helâ` derivations can overlap.

Follow-up native `ihtilallin` lacks the desired `ihtilalin` and proposes `ihtilal lin` instead. Original folded roots also lost source attributes. Added regression coverage for six folded inflections and prepared 25 exact source-backed attribute restorations in `audits/turkish-unaccented-attributes-plan-20261024.json`. This finding remains open until pack, regression and native verification complete.

Canonical alias validation completed: 760 XCTest with 95 opt-in skips and zero failures, plus 406 Swift Testing tests in 54 suites. Source inventory now recognizes 30,401 of 31,511 unique surfaces; missing decreased from 2,007 to 1,110 (897 gained, none regressed). All 895 imported source lemmas are recognized. Remaining gaps and folded-attribute repair are still active.

Folded attribute restoration completed for 25 source-matched roots (23 inverse harmony, two no-voicing). Before-change regressions failed 21 assertions: six missing forms, six invalid generated counterparts and three `mahkuku` → `mahkumu` replacements. All 14 focused tests pass afterward. Full pack validation: 761 XCTest, 94 opt-in skips, zero failures; 406 Swift Testing tests pass. The 744-row unaccented corpus offers all 240 intended duplicate corrections, makes 89 exact automatic corrections and zero unrelated ones; 480 undo and 24 intentional-repeat cases remain exact. Native corrected selection leaves discarded history zero and correct `ihtilalin` history one, with no personal entry.

Native rendering exposed a remaining presentation issue: the competing form is `ihtilâllin` (retaining the doubled l), not just `ihtilâlin`. Exact duplicate repair should precede merely adding a circumflex to a generated literal. Presentation refinement preserves the literal and automatic scoring; it also prefers an existing unaccented spelling over its accented alias when the input is unaccented. Regression and native checks are in progress.

Native refined presentation is verified: `ihtilallin / ihtilalin / ihtilâllin`; space preserves the literal, newline/two backspaces/middle selection yields `ihtilalin `. Incorrect history remains zero, correct history rises from one to two, personal entries remain absent. The refined build passes; 15 focused tests pass. Evidence: `audits/everyday-20261025-native-unaccented-ranking.json` and unaccented-ranking focused/refined-build logs. Full regression is still running.

Read-only next-work compound classification is in `audits/turkish-root-compound-review-20261025.json`: 855 source compound rows, including 102 vowel-base buffer-s forms, 498 simple terminal-vowel forms, 201 possible softened stems and 54 requiring specific mapping. Of these source rows, 765 are currently unrecognized. No compound import was made in this batch. Current single-vowel compound stem stripping cannot simply be applied to all buffer-s and irregular compounds; plural and possession paths need distinct validation.

Final unaccented presentation validation completed: 764 XCTest, 95 opt-in skips, zero failures; 406 Swift Testing tests in 54 suites pass. All 240 duplicate targets remain offered; zero unrelated automatic outputs; all 480 undo and 24 intentional-repeat controls exact (744 total rows). Uppercase unaccented aliases, explicit circumflex input, absent aliases and unrelated candidates are covered. Final evidence: `audits/everyday-20261025-unaccented-ranking-full.log`, matching duplicate JSON, and native-unaccented-ranking JSON. `tr-TR.bkr` SHA-256: `cc46374ce70f258b94bd166a836bca7112d270365dbca337e4c27c6e5d05dd71`. This batch is complete; comprehensive root coverage (1,110 remaining source surfaces) and the continuous scenario goal remain active.


### 2026-10-25 — Explicit compound stems and source expansion

The 12-word daily compound corpus exposed 63 missing duplicate targets: 36 variants of `anaokulundan`, 27 of `ayakucuna`. Native `aanaokulundan` offered `analıklından` / `analıklımdan` instead. Existing compound morphology only stripped one final vowel for possession and had no compound plural route.

Added explicit `Root.compoundStem`, separate from pronunciation and consonant alternation. Root pack v3 appends a bounded CSR string section; the reader still accepts v2 with absent metadata. Explicit stems distinguish `acemborusu → acemborum` from consonantal `kuşsesi → kuşsesim`, and support softening/vowel-loss pairs such as `buzdolabı / buzdolapları` and `deveboynu / deveboyunları`. Two non-accepting continuation states require possession after a compound plural, preventing unfinished `anaokullar` and malformed `buzdolabları`. Existing legacy compound behavior remains for records without explicit stems.

Added reproducible `Tools/import_compound_roots.py`. It reviews every source CompoundP3sg entry (935 source rows, not just the earlier 855 missing-POS subset), checks exact stem-to-lemma mappings and vowel harmony, preserves exact POS identity and existing metadata/weights, and includes both canonical and unaccented forms. Applied 902 record changes: 825 additions and 77 updates. New weights come from the existing wordlist when available, otherwise explicitly use the calibration floor 10. 37 review items remain deferred, including source inconsistencies and proper-name handling. The plan is `audits/turkish-compound-root-plan-20261025.json`; a second dry run proposes zero changes.

Initial isolated morphology check failed 12 assertions before and passes afterward. Expanded focused validation passes 15 XCTest, including production source coverage, v2 compatibility, v3 corruption rejection and the 1,149-row daily corpus. All 375 duplicate targets are offered (227 exact automatic outputs, zero unrelated automatic substitutions); all 750 undo and 24 intentional-repeat rows remain exact. Source recognition rises by 730 unique lemmas, with no regressions: 31,131 of 31,511 recognized, 380 remain missing. Native `aanaokulundan` now auto-corrects to `anaokulundan `; newline/two backspaces/recommit leaves wrong history zero and correct history one, with no personal entry. Full regression is running.

Compound validation completed: 768 XCTest, 96 opt-in skips, zero failures; 406 Swift Testing tests in 54 suites pass. Native plural `anaokullarımmızdan` offers and automatically corrects to `anaokullarımızdan `; Enter/two backspaces/recommit leaves wrong history zero, correct history one and both personal entries absent. Evidence: `audits/everyday-20261025-compound-full.log` and `audits/everyday-20261025-native-compound-plural.json`. Remaining-source review is `audits/turkish-root-remaining-review-20261025.json` (380 unique surfaces, 395 source rows). This compound batch is verified; comprehensive root coverage and continuous testing remain active.

### 2026-10-25 — Remaining legacy compound plural

The expanded plural corpus found 39 missing duplicate targets for `yeryüzlerinde`, including five unrelated automatic substitutions. Native `yeryüüzlerinde` also omitted the intended target. Added explicit `yeryüz` stem to the existing `yeryüzü` root without changing its weight; all production records marked possessiveCompound now have explicit stems. Added production inflection and duplicate regression assertions.

The exploratory corpus also included `kuşsesim`, a synthetic morphology fixture incorrectly treated as a standard joined lexical target. Its failures are retained in the before artifact and excluded from lexical conclusions; after validation replaces it with source-backed `acemborum`. No synthetic root was imported to make that probe pass.

Eight focused tests pass, including 1,545 corpus rows: all 507 duplicate targets offered, 330 exact automatic corrections, zero unrelated corrections, 1,014 exact undo cases and 24 exact intentional-repeat controls. Native space correction, Enter/two backspaces/recommit yields `yeryüzlerinde `, wrong history zero and correct history one, no personal entry. Build succeeds. Previous full suite passed before this one-record metadata change; this batch uses focused and native verification.

Environment event: Xcode initially could not connect to CoreSimulator because framework 1174.9.2 and service 1171.7 differed. A read-only simctl inventory automatically installed the component and refreshed the service, leaving both known devices shutdown. Only the audit simulator was booted; build/install/native verification then succeeded. Evidence is in the yeryuzu and compound-plurals audit artifacts. Comprehensive root coverage and the continuous goal remain active.

### 2026-10-25 — Standalone interjections and conjunctions

The 879-row conversation-particle corpus exposed 261 missing duplicate targets and 38 unrelated automatic substitutions, including `hamdolsunn` and `mademkii`. Native `hamdolsunn` offered `bandıksın` / `hadmışsın`.

Added a final, non-inflecting `Root.POS.fixed` value, preserving prior POS raw values. Fixed roots enter the accepting terminal continuation and do not generate nominal or verbal suffixes. The pack builder rejects inflection metadata on fixed records. Binary round-trip and isolated negative morphology checks cover `ayollar`, `mademkiler`, and similar unwanted generated forms.

`Tools/import_fixed_roots.py` imports absent Interj/Conj forms from the pinned source inventory, skips already recognized surfaces and existing roots, preserves canonical and unaccented spellings, and uses existing wordlist counts or explicit calibration floor 10. Applied 66 new records; a second dry run produces zero changes. Proper-source entries and suspicious `afedersinin` are deferred; reduplication fragments and other lexical classes remain separately reviewable. Root count is 52,010.

Seven focused tests pass. All 285 duplicate targets are offered, with 126 exact automatic corrections and zero unrelated automatic outputs; all 570 undo cases and 24 intentional-repeat controls remain exact. Source gaps fall from 380 to 319 (61 gained, zero regressions). Native `hamdolsunn` now corrects to `hamdolsun `; Enter/two backspaces/recommit records the correct word once and the wrong word zero times, with neither in personal vocabulary. Build passes. Full regression is running.

Full fixed-root validation passes: 770 XCTest with 96 opt-in skips and zero failures, plus 406 Swift Testing tests across 54 suites. Native `aleykümselamm` offers the unaccented correction ahead of its accented alias; space preserves the literal, and Enter/two backspaces/middle selection produces `aleykümselam ` with wrong history zero and correct history one. Fixed-record builder validation accepts the valid fixture and rejects compound, softening and vowel-drop metadata without writing output packs. Evidence: `audits/everyday-20261025-fixed-full.log`, `audits/everyday-20261025-native-fixed-unaccented.json`, and `audits/everyday-20261025-fixed-builder-validation.json`. Remaining 319 source gaps and the continuous goal stay active.

### 2026-10-25 — Formal postpositions

A 1,005-row formal corpus exposed 147 missing duplicate targets across binaen, mahsuben, müteakiben, iştiraken, izafeten and hürmeten, with 32 unrelated automatic changes. Native `başvurunuza biinaen` offered birinsen/birinsem and omitted binaen.

Extended the reproducible fixed-root importer with explicit reviewed class selection (`--classes Postp`, including case-qualified source POS values); defaults remain Interj/Conj. Added nine absent forms: binaen, hürmeten, ilâveten, ilaveten, iştiraken, izafeten, mahsuben, müteakiben, üzre. Existing recognized roots are preserved; a second import proposes zero changes. No runtime changes in this batch.

Seven focused tests pass: all 327 duplicate targets offered, 127 exact automatic corrections, zero unrelated outputs; 654 undo and 24 intentional-repeat controls exact. Source recognition improves by eight unique lemmas to 31,200/31,511, with no losses (311 missing). Build passes. Native space preserves uncertain `biinaen`; Enter/two backspaces/select binaen and completion of `başvurunuza binaen yanıt veriyorum ` leaves wrong word/pair counts zero and correct word/pair counts one, with no personal entry. Evidence is in the postposition audit artifacts. This lexical-only change uses focused and native verification; the previous full runtime suite remains the last full run. Comprehensive coverage and continuous typing remain active.

### 2026-10-25 — New lexical classes in missing-space phrases

Extended ShiftedSpaceRepairAuditTests with optional `KB_SHIFTED_SPACE_PAIRS` input while preserving its default regression corpus. Tested 12 new/formerly repaired phrase pairs spanning formal, affectionate, colloquial and everyday language, including başvurunuza:binaen, hamdolsun:iyiyim, gardaşım:nasılsın and anaokulundan:geldik. All 360 observations pass across three casing modes and ten boundary modes (omitted space or each bottom-row extra letter). Every expected split is offered and selection inserts the exact phrase; literal input remains first. No runtime change was needed.

Native deletion test writes `başvurunuza `, deletes the space and appends `binaen`. Selecting the middle split offer produces `başvurunuza binaen ` exactly. Enter/two backspaces/recommit retains that text. Joined wrong history/personal entries remain zero, while each correct word increases from one to two only once. Evidence: `audits/everyday-20261025-new-phrase-boundaries.json` and `audits/everyday-20261025-native-deleted-space-postposition.json`. The continuous goal and remaining source coverage work stay active.

### 2026-10-25 — Long technical inflections

A 1,491-row corpus exposed 333 missing duplicate targets and 85 unrelated automatic substitutions. Added eight source-attested roots (basınçlandır, ölçeklendir, sürümle, kimliklendir, derleyici, bağdaştırıcı, çözümleyici, doğrulayıcı), with source and weight provenance in `audits/turkish-engineering-root-plan-20261025.json`. No runtime changes. The 15 focused tests pass, including 16 ordinary inflected forms; all 489 duplicate targets are now offered, 298 correct automatically, and zero change to unrelated words. All 978 undo cases and 24 intentional-repeat controls remain exact. Build passes.

Native `ssürümlemeyi` previously omitted the correct target and offered sürüklemeyi. It now offers sürümlemeyi in the middle; space preserves the uncertain literal. Enter/two backspaces/middle selection yields `sürümlemeyi `, with wrong history zero, correct history one and both personal entries zero. Evidence: engineering-long audit artifacts and `audits/everyday-20261025-native-engineering-long.json`. The last full runtime suite remains the previous fixed-root run; this lexical-only batch uses focused/native verification. The general source inventory still has 311 reviewed gaps at its last export, and comprehensive coverage remains active.

### 2026-10-25 — Everyday long words and cold-verb causative

The 1,464-row daily/affectionate corpus exposed 33 missing targets and 27 unrelated automatic substitutions, all for üşütmeyesin. Existing üşü root lacked aorist and causative metadata. Set -Ir and -t without changing its count; the same corpus then offers all 480 targets, makes 330 exact automatic repairs, and produces zero unrelated outputs. All 960 undo and 24 expressive controls remain exact. Native üşütmeyeesin now offers üşütmeyesin; space preserves the literal, Enter/two backspaces/selecting the correction produces the correct word, with wrong history zero, correct history one and no personal entries. Evidence: everyday-long-metadata-after and native-cold artifacts.

The added production regression exposed a separate issue: bare üşüt was rejected because afterCausative was nonaccepting. Completed causative stems are now accepting second-person imperatives, while class restrictions and bounded derivation remain intact. Positive inflections and malformed harmony/repeated-causative negatives are tested. Full suite and rebuild are running; this runtime extension is not yet claimed validated.

Native follow-up on the runtime build verifies `üşütt` → explicit `üşüt` after space/Enter/two backspaces, with wrong history zero and correct history one. A contextual `sunucuyu başlatt` → `sunucuyu başlat ` repair retains sunucuyu once and increments the existing başlat count from one to two; wrong word/pair remain zero and the correct pair is one. Both personal entries remain zero. The new morphology regression passes within the ongoing full suite. Evidence: `everyday-20261025-native-causative-imperative.json` and `everyday-20261025-native-causative-command.json`. A 12-verb duplicate-position corpus is queued behind the full run.

Full causative validation passes: 772 XCTest, 95 opt-in skips and zero failures; 406 Swift Testing tests across 54 suites also pass. The final 1,464-row corpus still offers all 480 duplicate targets, has zero unrelated automatic corrections, and keeps all 960 undo and 24 intentional-repeat controls exact. Build and both native causative checks pass. Evidence: `audits/everyday-20261025-causative-full.log` and `audits/everyday-20261025-everyday-long-final.json`.

The follow-up corpus (üşüt, anlat, çalıştır, temizlet, başlat, beklet, oturt, güldür, yazdır, okut, uyut, yürüt) passes all 627 observations: 201 duplicate targets offered, 36 exact automatic repairs, zero unrelated automatic outputs, 402 undo cases and 24 intentional repeats exact. This confirms the imperative change beyond the original word. Evidence: `audits/everyday-20261025-causative-imperatives.json`. Comprehensive root review and continuous real-world typing remain active.

### 2026-10-25 — Reviewed reduplication components

A 360-case boundary corpus found 300 missing repairs for ten unrecognized components: şırıl, gümbür, fokur, kıkır, horul, mırıl, şakır, çatır, şapır, gürül. Imported these pinned-source Dup entries as fixed roots with no nominal or verbal inflections. The importer now supports Dup only with an explicit reviewed surface list; an unqualified import is rejected, and repeating the reviewed import adds zero records. No runtime change.

All 360 boundary repairs now pass across three casing modes and ten separator modes. All 573 duplicate/control observations pass target availability and unrelated-output checks. Synthetic fixed-root tests reject şırıllar/şırıldan/gümbürüm/gümbürde. Native şırılşırıl → şırıl şırıl selection followed by Enter/two backspaces/recommit preserves two word occurrences and one self-pair; wrong joined history and personal entries remain zero. Build passes; host and extension pack hashes match source. Source recognition gains ten lemmas with no losses, leaving 301 unrecognized source lemmas. Evidence: redup audit artifacts and `audits/turkish-root-runtime-redup-after-20261025.json`. The previous causative full suite remains the latest full runtime validation; this lexical-only batch uses focused and native verification.

### 2026-10-25 — Mixed reduplications

A 12-phrase corpus (eski püskü, yarım yamalak, çoluk çocuk, eğri büğrü, ufak tefek, ıvır zıvır, abuk subuk, paldır küldür, eciş bücüş, süklüm püklüm, pılı pırtı, allak bullak) exposed 90 missing boundary repairs, confined to three absent source components. Imported eciş, süklüm and pılı as fixed roots through the reviewed allowlist; repeated import adds zero. All 360 boundary cases now pass. A 294-row duplicate corpus offers all 90 targets, automatically repairs seven, produces zero unrelated outputs and retains all 180 undo/24 expressive controls. No runtime changes. Build and focused tests pass.

Native ecişbücüş → eciş bücüş selection, Enter/two backspaces/recommit leaves wrong joined history zero, each correct word one and the correct pair one; all personal entries stay zero. Source recognition gains three with no losses, leaving 298 unrecognized lemmas. Evidence: mixed-redup audit files, native-mixed-reduplication and turkish-root-runtime-mixed-redup-after-20261025. Last full runtime suite is the passing causative run. Continuous testing and comprehensive source review remain active.

### 2026-10-25 — Retraction after new lexical coverage

Expanded completed-message replacement regression with six contexts covering üşütme/dinlen, doğrulayıcı/derleyici, binaen, colloquial repeated forms, eciş bücüş and şırıl şırıl. All 46 contexts × three touch offsets × four modes (552 runs) pass: edited text, personal points and persisted history token/pair counts equal clean typing after tap, repeat or whole-word deletion. No runtime change.

Native canım üşütme + space/Enter, eight backspaces and dinlen yields canım dinlen. Earlier canım count 12 becomes 13 only once; removed üşütme and its pair stay zero, dinlen and its pair become one, with no personal entries. Evidence: new-roots-replacement log and native-cold-message-replacement JSON. Remaining-source triage splits the last 298 missing surfaces into 138 accented aliases with an existing unaccented root, 119 reduplication components needing review and 41 other cases. Alias presence is lexical evidence only and does not prove all inflections. Full source coverage and continuous typing stay active.

### 2026-10-25 — Separate phrases in source-gap review

Twelve phrase families (boru hattı, maden suyu, içme suyu, cam suyu, hava üssü, söz varlığı, her biri, orta parmak, göz yummak, düş kırıklığı, güven oylaması, yanı başı) pass 360 omitted/mistapped boundary observations. Joined forms are not recognized words and the intended split is offered/inserted exactly. Added a permanent regression asserting separate-word recognition and rejection of their joined forms, preventing future source imports from suppressing these repairs. Both focused tests pass; no runtime or lexical change.

Native madensuyu → maden suyu selection and Enter/two backspaces/recommit records each correct word and pair once; the joined form has zero history/personal entries. Evidence: source-separated audit artifacts and native-separated-source JSON. The source-missing count remains 298 intentionally: source artifacts must not be imported merely to lower a coverage count.

### 2026-10-25 — Unaccented inflection follow-up

Tested sükunetini, tahminimizi, şahsiyetini, mahkumların, meskunların, mefkuremiz, samimiyetini, suniliğini, ilahilerin, topyekun, kanunen and mezkurdur across all duplicate positions and three touch offsets. All 360 duplicate targets are offered; 172 repair automatically and none become unrelated words. All 720 undo and 24 expressive controls remain exact (1,104 total observations). No runtime or lexical change needed.

Native sükunnetini offers unaccented sükunetini. Space preserves the uncertain literal; Enter/two backspaces/explicit selection yields sükunetini with wrong history zero, correct history one and no personal entries. Evidence: unaccented-followup audit and native JSON. This verifies the requested ordinary unaccented spelling on additional inflections, without claiming every Turkish root is covered.

### 2026-10-25 — Long negative verbs

A 1,509-row corpus covering gelemeyeceğim, yetişemeyeceğiz, anlayamamışım, uyuyamıyorum, göremeyeceksiniz, bulamayınca, unutmayacağım, bekletmeyelim, üzülmeyesin, kaçırmayalım, konuşamayacakmışız and başaramadığımızdan offers all 495 duplicate targets. It automatically repairs 333 and produces zero unrelated automatic outputs; all 990 undo and 24 expressive controls stay exact. Native gelemeyeceğimm preserves the literal on space and selects gelemeyeceğim after Enter/two backspaces, with wrong history zero and correct history one.

Open follow-up: the native third suggestion is gelemeyeceğimim. This appears unnatural despite the correct middle offer and clean learning. Investigate the generated possessive/copular path and candidate ranking; do not broadly prohibit legitimate nominal/copular forms without counterexamples. Evidence: negative-long audit files and native-negative-long JSON.

### Spare generated suggestions after repeat repair (2026-10-25)

Native `gelemeyeceğimm` previously offered `gelemeyeceğimim` in the third slot. A 27-case score probe reproduced the same pattern for `geleceğimm`, `yapacağımm`, `öğretmenimm`, and `üşütmeyeesin`. Generated nominal/copular paths can score close to the intended correction; removing those paths entirely would also remove valid inflections. The presentation layer now rejects *longer, unlisted* generated spare alternatives when a known exact repeated-key deletion already explains the input. Listed and personal alternatives remain eligible; recognition and automatic correction scores are unchanged. `başlattı` survives alongside `başlat`, and `annem mi` survives alongside `annemi`. This is a bounded offer-quality rule, not a grammatical invalidity claim.

Validation: 19 focused tests, 2 opt-in skips, zero failures; simulator app build succeeded. Native repeated-key entry, space/Enter/undo, suggestion selection and dismissal ended at `gelemeyeceğim `. History increased only for that corrected word (1→2); misspelling and rejected spare stayed at zero, as did personal admission. See `audits/everyday-20261025-spare-suggestions-{before,after}.json` and `audits/everyday-20261025-native-spare-suggestions.json`. The full suite was not rerun for this presentation-only change; the prior full run remains the causative validation.

Open follow-up: native and automated `kannı` still offers `kan nı`. This short-fragment boundary is independent of generated word growth and needs a separate evidence-based repair preserving ordinary short words and question particles. No claim of complete root coverage or complete suggestion cleanup.

### Detached suffix frequency entries (2026-10-25)

The native `kannı → kan nı` split came from the corpus surface entry `nı` (19159), not a root. Removed that listed entry and analogous `nın` (336802) / `nün` (11261), then regenerated the language packs, including the character model. No morphology roots or rules were removed. `nün` remains generated from the retained noun `nü`; the initial test incorrectly expected it to be entirely unknown, so that assertion was corrected to require removal of its listed frequency while preserving recognition. `nun`, `nü`, `kanını`, `senin`, `günün`, and `annemi` remain known.

Focused validation: 28 tests, 3 opt-in skips, zero failures. Native fresh typing offers `kannı / kanı / kanını`, and the third-slot selection produces `kanını `. No personal admission of `kannı` occurred. Artifacts: `audits/turkish-detached-suffix-removal-20261025.json`, `audits/everyday-20261025-detached-suffix-final.log`, and `audits/everyday-20261025-native-detached-suffix.json`.

New reproducible finding: direct `kannı + Enter + Backspace` leaves the text intact but clears all suggestions, reproduced twice. This differs from the already covered SPACE+ENTER undo case. The nonempty newline branch explicitly invalidates the session history; investigate retaining verified touch/ledger evidence while still forgetting language context. One cancelled probe was dismissed and externally reset before correction, leaving one history occurrence; do not claim that the complete newline replacement learning path passed. Full-suite validation is deferred to the upcoming runtime repair.

### Direct newline undo restores correction choices (2026-10-25)

A nonempty `newline` committed the token and immediately invalidated all session history, unlike SPACE+ENTER. Removed that invalidation and its now-unused helper parameter. Word context is still forgotten; the existing language prior is preserved. Reopening still requires matching token ID, ledger text, separator and live host context.

Added `testDirectNewlineUndoRestoresSuggestionsAndCleanLearning`: six typo/correction pairs, clean selection versus 1/2/3 direct newlines followed by matching backspaces (24 runs). It compares exact offers after reopening, final text, personal scores and persisted history token counts. The initial probe tried to pick `kanını`, which was present in the native bar but not the clean automated baseline; the final regression uses the shared `kanı` target. The initial probe is not claimed as a valid red regression. Native pre-fix reproduction is documented in the detached-suffix batch.

Focused tests passed: 13 XCTest cases plus 12 Swift Testing cases. Simulator build passed; native `kannı + ENTER + BS` restores `kannı / kanı / kanını`, and `gelemeyeceğimm + ENTER×3 + BS×3` restores the correct offer without the previously removed spare. Both selections succeeded. Correct history occurrences increased by one; wrong occurrences stayed at their respective baselines and personal admission stayed zero. Evidence: `audits/everyday-20261025-native-direct-newline.json`. Full release suite is running in `/tmp/bk-direct-newline-full.log`; do not treat it as passed until its terminal result is inspected.

Direct-newline full-suite result: 777 XCTest cases, 97 opt-in skips, zero failures (253.8 seconds); 406 Swift Testing cases across 54 suites passed. Archived log: `audits/everyday-20261025-direct-newline-full.log`. This also covers the preceding detached-suffix data and spare-suggestion changes.

### Everyday sound/reduplication roots (2026-10-25)

Added 12 source-attested fixed roots: fısıl, fıkır, pıtır, şıkır, tıpış, şıpır, patır, takır, püfür, zangır, cıyak, homur. Each uses the declared calibration floor 10, not an invented measured frequency. Existing roots/weights remain unchanged; rerunning the importer adds zero records. Production and host/extension root packs match.

All 360 missing/mistapped-boundary examples were missing before; all 360 now offer and select the intended repeated phrase across three casings and ten separators. Native `fısılbfısıl + Enter + Backspace` offers `fısıl fısıl`, which selects correctly; only two correct word observations and one self-pair were recorded, with no misspelling/personal admission. Source recognition improves from 298 to 286 missing surfaces, exactly 12 gains and no losses. Latest source report: `audits/turkish-root-runtime-sound-after-20261025.json`.

Nine focused tests passed, but the opt-in duplicate audit found an unresolved edge: 180/183 repeated-key targets offered, four exact automatic corrections, no unrelated automatic changes; 366/366 undo and 24/24 intentional-repeat controls exact. The three missing rows are all `pıttır → pıtır`, at each touch offset. Existing `pıt` noun morphology recognizes `pıttır`, and the generated-literal presentation branch only promotes listed duplicate repairs (or circumflex ambiguity); the direct fixed root `pıtır` is not listed. Preserve valid literal recognition while extending explicit alternative evidence to fixed lexical roots. Do not report the duplicate batch as fully passing until that case is repaired.

### Fixed lexical alternatives to generated duplicate literals (2026-10-25)

Resolved `pıttır → pıtır` without removing the recognized `pıt` noun/copula path. `LiteralChannel.hasFixedLexicalSurface` walks the exact root-trie path and accepts only a plain `.fixed` terminal; it does not scan the root array, treat inflections as direct roots, or alter `hasListedSurface` semantics. The generated-literal duplicate-offer branch now accepts this direct fixed-root evidence alongside listed forms. Literal remains first and automatic protection is unchanged.

Regression verifies direct fixed root versus generated/noun/unknown surfaces and all three touch offsets; space preserves `pıttır`, backspace restores it, explicit `pıtır` selection succeeds, and no personal admission occurs. Twenty-two focused tests passed with two opt-in skips. Repeated-key corpus: all 183 targets offered (previously 180), four exact automatic corrections, no unrelated automatic changes, all 366 undo controls and 24 intentional-repeat controls exact.

Native old/new comparison: `pıttır / pottur / putttur` becomes `pıttır / pıtır / pottur`. SPACE+ENTER undo and middle selection finish at `pıtır `; history wrong=0, correct=1, both personal=0. Evidence: `audits/everyday-20261025-native-fixed-root-alternative.json`, `audits/everyday-20261025-fixed-root-doubles.json`. App build passed. Full-suite repetition was unnecessary after focused presentation, lexicon, circumflex and duplicate checks; the latest completed broad run remains `everyday-20261025-direct-newline-full.log`.

### Mixed messages with direct newline interruptions (2026-10-25)

Expanded the existing cancelled-fragment equivalence test from 25 to 31 messages, adding everyday sound roots, romantic, engineering, dialect and formal contexts. Added three direct-Enter modes (plain prefix, doubled key, substituted adjacent key), each undone before continuing. Across 31 messages, three touch offsets and eleven modes including clean, all 1,023 runs preserve exact final text, personal scores, history token counts and history pair counts. One focused XCTest passed in 123.126 seconds with zero failures. No runtime changes were needed in this batch. Log: `audits/everyday-20261025-mixed-message-newline.log`.

Native fixture: typed `aşkım fısılbfısıl`, Enter then backspace, selected `fısıl fısıl`; typed `konnuş`, Enter then backspace, selected `konuş`. Final text: `aşkım fısıl fısıl konuş `. History gained aşkım once, fısıl twice and konuş once; all three intended pair counts gained exactly one. Both wrong forms remained zero and no personal admissions occurred. Evidence: `audits/everyday-20261025-native-mixed-message-newline.json`. Broader goal remains ongoing; latest source coverage still has 286 unmatched source surfaces requiring review, not necessarily 286 valid missing roots.

### Unaccented mahkumiyet inflections (2026-10-25)

The long unaccented duplicate corpus exposed 42/42 missing `mahkumiyetinin` repair targets. The existing unaccented noun had `tToD`, while canonical `mahkûmiyet` correctly had `none`. Pinned source master-dictionary.dict:15052 explicitly says NoVoicing, and non-tdk.dict:3336 references that canonical entry. Changed only the unaccented root feature to none, retaining frequency 545. Regenerated packs and extended suffix regressions to test isolated valid/invalid inflections, literal preservation and correction ordering.

Initial corpus also mistakenly used `sukunetimizi`; that is not merely a circumflex omission. Corrected the test input to `sükunetimizi` for the follow-up rather than adding a spurious root. The initial artifact is retained with this qualification. All 21 focused tests passed. Corrected 1,491-row corpus: 489/489 duplicate targets offered, 174 exact automatic corrections, zero unrelated automatic changes, 978/978 undo cases exact, and 24/24 expressive-repeat controls exact.

App build passed. Native `mahkummiyetinin + Enter + Backspace` offers unaccented `mahkumiyetinin` before canonical `mahkûmiyetinin`; selecting it produces the correct final text. Correct history rises 0→1, typo/canonical counts remain zero, and personal admissions remain zero. Evidence: `audits/everyday-20261025-native-mahkumiyet.json`, `audits/everyday-20261025-unaccented-long-after.json`, `audits/turkish-mahkumiyet-feature-repair-20261025.json`. Goal remains active.

### Adet homograph preserves both inflection paths (2026-10-25)

Compared circumflex/unaccented root metadata after the mahkumiyet repair. The substantive remaining mismatch was intentional for distinct canonical nouns: adet (count, tToD) versus âdet (habit/custom, NoVoicing). Everyday unaccented spelling needs both paths. Added a second adet noun with no alternation, at declared calibration floor 10, preserving the existing count-root weight and tToD. Source master-dictionary.dict:227–228 attests the two entries. Compound-stem differences found in the comparison were only the corresponding circumflex spelling.

Before: all 72 duplicate targets across adetini/adetimiz/adetinden were missing; all 72 targets for adedini/adedimiz/adedinden worked. Twelve automatic outcomes differed from intended/literal, including assetimiz/saadetimiz and forced circumflex. After: all 144/144 targets offered, seven exact automatic corrections, zero unrelated/forced-circumflex automatic outcomes; 288/288 undo cases and 24/24 expressive controls exact. Twenty-two focused tests passed. Added isolated homograph generation checks requiring both adeti and adedi plus literal preservation for all six inflections. Packs and app build passed.

Native adetimmiz + Enter + Backspace offers adetimiz, followed by âdetimiz. Explicit unaccented selection finishes at adetimiz; only that token gains one history observation, typo stays zero, personal admissions zero. Artifacts: audits/everyday-20261025-adet-after.json, audits/everyday-20261025-native-adet.json, audits/turkish-adet-homograph-plan-20261025.json. Goal continues.

### Planning messages and reminder noun (2026-10-25)

Twelve planning/work words across every repeated-key position exposed hatırlatıcıları: 45/45 targets absent and 27 unrelated automatic changes, including hatırlatışçıları. Added the missing lexical noun hatırlatıcı with declared floor 10 (not measured frequency), attested by Google Keep Turkish help: https://support.google.com/keep/answer/3187168?co=GENIE.Platform%3DDesktop&hl=tr. Added plural/possessive recognition and all-offset repeated-key regression.

Root-only rerun restored all 489 duplicate targets and removed all unrelated automatic changes, but native testing still showed generated hatırlatışçıları as a spare suggestion. Tightened the existing unknown-literal duplicate repair presentation filter: an unlisted/nonpersonal spare must fit the existing length bound and be at most one letter edit (including adjacent swap) from the recognized duplicate repair. Listed/personal exceptions and automatic decisions are unchanged. The native spare is now absent. Nearby generated randevunuzu is preserved alongside randevumuzu at offsets -0.18 and 0; initial test incorrectly required it at +0.18, where the archived baseline already lacked it. Corrected that control based on the baseline, retained the initial failed log.

Final focused run: 37 XCTest cases, 2 opt-in skips, zero failures. Final 1,491-row corpus: 489/489 duplicate targets offered, 307 exact automatic corrections, zero unrelated automatic changes; 978/978 undo cases and 24/24 expressive-repeat controls exact. App build passed. Native hhatırlatıcıları + Enter + Backspace offers literal and hatırlatıcıları only; selection increments only the correct history token, personal stays zero. Earlier native randevvumuzu correction followed by erte + SPACE+ENTER+BS+BS + leyelim finishes randevumuzu erteleyelim, records each correct word and pair once, and leaves wrong fragment/typo absent. Evidence: audits/everyday-20261025-native-reminder.json, audits/everyday-20261025-planning-final.json, audits/everyday-20261025-reminder-final.log. Goal continues.

### Productive deverbal agent/instrument derivation (2026-10-25)

Household typing exposed the same structural gap as hatırlatıcı: temizleyici exists as a listed surface but its inflections lack a lexical root and the productive -(y)ICI derivation was absent. Before: 39/39 temizleyiciyi repeated-key targets missing, 21 unrelated automatic changes. Added suffix ID 138, verbRoot→nounRoot, vowel-conditioned y + harmonized I + c + harmonized I, cost 2.0. Existing voice/causative continuation construction inherits the rule. Source: TDK Terim Sorunları ve Terim Yapma Yolları (2025), §73, p.168, https://tdk.gov.tr/wp-content/uploads/2011/12/Terim-Sorunlari-ve-Terim-Yapma-Yollari-_2025_-WEB.pdf. No one-off temizleyici root was added.

Isolated roots test temizle→temizleyici, oku→okuyucu, yaz→yazıcı, sür→sürücü, gör→görücü; causative hatırla→hatırlatıcı is tested without the lexical shortcut. Production tests include case/plural/possessive continuations. Focused run: 36 tests, 2 opt-in skips, zero failures. 1,338-row household corpus: 438/438 duplicate targets, 309 exact automatic corrections, zero unrelated changes, 876/876 undo controls, 24/24 expressive controls exact. App build passed. Native ttemizleyiciyi + Enter + Backspace offers only literal and correct form; explicit selection records only the correct word once. Household message interruption also preserved final text and clean token/pair learning.

Evidence: audits/everyday-20261025-native-agentive.json, audits/everyday-20261025-household-after.json, audits/everyday-20261025-agentive-focused.log. Because this is a productive grammar change, the full release suite is running in /tmp/bk-agentive-full.log (session 59734); do not call the broad validation complete until its terminal result is inspected.

Productive-agentive broad validation completed: 782 XCTest cases, 97 opt-in skips, zero failures (303.862 seconds); 406 Swift Testing cases across 54 suites passed (4.302 seconds). Log archived at audits/everyday-20261025-agentive-full.log. This run includes the prior fixed-root presentation, mahkumiyet, adet homograph, reminder root and spare-alternative changes.

Additional independent native derivation control: no paketleyici root exists, but paketle verb does. Typed pakettleyiciyi, Enter, Backspace, then selected paketleyiciyi. Correct history 0→1, typo 0→0, both personal zero. Added to audits/everyday-20261025-native-agentive.json. The goal remains ongoing, with no claim that all root coverage or every real-world scenario is complete.


### Agentive family follow-up — 2026-10-25

Twelve everyday/technical agentive inflections passed 1,563 typing cases: all 513 duplicate targets offered, 338 exact automatic repairs and zero unrelated automatic changes; 1,026 undo cases and 24 intentional repeats exact. Native `şiffreleyiciyi` + Enter + Backspace offered `şifreleyiciyi`; selecting it recorded the correct token once, the typo zero times, and neither as a personal entry. Evidence: `audits/everyday-20261025-agentive-family.json` and `audits/everyday-20261025-native-agentive-family.json`.


### Desiderative participle discovery — 2026-10-25

A 1,716-case everyday/formal audit exposed missing `sarılasım`: all 27 doubled-letter probes missed the intended candidate, six changed automatically to another word. Added positive and negative `-(y)AsI` participles with nominal possession/case continuations; vowel-final roots retain buffer y. Evidence for the suffix family: https://tdkbelleten.gov.tr/tam-metin-pdf/628/tur . Isolated-root and production regressions passed (18 suffix tests). Simulator build passed; native `sarıılasım` + Enter + Backspace offered `sarılasım`, and selecting it recorded only the correct token once (typo zero, personal entries zero). Re-running the original corpus and full suite remains required.

Original corpus re-run passed: 564/564 duplicate targets offered, 388 exact automatic repairs, zero unrelated automatic changes (previously six), 1,128 undo cases and 24 intentional repeats exact. Full suite started; result pending.

Additional native message: `seni göre` + accidental Space + Enter + two Backspaces + `sim` + Space produced `seni göresim `. History incremented each intended token once; cancelled `göre` remained absent. The intended pair was recorded once and the cancelled pair zero times; no new personal entry. Evidence: `audits/everyday-20261025-native-desiderative-message.json`.

Desiderative validation completed: full release suite passed 783 XCTest cases (97 opt-in skips, zero failures) and 406 Swift Testing cases in 54 suites. Independent 12-word family audit passed 960 cases: 312/312 doubled-letter targets offered, 110 exact automatic repairs, no unrelated automatic changes, 624 undo cases and 24 intentional repeats exact. Evidence: `audits/everyday-20261025-desiderative-full.log` and `audits/everyday-20261025-desiderative-family.json`.


### Daily reduplication roots and short fixed repeats — 2026-10-25

Reviewed twelve missing Dup components against the pinned dictionary: bıcır, börtü, cümbür, cazır, cızır, fıldır, kütür, lıkır, mırın, parıl, tiril, zonk. Imported as fixed roots at declared calibration floor 10; no existing frequencies changed. All 360 shifted/missing-space probes failed before import. Root import restored 330; the short-pair lexical cutoff still rejected all 30 zonk zonk probes. WordBoundaryRepair now treats an exact repetition of a fixed lexical root as stronger evidence than arbitrary short fragments, exempting it from short-pair cost/window filtering. Unknown and ordinary token repetitions retain the cutoff; literal input and explicit-choice-only boundary repair remain unchanged.

Final focused validation passed 24 tests (two opt-in skips); all 360 probes retain literal first, offer and insert the exact phrase. Native parılbparıl and zonkbzonk + Enter + Backspace each offered the intended two-word repair. Picking stored each correct token twice and its pair once, no malformed token or personal entry. Evidence under `audits/everyday-20261025-daily-redup-*`, `native-daily-redup.json`, and `native-fixed-repetition.json`; import plan `audits/turkish-next-redup-review-20261025.json`. Broader validation is pending.

Additional validation: all 183 duplicate targets offered across 573 cases; 14 exact automatic repairs and zero unrelated changes, 366 undo cases and 24 intentional repeats exact. Source coverage improved by exactly the twelve imported forms, 286 to 274 missing, zero losses. Full suite is running.


### Listed spare candidates after a boundary repair — 2026-10-25

Native `börtübböcek` + two Enters + two Backspaces correctly offered `börtü böcek`, but also an unrelated listed `görünmek`. The existing presenter distance check exempted all form-trie candidates. Removed that exemption when an explicit boundary repair exists; listed and generated candidates now share the existing nearby-edit budget. One-edit/adjacent-swap dictionary priority and nearby generated alternatives retain their controls. Added regressions for görünmek/görüşmek/şarkıcıları beside correct phrase repairs at three touch offsets and two suggestion limits. Native rebuild removes görünmek, preserves the exact repair, and records each intended token and pair once more with malformed history/personal entries zero. Focused and full validation are pending; the already-running fixed-repetition full suite predates this presenter edit.

Fixed-repetition full validation completed: 784 XCTest cases (97 opt-in skips), zero failures, and 406 Swift Testing cases in 54 suites passed. This result covers the twelve roots and fixed-repetition boundary change; it predates the subsequent listed-spare presenter filter. Evidence: `audits/everyday-20261025-fixed-repetition-full.log`.

Listed-spare focused validation passed 23 tests (two opt-in skips). All 360 boundary probes still retain literal first and offer/pick the exact expected phrase. Relative to the previous artifact, removed görünmek in 15 cases, görüşmek in six, and şarkıcıları in three. Nearby alternatives retained; one-edit and adjacent-swap priority controls pass. Current presenter full validation has started and is not yet complete.

Native technical control on the listed-spare filter: erişimbreddedildi + Enter + Backspace offers only the literal and erişim reddedildi. Selection increments each correct token and pair once (2→3), malformed history stays zero and personal entries remain zero. Evidence: `audits/everyday-20261025-native-boundary-technical-control.json`.

Listed-spare filter full validation passed: 785 XCTest cases (97 opt-in skips), zero failures; 406 Swift Testing cases in 54 suites pass. Independent mixed-style follow-up (12 romantic/technical/dialect/formal pairs, three casings, ten missing/mistapped boundaries) passes all 360 literal-first, correct-offer and exact-selection checks. Evidence: `audits/everyday-20261025-boundary-spares-full.log` and `audits/everyday-20261025-mixed-boundary-followup.json`.


### Generated spare locality beside a boundary repair — 2026-10-25

Mixed-style audit exposed unlisted generated senizleydim and helezonmuşsak within the old multi-edit nearby budget. Generated whole-word spares beside an exact boundary repair now require one letter edit or an adjacent swap, matching the local evidence for the split itself. Listed candidates retain the existing nearby check; nearby generated and dictionary-priority controls pass. All 360 mixed-style probes preserve literal first, expected offer and exact selection. Removed senizleydim in 21 cases and helezonmuşsak in three, plus distant unlisted ayçiçek in nine cases. Focused tests: 24, two opt-in skips, zero failures. Native helezkonuşak + Enter + Backspace offers the literal and hele konuşak, without helezonmuşsak; selecting records only intended tokens and their pair. Full validation pending. Evidence: `audits/everyday-20261025-generated-boundary-*` and `audits/everyday-20261025-native-generated-boundary.json`.

Additional native romantic control: senibözledim + two Enters + two Backspaces offers only literal and seni özledim. Selection increments seni 20→21, özledim 4→5 and their pair 3→4; typo stays zero, all personal entries zero. Evidence: audits/everyday-20261025-native-generated-romantic.json.

Generated-boundary full validation passed: 786 XCTest cases, 97 opt-in skips, zero failures; 406 Swift Testing cases in 54 suites passed. Evidence: audits/everyday-20261025-generated-boundary-full.log.

### Flow/sound reduplication roots — 2026-10-25

Reviewed and imported twelve fixed roots from the pinned dictionary: şarıl, tıpır, ılgıt, ifil, fırıl, çıngır, şangır, langır, lungur, höpür, gacır, gucur, at declared floor 10. Before: 0/300 boundary repairs offered. After: 270/300; remaining şangır şungur probes revealed the missing companion şungur, also source-attested and now imported. Initial failed log and 270/300 artifact retained. Native şarılbşarıl previously offered unrelated şarkıları/şarkılarmış; rebuilt app offers only literal and şarıl şarıl after Enter+Backspace. Picking records şarıl twice and its pair once, typo zero, personal entries zero. Final 13-root validation is pending; simulator currently contains first twelve roots.

Flow-root final validation passed: six focused tests including unaccented-preference controls, 300/300 boundary repairs offered and selected exactly with literal first. Duplicate audit: {"rows": 645, "double": 207, "offered": 207, "auto_exact": 26, "unrelated_auto": 0, "undo_exact": 414, "undo": 414, "repeat_exact": 24, "repeat": 24}. Pinned-source missing surfaces 274→261, exactly thirteen gains and zero losses. Simulator rebuilt with all thirteen roots; native şangırbşungur + two Enters + two Backspaces offers only literal and şangır şungur. Selection learns each correct word and pair once, malformed token zero, no personal entries. Evidence: audits/everyday-20261025-flow-redup-final.log, flow-redup-doubles.json, native-flow-companion.json, and turkish-root-runtime-flow-redup-after-20261025.json.

### Longer mixed-message follow-up — 2026-10-25

Twelve romantic/technical/formal words passed 1,536 cases: 504/504 duplicate targets offered, 345 exact automatic corrections, zero unrelated changes; 1,008 undo and 24 expressive-repeat controls exact. Native seni görmeye sabır + Space/Enter/BS/BS + sızlanıyyorum offered sabırsızlanıyorum; selection recorded only final tokens/pairs. Native yetkilendirmmeyi + Enter/BS, corrected by selection, then güncel + Space/Enter/BS/BS + leyebiliriz completed the technical message. Cancelled fragments and typos remained absent in history and personal entries; correct tokens and pairs incremented once. Evidence: audits/everyday-20261025-evening-mixed.json and native-evening-mixed.json.

Native formal message check: dilekçemmizin + Enter/Backspace, select dilekçemizin; değer + Space/Enter/Backspace/Backspace + lendirilmesini rica ederim finishes the exact formal sentence. Each intended token and pair increments once; cancelled değer and misspelling remain zero; personal entries all zero. Evidence: audits/everyday-20261025-native-formal-long.json.

Next reviewed fixed-root batch: fosur, pofur, hapır, hupur, löpür, tangır, tungur, uğul, şıngır, zıngır, şupur, hışıl. All twelve are pinned source Dup entries, imported at calibration floor 10. Baseline 0/300 phrase repairs. Packs regenerated; focused tests and simulator build are running, not yet validated. Plan: audits/turkish-rumble-redup-review-20261025.json.

Rumble-root batch validation passed: six focused tests, 300/300 boundary repairs offered and selected with literal first. Duplicate audit {"rows": 591, "double": 189, "offered": 189, "auto_exact": 22, "unrelated_auto": 0, "undo_exact": 378, "repeat_exact": 24}. Source coverage {"missing_before": 261, "missing_after": 249, "gains": ["fosur", "hapır", "hupur", "hışıl", "löpür", "pofur", "tangır", "tungur", "uğul", "zıngır", "şupur", "şıngır"], "losses": []}. Native tangırbtungur + Enter/Backspace offers only literal and tangır tungur; selecting learns each intended token and pair once, typo zero, all personal entries zero. Evidence: audits/everyday-20261025-rumble-redup-* and native-rumble-redup.json.

### Expanded dialect typing — 2026-10-25

Native ula gardaşımm + Enter/Backspace, select gardaşım; hele konu + Space/Enter/Backspace/Backspace + şak completes ula gardaşım hele konuşak. Correct tokens/pairs increment once; typo and cancelled konu remain zero; personal entries remain zero. Independent 23-form dialect audit: {"rows": 1329, "doubles": 435, "offered": 435, "auto_exact": 176, "unrelated_auto": 0, "undo_count": 870, "undo_exact": 870, "repeat_count": 24, "repeat_exact": 24}. Evidence: audits/everyday-20261025-native-dialect-message.json and dialect-expanded.json.

### Motion/sound fixed roots — 2026-10-25

Twelve source-attested fixed roots added at calibration floor 10: bıngıl, cumbul, fingir, fışır, hırıl, ipil, pır, şıldır, vızır, vızıl, zırıl, mıncık. Last two are pinned non-tdk Ext entries, others master-dictionary Dup entries. Before 0/360 boundary repairs; after 360/360 offered/picked with literal first. Six focused tests pass including circumflex preferences. Native vızırbvızır + Enter/Backspace offers only literal and vızır vızır; selection records vızır twice and its pair once, malformed token zero, personal entries zero. Duplicate audit: {"rows": 582, "double": 186, "offered": 186, "auto_exact": 6, "unrelated_auto": 0, "undo_exact": 372, "repeat_exact": 24}. Coverage: {"missing_before": 249, "missing_after": 237, "gains": ["bıngıl", "cumbul", "fingir", "fışır", "hırıl", "ipil", "mıncık", "pır", "vızıl", "vızır", "zırıl", "şıldır"], "losses": []}. Evidence: audits/everyday-20261025-motion-redup-* and native-motion-redup.json.

Phone-observed typo recheck on current simulator build: belkş + Enter/Backspace offers belki; selection followed by yarın görüş + Space/Enter/Backspace/Backspace + ürüz yields belki yarın görüşürüz. Each correct token and pair increments once, typo and cancelled görüş remain zero, personal entries all zero. Evidence: audits/everyday-20261025-native-phone-typo-recheck.json. Broad release suite covering root batches through motion roots is running; style/control audit queued behind it.

Additional phone-observed typo check: anaokuku + Enter/Backspace offers anaokulu. Selection, then kay + Space/Enter/Backspace/Backspace + dını yapalım completes anaokulu kaydını yapalım. All correct tokens and pairs recorded once; malformed anaokuku and cancelled kay zero; personal entries all zero. Evidence: audits/everyday-20261025-native-phone-school-recheck.json.

Remaining source review is now explicitly classified in audits/turkish-remaining-root-review-20261025.json: 237 unrecognized source surfaces comprise 143 circumflex variants with an existing unaccented root or runtime-recognized counterpart, 58 reduplication components, and 36 requiring manual spelling/grammar review. These counts are source inventory categories, not a claim that only 237 Turkish roots remain. No blind import of concatenated source artifacts or suspected spelling errors.

Broad root-batch validation completed: 786 XCTest cases, 97 opt-in skips, zero failures (305.957 seconds); 406 Swift Testing cases in 54 suites passed. Includes all roots through motion batch. Style/control recheck: 105/105 dialect forms unchanged, 33/36 controls automatically exact; three patstes controls retain literal but offer patates for explicit choice, with no unrelated replacement. Evidence: audits/everyday-20261025-root-batches-full.log and phone-style-recheck.json.

Next reviewed rhythmic batch: apul, ceste, kıdım, pırtık, sapır, tapır, tukur, gıldır, fısır, şalap, yalap, zıngıl. All pinned source Dup records imported as fixed at floor 10; baseline 0/360 boundary repairs. Packs regenerated; focused validation and simulator build started, results pending. Plan: audits/turkish-rhythmic-redup-review-20261025.json. Broad suite above predates this batch.

Rhythmic-root validation completed: six focused tests pass; {"offered": 360, "picked_exact": 360, "literal_first": 360, "rows": 360} boundary checks. Duplicate audit {"rows": 582, "double": 186, "offered": 186, "auto_exact": 6, "unrelated_auto": 0, "undo_exact": 372, "repeat_exact": 24}. Coverage {"missing_before": 237, "missing_after": 225, "gains": ["apul", "ceste", "fısır", "gıldır", "kıdım", "pırtık", "sapır", "tapır", "tukur", "yalap", "zıngıl", "şalap"], "losses": []}. Native sapırbsapır + Enter/Backspace offers only literal and sapır sapır; selecting records sapır twice and its pair once, typo zero, personal entries zero. Evidence: audits/everyday-20261025-rhythmic-redup-* and native-rhythmic-redup.json.

### Short fixed-root batch discovery — 2026-10-25

Imported twelve pinned Dup roots at floor 10: zart, zurt, zırt, vır, vırt, çer, çör, fış, cır, mır, mık, vık. Baseline 330 probes: zero offers, nine already-known joined controls. Root-only result: {"rows": 330, "offered": 168, "known_joined": 9, "missing_unjoined": 153}. Distinct short pairs (zart zurt, zırt pırt, vırt zırt, çer çöp, çör çöp) remain filtered by short lexical cutoff. cırccır and mırmmır instead prefer legitimate joined duplicate repairs cırcır/mırmır; treat ambiguity separately. Failed log retained. No runtime relaxation yet; simulator not rebuilt. Next requires bounded lexical phrase evidence and appropriate regressions, not arbitrary short-pair acceptance.

The short-pair fix uses five explicit reviewed pairs (zart zurt, zırt pırt, vırt zırt, çer çöp, çör çöp), additionally requiring fixed-root evidence for the left component and recognition of both tokens. This bypasses only the short-fragment presentation cutoff, never automatic correction, dictionary scoring, or learning admission. It does not infer arbitrary pair combinations. Provenance: Ordu University reduplication research https://earsiv.odu.edu.tr/xmlui/bitstream/handle/11489/586/10319031.pdf?sequence=1 (zart zurt / zırt pırt), university Turkish syntax material https://ebs.duzce.edu.tr/Uploads/DersMateryal/C%C3%9CMLE%20B%C4%B0LG%C4%B0S%C4%B0%20ENFEL%20DO%C4%9EAN.PDF (çer çöp / vırt zırt), and primary linguistic study https://dergipark.org.tr/tr/download/article-file/5128760 (çer çöp / çör çöp). Negative tests cover arbitrary fixed-root combinations, unsupported separator characters, and text-only dictionary entries without fixed-root metadata. The audit explicitly preserves cırccır → cırcır and mırmmır → mırmır as six case-sensitive duplicate controls, rather than demanding a space repair for these ambiguous listed compounds. Validation is pending.

Short-pair focused validation passed 13 tests: 330 probes comprise 312 exact phrase offers/selections, nine recognized joined controls, and nine duplicate controls (including çerççöp → çerçöp; mırmır is recognized but not listed). All keep literal first. Duplicate audit: 384 rows, 120/120 targets offered, zero unrelated automatic changes, 240 undo cases and 24 intentional repeats exact. Source coverage: {"missing_before": 225, "missing_after": 213, "gains": ["cır", "fış", "mık", "mır", "vık", "vır", "vırt", "zart", "zurt", "zırt", "çer", "çör"], "losses": []}. Native zırtbpırt + Enter/Backspace offers zırt pırt; selection records correct tokens and pair once, malformed and personal entries zero. Native hala seni düşünüyyorum + Enter/Backspace then selection finishes hala seni düşünüyorum without forcing circumflex; correct history/pairs increment once, typo zero. Full release suite running (session 73607).

Short-root batch broad validation completed: 787 XCTest cases, 97 opt-in skips, zero failures (311.492 seconds); 406 Swift Testing cases in 54 suites passed (4.316 seconds). Full log: audits/everyday-20261025-short-redup-full.log. Additional native zartbzurt + two Enter/two Backspace offers zart zurt and records only intended tokens/pair once. Remaining classified inventory: 143 circumflex variants with unaccented coverage, 34 reduplication components, 36 manual spelling/grammar cases; report audits/turkish-remaining-root-review-after-short-20261025.json. This completes the current short-root batch, not the ongoing user goal.

### Long contextual duplicate discoveries — 2026-10-25

A 12-word, 1,662-row sweep found 22 missing duplicate offers: 21 for informal gelecem (absent from the conversational pack), one for yetkilendirilmemmiş at offset -0.18. Six gelecem probes were automatically changed to gelecek. Added reviewed conversational surface gelecem at the existing informal floor 800 and included intentional style preservation coverage. The technical typo and its target both have recognized generated analyses; the presenter previously admitted only listed/fixed/circumflex duplicate repairs for recognized generated literals. It now also offers an exact repeated-letter deletion when the recognized repair has strictly stronger lexical support than that generated literal. Listed literals, literal-first protection, and automatic scoring are unchanged. Regression verifies all three offsets, Enter/backspace, explicit selection, and clean personal learning. Focused validation: 22 tests, two opt-in skips, zero failures. Native ula yarın ggelecem and servis yetki + cancelled boundary + lendirilmemmiş both offer/select intended text and learn only the final tokens/pairs once. Native romantic keşke sana sarılabilseydim likewise preserves cancelled fragment/typo exclusions. Evidence: audits/everyday-20261025-long-context-* and native-gelecem.json, native-long-negative.json, native-long-romantic.json. Repeat sweep and broad suite still pending.

Long-context repeated sweep passed: 1,662 rows, all 546 duplicate targets offered, 384 exact automatic repairs, zero unrelated automatic changes (baseline six), 1,092 undo controls exact and 24 intentional repeats exact. Broad release suite started, session 14002, log audits/everyday-20261025-long-context-full.log. Do not treat broad validation as complete until the live process finishes.

Long-context broad validation passed: 788 XCTest cases, 97 opt-in skips, zero failures (304.694 seconds), plus 406 Swift Testing cases in 54 suites (4.260 seconds). Native talebim değerlendirilmemmiş + Enter/Backspace also offers an exact selected repair with intended history/pair once and typo/personal entries zero. A separate native UI issue remains recorded: long suggestion suffix differences are hidden by tail truncation.

### Paired reduplication root batch — 2026-10-25

Pinned Dup roots anha, bici, cambul, ciyak, cungul, fiso, fıkı, gulu, okus, pokus, ıkına, yapıldak imported at floor 10. Companion minha is absent from that inventory but attested in the Ordu University reduplication study (https://earsiv.odu.edu.tr/xmlui/bitstream/handle/11489/586/10319031.pdf?sequence=1, anhâ minhâ); added as reviewed unaccented fixed surface at the same floor. No fabricated token frequency. Initial exploratory probe çırıl yapıldak was corrected after source review to yayan yapıldak, attested in https://dergipark.org.tr/en/download/article-file/3572543 (also attests sıkı fıkı). Corrected baseline has 330 probes, zero offers. Existing bounded short-pair evidence now includes fasa fiso and sıkı fıkı and requires either component to be fixed (the other still recognized); unrelated combinations fasamık/sıkızurt added as negative controls. Root metadata gives these components no productive suffix path. Plans: audits/turkish-paired-redup-review-20261025.json and companion-review. Focused tests and own simulator build running; not yet validated.

Paired-root validation: 13 focused tests passed, 330/330 boundary offers selected exactly with literal first. Duplicate sweep: 600 rows, 192/192 targets offered, four exact automatic repairs, zero unrelated changes, all 384 undo and 24 intentional repeat controls exact. Pinned-source missing surfaces 213 → 201, exactly twelve gains and zero losses; companion minha is outside this inventory. Native fasabfiso + Enter/Backspace offers fasa fiso; selecting stores intended tokens/pair once, typo/personal zero. Full release suite running under session 94188, log audits/everyday-20261025-paired-redup-full.log.

Native long-suggestion display fix: SuggestionBar CATextLayer truncation now preserves both ends (middle ellipsis), so evaluation suffixes remain distinct. Actual screenshot showed ...emmiş / ...ilmemiş / ...mekmiş; middle selection yielded exact talebim değerlendirilmemiş. History tokens/pair increased from one to two, malformed token stayed zero. Full accessibility labels already exist in source; no accessibility or suggestion payload change was needed. Built/installed only own simulator, PID 88974.

Paired-root broad suite passed: 788 XCTest cases, 97 opt-in skips, zero failures (306.957 seconds); 406 Swift Testing cases in 54 suites (4.049 seconds).

### Corrected compound source metadata — 2026-10-25

Manual source audit confirmed güveyfeneri, hasekiküpesi, havvaanaeli and tavuskuyruğu are unrecognized. Their pinned Roots annotations mistakenly use güney, heseki, hayvan and tavuk. Primary published spelling attestations and original source records are preserved in audits/turkish-corrected-compound-inventory-20261025.json. Reviewed inferred stems are güveyfener, hasekiküpe, havvaanael and tavuskuyruk. Imported as four possessiveCompound roots using existing builder support and floor 10, with original inventory unchanged. Added real singular/case/plural controls and isolated rejection of doubled possessive suffixes. Packs rebuilding; validation pending.

Corrected compound validation completed: seven focused tests pass (real inflections, isolated malformed suffix rejection, circumflex preferences). Duplicate sweep: 1,023 rows, 333/333 targets offered, 268 automatic exact repairs, zero unrelated changes, 666 undo and 24 intentional repeat controls exact. Native hasekiküppesini + Enter/Backspace → selected hasekiküpesini, then cancelled sula boundary and completion to suladım: intended text/history/pair exact, typo/cancelled fragment/personal zero. Source missing surfaces 201 → 197, exactly the four intended gains and no losses. Last full suite predates this four-root data-only batch; targeted validation completed. Manual-source decision ledger also resolves twelve joined artifacts and three source typos already covered; 17 manual records remain unresolved, alongside 22 Dup components. Raw missing count must not be presented as the number of legitimate roots still to import.


### Final pinned Dup review (2026-10-25, validation in progress)

Added the final 22 pinned Dup components as fixed roots at calibration floor 10, plus independently reviewed companions çangıl and çangır. Plans: `audits/turkish-final-dup-review-20261025.json`, `audits/turkish-final-dup-companion-review-20261025.json`. Ordu University primary thesis https://earsiv.odu.edu.tr/xmlui/bitstream/handle/11489/586/10319031.pdf?sequence=1 attests çangıl çungul, çangır çungur, şaka maka, and kayıt kuyut. The exploratory kuy tu/kuyut pairing was not supported; final audit uses kayıt kuyut instead. Garç gurç is attested in the TDK dictionary hosted by OMU: https://avys.omu.edu.tr/storage/app/public/zihniz/133975/Buyuk%20Turkce%20Sozluk%20%28TDK%29%20%28PDF%2C%209.9%20MB%29.pdf .

Root-only audit: 387/510 offers. Missing companions and the two short pairs explain 120 misses; gıygıy accounts for three casing variants of a legitimate recognized compound. The bounded reviewed short-pair set now includes garç gurç and şaka maka. After these additions, şakamaka still offered şaka aka and şakama ka instead of the exact phrase: fixed roots were excluded from the listed-exact prioritization. Recognized reviewed fixed phrases now provide the same exact-boundary evidence for prioritization/filtering. No automatic replacement scoring change. Existing negative short-fragment controls retained. Native şakabmaka + Enter + Backspace + selection verified correct phrase learning only (each token 0→1, pair 0→1, typo 0, personal 0). Final matrix and full suite pending.

Final focused validation: 7 boundary tests passed. The final 510-row shifted-space matrix has 507 exact offers/picks and three recognized gıygıy compound controls, with literal first throughout. Duplicate audit: 1,113 rows; all 363 target offers present, 47 exact automatic corrections, zero unrelated automatic replacements, 726/726 undo checks and 24/24 intentional repeats exact. Source coverage improves 197→175 raw omissions, exactly the 22 reviewed Dup gains and no losses; remaining raw count includes 143 circumflex variants and previously resolved artifacts, not 175 real missing roots. Native exact şakamaka priority check on PID 94991 shows literal first, şaka maka next; choosing it increments only the two correct tokens and pair once, typo/personal zero. Full suite launched as session 48767, log `audits/everyday-20261025-final-dup-full.log`; completion not yet claimed.


### Long suggestion internal differences (2026-10-25)

Native formal typing combined duplicated r, accidental Space+Enter, two Backspaces, continuation, suggestion selection, and final Enter. Final başvurumun değerlendirilmesini rica ederim was exact; every final token/pair increased once, cancelled fragment and typo stayed zero. Evidence: `audits/everyday-20261025-native-formal-mixed-boundaries.json`.

Discovered that middle truncation still makes all three long offers visually identical when the difference is internal. SuggestionBar now renders overflowing text in two balanced grapheme lines at 11–13pt, keeping 16pt for fitting text. It updates CALayer frames directly without invalidating Auto Layout; selection and accessibility retain the unmodified slotWords. Native PID 96111 verified distinct full forms değerlendirrilmesini/değerlendirilmesini/değerlendirtilmesini; middle selection inserts the complete correct word, no display newline. Short rica returns to 16pt one line. Completed sentence and history/pair increments exact, typo/personal zero. Build passed; evidence `audits/everyday-20261025-native-long-offer-wrap.json`. This app-only visual change is independent of the running core suite. Extremely long content beyond two lines at the minimum readable font still uses tail truncation.

Final Dup broad validation completed: 789 XCTest cases, 97 opt-in skips, zero failures (314.354s); 406 Swift Testing cases across 54 suites passed (4.253s). Session 48767 closed successfully; no core checks pending for this batch. Native technical sentence sunucunun yapılandırmasını güncelledim passed after accidental Space+Enter inside yapılandırmasını, undo, doubled s, another Enter/undo and explicit correction. Final tokens and pairs each +1; cancelled yapı and wrong yapılandırmassını zero in history/personal. Evidence `audits/everyday-20261025-native-technical-mixed-boundaries.json`.

Two manual source records resolved as joined artifacts: üstderi → üst deri (TDK deri entry lists it separately, https://sozluk.gov.tr/gts?ara=deri); yabanasması → yaban asması (MEB Teras Bahçeleri, https://megep.meb.gov.tr/mte_program_modul/moduller/Teras%20Bah%C3%A7eleri.pdf). No joined root added. 60 casing/space-adjacent-letter checks all retain literal first, offer the spaced phrase and pick it exactly: `audits/everyday-20261025-reviewed-separate-two.json`. Manual decisions updated; 15 unresolved entries remain. Raw source omissions unchanged because artifacts should remain unrecognized as single words.


### Six further separate-word source artifacts (2026-10-25)

TDK entries confirm acı çiğdem, acı yonca, altın suyu, besi suyu; the older official su entry also lists er suyu and kenar suyu separately. Primary URLs are recorded per entry in `audits/turkish-manual-source-decisions-20261025.json`. No concatenated roots imported. Manual unresolved count is now 9, distinct from raw source omissions.

Baseline shifted-space matrix passed 150/180; all 30 besi suyu cases failed because the short-fragment joint lexical cutoff suppressed the phrase. Added one explicitly dictionary-attested pair (besi suyu), with both components still required to be recognized. The general threshold stays unchanged, no automatic correction scoring change. New permanent test covers all space-adjacent substitutions and missing-vocabulary rejection. Eight focused tests pass; 180/180 matrix rows now literal-first with exact offer/pick. Native besibsuyu+Enter+Backspace+selection yields besi suyu, correct tokens and pair +1, typo history/personal zero (PID 98509). Broad suite started in `audits/everyday-20261025-besi-suyu-full.log`, not yet complete.

Dialect native check ula garrdaşım+Enter+Backspace+selection+yarın gelecem preserves informal wording, all four tokens and three final pairs +1, typo zero. Evidence `audits/everyday-20261025-native-dialect-duplicate.json`.


### Triple-key generated spare discovery (2026-10-25)

Besi-suyu broad validation finished: 790 XCTest (97 opt-in skips), zero failures in 318.592s; 406 Swift Testing cases passed in 4.284s. This predates the following presenter change.

Native shopping message markettten produced offers markettten/marketten/marketsten. Correct selection and final marketten ekmek alacağım history were exact, but marketsten was an unsupported spare derived from existing technical noun markets. Instead of deleting technical vocabulary, the duplicate-repair spare filter now bounds generated candidate length by the exact repair, not the longer mistyped literal. This rejects inserting a different letter after duplicate removal; listed/personal alternatives retain their prior exceptions, and same-length generated randevunuzu remains tested. Extended regression covers markettten→marketten rejecting marketsten at three touch offsets. Focused 17 cases (2 opt-in skips) pass. Native PID 1901 now displays only markettten/marketten; correct token +1, both wrong forms zero in history/personal. Evidence native-market-triple-before/after JSON.

Eight-word double-key audit: 762 rows; all 246 intended words offered, 117 exact automatic corrections, zero unrelated replacements, all 492 undo checks and 24 intentional-repeat controls exact. Full suite launched at `audits/everyday-20261025-market-triple-full.log`, pending completion. Borazancıbaşı metadata plan remains unapplied until this validation is closed.

Market triple broad suite completed: 790 XCTest, 97 opt-in skips, zero failures (302.786s); 406 Swift Testing cases in 54 suites passed (4.022s). This covers the duplicate-spare filter change. Acem lalesi separate-word audit passed all 30 variants; TDK https://sozluk.gov.tr/gts?ara=Acem+lalesi supports this spelling. Source acemlale resolved as malformed joined artifact, no root imported. Eight manual records remain. Baseline probes for bacabaşı/borazancıbaşı and forms, öbürkü and cases, ahacık, rabbena, beşikdüzü, şöylemesine all unrecognized. The two compound plans remain unapplied; isolated root round-trip and case tests are currently compiling/running.


### Last two compound corrections and proper place (2026-10-25)

Applied reviewed bacabaşı (underlying bacabaş) and borazancıbaşı (borazancıbaş) corrections, plus proper Beşikdüzü (beşikdüz), each floor 10 with possessiveCompound. Pinned inventory preserved. Plans: turkish-last-two-compounds-plan and turkish-besikduzu-review. Municipality attests Beşikdüzü’nde; proper POS survives pack roundtrip. Six compound tests pass, including valid forms and rejection of doubled possessive or incorrect y-buffer forms. Production probes recognize all 12 reviewed root/inflection forms. Duplicate audit: 1,401 rows; 459/459 target offers, no unrelated automatic replacements, 918/918 undo checks and 24/24 intentional repeats exact. Source omissions 175→172, exactly three reviewed gains and no losses. Native lower-case everyday yarın beşikkdüzüne + Enter/undo + explicit selection yields yarın beşikdüzüne; final tokens/pair +1, typo history/personal zero. This native case does not claim apostrophe input coverage.

Five manual records remain: ahacık, arapsuyu, rabbena, öbürkü, şöylemesine. Last full suite predates these bounded data-only additions; scoped checks above completed and no process remains running.


### Lexical öbürkü and mixed native continuations (2026-10-25)

Added appended kiPronoun POS and kiPronounRoot continuation. The class reuses third-person n-buffered cases/copulas and ordinary plural, without admitting noun possessive suffixes directly at the root. Existing POS raw values remain unchanged; root pack round-trip preserves the new class. TDK attests öbürkü and öbürkünü: https://sozluk.gov.tr/gts?ara=%C3%B6b%C3%BCrk%C3%BC. Added öbürkü at calibration floor 10. Thirteen focused tests pass, including 13 valid forms and 8 invalid controls for this root. Production source omissions 172→171, exactly öbürkü gained and no losses. Duplicate matrix: 771 rows, all 249 target offers, 61 exact automatic corrections, zero unrelated replacements, 498 exact undo checks, 24 intentional-repeat controls. Native bunu öbürkküne+Enter+Backspace+selection+ver yields bunu öbürküne ver, correct final tokens/pairs increment once, typo history/personal remain zero.

Full suite: 792 XCTest, 97 opt-in skips, zero failures in 318.363s; 406 Swift Testing cases in 54 suites passed in 4.208s. This also covers the prior three compound/proper additions. Manual source review now has four unresolved records: ahacık, arapsuyu, rabbena, şöylemesine. This is a reviewed source inventory milestone, not exhaustive Turkish coverage.

Two further native messages mixed premature Space+Enter, two Backspaces, suffix continuation and a duplicated consonant: akşam buluşabilirrsek→akşam buluşabilirsek sevinirim, and yedekleri eşitleyemeyinnce→yedekleri eşitleyemeyince yeniden denedim. In both, final tokens/pairs increment exactly once and cancelled fragments (buluş/eş) and wrong spellings remain zero. Reports: everyday-20261025-native-bulusabilirsek.json and native-esitleyemeyince.json.


### Ahacık dialect particle (2026-10-25)

Kastamonu University source p137 item136 attests ahacık as a demonstrative particle (see turkish-ahacik-review-20261025.json for URL). Added fixed lexical root and wordlist entry at floor10; original Det inventory preserved. Production now recognizes ahacık and rejects four tested unsupported nominal forms. Three focused tests pass. Duplicate audit: 222 rows, 66/66 exact target offers, 24 exact automatic corrections, no unrelated replacements, 132 exact undo checks and 24 repeat controls. Native ahaccık+Enter+Backspace+selection+buradayım yields ahacık buradayım; correct tokens/pair +1 and typo history/personal zero. Source omissions 171→170, sole gain ahacık, no losses. Three manual entries remain (arapsuyu, rabbena, şöylemesine). Last full oburku suite predates this data-only root; scoped checks completed with no pending process.


### Şöylemesine lexical adverb (2026-10-25)

TDK-hosted dialect study https://agiz.tdk.gov.tr/tdk_arsiv_pdf/TDKAA305.pdf and PONS attest şöylemesine as adverbial usage. Pinned source incorrectly marks CompoundP3sg with Roots:şöylem-es. Preserved source inventory, added fixed root plus wordlist floor10, avoiding unsupported nominal inflection. Three focused tests pass; positive production recognition and four invalid forms checked. Duplicate matrix: 303 rows, 93/93 target offers, 33 exact automatic corrections, no unrelated replacements, 186 exact undo checks and 24 repeat controls. Native şöylemessine+Enter+Backspace+selection+baktım yields şöylemesine baktım; correct tokens/pair +1, typo history/personal zero. Source omissions 170→169, sole gain şöylemesine and no losses. Two manual entries remain: arapsuyu and rabbena. Last full oburku suite predates this data-only addition; scoped checks passed, no running process.


### Arapsuyu and water compound buffer (2026-10-25)

Official municipality https://www.konyaalti.bel.tr/haberler/18807/arapsuyuna-ozgecan-aslan-parki and TOKİ https://www.toki.gov.tr/haber/kamuoyu-aciklamasi5 attest Arapsuyu and n-buffered cases. Added proper root floor10, possessiveCompound, underlying arapsu. RootTrie now removes s only when actually present before final vowel; su-yu preserves y for arapsuyum. Builder previously required s for every vowel-final compound stem; added bounded stem-ending-su plus exact stem+yu exception. Builder controls accept arapsuyu/acemborusu and reject acemboruyu/arapsuyi. Seven focused tests pass; production seven positives and five negative controls pass. Duplicate matrix663: all213 intended offers,94 exact automatic corrections,zero unrelated replacements,426 undo and24 repeat controls exact. Native yarın arapsuyunnda +Enter/undo+selection+buluşalım gives correct final words/pairs +1, typo zero. Coverage169→168, sole gain arapsuyu. Full:793 XCTest,97 skips,0 failures,309.464s;406 Swift Testing cases passed4.104s. Only rabbena remains in manual source review.

A separate native discovery remains unresolved: Arapsuyu'nnda shows no correction offer because CorrectionContext protects apostrophes and WholeWordSuggestion only covers circumflex words. Manual recovery yields Arapsuyu'nda buluşalım; correct lowercase canonical token learned once, typo and isolated nda/nnda zero. Regression test prepared for explicit host-verified whole-word offers, preserving automatic protection. Baseline test queued after the full suite above; no runtime repair for this separate issue yet.


### Explicit apostrophe duplicate repair (2026-10-25)

Native Arapsuyu'nnda had no offer; focused baseline reproduced nil WholeWordSuggestion. Added shared exact lexical-root POS lookup to LiteralChannel and bounded duplicate deletion in WholeWordSuggestion. A candidate must retain the written apostrophe and casing, have a dictionary proper root, and a recognized joined inflection. Already recognized forms, multiple apostrophes, technical syntax/tails, selections and secure fields produce no new offers. This is explicit selection only; CorrectionContext's automatic protection remains unchanged. Focused11 tests (2 opt-in skips) passed. Regression covers suffix/root duplicates, title/all capitals, ASCII/curly apostrophes, legitimate Çanakkale double k and unsafe contexts.

Native PID17644: Arapsuyu'nnda+Enter/undo→select Arapsuyu'nda→buluşalım preserves case/punctuation; correct token/pair +1, typo and suffix fragments zero. Ankkara'da+Space+Enter+two Backspaces→select Ankara'da→görüşürüz also passes with exact history. Selecting Arapsuyu'nda, deleting its appended separator and last a, then retyping a+Space+Enter increments correct history only once; typo/fragment zero. Evidence: native-arapsuyu-apostrophe-after.json, native-apostrophe-root-duplicate.json, native-apostrophe-selection-reedit.json.

Full validation passed:794 XCTest,97 opt-in skips,0 failures,318.191s;406 Swift Testing cases in54 suites passed4.250s. The apostrophe duplicate finding is closed within this explicit single-duplicate repair scope; ongoing broader typing audit remains active.

### 2026-10-25 — Reviewed Rabbena lexical entry

Added fixed lexical `rabbena` and `rabbenâ` at calibration floor 10, preserving the pinned source inventory. Diyanet usage supports both spellings; everyday unaccented input is not forced to circumflex. Production probes recognize both forms and reject five unreviewed typo/nominal forms. Fixed lexical tests passed. The direct-key duplicate fixture cannot type circumflex (no layout key); its initial failure is recorded in `audits/everyday-20261025-rabbena-focused.log`. The supported unaccented run passed: 21/21 duplicate offers, 42/42 undo checks, 24/24 intentional-repeat controls, zero unrelated automatic replacements. Native PID 20989 on the isolated test simulator verified `rabbbena` + Enter + Backspace, selecting `rabbena`, then `okudum` + Enter: correct tokens and pair recorded once, typo history/personal entries zero. See `audits/everyday-20261025-native-rabbena.json`.

Pinned-source recognition improved from 168 to 167 missing raw surfaces, with only `rabbena` gained and no losses. All 36 deferred manual decisions are now resolved; this does not establish exhaustive Turkish coverage. Latest full code suite predates this data-only addition; scoped pack, runtime, duplicate, build and native validations cover the addition. Continuous mixed-scenario testing and the physical-phone learning investigation remain open.

### 2026-10-25 — Stray internal-space suggestion

Native `akşam gele cek` exposed a missing join offer: only `cek`, `çek`, `cem` appeared. `WholeWordSuggestion` now scans the immediately preceding letter token across exactly one ASCII space and offers a dictionary-recognized concatenation when at least one fragment is unknown. Both parts must contain at least two letters; valid two-word phrases, line/tab/multiple-space boundaries, technical punctuation, sentence-case discontinuities, secure fields and selections are excluded. Original text remains the first choice, automatic correction is unchanged, and existing host-context validation and recorded replacement handle selection. Eight focused tests passed, including `gelecek misin`, `ev de`, `bir şey`, and `bu gün` negative controls.

Build and two native runs passed on isolated simulator PID 23590. `akşam gele cek` → `akşam gelecek misin` records each correct token and pair once and cancels the fragments. `bilgisa yar` + Enter/Backspace → selected `bilgisayar`, deleting the space and final letter and retyping it also records only one correct token, with all fragments absent from history/personal learning. Reports: `audits/everyday-20261025-native-stray-space-after.json` and `audits/everyday-20261025-native-stray-space-reedit.json`. Full regression suite is still running in session 58172; do not treat this entry as full-suite completion.

Stray-space follow-up: full suite passed (795 XCTest, 97 opt-in skips, zero failures, 319.086 seconds; 406 Swift Testing tests, 54 suites, 4.610 seconds). Native titlecase `Gele cek` → `Gelecek misin` and real phrase `bir şey` controls also passed. User explicitly requested physical-phone installation; the current Release build was installed in place and successfully launched on paired iPhone 00008120-0002382C2EC0201E. No uninstall or learning-data reset was performed. Deployment log: `audits/everyday-20261025-phone-deploy.log`.
