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
| Kelime bigramı (`F_ctx`) | ❌ |
| Kişisel sözlük, korpus içe aktarımı | ❌ |
| Emoji, temalar, VoiceOver | ❌ |

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

Aynı disiplin kodda da var: yorumlar *neden* böyle olduğunu, ve çoğu zaman
*hangi alternatifin neden yanlış olduğunu* anlatıyor.

## Yapı

```
Packages/KeyboardCore/          saf Swift, UIKit'siz, macOS'ta test edilir
  KBGeometry                    layout, normalize koordinat
  KBSpatial                     uzamsal likelihood + kalibrasyon durumu
  KBLexicon                     form trie, karakter n-gram, genişletme haritası
  KBMorphology                  kök trie, morfotaktik, fonoloji
  KBDecoder                     beam search, literal kanalı, oracle
  KBRuntime                     girdi koordinatörü, host senkronizasyonu
  KBLearning                    kalibrasyon öğrenimi ve kalıcı depo
Apps/BestKeyboardExtension/     UIInputViewController — ince adaptör
Apps/BestKeyboard/              ana uygulama + tezgah
Tools/packbuild                 TSV → binary paket
Tools/kbbench                   gecikme ve doğruluk ölçümü
Tools/kbdiag                    teşhis (θ taraması, ölçek uyumu, kalibrasyon)
```

Karar mantığının tamamı `KBRuntime`'da; `UIInputViewController` yalnız dokunmayı
iletip sonucu çiziyor. Sebep test edilebilirlik: UIKit içindeki hiçbir şey
`swift test` altında koşmuyor.

## Çalıştırma

```bash
swift test --package-path Packages/KeyboardCore   # 279 + 75 test
./Tools/build-packs.sh                            # dil paketleri
./Tools/deploy.sh                                 # iPhone'a derle-yükle-başlat
```

Ölçüm araçları:

```bash
swift run -c release --package-path Tools/kbbench kbbench --root-pack LanguagePacks/tr-TR/tr-TR.bkr
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
