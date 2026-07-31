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
| Türkçe morfoloji (30k kök, ünlü uyumu, yumuşama, ünlü düşmesi) | ✅ |
| Açık-vocabulary literal kanalı (karakter n-gram) | ✅ |
| Çoklu dil (tr + en, tek layout, aynı beam) | ✅ |
| Parmak sapması kalibrasyonu (global + satır + tuş) | ✅ |
| Argo/kısaltma katmanı + genişletme haritası | ✅ |
| Shift, caps-lock, rakam/sembol düzlemleri | ✅ |
| Seçilen kelimeyi düzenleme | ✅ |
| Tema (sistem/açık/koyu) | ✅ |
| Ayarlanabilir ⇧/⌫/boşluk ölçüleri, üst sayı sırası | ✅ |
| Ayarlanabilir ⌫ basılı tutma kademeleri | ✅ |
| Kişisel sözlük + korpus içe aktarımı | ✅ |
| Kelime bigramı (`F_ctx`) | ❌ |
| Emoji, VoiceOver | ❌ |

`kalemlerimizden` gibi hiçbir korpusta geçmeyen formlar morfolojiden türetilir.

## Yöntem

Projenin merkezinde **tek bir normatif belge** var:
[`docs/00-score-contract.md`](docs/00-score-contract.md). Skor modelinin tanımı
yalnız oradadır; başka hiçbir dosya kendi maliyet tanımını yapmaz.

Belge ölçümlerle büyüdü ve **çürütülen varsayımları da kaydediyor**:

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
  KBLexicon                     form trie, karakter n-gram, genişletme haritası
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

## Çalıştırma

```bash
swift test --package-path Packages/KeyboardCore   # 331 + 323 test
./Tools/build-packs.sh                            # dil paketleri
./Tools/deploy.sh                                 # iPhone'a derle-yükle-başlat
```

Ölçüm araçları:

```bash
swift run -c release --package-path Tools/kbbench kbbench --root-pack LanguagePacks/tr-TR/tr-TR.bkr
swift run -c release --package-path Tools/kbbench kbbench --personal \
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
