# Skor Sözleşmesi

> **Bu belge normatiftir.** Decoder'ın maliyet tanımı yalnız burada yapılır. Kod ve diğer
> dokümanlar buraya referans verir, kendi tanımını yapmaz.
>
> Faz -1A₀ çıktısı. Bu belge sabitlenmeden beam veri yapılarına ve performans mimarisine
> başlanmaz.

## 1. Model tipi

**Koşullu log-linear (ağırlıklı FST) skor modeli.** Normalize edilmiş üretici bir olasılık
modeli *değildir*; `P(T, A | w)` kurulmaz.

Gerekçe:

- Türkçe morfoloji **sınırsız üretkendir**. Onu proper bir olasılıksal otomata çevirmek sonlu
  partition function ve neredeyse-kesin sonlanma ispatı ister. Bu bir ürün işi değil.
- **Kalibre olasılığa ihtiyaç yok.** Gereken (a) iyi bir *sıralama*, (b) **tek** kalibre karar
  noktası: commit eşiği `θ`. `θ` held-out veride yanlış-düzeltme oranı hedefiyle ayarlanır.

Sonuçları:

- Yasal olmayan olaylar maskelenir, kalanlar **yeniden normalize edilmez**.
- `min_A` bir yaklaşım değil, **skorun tanımıdır**.
- Dil sıcaklık/offset'i ve backoff skorları meşru ağırlık kalibrasyonudur.

### Bağlayıcı dört disiplin

1. **Tek sahiplik** — hiçbir kanıt iki özniteliğe birden girmez (§2).
2. **Tek kalibre karar** — kullanıcının hissettiği tek şey `θ`; kalibrasyonu ölçülür.
3. **Prefix-causality** — bir geçişin maliyeti yalnız `touchIndex`, **geçmiş** ve o geçişin
   *kendi tükettiği* gözlemlere bağlıdır. Gelecekteki gözleme bağlı öznitelik **yasaktır** (§3).
4. **Sonlanma ve alt sınır** — emisyon-only yollar sonlu, her emisyonun net maliyeti kesin
   pozitif olmalıdır (§2.5). Bu sağlanmadan negatif `w_len` kullanılamaz.

---

## 2. Öznitelik vektörü

```
cost(w, A, ℓ | T, ctx) = Σ_k  w_k · F_k
cost(w, ℓ)             = min_A cost(w, A, ℓ | T, ctx)        ← skorun TANIMI
```

**Düz vektör, tek seviyeli katsayılar.** Dış grup ağırlığı × iç ağırlık kullanılmaz — o kombinasyon
gauge serbestliği yaratır.

**Ölçek sabitleme:** `w_spa ≡ 1` ve `offset_tr ≡ 0`.

| # | Öznitelik | Tip | Ağırlık | Tanım |
|---|---|---|---|---|
| 1 | `F_spa` | sürekli | **≡ 1** | `Σ −log p(t_i \| key(c_j))` — doğrudan SUB ve TR üzerinden |
| 2 | `F_spa_eq` | sürekli | `w_spa_eq` | `Σ −log p(t_i \| key(base(c_j)))` — **eşdeğerlik** SUB'ları üzerinden (§2.4) |
| 3 | `F_eq` | sayaç | `w_eq` | eşdeğerlik ikamesi sayısı |
| 4 | `F_om_gem` | sayaç | `w_om_gem` | `c_j == c_{j−1}` (**pozisyonel**, emisyon sırası değil) |
| 5 | `F_om_init` | sayaç | `w_om_init` | `j == 1` (kelime başı) |
| 6 | `F_om` | sayaç | `w_om` | diğer atlamalar |
| 7 | `F_ins_near` | sayaç | `w_ins_near` | `Δt(i,i−1) < τ_fast` **ve** `dist(i,i−1) < d_near` |
| 8 | `F_ins` | sayaç | `w_ins` | diğer fazla dokunmalar (`i == 1` **daima** bu sınıfa girer) |
| 9 | `F_ins_bg` | sürekli | `w_ins_bg` | `Σ −log p_bg(t_i)` fazla dokunmalar üzerinden |
| 10 | `F_tr` | sayaç | `w_tr` | transposition sayısı |
| 11 | `F_len` | sayaç | `w_len` | **emisyon sayısı `m`** |
| 12 | `F_lex` | sürekli | `w_lex` **> 0** | yüzey formunun ham leksikal özniteliği (§7) |
| 13 | `F_ctx` | sürekli | `w_ctx` | bağlam **delta**'sı: `−log P̂(w\|ctx,ℓ) + log P̂(w\|ℓ)` |
| 14 | `F_lang_prior` | sürekli | `w_lang` | `−log P̂(ℓ \| oturum)` |
| 15 | `F_lang_switch` | gösterge | `w_switch` | `[ℓ ≠ ℓ_önceki]` |
| 16 | `F_lang_off_ℓ` | gösterge ailesi | `offset_ℓ` | **parametre ailesi**, öznitelik değil; `offset_tr ≡ 0` |

**16 öznitelik ailesi, 2 aktif dilde 15 serbest skaler parametre.** (14 tablo ağırlığı + ikinci
dilin serbest `offset_ℓ`'si; `w_spa` ve `offset_tr` sabitlenmiştir.)

`w_lex > 0` bir **kısıttır**, tercih değil — maliyet itmenin admissible alt sınır üretebilmesi
buna bağlıdır (§7).

### 2.1 Tek sahiplik kuralı

| Kanıt | Tek sahibi | Girmediği yer |
|---|---|---|
| Harf sıklığı | `F_lex` | uzamsal terimlere **girmez** |
| Unigram kütlesi | `F_lex` | `F_ctx` onun üzerine **delta**'dır |
| Ark üzerindeki ek maliyeti | `F_lex` bileşeni | ayrı ceza olarak **eklenmez** |
| Morfem sayısı | `F_lex` bileşeni | ayrı ceza **yoktur** |

**Uzunluk bir istisnadır ve kasıtlıdır.** Uzunluk etkisinin **izin verilen kanalları**: `F_len`
(doğrudan), `F_lex` (dolaylı — uzun formlar genelde daha nadir), karakter n-gram (§7, OOV
yolunda). Bunlar korelasyonludur; tek sahiplik kuralı burada uygulanmaz, çünkü uzunluk tek bir
"kanıt" değil birden çok mekanizmanın ortak sonucudur. Ayrıştırma `w_len`'in ampirik olarak
öğrenilmesiyle yapılır (§6).

### 2.2 Olay → öznitelik eşlemesi

| Olay | Tüketir | Emisyon | Katkı |
|---|---|---|---|
| `SUB` | `t_i` | `c_j` | `F_spa += −log p(t_i\|key(c_j))`; `F_len += 1` |
| `SUB_eq` | `t_i` | `c_j` | `F_spa_eq += −log p(t_i\|key(base(c_j)))`; `F_eq += 1`; `F_len += 1` |
| `OM` | — | `c_j` | `F_om_{gem\|init\|·} += 1`; `F_len += 1` |
| `INS` | `t_i` | — | `F_ins_{near\|·} += 1`; `F_ins_bg += −log p_bg(t_i)` |
| `TR` | `t_{i−1}, t_i` | `c_{j−1}, c_j` | `F_tr += 1`; `F_spa += −log p(t_{i−1}\|key(c_j)) − log p(t_i\|key(c_{j−1}))`; `F_len += 2` |
| `END` | — | — | **kendi katkısı yok**; yalnız otomat kabul durumundayken yasal |

`END`'in katkısı olmaması bilinçlidir: uzunluk etkisi `w_len·m` ve `F_lex` üzerinden gelir.
`END` çoğu karakter geçişinde yasal olmadığı için "her devam adımı survival öder" matematiği zaten
oluşmaz.

### 2.3 `SUB` / `SUB_eq` — yasallık ve seçim

Dokunma yalnız bir **koordinattır**; gözlenen ayrık bir "kaynak harf" yoktur. Bu yüzden eşdeğerlik
seçimi gözlemden türetilemez, **açık ve kaynaktan bağımsız bir yasallık fonksiyonuyla** tanımlanır:

```
base(c) : dil paketinden gelen eşdeğerlik haritası
          tr: ç→c, ğ→g, ı→i, ö→o, ş→s, ü→u     (yalnız bu yön)
          base(c) tanımsızsa SUB_eq yasal değildir
```

Her ikisi de yasalsa **decoder ikisini de dener ve ucuz olanı kazanır**:

```
sub(i, j) = min( sub_direct(i, j), sub_eq(i, j) )

sub_direct(i, j) = 1 · (−log p(t_i | key(c_j)))
sub_eq(i, j)     = w_spa_eq · (−log p(t_i | key(base(c_j)))) + w_eq        [base(c_j) varsa]
```

**Neden bu formülasyon doğru:** Türkçe Q'da `u` ve `ü` **ayrı tuşlardır**. Kullanıcı `guzel`
yazıp `güzel` kastettiğinde parmağı `u` tuşundadır. `sub_direct` bu dokunmayı `ü` tuşuna göre
skorlar (uzak, pahalı); `sub_eq` `u` tuşuna göre skorlar (yakın, ucuz) artı sabit `w_eq`. Yani
deasciification uzamsal kanıtı **iptal etmez**, doğru tuşa yönlendirir.

### 2.4 Uzamsal öznitelikler — ortak referans ölçüsü

`p(t|c)` ve `p_bg(t)` ikisi de `[0,1]²` üzerinde yoğunluktur.

- `p(t|c)`: klavye alanında **truncate edilmiş** 2B Gaussian, `[0,1]²` üzerinde yeniden
  normalize. Normalizasyon sabiti dokunma başına hesaplanmaz — kalibrasyon tablosuyla önceden
  hesaplanır.
- `p_bg(t)`: arka plan dokunma yoğunluğu, aynı ölçüde.
- **Kovaryans alt sınırı zorunludur**: `σ ≥ σ_min` (paket sabiti). Yoğunluk olduğu için
  `p(t|c) > 1` mümkündür ve `−log p` **negatif olabilir**; aşırı dar kovaryans çok büyük negatif
  değerler üretip hem sayısal kararlılığı hem uzunluk eğilimini bozar. `σ_min` §3'teki kırpma
  sınırıyla (`0.25·w`) tutarlı seçilir.

**Test:** her ikisinin de sayısal integrali 1 olmalı; `−log p`'nin alt sınırı `σ_min`'den türetilip
belgelenmeli.

### 2.5 Bütçe yok — ama sonlanma invariantı var

Insertion/omission için **sabit sayaç bütçesi kullanılmaz.** Gerekçe: bütçe ya modelin parçası
olup state'i şişirir, ya da yalnız arama kısıtı olup dedup'ta iki farklı bütçe kullanımının
birleşmesiyle yanlış sonuç üretir.

**Ama bütçeyi kaldırmak tek başına güvenli değildir.** `OM` dokunma tüketmez; üretken bir
morfoloji FST'sinde emisyon-only yollar sınırsız olabilir. Yerine **iki normatif invariant**:

**(I1) Sonlu yüzey uzunluğu.** Her dil paketi bir `MAX_SURFACE_LEN` (öneri: 40) taşır ve otomat
bu sınıra kadar açılmış, **çevrimsiz** olacak şekilde derlenir. Emisyon-only yollar bu sayede
yapısal olarak sonludur. Sınır paket manifestinde ve bu belgede birlikte durur.

**(I2) Emisyon başına kesin pozitif net maliyet.** Her emisyon-only geçiş için:

```
w_om_min + w_len + w_lex · ΔF_lex_min  >  0
```

`w_om_min = min(w_om_gem, w_om_init, w_om)`, `ΔF_lex_min` = paketteki en küçük emisyon başına
itilmiş leksikal delta. Bu **paket üretim zamanında denetlenir**; sağlanmıyorsa paket üretimi
başarısız olur.

> **(I2), `w_len`'in negatif olmasına doğrudan kısıt koyar.** Negatif `w_len` ancak bu eşitsizlik
> sağlandığı sürece meşrudur. Ağırlık fit'i bu kısıt altında yapılır.

---

## 3. Prefix-causality denetimi

Her öznitelik, alındığı anda `(touchIndex, geçmiş, o geçişin kendi tükettiği gözlemler)` bilgisiyle
hesaplanabilmelidir.

| Öznitelik | Neye bakar | Prefix-causal? |
|---|---|---|
| `F_spa`, `F_spa_eq` | `t_i` (tüketilen), `c_j` (ark) | ✅ |
| `F_eq` | ark tipi | ✅ |
| `F_om_gem` | `lastSurfaceSymbol` (§4) | ✅ geçmiş |
| `F_om_init` | `atWordStart` | ✅ geçmiş |
| `F_ins_near` | `t_i` ile `t_{i−1}` arası `Δt` + mesafe | ✅ geçmiş |
| `F_ins_bg` | `t_i` | ✅ |
| `F_tr` | `t_{i−1}, t_i` — **kendi tükettikleri** | ✅ (§3.1) |
| `F_len` | artımlı biriken sayaç | ✅ |
| `F_lex` | itilmiş prefix maliyeti | ✅ |
| `F_ctx` | tamamlanmış `w` — **`END` olayında** | ✅ terminal (§3.2) |
| `F_lang_*` | yol boyunca sabit / oturum durumu | ✅ |

**Yasaklı öznitelikler:** `kalan dokunma sayısı`, `toplam dokunma sayısı n`, `kelimenin nihai
uzunluğu`. Matematiksel olarak meşru olurlardı ama **artımlı kod çözmeyi geçersiz kılarlar**:
yeni dokunma geldiğinde geçmiş geçişlerin maliyeti değişir ve geri alınamayan budama kararları
yanlış olur.

### 3.1 ⚠️ `TR`'nin uygulama sonucu: bir dokunmalık gecikme

`TR` iki dokunma tüketir. Prefix-causality ihlali **değildir** (yalnız kendi tükettiklerine bakar),
ama artımlı decoder için somut bir sonucu vardır:

> Dokunma `i` geldiğinde `TR(t_{i−1}, t_i)` ancak o an değerlendirilebilir — kaynağı
> `touchIndex = i−2` frontier'ıdır.
>
> **Bu yüzden beam, yalnız güncel frontier'ı değil bir önceki adımınkini de tutar.**
> Ping-pong tampon yetmez; **üç yuvalı halka** gerekir.

Bu, performans mimarisini doğrudan etkiler ve `-1A₁`'de böyle kurulur.

### 3.2 `F_ctx` terminal bir özniteliktir — sonucu var

`F_ctx` yalnız `END`'de uygulanır, dolayısıyla **erken budamaya yardım etmez** ve daha önemlisi:
farklı yüzey öneklerinin birleştirilmesini **yasaklar** (§4.2). v1'de kabul edilen bir özelliktir.
(İleride admissible bir alt sınır itilebilir; ölçüm göstermedikçe yapılmaz.)

---

## 4. Decoder state şeması

Bir durum, **gelecekteki maliyetleri ve çıktıları etkileyen her şeyi** taşımalı; fazlasını
taşımamalı.

```
DecoderState:
  automaton          : UInt3    // formTrie | morphology | personal | domain
  language           : UInt2
  node               : UInt32   // kaynağa özgü paketlenmiş düğüm kimliği
  surfaceId          : UInt32   // yüzey öneki kimliği (§4.2) — formTrie'de node ile aynı
  touchIndex         : UInt6    // tüketilen dokunma sayısı (0..63)
  lastSurfaceSymbol  : UInt8    // önceki yüzey POZİSYONUNUN sembolü (§4.1)
  atWordStart        : UInt1
```

### 4.1 `lastSurfaceSymbol` — normatif güncelleme kuralı

Alan, **son fiziksel emisyon değil, yüzey önekinin son pozisyonundaki semboldür.** Fark yalnız
`TR`'de ortaya çıkar ama kritiktir.

| Olay | Yeni değer |
|---|---|
| `SUB`, `SUB_eq` | `c_j` |
| `OM` | `c_j` — atlanan karakter de yüzeyin parçasıdır |
| `TR` (emisyon sırası `c_j`, `c_{j−1}`) | **`c_j`** — yüzey pozisyonu olarak son olan |
| `INS` | değişmez |

`F_om_gem` bu alana göre sınıflandırılır ve tanımı **pozisyoneldir** (`c_j == c_{j−1}`), emisyon
sırasına bağlı değildir. İkiz harf kelimenin bir özelliğidir (`elli`, `anne`), yürütmenin değil.

### 4.2 `surfaceId` — neden ayrı alan

**Farklı yüzey önekleri birleştirilemez.** Sebebi `F_ctx`, `F_lex` ve çıktı token'ının
**tamamlanmış yüzeye** bağlı olmasıdır: minimize edilmiş bir otomatta `N` düğümüne `P₁` ve `P₂`
önekleriyle ulaşılabilir; ikisi de aynı `s` sonekiyle devam eder ama `P₁s` ile `P₂s` **farklı
kelimelerdir**. Yalnız o ana kadar ucuz olanı tutup dedup yapmak, `F_ctx` eklendiğinde kazanacak
olan diğerini atar.

Normatif kural:

- **Form listesi bir trie'dir, minimize edilmiş DAWG DEĞİL.** Trie'de düğüm öneki tekil belirler,
  dolayısıyla `surfaceId ≡ node` — ek maliyet **sıfır**. Bu, double-array trie seçiminin
  gerekçesidir ve pazarlık konusu değildir.
- **Morfoloji FST'sinde** düğüm öneki belirlemez; `surfaceId` = yüzey önekinin **rolling hash**'i
  (32 bit). Çakışma olasılığı ihmal edilebilir ve çakışma yalnız kalite kaybına yol açar,
  bozulmaya değil.
- Bu alanın beam çeşitliliğine ve birleşme oranına maliyeti **`-1A₂`'de ölçülür**.

### 4.3 Her alanın gerekçesi

| Alan | Neden gerekli | Çıkarılırsa |
|---|---|---|
| `automaton`, `language`, `node` | otomat pozisyonu | farklı kelimeler karışır |
| `surfaceId` | `F_ctx`/`F_lex`/çıktı yüzeye bağlı | farklı kelimeler yanlış birleşir (§4.2) |
| `touchIndex` | gözlem pozisyonu | farklı dokunma öneki tüketmiş yollar karışır |
| `lastSurfaceSymbol` | `F_om_gem` sınıfı | ikiz harf indirimi yanlış uygulanır |
| `atWordStart` | `F_om_init` sınıfı | kelime başı atlama maliyeti yanlış olur |

`atWordStart`, yüzey öneki uzunluğunun sıfır olup olmamasıdır. Bir otomatta aynı düğüme hem sıfır
hem pozitif yüzey uzunluğuyla ulaşılamıyorsa bu bit `node`'dan türetilebilir ve **çıkarılır**;
otomat invariantı bunu belirler (`-1A₁`/`-1A₂` çıktısı).

### 4.4 `editContext` çözüldü

Plandaki tanımsız `editContext`, işi yapınca `lastSurfaceSymbol` + `atWordStart`'a indi:

- **Yarım transposition durumu yok** — `TR` atomiktir (2 tüketir, 2 emisyon), araya girilemez.
- **Insertion/omission bütçesi yok** (§2.5); yerine yapısal sonlanma invariantları var.
- **Önceki tüketilen dokunma indeksi ayrı alan değil** — dokunmalar kesinlikle sırayla
  tüketildiği için her zaman `touchIndex − 1`'dir.
- **Eşdeğerlik ikamesi geçmişi state'e girmez** — hiçbir gelecek öznitelik geçmişteki ikame
  tipine bakmaz.

> **Invariant:** kaynak/olay geçmişi state'e **yalnız** gelecekteki bir maliyeti veya çıktıyı
> etkiliyorsa girer. Yeni bir öznitelik eklendiğinde bu invariant yeniden denetlenir.

### 4.5 Dedup anahtarı

Anahtar = `DecoderState`'in tamamı. Aynı anahtara varan yollar birleşir, en düşük maliyet kalır —
`min_A` tanımı gereği doğrudur. Doğruluk tahmin edilmez, **kanıtlanır** (§5.4).

---

## 5. Exhaustive oracle — referans recurrence

Beam'in karşılaştırılacağı **tam** aramanın tanımı.

### 5.1 Birim maliyetler

```
sub(i, j) = min( sub_direct(i, j), sub_eq(i, j) )                    // §2.3
   sub_direct(i, j) = −log p(t_i | key(c_j))
   sub_eq(i, j)     = w_spa_eq·(−log p(t_i | key(base(c_j)))) + w_eq      [base varsa, yoksa +∞]

om(j)     = j == 1            →  w_om_init                           // önce bu kontrol edilir
            c_j == c_{j−1}    →  w_om_gem                            // j ≥ 2 olduğu garanti
            değilse           →  w_om

ins(i)    = i == 1                                     →  w_ins + w_ins_bg·(−log p_bg(t_1))
            Δt(i,i−1) < τ_fast ∧ dist(i,i−1) < d_near  →  w_ins_near + w_ins_bg·(−log p_bg(t_i))
            değilse                                    →  w_ins + w_ins_bg·(−log p_bg(t_i))

tr(i, j)  = w_tr − log p(t_{i−1} | key(c_j)) − log p(t_i | key(c_{j−1}))       // i,j ≥ 2
```

`om(j)`'de sıralama önemlidir: `j == 1` önce kontrol edilir, böylece `c_0` hiçbir zaman
referanslanmaz. `ins(1)` daima normal `F_ins` sınıfına girer (`t_0` yoktur).

### 5.2 DP

```
D[i][j] = ilk i dokunmayı ilk j karaktere hizalamanın minimum maliyeti
          (geçersiz indislerde +∞)

D[0][0] = 0
D[i][0] = D[i−1][0] + ins(i)              i ≥ 1     // saf insertion zinciri
D[0][j] = D[0][j−1] + om(j) + w_len       j ≥ 1     // saf omission zinciri

D[i][j] = min(
    D[i−1][j−1] + sub(i, j)   + w_len ,
    D[i  ][j−1] + om(j)       + w_len ,
    D[i−1][j  ] + ins(i)              ,
    D[i−2][j−2] + tr(i, j)    + 2·w_len       (i ≥ 2, j ≥ 2)
)
```

`w_len` emisyon başına burada uygulanır (`SUB`/`OM` → 1, `TR` → 2), böylece `F_len = m` özdeşliği
korunur.

```
cost(w, ℓ) = D[n][m]
           + w_lex·F_lex(w, ℓ)
           + w_ctx·F_ctx(w, ctx, ℓ)
           + w_lang·F_lang_prior(ℓ) + w_switch·[ℓ≠ℓ_prev] + offset_ℓ
```

### 5.3 `(i, j)`'nin yeterli istatistik olduğunun kanıtı

Birim maliyetlerin hepsi yola değil, yalnız `(i, j)` ve sabit `w`, `T`'ye bağlıdır:

- `om(j)` sınıfı `c_j` ile `c_{j−1}`'e bakar. **Pozisyonel tanım sayesinde** (§4.1) bu, hangi
  yoldan gelindiğinden bağımsızdır — transposition emisyon sırasını değiştirse bile yüzey
  pozisyonları değişmez.
- `ins(i)` sınıfı `t_i` ile `t_{i−1}`'e bakar; `T` sabit.
- `sub`, `tr` yalnız `(i, j)`'ye bakar.

Dolayısıyla `(i, j)` yeterli istatistiktir ve DP tam çözümdür.

Bu, §4'teki state şemasının doğrulamasıdır: sabit `w` üzerinde `lastSurfaceSymbol` ve
`atWordStart` doğrudan `j`'den okunur; **otomat yürüyüşünde ise okunamaz** (aynı düğüme farklı
önceki sembolle varılabilir), bu yüzden orada ayrı alan olarak tutulurlar.

> Uyarı: "önceki emisyon her zaman `c_{j−1}`'dir" ifadesi `TR` altında kelimesi kelimesine
> yanlıştır. Doğrusu: **önceki yüzey pozisyonu `c_{j−1}`'dir**; olayların yürütme sırası dikkate
> alınmaz.

### 5.4 Test kapıları

1. **Model eşdeğerliği** — küçük leksikon (≤ 2000 kelime) + kısa girdi (≤ 8 dokunma) üzerinde,
   **budamasız tam durum-uzayı araması** ile oracle DP'si birebir aynı sonucu vermeli.
   *(Sonlu bir beam genişliğinde eşitlik, tamlık kanıtı değildir — bu yüzden test budamasız
   koşar.)*
2. **Dedup güvenliği** — dedup açık/kapalı sonuç aynı olmalı. Morfoloji ve `surfaceId` bulunan
   kaynaklar üzerinde **ayrıca** koşulur.
3. **Artımlı eşitliği** — artımlı decode ile sıfırdan tam decode birebir aynı sonucu vermeli
   (prefix-causality'nin makine denetimi).
4. **Beam yaklaşım payı** — ayrı bir metrik olarak ölçülür ve raporlanır; test kapısı 1'e
   karıştırılmaz. Model hatası ile arama hatası ayrı raporlanır.
5. **Literal kanalı** — n-gram uzunluk sınırını aşan ve alfabe dışı karakter içeren token'lar
   dahil **her sonlu Unicode token'ı** sonlu maliyet almalı.
6. **Sonlanma** — `MAX_SURFACE_LEN` ve (I2) eşitsizliği paket üretiminde denetlenmeli (§2.5).

---

## 6. Ağırlık eğitimi ve tanımlanabilirlik

Ağırlıklar **dev setinde**, yanlış-düzeltme oranı hedefiyle, **(I2) kısıtı altında** fit edilir;
**test setinde asla** yeniden ayarlanmaz.

### 6.1 `w_len`'in işareti — ampirik prior

**Beklenen işaret: negatif** (emisyon başına bonus).

Bu bir **ampirik prior**'dur, türetilmiş bir gerçek değil. Yaygın "kısa kelime yanlılığı"
gözlemine ve ASR'deki word-insertion-bonus pratiğine dayanır. Şu gerekçe **geçersizdir ve
kullanılmamalıdır**: *"her SUB pozitif maliyet ekler"* — `p(t|c)` bir yoğunluktur, 1'i aşabilir
ve `−log p` negatif olabilir (§2.4).

Kısıt: negatif `w_len` yalnız **(I2) sağlandığı sürece** meşrudur. Fit prosedürü bu eşitsizliği
kısıt olarak taşır.

### 6.2 Tanımlanabilirlik

Güçlü kullanıcı sinyalleri hedef *kelimeyi* verir, gerçek *edit olay dizisini* vermez.
Hizalamaları kendi Viterbi decoder'ımızdan çıkarıp edit ağırlıklarını onunla eğitmek
**döngüseldir**.

1. **Elle doğrulanmış hizalama seti** (birkaç yüz kelime) referans olarak tutulur.
2. Geri kalanda latent-hizalama eğitimi.
3. **Ablation + Hessian/bootstrap kararlılığı** ile her ağırlığın ayrı belirlenebildiği gösterilir.

**Bilinen yüksek korelasyonlu çiftler** — başlangıçta birleştirilir, ancak elle hizalanmış sette
yeterli olay sayısı ve kabul edilebilir kararlılık görülürse ayrılır:

| Çift | Neden ayrılması zor |
|---|---|
| `w_spa_eq` ↔ `w_eq` | ayrışmaları için geniş uzamsal maliyet dağılımı gerekir |
| `w_ins` ↔ `w_ins_bg` | insertion sayısı ile `p_bg` toplamı güçlü korele |
| `w_len` ↔ `w_lex` | uzunluk ile leksikal nadirlik korele |
| `w_lang` ↔ `offset_ℓ` | ikisi de dil tercihini kaydırır |

**Parametre sayısı tek başına ölçüt değildir**; kapı, korelasyon ve kararlılıktır.

**Yeterli veri yokken varsayılanlar:** `w_spa = 1`, `offset_tr = 0`, edit sınıfları birleşik ve
elle seçilmiş sabitler, `w_len = 0` (işaret veriyle belirlenene kadar nötr).

---

## 7. `F_lex` — leksikal öznitelik

Her `(NFC-normalize UTF-8 yüzey formu, dil)` anahtarının **tek** bir `F_lex` değeri vardır.
Kaynaklar aynı skorun *alternatif yürütme mekanizmalarıdır*:

- Form listesinde varsa → değer oradan (gerçek korpus frekansı). Morfoloji aynı yüzeye ulaşsa bile
  **kendi maliyetini eklemez**.
- Yoksa → morfoloji üretim maliyetinden verir; ölçek uyumu paket üretiminde kalibre edilir.
- Hiçbirinde yoksa → **açık-vocabulary literal kanalı**:
  `F_lex = c_unk + F_char_ngram(w | OOV)`.
  Karakter n-gram: alfabe paketten, BOS/EOS sembolleri, uzunluk sınırı.
  **Taşma:** sınırı aşan her karakter `c_tail`, alfabe dışı her karakter `c_oov_char`; token
  ayrıca literal korumaya düşer (`θ = ∞`).
- Aynı yüzey **asla iki kanaldan birden** maliyet almaz.

`c_unk`, `c_tail`, `c_oov_char` **paket sabitleridir, öğrenilebilir ağırlık değildir** — `F_lex`
değerinin bileşenleridir ve dışarıda tek bir `w_lex` ile çarpılırlar. (Öğrenilebilir olsalardı
iç ağırlık × dış ağırlık yapısı doğar ve §2'de reddedilen gauge sorunu geri gelirdi.)

### 7.1 Maliyet itme sözleşmesi

**Paket, ham öznitelik deltalarını iter — ağırlıklı maliyeti değil.**

- Her ark, o arkın `F_lex` katkısını **ham** olarak taşır.
- Her düğüm, oradan ulaşılabilir en iyi kelimenin **ham** `F_lex` alt sınırını taşır.
- Çalışma anında her ikisi de güncel `w_lex` ile çarpılır.
- Alt sınırın admissible kalması `w_lex > 0` kısıtına bağlıdır (§2, öznitelik 12).

Bu seçimin sonucu: **`w_lex` değiştiğinde paketin yeniden üretilmesi gerekmez.** Ağırlıklı maliyet
itilseydi gerekirdi. Çalışma anı maliyeti arkta bir çarpmadır.

---

## 8. Commit kararı — tek fonksiyon

```
Δ = cost(literal) − cost(bestCandidate)
değiştir  ⟺  Δ > θ(literal, ctx)
```

`cost(literal)` **her zaman sonludur** (§7 literal kanalı) — bu olmadan `Δ` tam da en çok önemli
olduğu durumda (bilinmeyen kelime) tanımsız kalırdı.

`θ` artan fonksiyonu: literal kişisel sözlükte mi (**∞**), bilinen kelime mi ve hangi dilin önseli
altında, literal frekansı, alan türü, kod/literal koruma kuralları (**∞**).

`θ` **tek kalibre karar noktasıdır**; held-out veride yanlış-düzeltme oranı hedefiyle ayarlanır.

### 8.1 OOV otomatik düzeltme kapısı — ölçüm sonucu

`kbdiag --theta`, gerçek paketlerle (70k form, 30k kök, 77 KB karakter modeli) iki aileyi
karşılaştırdı: düzeltilmesi gereken typo'lar ve korunması gereken doğru yazılmış sözlük dışı
kelimeler (özel adlar).

| Aile | `Δ` aralığı |
|---|---|
| typo — düzeltilmeli | 7.55 … 20.74 |
| doğru yazılmış OOV — korunmalı | 2.63 … 17.56 |

**Aralıklar iç içe.** Ölçülen bu örneklemde (10 + 10 token, tam tuş merkezleriyle simüle edilmiş
dokunmalar) hiçbir tek eşik iki aileyi hatasız ayırmadı: typo'ları yakalayan her eşik
`zeynepcim`'i `zeybeğim`'e çevirir, isimleri koruyan her eşik typo'ların çoğunu kaçırır. Karakter
başına normalize etmek de ayırmadı (`lslem` 4.56 vs `ayşenur` 4.01). Küçük bir örneklemdir ve
popülasyon iddiası değildir; ama `θ`'yı bir sayı seçerek çözebileceğimiz varsayımını çürütmeye
yeter.

Sözleşme §5c'nin asimetri kuralı gereği (*gereksiz koruma zararsız, gereksiz düzeltme can
sıkıcı*), sözlük dışı token'lar **otomatik değiştirilmez**: aday öneri çubuğunda durur, kullanıcı
dokunursa uygulanır. Sözlükteki kelimelerin düzeltilmesi bundan etkilenmez.

### 8.1.1 Kapı AÇILDI — önceki ölçüm kusurluydu

Yukarıdaki ölçüm **geçersizdir**. Dokunmalar her iki ailede de **tam tuş
merkezine** konmuştu; bu, iki aileyi ayıran asıl sinyali ölçümün kendisi yok ediyordu:

- Bir typo'da parmak kaymıştır → literal'in **uzamsal** maliyeti yüksek
- Doğru yazılmış bir kelimede parmak hedefindedir → uzamsal maliyeti düşük

Her ikisini de merkeze koymak `F_spa`'yı iki tarafta da sıfırlar; geriye yalnız
leksikal fark kalır ve aileler elbette örtüşür. *"θ bu ayrımı yapamıyor"* sonucu
modelin değil, ölçümün kusuruydu.

`kbdiag --theta` gerçekçi dokunmalarla (parmak kayması simüle edilerek) yeniden ölçtü:

| Aile | örnek | p5 | medyan | p75 | maks |
|---|---|---|---|---|---|
| typo — düzeltilmeli | 1251 | 11.66 | 25.49 | 34.65 | — |
| doğru yazılmış OOV — korunmalı | 28 | — | 5.43 | 9.25 | **16.98** |

**Boşluk var.** İşletim noktaları:

| θ | typo düzelir | doğru kelime bozulur |
|---|---|---|
| 14.01 | %90 | %7 |
| 14.60 | %89 | %4 |
| **16.98** | **%82** | **%0** |

Seçilen: **`θ_oov = 17`** — §5c asimetrisi gereği muhafazakâr uç. Kapı **açıldı**.

**Sınır:** sentetik ölçüm; simülatör de decoder de Gaussian, yani uzamsal terim
açısından kendini doğrulama riski sürüyor. B ailesi 28 örnek. Gerçek dokunma
verisiyle yeniden fit edilecek (§9). Ama bulgunun yönü sağlam: uzamsal terim
ayırt ediyor ve önceki ölçüm onu görmüyordu.

### Kapının açılma koşulu (tarihsel — artık sağlandı)

Aşağıdaki üç madde kapı kapalıyken yazılmıştı; ikincisi §8.1.1'deki yeni ölçümle
karşılandı (ayırt edici sinyal zaten `Δ` içindeydi, ölçüm onu siliyordu):

1. Gerçek dokunma verisi üzerinde tanımlı bir **yanlış-düzeltme hedefi** (§9) ve held-out
   ölçümde o hedefin sağlanması.
2. **Yeni bir ayırt edici sinyal.** Yalnız `θ` ve `c_unk`'ı aynı skaler `Δ` üzerinde yeniden fit
   etmek yetmez — iç içe geçmiş iki aile tek bir eşikle zaten ayrılamaz.
3. Yeni sinyalin karar modeline sokulması.

İkinci maddenin yönü: `F_spa` **`Δ`'nın içindedir**, kaybolmuyor; sorun `Δ`'nın uzamsal ve
leksikal kanıtı tek bir farka indirmesi. İki aile o tek boyutta örtüşse de iki boyutta
(uzamsal marj, leksikal marj) ayrılabilir: bir typo'nun dokunmaları hedef kelimeye yakındır ama
literal'e de yakındır; doğru yazılmış bir ismin dokunmaları literal'e yakın, hedefe uzaktır.
Bu bir hipotezdir ve gerçek veriyle sınanacaktır.

---

## 8.2 Çoklu dil ölçümleri (§5b uygulaması)

### Ölçek uyumu

İki paket bağımsız korpuslardan üretiliyor; `offset_ℓ` ölçümle konur, tahminle değil.
`kbdiag --scale` iki listede de bulunan **12 108 ortak yüzeyde** maliyet farkını ölçtü:

| p10 | p25 | medyan | p75 | p90 | ÇAG |
|---|---|---|---|---|---|
| −2.71 | −0.70 | **+0.20** | +0.69 | +1.37 | 1.39 |

`offset_en = −0.20 nat`, referans dil `tr = 0` sabit (gauge).

**Bu bir geçici sezgiseldir, kalibrasyon değil.** Ortak-yüzey medyanı yalnız *"iki listede
de bulunan yüzeylerin koşullu konum farkı"*nın betimleyicisidir; genel korpus ölçek
offset'inin yansız tahmincisi **değildir**. Ortak yüzeyler dilsel olarak seçilmiş bir
örneklem (özel adlar, alıntılar, kısa diziler baskın) ve fark frekansa bağlı görünüyor:
en sık İngilizce işlev kelimelerinde −3…−6 nat (`the`, `you`, `it`) — bu bir ölçek
kayması değil, gerçek dil farkıdır ve offset'in düzeltmemesi gerekir. Medyan tam da bu
kuyruklardan etkilenmemek için seçildi.

1.39 natlık çeyrekler arası genişlik 0.20 natlık medyana göre **dar sayılamaz**; tek bir
sabitin bu farkı temsil ettiği iddiası mevcut veriyle desteklenmiyor. Sözleşmenin istediği
ortak dev korpusunda fit, frekans katmanlı analiz ve bootstrap güven aralığı hâlâ borç.

### Doğruluk bedeli

Sözleşme §Doğrulama *"`--langs tr,en` vs `--langs tr` yanlış düzeltme farkı"* istiyor.
70k form + 30k kök + 60k İngilizce form, 400 kelime, simüle dokunma:

| Metrik | tr | tr+en | fark |
|---|---|---|---|
| top-1 | 90.2% | 89.0% | −1.2 puan |
| top-3 | 95.5% | 95.2% | −0.3 puan |
| temiz yazımda top-1 hatası | 0.50% | 1.25% | **2.5×** |
| tuş başına p99 | 1.56 ms | 1.40 ms | −0.16 ms |

Ölçülen üç tohumda ikinci dil gecikmeyi artırmadı, hatta düşürdü. Bu genel bir performans
garantisi **değil**: tek bir makinede, tek bir kelime listesiyle, p99 üzerinden yapılmış
bir gözlem. Durum sayılarıyla uyumlu **hipotez** (nedensel ölçüm değil): tuş başına daha
çok durum üretiliyor (3930 → 4293) ama bunlar ucuz trie durumları ve pahalı morfoloji
yürüyüşlerini beam'den dışarı itiyorlar.

Asıl bedel doğrulukta. **Temiz yazımda top-1 hatası yanlış düzeltme değildir**: doğru
yazılmış ve `V`'de bulunan bir kelime `θ = ∞` ile korunur, top-1 ne derse desin
değiştirilmez. Görünür sonuç öneri çubuğundaki ilk adayın yanlış olması — bozulma değil,
kalite kaybı.

**Ölçümün kapsamadığı:** bu karşılaştırma Türkçe kelime listesiyle yapıldı, yani yalnız
**Türkçe regresyon bedelini** ölçüyor. İngilizce faydasını, karışık token dizilerini, dil
geçişlerini ve commit politikasıyla gerçek yanlış-düzeltme oranını ölçmüyor. Golden cümle
de token token decode ediliyor — `previousLanguage` güncellenerek tam dizi testi borç.

---

## 8.3 Kalibrasyon — Faz 1 (global sapma)

### Hizalama çıkarılmaz, kaydedilir

Plan §9 döngüsellik uyarıyor. İlk tasarım *"dokunma sayısı = kelime uzunluğu ise hizalama
benzersizdir"* diyordu — **yanlış**: `TR` uzunluğu korur, dengeli bir `OM`+`INS` çifti de
net uzunluğu korur.

Doğru kural: uzantı her dokunmada literal karakteri anında yazıyor, dolayısıyla
*"dokunma `i` → literal karakter `i`"* bir çıkarım değil **kayıttır**. Öğrenme yalnız
**commit edilen metin literal'e eşitken** yapılır; düzeltme olduysa ya da kullanıcı farklı
bir öneri seçtiyse token atılır.

Bedeli: tahmin sıfıra doğru **zayıflar** — parmağı komşu tuşa taşan dokunmalar tam da
düzeltmeye yol açanlar, yani toplananların dışında. Muhafazakâr yönde bilinçli hata.

### Ölçümler (sentetik mekanizma testi — **doğruluk kapısı değil**)

Öğrenme ve değerlendirme aynı simülatörden geliyor; §9'un *"kendini doğrulama"* dediği
durum. Meşru sonuç yalnız: mekanizma çalışıyor mu, zarar veriyor mu. Eğitim (120 kelime)
ve test (400 kelime) **ayrık**.

| Senaryo (tuş genişliği birimi) | kalsız | kal'lı | fark | en kötü tuş |
|---|---|---|---|---|
| sıfır sapma | 90.5% | 90.5% | +0.0 | +0.0 |
| hafif sağ-alt (0.15) | 89.7% | 90.2% | +0.5 | −4.0 |
| belirgin sağ-alt (0.35) | 84.9% | 90.7% | +5.8 | −8.0 |
| güçlü sağ-alt (0.50) | 75.6% | 90.5% | **+14.8** | +0.0 |
| sola-yukarı (−0.30) | 87.2% | 89.4% | +2.3 | −8.3 |
| zamanla değişen | 82.4% | 90.2% | +7.8 | +0.0 |

24 sentetik kullanıcı, rastgele sapma: **p10 +0.0 · medyan +2.5 · p90 +7.0 puan**.

### Bulunan zarar — Faz 3'ün gerekçesi

Ortalama iyileşme olumlu ve p10 kullanıcı zarar görmüyor, **ama**:

- **2 / 24 kullanıcı** yarım puandan fazla kaybediyor
- **en kötü tuşta −8.3 puan**

Bu beklenen ve yapısal: tek bir global kaydırma her tuşa aynı anda yardım edemez. Bazı
tuşlar için doğru düzeltme başka yönde. Plan §3'ün hiyerarşik modeli (`b_c = g + r_row(c)
+ d_c`, backfitting ile) tam olarak bunun için var ve Faz 3'e ait.

Bu sayılar sentetiktir; gerçek kabul kapısı bağımsız dokunma replay'leri ve kullanıcı
bazlı ayrık train/test ile kurulacak (§9).

---

## 9. Açık kalan sorular (`-1A₁`/`-1A₂` çıktısı)

| Soru | Nerede kapanır |
|---|---|
| `atWordStart` `node`'dan türetilebilir mi? | otomat invariantı, `-1A₁` |
| `surfaceId`'nin beam birleşme oranına maliyeti | `-1A₂` ölçümü |
| `MAX_SURFACE_LEN` = 40 yeterli mi? | Türkçe form dağılımı, `-1B` |
| `σ_min` değeri ve `−log p` alt sınırı | kalibrasyon verisi, `-1A₁` |
| Hangi edit sınıfları başlangıçta birleşik kalmalı | ablation, ilk gerçek veri |

## 10. Değişiklik kaydı

| Tarih | Değişiklik |
|---|---|
| 2026-07-28 | İlk sürüm. Log-linear normatif seçim; prefix-causality; `editContext` sadeleşmesi; `TR` gecikme sonucu; oracle recurrence. |
| 2026-07-29 | **§8.1.1 eklendi — kapı AÇILDI.** §8.1'deki ölçümün dokunmaları tuş merkezine koyup ayırt edici uzamsal sinyali yok ettiği bulundu. Gerçekçi dokunmalarla yeniden ölçüldü: θ = 17'de typo %82 düzeliyor, doğru yazılmış OOV %0 bozuluyor. `LiteralChannel.autoCorrectsOutOfVocabulary` açıldı. |
| 2026-07-28 | **§8.3 eklendi.** Kalibrasyon Faz 1 (global sapma) uygulandı: `KBLearning` modülü, `.bkl` kalıcı depo, profil ayrımı. Hizalama kuralı Codex turunda düzeltildi (uzunluk eşitliği hizalamayı kanıtlamıyor). Zarar metrikleri ölçüldü: p10 kullanıcı +0.0 ama 2/24 kullanıcı ve en kötü tuş −8.3 → hiyerarşik model (Faz 3) gerekçesi. |
| 2026-07-28 | **§8.2 eklendi.** Çoklu dil uygulandı: `LexiconSet` kaynak listesine genelleştirildi (dil kaynağın kendisinden gelir), `F_lang` bağlandı, `en-US` paketlendi. Ölçek uyumu 12 108 ortak yüzeyde ölçüldü (`offset_en = −0.20`); doğruluk bedeli ve gecikme raporlandı. |
| 2026-07-28 | **§8.1 eklendi.** Literal kanalı uygulandı (üçlü karakter modeli, `.bkc`, `V` = form listesi ∪ morfoloji). `kbdiag --theta` ölçümü `θ`'nın typo ile doğru yazılmış OOV'yi ayıramadığını gösterdi; OOV otomatik düzeltme kapısı kapalı, gerekçe ve açılma koşulu §8.1'de. |
| 2026-07-28 | **Codex tartışması sonrası revizyon.** `tr()` indis düzeltmesi; `F_om_gem` pozisyonel tanım + `lastEmitted` → `lastSurfaceSymbol` yeniden adlandırma ve güncelleme kuralı; `surfaceId` alanı (farklı yüzey önekleri birleştirilemez, form listesi trie olmalı); sonlanma invariantları (I1) `MAX_SURFACE_LEN` + (I2) emisyon başına pozitif maliyet ve bunun `w_len < 0`'a koyduğu kısıt; `w_len` gerekçesi ampirik prior'a indirildi (yoğunluk 1'i aşabilir); `sub = min(direct, eq)` ve `base()` yasallık fonksiyonu; 15 serbest skaler parametre; DP sınır koşulları ve `om(1)`/`ins(1)` sıralaması; maliyet itme sözleşmesi (ham delta, `w_lex > 0`); `c_unk`/`c_tail`/`c_oov_char` paket sabiti; oracle testi budamasız aramaya bağlandı; `σ_min` kovaryans alt sınırı. |
