# BestKeyboard

iPhone için Türkçe akıllı klavye. Bugünkü klavyelerden farkı: **basılan harfi
değil, dokunma koordinatını** kaydeder ve kelimeyi dokunma dizisi üzerinde
sıraya sadık bir aramayla bulur.

Kanonik vaka:

```
l s l e m   →   kalem        ("işlem" DEĞİL)
```

`l→k` ve `s→a` Türkçe Q'da komşu, `l→i` ve `s→ş` uzak. Sıra korunduğu için
karşılaştırma pozisyon pozisyon yapılır.

Sistem ayrıca kullanıcının yazımından **kendi kendini kalibre eder**: parmağın
sistematik sapmasını öğrenip tuş merkezlerini kaydırır.

## Durum

Çalışan bir iPhone klavyesi. Günlük kullanılabilir; App Store'a hazır değil.

| Bileşen | Durum |
|---|---|
| Uzamsal decoder (beam search, log-linear skor) | ✅ |
| Türkçe morfoloji (36.7k kök, 99 ek, çatı, sıfat-fiil, yapım ekleri) | ✅ |
| Meslek jargonu (tıp, hukuk, mühendislik, finans, tarım…) | ✅ 12 alan |
| Okunuşa göre ek (`sql'leri`, `iPhone'dan`) | ✅ |
| Açık-vocabulary literal kanalı (karakter n-gram) | ✅ |
| Çoklu dil (tr + en, tek layout, aynı beam) | ✅ |
| Parmak sapması kalibrasyonu (global + satır + tuş) | ✅ |
| Argo/kısaltma katmanı + genişletme haritası | ✅ |
| Shift, caps-lock, rakam/sembol düzlemleri | ✅ |
| Harf düzleminde nokta (basılı tutunca virgül) | ✅ |
| Boşlukta imleç sürükleme (kelime / kelime içi) | ✅ |
| Klavyeyi kapatma tuşu | ✅ |
| Seçilen kelimeyi düzenleme | ✅ |
| Tema (sistem/açık/koyu) | ✅ |
| Ayarlanabilir ⇧/⌫/boşluk ölçüleri, üst sayı sırası | ✅ |
| Ayarlanabilir ⌫ basılı tutma kademeleri | ✅ |
| Kişisel sözlük + korpus içe aktarımı | ✅ |
| Emoji (kategoriler + son kullanılanlar) | ✅ |
| Kelime bigramı (`F_ctx`) | ◐ mekanizma hazır, **veri yok** |
| VoiceOver | ✅ yazma, öneri, kelime silme |

`kalemlerimizden` gibi hiçbir korpusta geçmeyen formlar morfolojiden türetilir.

**`F_ctx` neden ◐:** paket formatı, decoder entegrasyonu, oracle karşılığı ve
üretim aracı hazır ve testli; eksik olan tek şey **Türkçe bigram verisi**.
Uydurulmuş bir tablo koymak, ölçülmemiş bir modeli ölçülmüş gibi göstermek
olurdu. Paket yokken `F_ctx ≡ 0` ve motor bugünkü davranışını birebir koruyor
(§8.8).

## Yöntem

Projenin merkezinde **tek bir normatif belge** var:
[`docs/00-score-contract.md`](docs/00-score-contract.md). Skor modelinin tanımı
yalnız oradadır; başka hiçbir dosya kendi maliyet tanımını yapmaz.

Belge ölçümlerle büyüdü ve **çürütülen varsayımları da kaydediyor**. §9'un açık
soru listesinde artık yalnız **veri bekleyen** iki madde var; kod ve otomat
soruları kapandı (üçü ölçümle, biri üst sınırla) ve hepsinin arkasında Faz 4'te
yeniden koşacak bir test duruyor:

- **§8.1 → §8.1.1** — sözlük dışı kelimeler için eşik seçilemiyor sanılmıştı.
  Ölçümün kendisi hatalıydı: dokunmalar iki ailede de tam tuş merkezine
  konuyordu, yani aileleri ayıran uzamsal sinyali ölçüm siliyordu. Gerçekçi
  dokunmalarla eşik bulundu — typo'ların %82'si düzeliyor, doğru yazılmış
  kelimelerin %0'ı bozuluyor.
- **§8.3 → §8.6** — global kalibrasyon ortalamada +5.8 puan kazandırıyor ama
  "en kötü tuşta 8.3 puan kaybettiriyor" deniyordu. **O sayı geri çekildi:**
  metrik tuş başına 8 kelimeye bakıyordu, orada tek kelime 12.5 puan oynatır;
  üstelik kelimenin decode başarısını ilk harfinin tuşuna yazıyordu. Yerine
  doğrudan atfedilebilir bir uzamsal ölçüm kondu.
- **§8.6** — hiyerarşik kalibrasyonun (`b_c = g + r_row + d_c`) ilk hâli elle
  seçilmiş bir shrinkage sabiti kullanıyordu; ölçüm bunu çürüttü. Sabit bir
  katsayı *"bu kullanıcıda tuş yapısı var mı"* sorusunu soramıyor, artığı yapı
  sanıp gürültüye uyuyordu — yapısı tamamen global olan kullanıcıda 1 puan
  **kaybettiriyordu**. Yerine katsayının veriden kestirildiği ampirik Bayes
  kondu. Aynı bölümde simülatörün birim hatası ve kirli eğitim etiketleri de
  kayıtlı: ikisi de deneyi sessizce kendi lehine çeviriyordu.
- **§8.4** — iOS'un `selectionDidChange`'i üçüncü taraf klavyeye **hiç
  gelmiyor**; cihazda ölçüldü.
- **§8.6 (devretme)** — kayıt tamponu 512 KB'ı geçince kaydedici yeni denemeye devrediyor
  ve koordinatörü sıfırdan kuruyordu. Kalibrasyon yalnız paket yüklemesinde ve
  profil değişiminde uygulandığı için **yeterince yazan kullanıcı öğrenilmiş
  sapmasını sessizce yürürlükten düşürüyordu** — dosya diskte duruyordu, o
  yüzden "kayboldu" diye de görünmüyordu.
- **§8.9** — VoiceOver etkinleştirmesinin **koordinatı yok**; tuş merkezini
  gözlem saymak, sapması tanım gereği sıfır olan örneklerle öğrenilmiş parmak
  sapmasını sıfıra çekerdi. Aynı hata §8.1.1'de bir ölçümü bozmuştu; burada
  ürünü bozardı. Kanıtın türetilmiş olduğu motora kadar taşınıyor.
- **§8.9 (yarım token)** — bunu yazarken çıkan ayrı bir hata: kaydedici kelime
  ortasında bırakıldığında yedek koordinatör **boş** başlıyor ve yüzeyin yalnız
  yeni kısmını kendi token'ı sanıyordu. Parçaya otomatik düzeltme uygulanıyor,
  ve `kalem` önerisi belgeyi `lslkalem` yapıyordu. VoiceOver yeni bir
  tetikleyiciydi; kusur yazma hatası yolunda zaten vardı ve görülmemişti.
- **§8.10** — nokta tuşu 3. satırı 10 yuvaya böldü ve harfleri %10 daralttı.
  Bedeli **ölçmedik, çünkü ölçemeyiz**: simülatör parmak sapmasını tuş
  genişliğinden üretiyor, yani tuş daralınca simüle parmak da daralıyor ve
  benchmark "fark yok" diyor. §8.1.1'in aynı tuzağı; sayı uydurmak yerine
  ölçülemediği yazıldı.
- **§8.12** — morfoloji grafı genişletilirken top-1 düştü ve sebep ölçümle bulundu:
  geniş zaman ile ettirgen seçimi **sözlüksel** (`gel-ir` ama `yaz-ar`), iki yüzeyi
  birden üretmek her fiile yanlış aday ekliyor. Yani kök özellik alanları
  morfotaktik genişlemenin **önkoşuluymuş** — planlanan sıra yanlıştı ve
  ölçüm onu tersine çevirdi.
- **§9 (`surfaceId`)** — beam bedelinin "yüzde birkaç" olduğu tahmin ediliyordu;
  ölçüm çürüttü. Gerçek pakette morfoloji beam'i **1.6 katına** çıkıyor, tutulan
  morfoloji yuvalarının %37'si yalnız yüzey ayrımı için duruyor. Ölçümün ilk
  tasarımı da çürüdü: budamasız decode üretim ölçeğinde hiç bitmiyor, yani o
  rejimde ölçüm yapılamıyor.
- **§8.7** — kişisel sözlükteki kelimenin maliyeti önce "paketin en nadir
  kelimesinden nadir" diye çıpalanmıştı (14.6 nat). Gerekçe tutarlıydı, ölçüm
  çürüttü: o değerde kullanıcı kendi kelimesini dikkatle yazdığında bile yalnız
  **%56'sı** geri geliyordu. Tarama, korktuğumuz zararın (kişisel kelimenin
  paket kelimesini çalması) 14.6–10.0 aralığında **tam olarak sıfır** olduğunu
  gösterdi; çıpa o platonun içinden seçildi ve tanınma %96'ya çıktı.

Aynı disiplin kodda da var: yorumlar *neden* böyle olduğunu, ve çoğu zaman
*hangi alternatifin neden yanlış olduğunu* anlatıyor.

## Yapı

```
Packages/KeyboardCore/          saf Swift, UIKit'siz, macOS'ta test edilir
  KBGeometry                    layout, normalize koordinat, tuş ölçüleri
  KBSpatial                     uzamsal likelihood + kalibrasyon durumu
  KBLexicon                     form trie, karakter n-gram, genişletme, bigram
  KBMorphology                  kök trie, morfotaktik, fonoloji
  KBDecoder                     beam search, literal kanalı, oracle
  KBRuntime                     girdi koordinatörü, host senkronizasyonu
  KBLearning                    kalibrasyon + kişisel sözlük, kalıcı depolar
Apps/BestKeyboardExtension/     UIInputViewController — ince adaptör
Apps/BestKeyboard/              ana uygulama + tezgah
Tools/packbuild                 TSV → binary paket
Tools/kbbench                   gecikme ve doğruluk ölçümü
Tools/kbdiag                    teşhis (θ taraması, ölçek uyumu, kalibrasyon)
```

Karar mantığının tamamı `KBRuntime`'da; `UIInputViewController` yalnız dokunmayı
iletip sonucu çiziyor. Sebep test edilebilirlik: UIKit içindeki hiçbir şey
`swift test` altında koşmuyor.

## Ayarlar

Tema (sistem/açık/koyu), üst sayı sırası, `⇧` / `⌫` / boşluk genişliği, boşluk
satırının yüksekliği, `⌫` basılı tutma kademeleri (tekrar gecikmesi, karakter
ve kelime aralığı, kelimeye geçiş eşiği).

Yükseklik ayarı **satırın**, tek tuşun değil: yalnız boşluğu uzatmak onu üstteki
harf satırının üstüne bindirirdi — düzelttiğimiz hatanın aynısı. Satır uzayınca
klavye büyüyor, harf satırları fiziksel yüksekliğini koruyor.

Bazı ölçüler yalnız çizimi değil **modelin girdisini** değiştiriyor: `⇧`
genişleyince 3. satırın harfleri daralır ve merkezleri kayar. Bu yüzden ölçüler
`KBGeometry`'de ve harf geometrisini değiştirenler `KeyLayout.id`'ye giriyor —
o durumda kalibrasyon profili de değişiyor, bir geometride öğrenilen parmak
sapması diğerine uygulanmıyor. Boşluk genişliği 4. satırda kaldığı için
kimliğe **girmiyor**; girseydi boşluğu bir kademe genişleten kullanıcı
öğrendiklerini kaybederdi.

Zamanlama ayarları geometri değil: kalibrasyon profiline ve decoder'a
dokunmuyorlar, o yüzden değiştirmek hiçbir şeyi yeniden kurmuyor.

Panelde ayrıca **kişisel sözlük** duruyor: klavyenin senden öğrendiği kelimeler
ve her birinin yanında sil.

## Kişisel sözlük

Sözlükte olmayan bir kelimeyi (adın, lakabın, bir marka) boşlukla kapatarak üç
kez yazdığında klavye onu öğreniyor. Sonrasında kelime **bilinen kelime**
sayılıyor: bir daha otomatik düzeltilmiyor, ve yanlış bastığın bir harften geri
kurtarılabiliyor.

Öğrenme koşulu bilinçli olarak dar: kanıt sayılması için klavyenin o token'ı
**gerçekten yargılamış ve düzeltmemiş** olması gerekiyor. E-posta alanı, `@ali`
gibi korumalı token'lar ve parola alanları hiç kanıt üretmiyor — oralarda karar
hiç sorulmadı, dolayısıyla "değiştirmedi" bir şey kanıtlamıyor.

Bir metinden toplu öğretmek de mümkün: kendi yazdığın bir metni herhangi bir
alana yapıştır, ⚙︎ → **Bu alandaki metinden öğren**. Metinde en az üç kez geçen
ve sözlükte olmayan kelimeler öğreniliyor. Panoyu okumuyor — klavyenin zaten
gördüğü alan metnini okuyor, dolayısıyla Tam Erişim gerekmiyor. iOS klavyeye
belgenin tamamını değil bir **pencere** verdiği için uzun metinleri parça parça
vermek gerekebilir; kaç kelime okunduğunu panel yazıyor.

Yanlış bir kelime öğrenilirse ⚙︎ panelinden siliniyor; öğrenilen kelime
korunduğu için silinebilir olması şart.

Saklanan tek şey kelimenin kendisi ve kaç kez doğrulandığı — dokunma
koordinatı, zaman damgası ya da hangi uygulamada yazıldığı **değil**. Dosya
uzantının kendi sandbox'ında ve yedeğe gitmiyor.

Kelimenin ne kadar "olası" sayılacağı ölçümle seçildi: fazla ucuz olursa senin
kelimen başka kelimelerin yerini çalar, fazla pahalı olursa yazdığında geri
gelmez. Ölçüm zararın sıfır olduğu geniş bir aralık gösterdi (§8.7) ve değer o
aralığın içinden alındı — tanınma dikkatli yazımda %96, günlük yazımda %81.

## Emoji

Öneri çubuğundaki 🙂 emoji yüzeyini açıyor: kategoriler, son kullanılanlar ve
`ABC` ile geri dönüş. Son kullandıkların başa alınıyor.

**Tuş ızgarasında değil, örtü katmanda** — ve bu bir tasarım tercihi değil,
zorunluluk: tuş satırlarına bir yuva eklemek bütün harf merkezlerini kaydırır,
`layoutID` değişir ve öğrendiğin parmak sapması başka bir kovaya düşerdi. Emoji
düğmesinin ⚙︎ ve kayıt düğmesinin yanında durmasının sebebi de aynı.

Emoji **kod çözmeye girmiyor** (rakam ve sembollerle aynı gerekçe: leksikonu
yok, komşuluk düzeltmesi istenmez) ve girişi sembol yolundan geçiyor —
dolayısıyla bir kelime sınırı, ve kayıt onu görüyor.

Deri tonu varyantları ve bayraklar yok: ilki ayrı bir seçici UI istiyor,
ikincisi doğru yapılması için Unicode'un RGI listesinin tamamını (250+ bölge)
gerektiriyor ve elle yazılmış bir alt küme hem eksik olurdu hem de "hangileri"
sorusunu bir küratör kararına çevirirdi. İkisi için de globe tuşu sistem
klavyesini veriyor.

**Bu sürüme geçerken kalibrasyon sıfırlanıyor.** 3. satırın geometrisi düzeldi
(`⇧`/`⌫` artık harflerin üstüne binmiyor), yani tuş merkezleri gerçekten
değişti; eski `tr-Q` profilinde öğrenilen parmak sapması yeni geometride yanlış
olurdu. Profil kimliği bilerek değişiyor ve öğrenme baştan başlıyor.

Kayıt ekranı da bu ayarları kullanıyor: kaydın amacı gerçek yazım davranışını
yakalamak ve kayıttan çıkarılan kalibrasyonun kullanıcının **günlük kullandığı**
profile gitmesi. Hangi geometride kaydedildiği `layoutID` ve `layoutFingerprint`
ile kayda yazılıyor, dolayısıyla iki kaydın aynı zeminde olup olmadığı okunabilir
bir olgu.

Ayarlar uzantının kendi sandbox'ında duruyor; kalibrasyonla aynı gerekçe (tek
yazar, App Group yok). Bu yüzden asıl panel klavyenin kendi yüzeyi: klavye
üstündeki ⚙︎. Ana uygulamadaki **Klavye ayarları** ekranı aynı ayarları canlı
önizlemeyle sunuyor ama uygulamanın kendi kopyasına yazıyor — tezgahı etkiler,
uzantıyı etkilemez.

## Nokta tuşu ve klavyeyi kapatma

`ç`'nin yanında bir nokta tuşu var; **basılı tutunca virgül** yazıyor (eşik
`⌫`'nin basılı tutma gecikmesiyle aynı, eşik geçilince tuşun üstündeki yazı da
`,` oluyor). İkisi de `123`'e geçmeden yazılabiliyor.

Bunun bir bedeli var ve gizlenmiyor: satır 11 birimlik sabit bir bütçe, yeni
yuva harflerden alındı ve **her harf tuşu %10 daraldı**. Genişliği `⇧`/`⌫`'den
almak mümkündü ve alınmadı — o iki tuşta yapılan hata düzeltilemez (yanlış
basılan `⌫` bir karakter siler), harfte yapılan hata ise decoder'ın zaten
çözdüğü şey.

Daralmanın gerçek etkisi **ölçülmedi, çünkü ölçülemiyor**: benchmark'ın simüle
parmağı sapmasını tuş genişliğinden alıyor, yani tuş daralınca parmak da
daralıyor ve ölçüm "fark yok" diyor (§8.1.1'in aynı tuzağı). Gerçek parmak
daralmıyor. Sayı uydurmak yerine ölçülemediği yazıldı; gerçek bedel §12'nin
dokunma verisiyle görülecek.

Geometri değiştiği için **öğrenilmiş kalibrasyon sıfırlanıyor**. `⇧` ve `⌫`
değişmediğinden eski profil kimliği yeni geometriye birebir benziyordu ve
sessizce bağlanırdı; kimliğe kuşak damgası (`-g2`) eklendi ve eski profiller
artık eşleşmiyor. Kayıp bilinçli — alternatif, 0.889 birimlik tuşlarda
öğrenilen sapmayı 0.80 birimlik tuşlarda doğru sanmaktı.

## Boşlukta imleç sürükleme

Boşluğu basılı tutup sürükleyince imleç geziyor:

- **Sağa/sola** → kelime kelime.
- **Yukarı/aşağı** → o kelimenin **içinde**, karakter karakter. İmleç
  kelimenin dışına çıkmıyor: parmağını ne kadar götürürsen götür sınırda
  duruyor, geri gelince oradan devam ediyor.

Aynı jestte **yalnız bir eksen** çalışıyor; ilk hareket hangisiyse o kilitleniyor
ve parmak kalkana kadar öyle kalıyor. İkisi birlikte çalışsaydı parmak hiçbir
zaman saf yatay gitmediği için kelime atlarken imleç kelimenin içinde de kayar,
kullanıcı hangi hareketin ne yaptığını ayırt edemezdi.

Kip basılı tutunca açılıyor (eşik `⌫` ile aynı) ve açıldığında boşluğun yazısı
`◂ ▸` oluyor. İmleç oynadıysa parmağı kaldırınca boşluk yazılmıyor; oynamadıysa
jest sıradan bir boşluk basışı olarak bitiyor.

VoiceOver'da sürükleme diye bir şey yok, o yüzden boşluk tuşunda iki özel eylem
var: **bir kelime geri**, **bir kelime ileri**. Dikey eksenin karşılığı bilerek
yok — VoiceOver metni karakter karakter zaten gezdiriyor.

Kip açıkken jest **klavyenin tek sahibi**: ikinci bir parmak yazamıyor. Jest
belgeyi jest başında okunmuş sabit bir bağlama göre hesaplıyor ve araya giren
bir harf onu geçersiz kılardı — ayrıca imleci konumlandırırken kazara değen bir
parmağın metne karakter sokması, jestin engellemek için var olduğu şey.

**Kayıt sırasında bu jest denemeyi kapatıyor.** İmleç hareketinin kayıt
komutlarında karşılığı yok ve uydurulmuş bir ofset başka bir belgede başka bir
yeri gösterirdi; kayıt ekranında jest hiç açılmıyor.

Öneri çubuğunda ayrıca bir **⌄ kapatma tuşu** var. Bazı host'larda klavyeyi
indirmenin başka yolu yok ve klavye ekranın yarısını kaplayıp duruyor. Yeri
çubuk, ızgara değil: oraya bir yuva daha eklemek harf merkezlerini bir kez daha
kaydırırdı ve kapatma tuşu o bedeli hak edecek kadar sık kullanılmıyor.

## VoiceOver

Tuşlar okunuyor ve çift dokunuşla yazıyor; öneri çubuğu, ⚙︎, 🙂, ⌄ ve kayıt
düğmesi de gezilebiliyor. İki tuşta özel eylem var — ikisi de basılı tutmanın
karşılığı, çünkü VoiceOver'da parmak tuşun üstünde durmuyor: `⌫` üzerinde
**kelimeyi sil**, nokta üzerinde **virgül**.
Düzlem değişince (`123`, `#+=`, `ABC`) ekran okuyucuya yeni yüzey bildiriliyor.

⚙︎ ve 🙂 panelleri açıkken klavye ekran okuyucudan da **kapanıyor**. Görsel
olarak zaten kapalıydı ama erişilebilirlik ağacında duruyordu: kaydırarak
görünmeyen bir tuşa ulaşıp harf yazmak mümkündü. Bu eksiklik tuşlar
etkinleştirilemezken zararsızdı — yeni özellik onu işler hâle getirdi.

⚙︎ panelinde her denetim **kendi adını** söylüyor. Etiketler ayrı öğeler
olduğu için sürgüler isimsiz bir yüzde, anahtarlar isimsiz bir "açık" okuyordu;
en kötüsü kişisel sözlüktü — arka arkaya beş tane "sil, düğme" ve hangisinin
hangi kelimeye ait olduğu yalnız ekrana bakınca belli. Yıkıcı bir eylemde bu,
yanlış kelimeyi silmek demek. Her düğme artık kelimesini taşıyor.

**Otomatik düzeltme VoiceOver'la yazarken kapalı.** Sebebi bir tercih değil:
etkinleştirmenin dokunma koordinatı yok, olan tek şey hangi tuşun seçildiği.
Klavye o harfin koordinatı olarak tuşun merkezini kullanmak zorunda, ve tam
merkeze konan dokunmalarla hesaplanan bir `Δ` gerçek bir parmak kanıtını temsil
etmiyor. Kullanıcı zaten her tuşu **duyarak** seçiyor; orada düzeltilecek bir
kayma yok. Öneriler görünmeye devam ediyor — dokunursan uygulanıyor (§8.9).

Aynı sebeple bu yazımdan **kalibrasyon öğrenilmiyor**: sapması tanım gereği
sıfır olan dokunmalar, öğrenilmiş parmak sapmasını sessizce sıfıra çekerdi.

İki bilinen sınır, ikisi de aynı olgudan:

- Bu yolla klavyeye yeni kelime **öğretilemiyor** (kişisel sözlük kanıtı
  "reddedilmiş düzeltme" demek ve burada düzeltme hiç denenmiyor). ⚙︎ →
  **Bu alandaki metinden öğren** çalışmaya devam ediyor.
- VoiceOver açıkken **kayıt tutulmuyor**. Kayıt her harfe bir dokunma olgusu
  bağlıyor; tuş merkezini "ham koordinat" diye yazmak, ölçmek için topladığımız
  verinin içine uydurulmuş bir gözlem koymak olurdu.

Erişilebilirlik ağacı **gerçek bir istemciyle** sınanıyor: `AccessibilityUITests`
etiketleri, shift'i izleyen harf etiketini ve düzlem değişimini XCUITest ile
okuyor — VoiceOver'ın kullandığı yoldan. Cihazda VoiceOver turunun yerini
tutmuyor, aradaki boşluğu daraltıyor.

Ölçülmedi: VoiceOver'la yazma hızı ya da doğruluğu hakkında bir sayımız yok.
Yapılan iş klavyeyi kullanılabilir kılmak ve modelin bozulmamasını garantiye
almak; kazanç iddiası yok.

## Çalıştırma

```bash
swift test --package-path Packages/KeyboardCore   # 381 + 368 test
xcodebuild test -project Apps/BestKeyboard.xcodeproj -scheme BestKeyboard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'   # 9 UI testi
./Tools/build-packs.sh                            # dil paketleri
./Tools/deploy.sh                                 # iPhone'a derle-yükle-başlat
```

Ölçüm araçları:

```bash
swift run -c release --package-path Tools/kbbench kbbench --root-pack LanguagePacks/tr-TR/tr-TR.bkr
swift run -c release --package-path Tools/kbbench kbbench --personal \
                                                          --root-pack LanguagePacks/tr-TR/tr-TR.bkr
swift run -c release --package-path Tools/kbbench kbbench --beam-sweep \
                                                          --root-pack LanguagePacks/tr-TR/tr-TR.bkr
swift run -c release --package-path Tools/kbdiag  kbdiag  --theta LanguagePacks/tr-TR/tr-TR.bkt \
                                                          LanguagePacks/tr-TR/tr-TR.bkc
```

**`-c release` şart.** Decoder saf Swift beam search; `-Onone` altında tuş başına
p50 12.44 ms ölçülüyor, `-O` altında 0.95 ms. Debug ile ölçülen hiçbir gecikme
sayısı anlamlı değil.

## Performans

Sözleşme tuş başına p99 < 8 ms istiyor. Ölçülen (**release**; 70k form + 30k kök +
60k İngilizce form):

| | p50 | p99 |
|---|---|---|
| tuş başına | 0.92 ms | **1.40 ms** |
| literal kanalı (token başına) | 0.011 ms | 0.026 ms |

İkinci dil gecikmeyi artırmıyor; doğruluk bedeli ölçüldü ve belgede (§8.2)
kayıtlı.

`beamWidth = 128` artık bir varsayılan değil **ölçülmüş çalışma noktası**:
tarama 128 → 1024 arasında top-1'in yalnız **+0.50 puan** arttığını, buna
karşılık gecikmenin altı katına çıktığını gösterdi (`kbbench --beam-sweep`).
Eğri 256'dan sonra fiilen düz.

Aynı iş yükü `-Onone` ile **13 kat** yavaş (p50 12.44 ms). `deploy.sh` uzun süre
varsayılan olarak Debug kuruyordu — cihazdaki "hafif yavaşlık" hissinin sebebi
buydu, kodun kendisi değil. Varsayılan artık Release; Debug `--debug` ile
alınıyor ve klavye durum satırında `⚠︎DEBUG` yazıyor.

## Cihaza yükleme

```bash
./Tools/fix-signing.sh     # BİR KEZ: codesign'a anahtar erişimi ver
./Tools/deploy.sh          # paket üret → derle → yükle → aç
./Tools/deploy.sh --help   # seçenekler ve ön koşullar
```

Xcode açmaya gerek yok. Tek seferlik ön koşullar (script kontrol eder, kendisi
yapamaz):

1. iPhone'da **"Bu bilgisayara güven"**
2. iPhone: Ayarlar → Gizlilik ve Güvenlik → **Geliştirici Modu** → aç → yeniden başlat
3. Xcode → Settings → Accounts → **Apple ID ekle** — sertifikayı Apple'ın
   sunucusundan yalnız Xcode alabildiği için kaçınılmaz. Bir kereliktir.
4. `./Tools/fix-signing.sh`

Kablosuz için ayrıca bir şey gerekmiyor: Xcode 15+ eşleşmiş ve Geliştirici Modu
açık cihazlarda ağ bağlantısını kendiliğinden kurar. Ücretsiz (Personal Team)
hesapla imzalanan uygulama **7 gün** sonra açılmaz.

## Lisans

**İki ayrı rejim** — ayrımı bilerek koruyoruz.

- **Kod** (`Packages/`, `Apps/`, `Tools/`): telifi bize ait. Veriden bağımsız
  bir eser; aşağıdaki veri lisansları koda geçmez.
- **Dil verisi** (`LanguagePacks/**/wordlist.tsv` ve onlardan üretilen `.bkt`
  paketleri): **CC BY-SA 4.0**. Kaynaklar ve yapılan değişiklikler
  [`LICENSES.md`](LICENSES.md)'de.
- **Kök sözlüğü** (`roots.tsv`): Zemberek'ten türetilmiş, **Apache-2.0** —
  share-alike yok.
- **Argo listesi** (`informal.tsv`, `expansions.tsv`): elle küratörlü, hiçbir
  korpustan türetilmedi.

Bu depo aynı zamanda CC BY-SA'nın **share-alike** yükümlülüğünü karşılıyor:
türetilmiş listeler ve paketler burada herkese açık ve DRM'siz duruyor.
Ticari kullanım serbesttir.

## Ortam

Xcode 26.5 · Swift 6.3.2 · iOS klavye uzantısı (App Extension)

## Katkı

Bu kişisel bir proje ve dış katkıya açık değil. Kodu okumak, ölçüm
yöntemlerini ödünç almak ve dil verisini CC BY-SA koşullarıyla kullanmak
serbest.
