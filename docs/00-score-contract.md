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

## 8.4 iOS seçim API'si — cihazda ölçülen gerçekler

Seçilen kelimeyi düzenleme özelliği cihazda iki kez sessizce çalışmadı. Uzaktan tahmin
yerine durum satırına sayaç basıldı; tek bir ekran görüntüsü dört şeyi birden verdi:

```
sel#0  txt#32  seç='anlamdım'  ✗geçmişte yok  geçmiş=0
```

| Gözlem | Sonuç |
|---|---|
| `sel#0` | **`selectionDidChange` hiç çağrılmıyor.** Archagon'un 2014'teki bulgusu 2026'da hâlâ geçerli. Seçim değişimi dahil her şey `textDidChange`'den geliyor. |
| `txt#32` | `textDidChange` çalışıyor — tek güvenilir kanal. |
| `seç='anlamdım'` | **`selectedText` çalışıyor.** Tam Erişim gerektirmiyor, host `UITextField` ise doluyor. |
| `geçmiş=0` | Asıl hata: geçmiş silinmişti. |

### Bulunan hata: uzlaştırma kanıtı yok ediyordu

`textDidChange` içindeki **senkron** host uzlaştırması, seçim yolundan önce çalışıyordu:

1. Kullanıcı bir kelime seçince `documentContextBeforeInput` seçimin **öncesine** kayar
2. `agreesWithHost` bu yüzden düşer
3. Senkron `invalidate()` geri dönüş geçmişini **siler**
4. Ardından çalışan async okuma `selectedText`'i doğru görür ama eşleşecek geçmiş kalmamıştır

Yani uzlaştırma, tam da seçimi ele almamız gereken anda gereken kanıtı yok ediyordu.
Doğru sıra: **önce seçim, sonra uzlaştırma**, ikisi de tek fonksiyonda.

### İkinci ölçüm: `txt#5` ve çift dokunuşun ilk yarısı

İlk düzeltmeden sonra aynı sonuç geldi — ama sayaç yeni bir şey söyledi:

```
sel#0  txt#5  seç='yanş'  ✗geçmişte yok  geçmiş=0
```

22 karakter yazılmışken **yalnız 5** `textDidChange`. Yani geri çağrı bizim kendi
eklediğimiz metinde tetiklenmiyor; yalnız **imleç hareketi ve seçim** değişiminde
geliyor. (Archagon'un *"the text methods only get called when the selection changes or
the cursor is moved"* ifadesi birebir doğrulandı.)

Bu, hatanın kalan yarısını açıkladı: **çift dokunuşun ilk dokunuşu** imleci taşıyor,
o anda henüz seçim yok, `agreesWithHost` düşüyor ve tam `invalidate()` geçmişi
siliyordu. İkinci dokunuş seçimi oluşturduğunda eşleşecek kanıt kalmıyordu.

Düzeltme: imleç hareketi **yalnız yazılmakta olan token'ı** atar
(`invalidateComposing`), geri dönüş yığınını değil. Bir imleç hareketi *ne
yazdığımızı* yanlış yapmaz; kayıt bayatlamışsa `beginEditingSelection`'ın iki taraflı
konum doğrulaması onu zaten reddeder — koruma orada olmalı, burada değil.

### Tasarım hatası: özelliği geçmişe bağlamak

İki düzeltmeden sonra da çalışmadı ve sebebi artık mekanizma değil **tasarımdı**:
özellik yalnız *bu oturumda biz yazmışsak* çalışıyordu. Uygulama her yeniden
yüklendiğinde geçmiş sıfırlanıyor; kullanıcının yapıştırdığı ya da önceden orada duran
kelimelerde zaten hiç çalışmayacaktı.

Kayıp olan ayrım: **uzamsal gözlem** ile **öneri üretmek** aynı şey değil.

- Gerçek dokunmalar → uzamsal gözlem → otomatik uygulamaya yetki verir
- Yüzeyden türetilmiş dokunmalar (her harf kendi tuşunun merkezinde) → gözlem
  **değil**, ama decoder'ın komşu-tuş ve eşdeğerlik sınıfı adayları üretmesine yeter:
  `guzel` → `güzel`, `kalen` → `kalem`

İkisi ayrı bayrakla taşınıyor (`selectionHasRealEvidence`). Türetilmiş kanıtta öneriler
gösteriliyor ama **otomatik uygulama yok** — `Δ` gerçek bir parmak kanıtını temsil
etmediği için `θ` kararı orada anlamsız; kullanıcının adaya dokunması gerekiyor.

### Kalıcı sonuçlar

- `selectionDidChange`'e **güvenilmez**; hook duruyor ama tek başına yetmiyor
- `textDidChange` **kendi düzenlememizde tetiklenmez** — yalnız imleç/seçim değişiminde
- İmleç hareketi composing token'ı atar, **geçmişi atmaz**
- Proxy okuması `DispatchQueue.main.async` ile **ertelenmeli** — geri çağrı anında
  proxy henüz yeni durumu yansıtmıyor
- Host uzlaştırması seçim kontrolünden **sonra** gelmeli
- `documentContextBefore/AfterInput` yalnız imlece yakın bir pencere veriyor; pencere
  dışındaki tekrarlar görülemez (§seçim doğrulaması bu sınır içinde muhafazakâr)

---

## 8.5 Gayrıresmî katman (plan §4.B / §4.D)

### `F_ins,rep` — üçüncü insertion sınıfı

Uzatmalar (`çoookk`, `evettt`, `bakkk`) plan §4.B'de *"kuralla çözülür"* diyor. Ayrı bir
kural yerine sözleşmenin `F_ins,k` sınıflarına üçüncü bir sınıf eklendi: fazladan dokunma
**en son emit edilen karakterin tuşuna** düşüyorsa tekrar insertion'ı.

Sınıf eklemek sözleşmeye aykırı değil — §2: *"sınıf sayısı, veri miktarına göre ablation
ile belirlenir"*.

Ayırt edici sinyal **zamanlama değil kimlik**. Mevcut `w_ins_near` `Δt < τ_fast` istiyor,
ama kullanıcı harfi bilerek uzatırken kendi temposunda basıyor.

**Prefix-causal**: yalnız `lastSurfaceSymbol` (zaten durumda) ve o anki dokunmaya bakıyor.

### Ağırlık taraması

`kbdiag --repeat`, 521 kelimede uzatma üretip her ağırlıkta ölçtü:

| `w_ins_rep` | uzatma ✓ | normal ✓ | çift harf ✓ | gürültülü ✓ |
|---|---|---|---|---|
| 4.5 (sınıf yok gibi) | 43.6% | 99.8% | 99.7% | 91.7% |
| 2.0 | 77.2% | 99.8% | 99.7% | 91.7% |
| **1.0** | **88.4%** | 99.8% | 99.7% | 91.3% |
| 0.6 | 91.9% | 99.8% | 99.7% | 91.3% |
| 0.3 | 93.1% | 99.8% | 99.7% | 91.3% |

*çift harf* = gerçekten çift harfli 300 kelime (`anne`, `bekle`) — ucuz insertion'ın onları
`ane`+insertion diye açıklama riski. *gürültülü* = σ 0.45 ile normal yazım.

Seçilen **1.0**: kazancın çoğunu alıyor, bedeli 0.4 puan. Daha ucuzu az kazandırıp
insertion'ı neredeyse bedava yapıyor ve tarama tek bir gürültü seviyesini kapsıyor.

Seçim **kalibre edilmiş değil**. Tarama gerçek kullanıcı temposunu, tuş sınırı hatalarını,
deasciification sonrası tekrarları ve üçten fazla gerçek tekrar içeren biçimleri
kapsamıyor; tek bir gürültü seviyesinde ve sentetik. Gerçek dokunma verisiyle yeniden
seçilecek (§9).

**Ürün kararı:** yüklem tam tuş eşitliği arıyor. `ü` emit edildikten sonra `u` dokunuşları
tekrar sayılmaz — eşdeğerlik sınıfını buraya da sokmak `u`↔`ü` ayrımını taşıyan başka
yerlerle tutarsızlık üretirdi.

### Kısaltmalar otomatik açılmaz

`slm`, `nbr`, `tmm` **form listesiyle birleşik tek trie'de**. Ayrı bir kaynak olarak
yüklemek §7'yi ihlal ediyordu: aynı yüzey iki trie'de bulunduğunda decoder ucuz olanı
seçiyor, oysa listeler farklı toplamlara göre normalize edilmiş ve maliyetleri
karşılaştırılabilir değil. `packbuild --informal` birleştirmeyi yapıyor ve çakışmayı
**derleme hatası** sayıyor — ilk denemede 67 formun 36'sı resmî listede zaten vardı.

Ayrı **dosya** olarak durması yazım kolaylığı ve lisans ayrımı için (elle küratörlü,
korpustan türetilmedi).

Sözlükte oldukları için `θ = ∞` alıyorlar; plan §4.B: *"Gayrıresmî formlar asla otomatik
olarak resmî karşılığına çevrilmez."*

Açılımlar (`.bkx`, §4.D) öneri çubuğunda **ek aday** ve kendilerine ayrılmış slotta:
sona ekleyip kesmek, liste doluyken açılımı hiç göstermiyordu. Yükleme sırasında
**doğrulanıyorlar** — anahtarı sözlükte olmayan girdi atılıyor, yani iki paket bağımsız
yüklense de tutarsız durum oluşamıyor.

Yan kazanç: kısaltmanın **yazım hatası** düzeltilebiliyor (`sln → slm`).

---

## 8.6 Kalibrasyon — Faz 3 (hiyerarşik sapma)

§8.3 Faz 1'i ölçmüş ve gerekçeyi kaydetmişti: global sapma ortalamada kazandırıyor ama tek
bir kaydırma her tuşa aynı anda yardım edemiyor. Faz 3 plan §3'ün modelini uyguluyor ve
**ürün yolunda** (`InputCoordinator.applyCalibration`) artık bu koşuyor:

```
b_c = g + r_row(c) + d_c
```

### Tanımlanabilirlik: merkezleme, ve ölçülen invariantlar

Üç katman ham artıktan bağımsız kestirilemez — `g`'yi artırıp her `r_row`'u aynı kadar
azaltmak aynı `b_c`'yi verir. Her backfitting geçişinin **sonunda** ince katman
örnek-ağırlıklı sıfır ortalamaya çekilip kütle bir üst katmana itiliyor:

```
Σ_{q açık} n_q · r_q = 0        ve her açık satır q için:  Σ_{c ∈ q, açık} n_c · d_c = 0
```

Bu kısıtlar `HierarchicalCalibration.invariants()` ile **dışarıdan doğrulanabiliyor** ve
testlerde kapı. Gerekçesi doğrudan bir hata: ilk uygulamada aynı invariantlar yorumda
yazılıydı ama kodda **tutmuyordu** (tuş kütlesi satıra itiliyor, satır bir daha
merkezlenmiyordu; ayrıca merkezlemenin paydası tüm örneklerdi, oysa açık satırlarınki
olmalıydı). Belgelenmiş ama test edilmemiş bir kısıt yoktur.

### Çürütülen varsayım — elle seçilmiş shrinkage

İlk uygulama ince katmanlarda Faz 1'in `n/(n+κ)` biçimini elle seçilmiş `κ` ile
kullanıyordu. Ölçüm bunu çürüttü: sapması **tamamen global** olan kullanıcıda hiyerarşi
1.0 puan kaybettiriyordu. Sabit bir `κ` *"bu kullanıcıda tuş yapısı var mı"* sorusunu
soramaz; artığın tamamını yapı sanıp gürültüye uyar. Sorun sabitin değerinde değil,
**biçimindeydi**.

Yerine ampirik Bayes (rastgele etkiler) kondu:

```
E[ S²(m_u) ] = τ² + ort_u(v_u)          v_u = σ²_u / n_u
katsayı_u    = τ̂² / (τ̂² + v_u)
```

`σ²_c = s²·ölçek_c²` — havuzlanmış **tek** bir `σ²` yanlıştı: `SpatialModel` yayılımı tuş
ölçüsüyle orantılı kuruyor ve Türkçe Q'da üst satır 12, alt satırlar 11 tuşlu.

### Bulunan hata: devretme kalibrasyonu yürürlükten düşürüyordu

Kaydedici bayt sınırına gelince (`ProductionRecorder.byteCap`, 512 KB) **yeni
bir denemeye devrediyor** ve devretme koordinatörü sıfırdan kuruyor. Uzantı
`applyCalibration`'ı yalnız iki yerde çağırıyordu: paket yüklemesi ve profil
değişimi. Devretme ikisi de değil.

Sonuç: yeterince yazan kullanıcı, öğrenilmiş sapmasını **sessizce yürürlükten
düşürüyordu**. Dosya diskte duruyordu (bu yüzden "kalibrasyon kayboldu" diye de
görünmüyordu), ama canlı decoder kalibrasyonsuz koşuyordu — bir sonraki paket
yüklemesine ya da profil değişimine kadar.

İkinci bir sonucu daha vardı: kayıt `applied: false` yazarken canlı motor
öğrenilmiş profili uyguluyordu (uzantı `applyCalibration`'ı snapshot
yazıldıktan **sonra** çağırıyordu). Yani kayıt kendi motorunu yanlış anlatıyor
ve replay farkı ortam uyuşmazlığı olarak bile görünmüyordu — sahte bir kod
regresyonu diye okunurdu. §8.4'te bir kez düzeltilen hatanın aynı sınıfı.

**Çözüm kişisel sözlükle aynı (§8.7):** rezervuar `configure`'ın parametresi,
yani her denemede yeniden veriliyor ve snapshot'tan **önce** uygulanıyor.
Rezervuarın canlı kopyası her eylemden sonra tutuluyor; `configure` sırasında
motor göstergesi çoktan yeni (boş) koordinatörü işaret ettiği için oradan
okumak imkânsız.

Testler ikisini de tutuyor: devretmeden sonra rezervuar duruyor, ve snapshot
uygulanan sapmayı anlatıyor. İkisi de düzeltme geri alındığında kırılıyor.

### `τ̂²` bir güven sınırı DEĞİL

`τ̂² = max(0, S²·(U−1)/χ²_{0.90}(U−1) − v̄)`. Katsayının **biçimi** χ²'den geliyor, ama
garanti iddia edilmiyor: `v_u` birimden birime değişiyor, `s²` aynı veriden kestiriliyor
ve `m_u` backfitting yüzünden bağımsız değil. Tam çözüm REML olurdu; token sınırında koşan
bir uzantı için değil.

Garantinin yerini **ölçüm** alıyor. Null altında (dengeli ve Zipf-benzeri dengesiz
dağılımlarla, 40 çekiliş) sahte ince katsayıların büyüklüğü sayılıyor: kayda değer
(> tuşun %2'si) sapma **satırda 1/40, tuşta 0/40**; en büyüğü %2.

Bu ölçüm bir metrik hatasını da ortaya çıkardı: *"katman açıldı mı"* ikili bayrağı 40'ta 14
diyordu, ama katsayılar tuşun %1'i mertebesindeydi. Bayrak zararı değil **duyarlılığı**
ölçüyordu; kapı büyüklük üzerinden yeniden kuruldu.

### Ölçüm — üç kol

Eğitim 400 kelime, test 400 kelime (ayrık, sabit); senaryo başına 3 kullanıcı × 4 çekiliş.
Katman sapmaları kullanıcıya sabit, çekilişler yalnız gürültü.

| Senaryo | kalsız | global | hiyerarşik | uzOrt-g | uzOrt-h |
|---|---|---|---|---|---|
| sapma yok | 85.1% | 85.2% | 85.1% | −0.0 | −0.0 |
| yalnız global | 77.7% | 84.7% | 84.6% | +21.0 | +21.0 |
| global+satır | 81.9% | 84.0% | **84.9%** | +9.8 | +11.3 |
| global+satır+tuş | 79.2% | 82.3% | **85.5%** | +7.4 | +15.8 |
| yalnız tuş | 80.5% | 81.8% | **85.2%** | +1.7 | +10.1 |
| yalnız tuş (IID, stres) | 78.9% | 78.8% | **84.3%** | −0.0 | +6.5 |
| zamanla değişen | 75.6% | 83.0% | 83.4% | +19.3 | +21.2 |

`uzOrt` = tuş başına **uzamsal** isabetin 32 tuş ortalaması, kalsız kola göre fark
(decode yok, doğrudan atfedilebilir).

24 sentetik kullanıcı, rastgele katmanlı sapma:

| | p10 | medyan | p90 | zarar gören |
|---|---|---|---|---|
| global − kalsız | +0.1 | +3.2 | +8.9 | 0/24 |
| hiyerarşik − kalsız | **+1.1** | **+4.2** | +9.9 | **0/24** |
| hiyerarşik − global | +0.0 | +1.4 | +2.5 | **0/24** |

**Sonuç:** yapı varken hiyerarşi 3–5 puan kazandırıyor, yapı yokken Faz 1'e iniyor
(fark ≤ 0.1 puan) ve hiçbir kullanıcıya zarar vermiyor. `κ`'lı ilk sürümdeki −1.0 puanlık
zarar ortadan kalktı.

İnce katman **veri istiyor** — Faz 3'ün temel önermesi buydu ve ölçüldü:

| eğitim | örnek | kalsız | global | hiyerarşik | kendi `d_c`'si |
|---|---|---|---|---|---|
| 60 | 232 | 78.6% | 81.2% | 83.2% | 2/32 |
| 120 | 515 | 78.6% | 81.4% | 82.9% | 11/32 |
| 400 | 1954 | 78.6% | 81.4% | 84.7% | 22/32 |
| 1200 | 2000★ | 78.6% | 81.4% | 84.9% | 22/32 |

★ rezervuar kapasitesi (2000); o satırdan sonrası daha fazla veri değil.

### Hedef fonksiyonu uyuşmazlığı — "en kötü tuş" neden kapı değil

Tabloda görünmeyen ama ölçülen bir gerilim var: hiyerarşik model **kelime doğruluğunda**
kazanırken **en kötü tuşun uzamsal isabetinde** global'den daha çok kaybettiriyor
(−35.4 vs −18.3, "yalnız tuş").

Sebep bir hata değil, hedef farkı. Kalibre edilmiş argmax **toplam** sınıflandırma hatasını
optimize eder, en kötü tuşun recall'ını değil. Komşu iki tuşun gerçek sapmaları birbirine
doğruysa dokunma kümeleri **gerçekten** örtüşür — bilgi kayıptır. Kalibrasyon merkezleri
kümelere taşıyor (doğru olan bu) ve örtüşme görünür hâle geliyor. Kalibrasyonsuz modelin
geniş tuş aralığı bir prior değil, bazı tuşları tesadüfen koruyan yanlış tanımlı bir karar
sınırı.

Ölçerek sınandı: tuş sapmasının std'si 0.30 → 0.15 yapılınca uzamsal zarar −32.5 → −12.5'e
iniyor (kelime kazancı da +4.9 → +0.8). Zarar komşu ıraksamasıyla ölçekleniyor.

Bu yüzden **en kötü tuş metriği teşhistir, kabul kapısı değil**: 32 tuş üzerinden minimum
almak güçlü bir seçim yanlılığı taşır ve tahmin gürültüsü tablo basamaklarıyla aynı
mertebede. Kapı kelime doğruluğu ve kullanıcı dağılımıdır.

### Ölçümün kendisi iki kez çürütüldü

Bu bölümün sayıları, önceki ölçüm rejimi düzeltilmeden anlamsızdı:

- **§8.3'ün "en kötü tuş −8.3" sayısı ölçüm gürültüsünden ayırt edilemez.** Metrik tuş
  başına 8 kelimeye bakıyordu; orada tek bir kelime 12.5 puan oynatır. Üstelik kelimenin
  tamamının decode başarısını **ilk harfinin** tuşuna yazıyordu — hata kelimenin herhangi
  bir yerinden gelebilirken. O metrik kaldırıldı, yerine doğrudan atfedilebilir uzamsal
  sonda kondu.
- **Simülatör sapmayı her tuşun kendi genişliğiyle çarpıyordu.** Üst satır 12, alt satırlar
  11 tuşlu olduğu için *"yalnız global sapma"* senaryosu fiilen satırdan satıra değişen bir
  kayma üretiyordu: global kolun öğrenemeyeceği bir satır etkisi senaryonun içine
  gizlenmişti ve hiyerarşinin oradaki üstünlüğü kendi kendine yaratılmıştı. Kaymalar artık
  referans tuş ölçüsüyle, normalize koordinatta sabit.
- **Eğitim verisi kirliydi.** Simülatör transposition ve kalın kuyruk üretirken benchmark
  `literal` olarak hedef kelimeyi veriyordu; dokunmalar yanlış tuşlara "strong"
  etiketleniyordu. Gerçek uzantıda o token `commit != literal` olduğu için atılır. Eğitim
  akışında bu olaylar kapatıldı.
- **Tekrarlar aynı kullanıcının tekrarı değildi** — her çekilişte katman sapmaları yeniden
  çekiliyor, tuş sayaçları o farklı kullanıcılar boyunca havuzlanıyordu: birinin zararı
  diğerinin kazancıyla sessizce götürülüyordu.

Ayrıca IID tuş sapması **gerçekçi bir kullanıcı değil**: gerçek parmak sapması el
geometrisinden doğar, komşu tuşlar benzer sapar. Komşu farkının varyansı `2σ²(1−ρ)`
olduğuna göre IID (`ρ = 0`) düzgün alandan serttir. Ana senaryolar artık korelasyon uzunluğu
2 tuş olan düzgün alan kullanıyor; IID ayrı bir **stres satırı** olarak duruyor.

---


## 8.7 Kişisel sözlük — kullanıcının kendi kelimeleri

§8.1.1 OOV otomatik düzeltme kapısını açtı: sözlük dışı bir token `Δ > θ` ise
düzeltiliyor. O ölçüm doğruydu ama **yanlış soruya** cevaptı. Ölçülen şey
"rastgele bir OOV token bozuluyor mu" idi; kullanıcının derdi ise *"kendi adımı
günde otuz kez yazıyorum"*. Kelime başına %0 bozulma, o kelime otuz kez
yargılanınca artık %0 değil ve klavyenin bir kez yanılması güveni kaybettirmeye
yetiyor.

Kişisel sözlük kelimeyi `V`'ye sokar. Sonucu iki katlı:

- `LiteralChannel.Score.isInVocabulary` → `θ = ∞` (§8 bilinen kelime koruması):
  kelime artık **bozulamaz**;
- decoder kaynağı olur: yanlış dokunmalardan da geri kurtarılabilir.

### Kabul politikası — kanıt yalnız reddedilmiş düzeltmedir

Bir yüzey, **boşlukla kapanan** bir token'da şu koşullarla bir puan biriktirir:

1. alan parola alanı değil,
2. düzeltme uygulanmadı,
3. yüzey `V` dışında,
4. **`θ` sonlu** — yani klavye token'ı gerçekten yargıladı ve literal'i bıraktı.

Dördüncüsü belirleyici. `θ = ∞` olan hiçbir yol kanıt üretmez: e-posta/URL alanı,
korumalı token (`@ali`, `x1`), uzunluk taşması, kapalı OOV kapısı. Oralarda karar
**hiç sorulmadı**; "değiştirmedi" bir olgu değil, sorunun sorulmamış olmasıdır.
Aynı gerekçeyle sembol (`kelime.`) ve satır sonu yolları da kanıt üretmiyor —
ikisinde de düzeltme hiç denenmiyor.

Eşik üç puan; zayıf gözlem 1, açık seçim 3 puan. Değer **asimetriden** geliyor,
ölçümden değil (§5c'nin aynı muhakemesi): yanlış kabul aktif zarardır — typo
`V`'ye girer, `θ = ∞` olur ve bir daha düzeltilmez; geç kabul yalnız faydayı
erteler.

> **Güçlü kanalın üreticisi yok.** `Confidence.strong`'un doğal kaynağı
> *"kullanıcı kendi yazdığı yüzeyi öneri çubuğundan seçti"* olurdu. Ama çubuk
> yalnız decoder adaylarını ve genişletmeleri gösteriyor; sözlük **dışı** bir
> literal hiçbir kaynakta olmadığı için orada belirmiyor, dolayısıyla
> seçilemiyor. Çubuğa eklemek yeni bir `SuggestionOrigin` gerektiriyor ve o,
> kayıt şemasına dokunmak demek (§12.6.1) — bilerek ertelendi. Bugün tek üretici
> zayıf kanal.

Bu, özelliği kendi kendini baltalayan bir döngüye sokmuyor: §8.1.1 doğru yazılmış
OOV kelimelerin **%0**'ının bozulduğunu ölçtü, yani dikkatle yazılan bir ad
commit olup puan biriktiriyor. Düzeltilen yüzeyler ise zaten dikkatsiz
yazılanlar — onları otomatik kabul etmek istemiyoruz.

### Korpus içe aktarımı — aynı eşik, ikinci kanal

Kullanıcı kendi metnini bir alana yapıştırıp *"bu alandaki metinden öğren"*
diyebiliyor. Metindeki bir yüzey **üç kez** geçiyorsa kabul ediliyor; bir kez
geçen yalnız puan biriktiriyor. Yazarak öğrenmeyle aynı eşik — ayrı bir sabit
tanımlanmadı, çünkü tanımlanacak bir ölçüm yok.

Katkı `admissionPoints` ile **doyuruluyor** ve puan düşürülmüyor. İkisi birden
iki şey sağlıyor: aynı metni iki kez aktarmak sonucu değiştirmiyor (idempotent),
ve bin kez geçen bir kelime eviction sıralamasında yazarak öğrenilmiş kelimeleri
ezmiyor. Sınır olmasaydı tek bir içe aktarım kapasiteyi kendi lehine yeniden
dağıtırdı.

Bölme **tek tokenizer**'la (§2.3, `PromptTokenizer`): maksimal layout-harf
dizileri, NFC, Türkçeye duyarlı küçültme. İkinci bir bölücü yazmak `Wi-Fi` ve
`Caddesi'ne` gibi vakalarda kayıtla içe aktarımın farklı token üretmesi olurdu.

Kaynak **alanın kendisi, pano değil**: panoyu okumak Tam Erişim istiyor ve iOS
her okumada sistem onayı gösteriyor; alandaki metni klavye zaten izinsiz
görüyor. Ama gördüğü `documentContext` bir **pencere**, belgenin tamamı değil —
rapor bu yüzden okunan token sayısını söylüyor. "Hepsini okudum" doğrulanamaz
bir iddia olurdu ve kullanıcı metni parça parça verebilmeli.

Parola alanında çalışmıyor.

### `F_lex` çıpası — ilk gerekçe tutarlıydı, ölçüm çürüttü

Kişisel sayımları kendi toplamlarına normalize etmek (`−log(n/Σn)`) paket
ölçeğiyle **karşılaştırılamaz** bir maliyet üretirdi; argo katmanını ayrı kaynak
olarak yüklerken bir kez yapılan hatanın aynısı. Elde üç gözlem var ve ondan
frekans çıkarmak, veriden gelmeyen bir modeli veri gibi göstermek olurdu (§8.6'da
elle seçilmiş shrinkage ile bir kez yapıldı, ölçüm onu da çürütmüştü).

O yüzden tek bir sabit, ve **paketin kendi ölçeğinden** çıpalanmış.
`wordlist.tsv` üzerinde `−log(freq/total)` dağılımı:

| paket | n | min | medyan | p95 | maks |
|---|---|---|---|---|---|
| tr-TR | 70 009 | 3.66 | 12.91 | 13.80 | **14.57** |
| en-US | 60 000 | 3.00 | 13.90 | 15.05 | 15.14 |

İlk seçim 14.6'ydı: *"korpusun hiç görmediği kelime, listeye giren en nadirden
nadirdir."* Gerekçe tutarlı, sonuç kötü — o değerde kullanıcı kendi kelimesini
**dikkatle** yazdığında bile yalnız %56'sı geri geliyordu.

`kbbench --personal` çıpayı taradı (aynı dokunmalar, tek değişken kişisel
`F_lex`; 210 kişisel yüzey, 1496 paket kelimesi):

| `F_lex` | tanınma (σ 0.12) | tanınma (σ 0.35) | paket top1 | çalınan |
|---|---|---|---|---|
| 14.6 | 56.2% | 24.8% | 87.83% (+0.00) | 0 |
| 13.8 | 84.8% | 54.3% | 87.83% (+0.00) | 0 |
| 12.9 | 91.0% | 69.0% | 87.83% (+0.00) | 0 |
| **11.5** | **95.7%** | **81.4%** | **87.83% (+0.00)** | **0** |
| 10.0 | 98.6% | 87.6% | 87.83% (+0.00) | 0 |
| 9.0 | 100.0% | 91.9% | 87.70% (−0.13) | 2 |
| 8.0 | 100.0% | 93.8% | 87.63% (−0.20) | 3 |
| 6.0 | 100.0% | 94.8% | 87.50% (−0.33) | 5 |

Mıknatıs etkisi — kişisel kelimenin paket kelimesinin kod çözümünü çalması —
14.6'dan 10.0'a kadar **tam olarak sıfır**: tek bir paket kelimesi bile
bozulmuyor. İlk zarar 9.0'da. Sözlük 4 katına (810 yüzey) çıkarıldığında eğri
aynı yerde kırılıyor, yani plato sözlük boyutuna duyarlı değil.

Sıfır-zarar platosunun içinde seçim tanınmaya bakar: **`F_lex` = 11.5**, gözlenen
ilk zarardan 2.5 nat, platonun kenarından 1.5 nat uzakta. Pay §5c'nin istediği
muhafazakârlık — "sıfır" bir üst sınır değil, 1496 kelimelik bir örneklemdeki
gözlem.

Değerin paket medyanının (12.91) **altında** olması bilinçli: kelime korpusta
nadir olabilir ama onu üç kez yazmış olan kullanıcı için nadir değildir. Çıpa
paketin dağılımını değil, o kullanıcının dağılımını temsil ediyor.

> **Popülasyon vekildir.** Ölçümün kişisel yüzeyleri İngilizce listeden alındı
> (tr paketinde **ve morfolojisinde** bulunmayanlar) + elle yazılmış on gerçek
> vaka (kullanıcı adı, lakap, türetilemeyen soyad). Kısa İngilizce kelimeler
> Türkçe kelimelerle bol bol çakıştığı için popülasyon her iki ölçümde de
> kötümser. Ölçüm **mekanizmanın çalıştığını** gösterir; kullanıcı
> popülasyonunda kazanç iddiası değildir.

### Kabulün bedeli

Kabul motoru yeniden kurduruyor ve bu **token sınırında, ana thread'de** oluyor
(§5b: model sürümü yalnız token sınırında değişir). Ölçüldü (release, 210
kişisel yüzey, gerçek tr paketi + 30k kök):

```
kişisel kaynak (OOV süzgeci + trie)   2.1 ms
leksikon + decoder yeniden kurulumu   2.1 ms
```

Toplam ~4 ms, ve yalnız **kabul anında** — puan biriktiren ama eşiği geçmemiş bir
gözlem hiçbir şey kurmuyor. Yazma yolundaki tuş başına p99 bütçesine (8 ms)
girmiyor çünkü aynı olay değil: bu, kelime sınırında bir kereye mahsus.

### Tek sahiplik, dil, ve kimlik

**§7 tek sahiplik:** paket (form listesi ∪ morfoloji) yüzeyi zaten kabul
ediyorsa kişisel kopya kurulmaz. Süzgeç her kurulumda yeniden koşuyor, böylece
paket güncellenip kelimeyi içerir hâle geldiğinde kişisel kopya kendiliğinden
düşüyor.

**Dil = referans dil** (`LiteralChannel.oovLanguage`). Sözlük dışı bir token'ın
dili tanımı gereği gözlenmiyor. Kabulden önce yüzey referans dilde puanlanıyordu;
kabulden sonra başka bir dile atamak `Δ`'nın iki tarafını farklı dil terimleriyle
hesaplamak olurdu — kabul, dil kararını sessizce çevirmemeli.

**Kaynak kayda giriyor (§12.7).** Kişisel kaynak `LexiconSet`'in bir üyesi ve onu
yazmamak, kaydın kendi motorunu eksik anlatması olurdu — §12.1'in yasakladığı
şeyin ta kendisi. `engineConfigured` snapshot'ında `role: personal` bir `PackRef`
duruyor; özet kurulan trie'nin baytları üzerinden (aynı kelime kümesi aynı
baytları üretiyor). Diskte dosya karşılığı olmadığı için `ReplayEngineFactory`
onu `missingPacks`'e yazacak ve replay **ortam uyuşmazlığı** olarak
işaretlenecek. İstenen tam olarak bu: kişisel sözlükle kaydedilmiş bir yazım, o
sözlük olmadan birebir yeniden üretilemez ve kayıt bunu söylemeli.

Kabul anı **kayıt dışı bir motor değişikliğidir** (`applyCalibration` ile aynı
durum): deneme işaretleniyor ve kaydedici yenisine geçiyor. Sözlük, devretmede
sıfırdan kurulan koordinatöre `configure`'ın parametresi olarak veriliyor —
sonradan uygulansaydı yeni snapshot da leksikonu eksik anlatırdı.

### Kalıcılık ve gizlilik

Depo uzantı sandbox'ında (`personal.bkp`), kalibrasyonla **aynı gerekçe**: Tam
Erişim açılıp kapanabildiği için iki yazılabilir depo split-brain üretir.
Kalibrasyonun aksine **profil yok** — öğrenilen şey bir yüzey, tuş merkezlerine
bağlı değil; profil anahtarı koymak, klavye ölçüsünü değiştiren kullanıcıya kendi
adını yeniden öğretirdi.

Saklanan tek şey yüzey ve kaç kez doğrulandığı. Dokunma koordinatı, zaman
damgası, hangi uygulamada yazıldığı: hiçbiri. Yaş ölçütü bir **sıra numarası**,
saat değil. Parola alanında hiçbir şey öğrenilmiyor; üretimde tampon zaten
düşürülüyor ama yedek yol koordinatörü doğrudan kullanıyor ve başka bir katmanın
davranışına dayanan koruma, koruma değildir.

Yazma diske **devretmeden önce** yapılıyor: devretme yeni koordinatörün sözlüğünü
diskten okuyor ve yazmayı token sınırına bırakmak, tam da kabul edilen kelimeyi
bir sonraki denemede kaybettirirdi.

Bozuk dosya yok sayılıyor ve sözlük boş başlıyor: bozuk bir kişisel sözlükle
çalışmak aktif zarardır (`θ = ∞` yanlış yüzeylere gider), boş başlamak yalnız
faydayı erteler.

### Bilinen sınırlar

| Sınır | Sebep |
|---|---|
| İçe aktarım yalnız alanın gördüğü kadarını okuyor | `documentContext` iOS'un verdiği pencere; belgenin tamamına erişim yok. Metin parça parça verilebiliyor ve rapor okunan token sayısını söylüyor. |
| Güçlü kanalın üreticisi yok | Çubuk sözlük dışı literal'i gösteremiyor; göstermek `SuggestionOrigin`'e yeni bir durum, yani şema değişikliği demek. |
| Sembol/satır sonu kanıt üretmiyor | O yollarda düzeltme hiç denenmiyor; "değiştirmedi" olgu değil. |
| Dolu sözlük donuyor | 512 kabul edilmiş yüzeyde yeni bir zayıf gözlem kendisi düşüyor. Alternatif, kanıtı çok daha güçlü bir yüzeyi tek bir gözlem uğruna atmaktı. Kullanıcı yer açmak isterse siliyor. |
| Kazanç kullanıcıda ölçülmedi | Ölçüm vekil popülasyonda ve simüle dokunmalarla; gerçek kapı §12 verisiyle kurulacak. |

---


## 8.8 `F_ctx` — mekanizma kuruldu, model **kurulmadı**

Öznitelik 13 (§2) sözleşmenin ilk sürümünden beri tanımlı ve bugüne kadar
uygulanmamıştı. Bu bölüm **ne uygulandığını ve neyin kasıtlı olarak eksik
bırakıldığını** kaydediyor.

Uygulanan: paket formatı, decoder ve literal kanalı entegrasyonu, oracle
karşılığı, bağlamın yaşam döngüsü, üretim aracı, gecikme ölçümü.

Uygulanmayan: **modelin kendisi**. Depoda Türkçe bigram verisi yok ve
uydurulmuş bir tablo koymak, ölçülmemiş bir modeli ölçülmüş gibi göstermek
olurdu. `.bkg` paketi yokken `F_ctx ≡ 0` ve motor bugünkü davranışını **birebir**
koruyor — ayrı bir bayrağa gerek kalmamasının sebebi bu: görülmemiş çift de
zaten 0 aldığı için "paket yok" ile "hiçbir çift bilinmiyor" aynı motor.

### Paket **delta** saklıyor, olasılık değil

```
F_ctx(w | ctx) = −log P̂(w | ctx) + log P̂(w)
```

İki olasılık ayrı saklansaydı çalışma anında `log P̂(w)` bigram korpusundan,
`F_lex` ise form listesinden gelirdi — **iki ayrı normalizasyon**, ve farkları
anlamsız. §2.1 zaten unigram kütlesinin sahibini `F_lex` olarak sabitliyor ve
`F_ctx`'i onun üzerine delta olarak tanımlıyor. Delta paketin kendi içinde,
aynı korpustan hesaplanıyor; böylece form listesi başka bir korpustan gelse bile
terim iyi tanımlı kalıyor. Aynı hata argo katmanını ayrı kaynak olarak yüklerken
bir kez yapılmıştı.

**Görülmemiş çift → 0.** Olasılıksal olarak görülmemiş bir bigram unigram'dan
daha az olası olmalı (yani `F_ctx > 0`), ama o cezanın büyüklüğü veriden
gelmiyor. Kanıtın yokluğunda cezalandırmamak §5c asimetrisiyle uyumlu: gereksiz
koruma zararsız, gereksiz ceza kelimeyi kaybettirir.

### Terminal olmanın üç sonucu

§3.2 `F_ctx`'i terminal ilan ediyor; uygulama üç yerde bunu gösteriyor:

1. **Erken budamaya yardım etmiyor.** Terim yalnız kabul anında, aday
   materyalize edilirken ekleniyor. Beam genişletmesi onu görmüyor.
2. **Dedup anahtarı bağlam taşımıyor.** Bağlam token boyunca sabit olduğu için
   aynı yüzeye varan iki yol aynı `F_ctx`'i alır; anahtara koymak durumları
   gereksiz yere ayırırdı.
3. **Oracle da aynı terimi taşıyor.** Referans, taklit değil: modelde olan her
   terim orada da olmalı, yoksa §5.4/1 eşdeğerlik kapısı `F_ctx` eklendiği anda
   kırılır ve fark "beam yanlış" diye okunur. §8.5'te gayrıresmî insertion
   sınıfı eklenirken aynı hata yapılmış ve eşdeğerlik testi ayrışmayı
   yakalamıştı.

### `Δ`'nın **iki tarafı** da terimi taşıyor

`Δ = cost(literal) − cost(best)`. Terimi yalnız decoder tarafına eklemek,
bağlamın beklediği bir adayı ucuzlatırken literal'i olduğu yerde bırakırdı: `Δ`
bağlam gücü kadar şişer ve `θ` eşiği **sessizce düşmüş** olurdu. Literal kanalı
bu yüzden aynı paketi ve aynı bağlamı taşıyor.

Sözlük **dışı** bir literal için terim 0 kalıyor: paket yalnız gördüğü yüzeyleri
taşıyor ve OOV token orada yok. Yani bağlam kanıtı yalnız bilinen kelimeler için
var — bilinçli, çünkü OOV yolundaki maliyet zaten `c_unk` + karakter modeli.

### Bağlamın yaşam döngüsü

Bağlam **kapanmış önceki token**, kanonik biçimde (NFC + Türkçe küçük harf):
`Ve` ile `ve` aynı bağlam.

| Olay | Bağlam |
|---|---|
| Boşlukla commit, öneri seçimi | kapanan kelime |
| Boş token (art arda boşluk) | **değişmiyor** — önceki kelime bağlam olmaktan çıkmadı |
| Virgül, tire, kesme işareti | kapanan kelime |
| `.` `!` `?` `…` `:` `;` ve satır sonu | **düşüyor** — sonraki kelime öncekinin devamı değil |
| İmleç oynadı, seçim değişti, kanıt koptu | **düşüyor** — önündeki kelimenin ne olduğunu bilmiyoruz |

Son satır bir çıkarım değil bir itiraf: imleç taşındıktan sonra belgede
önümüzde duran kelimeyi *okuyabilirdik*, ama okuduğumuz şeyin bizim
kapattığımız token olduğunun garantisi yok. Yanlış bağlamla puanlamaktansa
bağlamsız puanlamak yeğdir.

**Prefix-causality (§3).** Bağlam `IncrementalDecoder` kurulurken kimliğe
çözülüp snapshot'lanıyor; token ortasında değiştirmek aktif beam'i etkilemiyor.
`languageModel` ile aynı kural, aynı gerekçe (§5b: model sürümü yalnız token
sınırında değişir). Kimliğin bir kez çözülmesi ayrıca aday başına yüzey
aramasını da ortadan kaldırıyor.

**Devretmede bağlam sıfırlanıyor.** Kaydedici devrettiğinde koordinatör
sıfırdan kuruluyor ve bağlam `nil` oluyor. Bu bir kayıp (o token bağlamsız
puanlanıyor) ama **replay sadakati açısından doğru**: canlı motor da replay de
`nil`'den başlıyor, dolayısıyla ikisi aynı motoru koşuyor. Bağlamı belgeden geri
okumak farkı kapatırdı ama olguyu çıkarımla değiştirmek olurdu.

### Üretim zamanı politikası — **geçici**

| Parametre | Değer | Gerekçe |
|---|---|---|
| en az çift sayımı | 2 | Tek gözlemin log-oranı korpus büyüklüğü kadar sapabilir; o değer veriden değil örneklem kazasından gelir. Gürültüye karşı **asıl** savunma bu. |
| `|F_ctx|` sınırı | 6 nat | Arka duruş, model değil. Leksikal maliyet dağılımının tamamı ~11 nat (tr-TR: 3.66 … 14.57); tek bir bağlam teriminin bunu aşması `F_ctx`'in delta olduğu iddiasını boşa çıkarırdı. Bağlam sıralamayı **çevirebilmeli**, tek başına belirlememeli. |

İkisi de veri geldiğinde kalibre edilecek. Sınıra dayanan çiftler `packbuild`
çıktısında **sayılıyor**: sessizce kırpmak, veriyi modelmiş gibi göstermek olurdu.

### Gecikme ölçüldü, doğruluk **ölçülmedi**

Doğruluk kapısı gerçek bigram verisi olmadan kurulamaz. Gecikme ise veriye
değil **tablo boyutuna** bağlı, ve sözleşme tuş başına p99 < 8 ms istiyor —
sentetik bir paket bu soruyu dürüstçe yanıtlıyor (`kbbench --bigram-latency`,
release):

```
40 000 yüzey · 999 670 çift · 8.3 MB
tuş başına p50   0.977 ms → 1.001 ms   (+0.024)
tuş başına p99   1.569 ms → 1.585 ms   (+0.015)
```

Ölçüm `results()` çağrısını da içeriyor: terim tam da orada uygulanıyor ve
yalnız `append`'i ölçmek onu ölçüm dışında bırakırdı.

### Açılma koşulu

1. Türkçe bigram sayımları — form listesiyle **aynı korpustan** ya da kendi
   unigram sayımlarıyla birlikte (`packbuild --bigrams` ikisini de istiyor).
2. Lisans kaydı: `LICENSES.md`'ye kaynak ve türetme zinciri.
3. Held-out ölçüm: `F_ctx`'in doğruluğu **artırdığının** ve `Δ`'yı bozmadığının
   gösterilmesi. §8.1.1'in dersi burada da geçerli — ölçümün kendisi kusurlu
   olabilir; kolun tasarımı veri gelmeden yazılmalı.

---


## 8.9 Erişilebilirlik — koordinatsız girdi

VoiceOver'la yazan kullanıcı tuşa **basmıyor**: öğeyi keşfediyor, adını duyuyor
ve çift dokunarak etkinleştiriyor. O çift dokunuşun koordinatı ekranın herhangi
bir yeri; sistem bize yalnız **hangi öğenin** etkinleştirildiğini söylüyor.

Bu klavye için sıradan bir uyarlama değil, doğrudan modelin girdisine dokunan
bir durum: bütün skor sözleşmesi *"basılan harfi değil dokunma koordinatını"*
okumak üzerine kurulu ve burada dokunma koordinatı **yok**.

### Öğeler etkinleştirilebilir, kanıt sahte değil

Üç seçenek vardı ve ikisi yanlıştı:

1. **Bağlamamak** (bu turdan önceki hâl). Tuşlar okunuyor, çift dokunuş hiçbir
   şey yazmıyor. Dürüst ama klavye kullanılamaz.
2. **Bağlayıp tuş merkezini gözlem gibi işlemek.** Yazma çalışır, ve kalibrasyon
   sessizce bozulur: sentetik dokunmaların sapması **tanım gereği sıfır**, yani
   her VoiceOver kelimesi öğrenilmiş parmak sapmasını sıfıra doğru çeken bir
   örneklem olur. §8.1.1 tam merkeze konan dokunmaların ne yaptığını zaten
   kaydediyor — orada bir ölçümü bozmuştu, burada ürünü bozardı.
3. **Bağlayıp kanıtın türetilmiş olduğunu taşımak.** Uygulanan bu.

Nokta yine üretiliyor (decoder bir `Point` istiyor ve tuş merkezi doğru değer),
ama **nereden geldiği** motora kadar gidiyor: `KeyActivation` → `insertLetter(…,
synthetic:)` → `ComposingSession.evidenceIsSynthetic`.

### Türetilmiş kanıdın iki sonucu

| | Neden |
|---|---|
| **Otomatik düzeltme yok** | `Δ = cost(literal) − cost(best)`'in uzamsal terimi yapay: literal her harfte tam merkezde olduğu için en iyi değeri alıyor, aday tarafındaki fark tamamen leksikal. Böyle bir `Δ`'yı `θ` ile karşılaştırmak, kullanıcının **duyarak seçtiği** harfleri fat-finger düzeltmesine açmak olurdu. Seçim kipindeki kural (§8.4, `selectionHasRealEvidence`) bunun aynısı; yazma yolunda da geçerli olması gerekiyordu. |
| **Kalibrasyon örneği yok** | Yukarıdaki (2). |

Kapatılmayan şey **öneri**: aday listesi çıkmaya devam ediyor ve kullanıcı
adaya dokunabiliyor. §5c asimetrisinin doğru tarafı bu — otomatik karar
kanıt ister, kullanıcının kendi kararı istemez.

Öneri seçimi normalde `.strong` etiket üretiyor; sentetikte yine öğrenilmiyor.
"Kullanıcı bu kelimeyi kastetti" doğru, "parmağı şuraya düştü" hâlâ uydurma —
güçlü etiket yalnız **hizalamayı** güçlendirir, gözlemin kendisini değil.

### Leke token başına

Karışık token (kullanıcı VoiceOver'ı kelime ortasında açtı) **bütünüyle**
düşüyor. Hangi karakterin hangi kanıttan geldiğini saklamak mümkündü ama
yalnız kalibrasyonun okuyacağı bir alan eklerdi; §5c asimetrisi tarafı
belirliyor: bir örnek kaybetmek, sapmayı kirletmekten ucuz.

Leke token sınırında düşüyor ve **geri açmada geri geliyor**: `⌫` ile boşluğu
silip kelimeyi yeniden açmak dokunmaları geri yüklüyor, lekeyi yüklemeseydi
aynı kelime ikinci kapanışta gerçek gözlem sayılırdı. Aynı sebeple seçim
kipi de devraldığı token'ın lekesini okuyor — `beginEditingSelection` "bu
kelimeyi biz yazdık"tan "kanıt gerçek" sonucunu çıkarıyordu ve o çıkarım
sentetik token'da yanlış.

### Kişisel sözlük: ayrı kural değil, aynı kuralın sonucu

Sentetik token kişisel sözlüğe kanıt üretmiyor. §8.7 kanıtı *reddedilmiş
düzeltme* olarak tanımlıyor ve burada düzeltme **hiç denenmedi** — karar
sorulmadığı için `θ` de üretilmiyor, kapı kendiliğinden kapalı. Ayrıca bir
kontrol **eklenmedi**: kuralı ikinci bir yerde tekrarlamak, birinin değişip
diğerinin kalmasına açık kapı bırakır.

Sonuç bir sınır: VoiceOver'la yazan kullanıcı klavyeye yeni kelime
**öğretemiyor**. Kayıp göründüğü kadar büyük değil — kişisel sözlüğün iki
işlevi (otomatik düzeltmeden koruma, yanlış harften kurtarma) zaten fat-finger
içindi ve o kullanıcıda ikisi de yok. Korpus içe aktarımı (§8.7) o yoldan
çalışmaya devam ediyor.

### Örtü panel — yeni özelliğin eski bir kusuru işler hâle getirmesi

`cancelInteraction()` panel açılırken **parmakları** kesiyor: ⌫'yi basılı
tutarken ⚙︎'ye basmak panelin arkasında silmeyi sürdürüyordu ve o düzeltilmişti.
Erişilebilirlik etkinleştirmesi ise parmak değil — panelin arkasındaki tuşlar
erişilebilirlik ağacında duruyordu ve VoiceOver kullanıcısı sağa kaydırarak
**görünmeyen** bir klavyeye ulaşabiliyordu.

Bu kusur §8.9'dan önce zararsızdı: tuşlar okunabiliyor ama etkinleştirilemiyordu,
yani en kötü ihtimalle gürültüydü. Etkinleştirme bağlanınca **gerçek** oldu —
panel açıkken görünmeyen bir tuşa basıp belgeye harf yazmak. Kayda değer olan
şu: yeni özellik yeni bir hata üretmedi, **var olan bir kusuru işler hâle
getirdi**. Erişilebilirliği bağlamanın maliyeti yalnız yeni kod değil, o zamana
kadar sonuçsuz kalmış eksikliklerin de sonuç doğurmaya başlaması.

İki savunma, ayrı gerekçelerle:

1. `accessibilityViewIsModal` — panelin kardeşlerini ağaçtan düşürüyor. Doğru
   ve genel çözüm bu; gezinme de panelin içinde kalıyor.
2. `allowsAccessibilityActivation` — tuş yüzeyinin kendi kapısı. Modalliğin
   doğru uygulanmasına bel bağlamamak için, ve `cancelInteraction`'ın var olma
   sebebiyle aynı: o dersin bedeli bir kez ödendi.

Panel açılışında ve kapanışında `.screenChanged` gönderiliyor. Bildirimsiz
açılan panelde odak ⚙︎ düğmesinde kalıyor ve kullanıcı bir panelin açıldığını
hiç duymuyor; argüman odağın nereye gideceğini söylüyor (açılışta panele,
kapanışta tuş yüzeyine).

### Ayar paneli — etiketin ayrı öğede kalması

Tuş yüzeyi bağlanınca ⚙︎ paneli de ekran okuyucuya **ulaşılabilir** oldu, ve
ulaşılabilir olması kullanılabilir olması demek değil. Üç yerde aynı kusur
vardı: etiket ile denetim ayrı öğeler ve VoiceOver ikisini ayrı duraklar olarak
okuyor, dolayısıyla denetime gelindiğinde elde **isimsiz bir değer** kalıyor.

| Yer | Duyulan | Sorun |
|---|---|---|
| Kişisel sözlük satırları | "sil, düğme" ×N | Hangi kelime olduğu yalnız ekrana bakınca belli — ve bu **yıkıcı** bir eylem |
| Ölçü sürgüleri | "%40, ayarlanabilir" | Hangi ayar olduğu bir önceki durak hatırlanarak çıkarılıyor |
| Tema / sayı sırası | "açık, anahtar" | Aynısı |

Silme düğmesi diğer ikisinden ayrı duruyor: orada yanlış öğeyi seçmek bir
ayarı kaydırmıyor, **kullanıcının öğrettiği kelimeyi siliyor**. Etiket artık
kelimeyi taşıyor (`"<kelime> sözcüğünü sil"`).

Sürgülerde ayrıca `accessibilityValue` biçimlendirilmiş değere bağlandı:
`UISlider` varsayılan olarak yüzde okuyor, oysa panelin `valueLabel`'ı tam da
bu yüzden var — göreli bir ifade kullanıcının aynı ayarı ikinci cihazda
tekrarlamasını imkânsız kılıyor (§Ayarlar).

### Kayıt ile VoiceOver aynı anda çalışmıyor

Kaydedici VoiceOver açıkken **hiç kurulmuyor**; kayıt sürerken açılırsa
bırakılıyor ve sebebi durum satırına yazılıyor.

Sebep şema eksiği değil bir olgu: kayıt her harfe bir dokunma olgusu bağlamayı
şart koşuyor (`touchID` harf komutlarında zorunlu) ve etkinleştirmenin bir
dokunması yok. Tuş merkezini `rawX/rawY`'ye yazmak, §12'nin **toplamak için var
olduğu** veri kümesinin içine uydurulmuş bir gözlem koymak olurdu; §12.6.1
kaydın olgu yazacağını, çıkarım yazmayacağını zaten sabitliyor.

Kayıt ekranı da (`RecorderViewController`) etkinleştirmeyi reddediyor —
aynı gerekçe, ve orada amaç doğrudan gerçek yazım davranışını ölçmek.

### Kelime ortasında bırakma — bulunan hata

Bu bölümü yazarken ortaya çıkan ve **kapatılan** bir kusur: kaydedici
bırakıldığında yedek koordinatör boş başlıyor, ama belgede yarım bir token
duruyor. Yedek yol o andan sonra yüzeyin yalnız **yeni kısmını** kendi token'ı
sanıyordu.

Ölçülen iki zarar (`kal` yazılmışken kaydedici bırakılıp `em` yazıldığında):

| | Sonuç |
|---|---|
| Otomatik düzeltme | Parça (`em`) tek başına yargılanıyor; ölçümde `Δ = −4.11` ile karar gerçekten kuruluyordu. |
| Öneri seçimi | `replaceDisplay` `display.count` kadar siliyor: `kalem` seçmek belgeyi **`lslkalem`** yapıyordu. |

VoiceOver bunun **yeni bir tetikleyicisi**; kusurun kendisi yazma hatası
yolunda (`writeFailed`) zaten vardı ve görülmemişti.

Kapatma yeni bir kavram gerektirmedi — gereken epistemik durum zaten vardı:
**yüzey biliniyor, kanıt bilinmiyor** = `isDetached`. Yedek koordinatör yarım
token'ı kopuk olarak devralıyor (`adoptDetachedSurface`) ve mevcut kapıların
hepsi kendiliğinden kapanıyor: `correctionDecision`, `replaceDisplay` ve
`pickSuggestion` zaten kopuk token'a dokunmuyor, `finishToken` onu geçmişe
yazmıyor. Devralınan yüzey **ölen oturumdan** okunuyor, belgeden
ayrıştırılarak değil — biri olgu, diğeri tahmin.

Devralınan yüzeyin bir kısmı bize ait olmayabilir (host'un metni). §5c
asimetrisi bunu kabul edilebilir kılıyor: fazladan devralmanın bedeli
düzeltilebilir bir kelimeyi düzeltmemek, tersinin bedeli kullanıcının metnini
bozmak.

### Doğrulama — okumak yetmedi, çalıştırmak gerekti

§8.9'un büyük kısmı `swift test` altında koşamıyor: etiketler, `keyboardKey`
niteliği ve öğe listesinin ne zaman kurulduğu UIKit'e ait. Bu yüzden ilk turda
hepsi **kodu okuyarak** doğrulanmıştı — ve sonraki turlarda okuyarak üç ayrı
kusur bulundu (panel arkasında etkinleştirilebilen tuşlar, isimsiz denetimler,
`ABC` diye okunan kapatma düğmesi). Okuma açıkça yeterli bir yöntem değildi.

`AccessibilityUITests` (XCUITest, tezgah üzerinde) ağacı **gerçek bir
erişilebilirlik istemcisiyle** soruyor: VoiceOver'ın kullandığı yoldan. Dört
şey sabitlendi — işlev tuşlarının Türkçe okunması, harf etiketinin shift'i
izlemesi, düzlem değişiminde öğelerin yenilenmesi, 29 harfin tamamının
ulaşılabilir olması.

İkisi **ilk koşuşta kırmızı yandı** ve sebep erişilebilirlik kodu değildi:
tezgah `⇧` ve `123` tuşlarını `default: break` ile yutuyordu. Yani tezgahta o
tuşlara basan bir kullanıcı hiçbir şey olmadığını görüyor ve bunun tezgah
eksiği mi klavye hatası mı olduğunu ayırt edemiyordu. Test yazmak, sınamak
istediğinden **başka** bir kusuru ortaya çıkardı; tezgah düzeltildi.

Kapsamadığı şey açık: `accessibilityActivate()` yolu XCUITest'ten
sınanamıyor — `.tap()` gerçek bir dokunma sentezliyor, yani
`touchesBegan/Ended`'den geçiyor. Sentetik kanıt yolunun kendisi `swift test`
altında kapalı (`InputCoordinatorTests`); burada sınanan şey öğelerin var
olduğu, doğru adlandığı ve doğru zamanda güncellendiği.

**Cihazda VoiceOver turunun yerini tutmuyor.** Aradaki boşluğu daraltıyor.

### Ölçülmedi

Bu bölümde ölçüm yok ve olduğu iddia edilmiyor. VoiceOver'la yazan bir
kullanıcının hız/doğruluk profili elimizde değil; yapılan şey **modelin
bozulmamasını** garantiye almak, kazancı ölçmek değil. Ölçülebilir hâle
gelmesi §12'nin veri toplama protokolüne yeni bir koşul eklemeyi gerektirir
ve o koşulun kaydı yukarıdaki sebeple bugün mümkün değil.

---

## 8.10 Nokta tuşu — ızgaraya yuva eklemenin bedeli

3. satır `⇧ + 9 harf + ⌫` idi; artık `⇧ + 9 harf + . + ⌫`. Satırın birim
bütçesi sabit (11 birim) olduğu için yeni yuvanın genişliği bir yerden gelmek
zorundaydı ve **harflerden** alındı: varsayılan ölçüde yuva 0.889 → 0.80 birim,
yani her harf tuşu **%10 daraldı**.

### Neden `⇧`/`⌫`'den alınmadı

Alternatif vardı ve modele hiç dokunmuyordu: `⇧` ve `⌫` 1.5 → 1.0 birime
inseydi harf merkezleri **kılına dokunulmadan** kalırdı — ne kalibrasyon
bayatlar, ne kuşak damgası gerekir, ne de bu bölüm yazılırdı.

Seçim yine de harflerden yana yapıldı ve bu bir tercih, bir çıkarım değil:
`⇧`/`⌫` üzerinde yapılan bir daralma o iki tuşun ıskalanma oranını artırır ve
ikisi de **düzeltilemez** tuşlar (yanlış basılan `⌫` bir karakter siler, geri
getirecek bir model yok). Harflerdeki daralmanın karşılığında ise decoder
duruyor. Yanlış basılan harf zaten sistemin çözmek için var olduğu problem.

### Bedel **ölçülmedi** ve ölçülemez

Sayı üretmek kolay olurdu: `kbbench` bu geometriyle koşulur, top-1 okunur,
öncekiyle karşılaştırılır. Sonuç **anlamsız** olurdu ve sebebi §8.1.1'de zaten
kayıtlı.

`TouchSimulator` sapmayı `sigmaXFactor × key.width`'ten üretiyor — yani tuş
%10 daralınca simüle edilen parmak da %10 daralıyor. Ölçüm ölçek-değişmez
çıkar ve "fark yok" der. Gerçek parmak daralmıyor.

Bu, §8.1.1'in tam merkeze konan dokunmalarla ölçüm yapma hatasının aynısı:
model kendi varsayımıyla sınanırsa her zaman geçer. Doğru cevap sayı
uydurmak değil, **ölçülemediğini yazmak**:

| | |
|---|---|
| Ölçülebilir | Ölçülemez |
| Yuva geometrisi tam doluyor mu (`LayoutGeometryTests`) | Daralmanın gerçek hata oranına etkisi |
| Nokta yuvası harflerle çakışıyor mu | Kullanıcının bunu fark edip etmeyeceği |

Gerçek bedel §12'nin dokunma verisiyle görülecek: aynı kullanıcının iki
kuşaktaki kayıtları karşılaştırılabilir hâle geldiğinde. Kuşak damgası bunu
mümkün kılıyor — kayıtlar hangi ızgarada alındığını artık **söylüyor**.

### Kuşak damgası (`-g2`)

`idSuffix` bugüne kadar kullanıcının seçtiği ölçüleri kodluyordu ve mantık
şuydu: *ölçüler aynıysa geometri aynıdır*. Nokta tuşu bu çıkarımı bozdu —
`⇧` ve `⌫` hiç değişmeden bütün harf merkezleri kaydı.

Damgasız iki somut zarar:

1. `CalibrationStore.ProfileKey` eski profili yeni geometriye bağlardı: 0.889
   birimlik tuşlarda öğrenilen sapma 0.80 birimlik tuşlara uygulanırdı. Sessiz,
   çünkü "biraz kaymış" ile "yanlış geometri" dışarıdan aynı görünür — §8.6
   devretme hatasının sinsiliği.
2. Eski kayıtlar yeni ızgarayla çözülürdü. v3'te `layoutFingerprint` bunu
   yakalıyor; **v2 kayıtlarında parmak izi yok** ve orada tek koruma kimliğin
   kendisi.

`init?(idSuffix:)` artık damgayı **zorunlu** tutuyor ve bilinmeyen kuşağı da
reddediyor: ileri yön (gelecekteki bir kimliği bugünün ızgarasıyla kurmak) geri
yön kadar tehlikeli. Reddedilen kimlik `RecordedLayout.unknownLayoutID` olarak
çıkıyor — kayıt atlanıyor, sessizce yanlış çözülmüyor.

Bunun **kabul edilen** bedeli: nokta tuşundan önce toplanmış kalibrasyon
profilleri kullanılmıyor ve kullanıcı sapmayı sıfırdan öğretiyor. Doğru takas —
alternatif, yanlış geometride öğrenilmiş bir sapmayı doğru sanmaktı.

### Uzun basma → virgül

Virgül `123`'e geçmeyi gerektiriyordu; artık nokta tuşunu basılı tutmak
yetiyor. Mekanizma `⌫` tekrarından **ayrı** ve bu bilinçli: tekrar bir *süre*
işlemi (ne kadar tutarsan o kadar sil) ve tik başına yeniden zamanlanıyor;
virgül tek bir karakter. `Self.repeats(_:)`'e nokta eklemek parmak kalkana
kadar virgül yağdırırdı.

Eşik `cadence.initialDelay`'den geliyor (kullanıcının `⌫`'de öğrendiği süre) ve
eşik geçildiği anda hem virgül yazılıyor hem tuşun etiketi `,` oluyor.
Emisyonu bırakışa ertelemek (globe uzun basmasının yaptığı) burada yanlış
olurdu: globe bir menü açıyor ve menü kendisi geri bildirim, virgülde ise
kullanıcı ne alacağını iş işten geçtikten sonra görürdü.

VoiceOver karşılığı özel eylem (`virgül`) — çift dokunuş bir *süre* taşımıyor
ve olmasaydı virgül o kullanıcı için harf düzleminde hiç erişilemezdi (§8.9'daki
`kelimeyi sil` ile aynı gerekçe).

### Ölçülen tek şey: satır tam doluyor

Nokta yuvasının genişliği hesaplanmıyor, `⌫`'nin sol kenarına kadar
**uzatılıyor** — `⏎`'nin 4. satırda artanı almasıyla aynı gerekçe. Yuvarlama
artığı `ç` ile `⌫` arasında hiçbir tuşa ait olmayan bir şerit bıraksaydı oraya
düşen dokunma `.content`'e, oradan `nearestKey` ile bir **harfe** giderdi:
kullanıcı noktaya basıp harf yazardı.

`LayoutGeometryTests` bunu dokuz ölçü kombinasyonunda sabitliyor ve çakışmama
invariantı da nokta yuvasını kapsıyor — düzeltilen özgün hata (`⇧`/`⌫` `z` ve
`ç`'yi yutuyordu) tam olarak bu sınıftandı.

---

## 8.11 Boşlukta imleç sürükleme

Boşluk basılı tutulup sürüklenince imleç geziyor: **yatay = kelime kelime**,
**dikey = o kelimenin içinde karakter karakter**. Aynı jestte yalnız bir eksen
çalışıyor.

### Eksen kilidi neden zorunlu

İki ekseni birlikte çalıştırmak "daha yetenekli" görünüyor ve kullanılamaz:
parmak hiçbir zaman saf yatay gitmiyor, dolayısıyla kelime atlarken imleç
kelimenin içinde de kayardı ve kullanıcı iki hareketin hangisinin ne yaptığını
ayırt edemezdi. Kilit ilk eşik geçişinde kuruluyor ve **parmak kalkana kadar**
duruyor; eksen değiştirmek yeni bir jest gerektiriyor.

Beraberlikte yatay kazanıyor: jestin ilan edilen işi kelime kelime gezinmek,
dikey onun ince ayarı.

### Dikey eksen kelimeyi **değiştirmiyor**

Sınırlar jest başında bir kez okunuyor (`WordBoundaries.currentWord`) ve
hedef ofset o aralığa kırpılıyor. Parmak ne kadar giderse gitsin imleç
kelimenin dışına çıkmıyor — jestin var olma sebebi tam olarak bu: kullanıcı
kelimeyi kaybetmeden içinde istediği yere gelebilsin.

Kırpma **hedefte**, adımda değil. Adımı kırpsaydık sınırın ötesinde harcanan
mesafe birikir ve parmak geri geldiğinde imleç gecikmeli tepki verirdi.

İmleç boşluktaysa aralık `(0, 0)` ve dikey eksen hiçbir şey yapmıyor. En yakın
kelimeye atlamak da mümkündü; yapılmadı çünkü kullanıcı parmağını kaldırmadan
hangi kelimeye girdiğini göremez.

### Mutlak öteleme, artımlı değil

Adımlar parmağın **başlangıçtan** toplam ötelenmesinden hesaplanıyor. Artımlı
toplamda yuvarlama artıkları birikir ve parmağı geri getiren kullanıcı
başladığı yere dönemez — jestin en çok güven isteyen kısmı tam da geri
dönebilmek.

### Bağlam jest başında **bir kez** okunuyor

İlk uygulama her karede host'a bağlam soruyordu ve yanlıştı:
`adjustTextPosition` proxy'yi anında güncellemiyor, yani bir sonraki kare hâlâ
eski konumu anlatan bir bağlam okuyabiliyor ve ofseti yanlış yerden
hesaplıyordu. Ardışık kareler arasındaki bu yarış tek karede birden çok kelime
atlamayı düzeltmekle kapanmıyordu.

Çözüm bağlamı jest başında bir kez yakalamak ve jest boyunca ona sabit kalmak
(`CursorDragSession`). Hedef mutlak olduğu için her kare "başlangıçtan kaç
kelime uzakta olmalıyım" sorusunu yeniden cevaplıyor; çağıran farkı alıyor ve
birikim olmuyor.

Bedeli: bağlam host tarafından kırpılıyor (çoğu host'ta içinde bulunulan
paragraf) ve jest o pencerenin dışına çıkamıyor. Sınıra dayanan sürükleme
**duruyor**, yanlış yere gitmiyor.

### Ofsetler UTF-16, sınır tespiti grapheme

`adjustTextPosition(byCharacterOffset:)` `UITextInput` konumlarına dayanıyor ve
o katmanın tamamı `NSString` semantiği. Kelime sınırını grapheme üzerinde bulup
ofseti grapheme sayarak vermek emoji içeren metinde imleci kelimenin **ortasına**
düşürürdü: `👨‍👩‍👧` tek `Character` ama 8 UTF-16 birimi.

İki birim bilerek farklı: kelimenin nerede bittiğine grapheme karar veriyor
(bir emoji'nin yarısında kelime bitmiyor), ne kadar ilerleneceğini UTF-16
sayıyor. Türkçe düz metinde ikisi birebir aynı; fark yalnız emoji/ZWJ
dizilerinde ortaya çıkıyor. **Cihazda doğrulanmalı** — host'ların `UITextInput`
uygulaması teoride grapheme tabanlı olabilir.

### Ne söylenmiyor: "imleç oynadı"

Boşluk yazımını bastıran bayrağın adı `didRequestMove` ve söylediği tam olarak
şu: *jest başında okunan bağlam içinde, sıfır olmayan bir hareket istendi.*

"İmleç oynadı" demiyor ve **diyemez**: `adjustTextPosition` sonuç döndürmüyor
ve host'un isteği karşılayıp karşılamadığı gözlemlenemiyor. Yakalanmış bağlamın
içindeki kırpma yönetiliyor; host'un geçerli bir ofseti kısmen uygulaması
yönetilmiyor ve yönetildiği iddia edilmiyor.

Bastırma kararı için bu yeterli: kullanıcı gerçekten sürükledi, boşluk
beklemiyor. Belgenin başında bir kelime geri istemek ise sıfır ofset üretiyor ve
o jest boşluk yazmaya devam ediyor.

### Kip açıkken jest **klavyenin tek sahibi**

Sahiplik guard'ı (`spaceDragTouch == nil`) yalnız ikinci bir jestin açılmasını
engelliyordu, **commit'i değil**: ikinci parmak normal yoldan harf ya da boşluk
yazabiliyordu ve o mutasyon jestin dayandığı sabit bağlamı geçersiz kılıyordu.

Kip açılırken sahip dışındaki bütün parmaklar düşürülüyor ve kip açıkken yeni
parmak `activeTouches`'a hiç girmiyor. Alternatif ("sonraki commit'te jesti
bitir") seçilmedi: kullanıcı imleci konumlandırırken yazmayı beklemiyor ve
kazara değen bir parmağın metne karakter sokması, jestin engellemek için var
olduğu şeyin ta kendisi.

Düşürülen parmaklar bırakıldığında kayda **`.cancelled`** olarak giriyor.
Eskiden `unhitOutcome` yoluna düşüp `.leftBounds` yazılıyordu — "parmak klavye
dışına kaydı", oysa parmak yerinde duruyor ve onu düşüren klavyenin kendisi.
Kusur bu jestle gelmedi: düzlem değişimi ve panel açılışı (`cancelAllTouches`)
aynı yalanı söylüyordu. Şemaya yeni bir `Outcome` **eklenmedi**; `.cancelled`
zaten olanı doğru anlatıyor ve değer eklemek bütün v3 okuyucularını
ilgilendirirdi.

### Kelime tanımı

Kelime = boşluk olmayan karakterlerin maksimal dizisi. Noktalama kelimeye
dahil: `kalem.` tek kelime. Ayırmak "daha doğru" görünüyor ama kullanıcı için
noktadan önce duran fazladan bir engel demek, ve sistem klavyesi de böyle
davranıyor — jest onun kas hafızasını kullanıyor.

### Kayıt bu jesti **anlatamıyor**

`ReplayCommand` kümesinde imleç hareketinin karşılığı yok. Komut eklemek de
doğru değil: imlecin nereye gittiği host'un metnine bağlı ve replay o metni
yeniden kurmuyor, yani kaydedilen ofset başka bir belgede başka bir yeri
gösterirdi.

Bu yüzden jest imleci oynattığında `noteStateChangedOutsideTheLog()` çağrılıyor
ve `rollOverIfNeeded` denemeyi kapatıyor. `selectionChanged` bunu
karşılamıyordu: orada bayrak yalnız seçim varsa ya da bir şey değiştiyse
kalkıyor, düz bir imleç hareketi sessiz geçiyordu.

Kayıt ekranında jest **hiç açılmıyor** (`onSpaceDragChanged` bağlanmamış):
orada amaç yazım davranışını ölçmek ve her jest denemeyi kapatırdı.

### Yedek koordinatör imleç hareketini görmüyordu — bulunan hata

`readSelection` uzun süre yalnız `input`'u (kaydedicinin koordinatörü)
uyarıyordu. Kaydedici çoğu oturumda **yok**; o hâlde imleç oynadığında yedek
koordinatörün composing token'ı yerinde kalıyor, belgede başka bir yeri
anlattığı hâlde. Sonucu bilinen sınıftan: öneri seçimi `display.count` kadar
siliyor ve metni bozuyor (§8.9'daki yarım token devrinin aynısı).

Kusur yeni değil — host'a dokunup imleci taşımak da aynı yoldan geçiyordu ve
görülmemişti. Boşluk sürüklemesi onu **sık** hâle getirdi; §8.9'daki örtü panel
dersinin birebir tekrarı: yeni özellik eski bir kusuru işler yaptı.

İki koordinatör birden uyarılmıyor — `handleSelection` seçim varken belgeyi
değiştiriyor (`beginEditingSelection`) ve ikisi aynı düzenlemeyi iki kez
uygulardı. Yazan hangisiyse o haberdar ediliyor.

### Eşik ve geri bildirim

Kip **basılı tutmanın ardından** açılıyor, eşik `⌫` ve nokta ile aynı
(`cadence.initialDelay`). Eşiksiz açmak daha akıcı görünüyor ama boşluğa basıp
parmağını hafifçe kaydıran herkesin imlecini oynatırdı — ve boşluk klavyenin en
çok basılan tuşu.

Kip açılınca boşluğun yazısı `◂ ▸` oluyor: kullanıcı parmağını kaldırmadan
kipte olduğunu görmeli, yoksa boşluk yazacağını sanıp sürükler. İmleç fiilen
oynadıysa bırakışta boşluk **yazılmıyor**; oynamadıysa jest sıradan bir boşluk
basışı olarak bitiyor.

### VoiceOver

Jest bir **öteleme** istiyor ve VoiceOver'da öteleme yok — parmak gezinip çift
dokunuyor. Boşluk tuşuna iki özel eylem bağlandı (`bir kelime geri`, `bir
kelime ileri`), yani aynı yetenek ayrık adımlar hâlinde duruyor.

Dikey eksenin karşılığı **yok ve olmamalı**: VoiceOver metni karakter karakter
zaten gezdirebiliyor (rotor) ve ikinci bir yol koymak sistemin kendi
mekanizmasıyla yarışırdı.

### Mantık çekirdekte, çünkü orada sınanabiliyor

Bağlam okuması, eksen kilidi, mutlak hedef → ofset çevrimi ve boşluk bastırma
kararı `CursorDragSession`'da; controller'da kalan tek iş ofseti proxy'ye
vermek. Önce controller'daydı ve orada `swift test` altında koşamıyordu
(`UIInputViewController` alt sınıfı) — oysa jestin en kırılgan kararları tam
olarak bunlar.

### Ölçülmedi

Jestin hız ya da doğruluk kazancı hakkında bir sayı yok ve olduğu iddia
edilmiyor. Ölçülen tek şey aritmetik: kelime sınırları, UTF-16 birimi, eksen
kilidi, kırpılmış bağlamda geri dönüşün başlangıcı aşmaması ve sıfır ofsetin
hareket sayılmaması (`CursorDragTests`).

Cihazda doğrulanmayı bekleyen iki şey var ve ikisi de kod okunarak
kapatılamaz: `adjustTextPosition`'ın gerçek host'lardaki birim yorumu
(emoji/ZWJ ile) ve çok parmaklı kullanımda kipin hissi.

---

## 8.12 Faz 4 · morfoloji, sözlüksel sınıflar ve okunuş

### Ölçülen başlangıç: graf iş görmüyordu

20 günlük Türkçe formdan **yalnız 1'i** morfolojiden türüyordu; 11'i 70k düz
listede duruyordu, 8'i hiç yoktu. Dili graf değil liste taşıyordu ve bu
rastgele hissediliyordu: `kitabımın` listede olduğu için çalışıyor,
`kalemimin` — aynı yapı — çalışmıyordu.

### İsim tarafı: eksik zincirler

Kapsam matrisinin en pahalı eksiği iyelik sonrası genitifti (`kalemimin`,
`panelinin`). Eklendi; yanına 2. çoğul iyelik ve çoğuldan genitif geldi
(sonuncusu `-ki` eklendikten sonra ölçümle çıktı: `evdekiler` türüyordu ama
`evdekilerin` türemiyordu).

**3. çoğul iyelik `-lArI` bilerek eklenmedi.** Yüzeyi `-lAr + -(s)I` zaten
üretiyor; ayrı ek aynı yüzeye ikinci bir yol açar ve §9'da ölçülen `surfaceId`
parçalanmasını doğrudan büyütürdü. Ayrım anlamsal, decoder yüzey üretiyor.

### `-ki` ve grafın ilk çevrimi

`evde → evdeki → evdekiler → evdekilerin → evdekilerinki` — ilkece sınırsız.
Türkçe gerçekten böyle. Bunun için hâller tek `afterCase` durumundan çıkarılıp
`afterLocative` / `afterGenitive` / `afterNominalCase` diye ayrıldı: `-ki`
yalnız ilk ikisinden türüyor, `eveki` ya da `evdenki` üretilmemeli.

`-ki`'nin hedefi `nounRoot`: sonrasında bütün isim çekimi geliyor ve ayrı bir
`adjectivalStem` durumuna 14 ekin kopyasını koymaktansa oraya bağlamak tek
bakım noktası bırakıyor. Bedeli hafif aşırı üretim (`evdekim`).

Ünlü uyumu **yok**: `-ki` değişmez. `.archiI` kullanmak `kitaptakı`
üretirdi. Bilinen eksik `-kü` (`bugünkü`, `dünkü`) — kapalı ve çok küçük sınıf.

### `maxSurfaceLen`in anlamı değişti

Eski test "graf çevrimsiz olmalı" diyordu ve `-ki` eklenince kırıldı. Kırılma
regresyon değil, **eski test bunu zaten haber veriyordu**. Yapısal üst sınır
(en uzun kök + en uzun ek zinciri) çevrimle tanımsızlaştı.

Sınır kalkmadı, anlamı değişti: artık decoder'ın emisyon bütçesi. Dilbilgisi
değil bellek ve beam koruması. Test de tersine döndü — çevrimin **var
olduğunu** sabitliyor, çünkü kazara kaybolursa `evdekiler` sessizce
üretilemez hâle gelir.

### Sözlüksel sınıflar: sıralamayı ters kurmuşuz

Fiil tarafı eklenince top-1 **%89.2 → %87.4** düştü. Sebep ölçümle bulundu:
graf `geltiş`, `gelililmem`, `kitabmıştın`, `gelmeecek` gibi yüzlerce çöp
üretiyor ve top-k'yı dolduruyordu.

Üç ayrı kök neden:

1. **Geniş zaman ve ettirgen sözlüksel.** `gel-ir` ama `yaz-ar`; `yap-tır`
   ama `başla-t`. İki yüzeyi birden üretmek her fiile yanlış bir aday ekliyor.
2. **Ek-fiilde `bufferIfVowel` yanlış yorumlanıyordu.** `-(y)mIş` ünsüzden
   sonra `mIş` veriyor — ünsüz. Varsayılan çıkarım onu ünlü sayıp kökte
   yumuşama tetikliyordu: `kitapmış` yerine `kitabmış`. `Suffix`'e açık
   geçersiz kılma alanı eklendi.
3. **Edilgen `-Il` `verbRoot`'a dönünce kendisiyle yığılıyordu**
   (`gelililmen`). Çıkarıldı; doğru çözümü kendi `afterPassive` durumu ve
   oradan yalnız çekim — envanterde de en son aile.

Bulgunun asıl sonucu bir **sıra düzeltmesi**: kök başına sözlüksel sınıf
alanları (C) morfotaktik genişlemenin (B) önkoşuluymuş. Plan A→B→C→D idi,
doğrusu **A→C→B→D**.

`Root.aoristClass` / `Root.causativeClass` eklendikten sonra ekler kılavuzlu
geri geldi. Kılavuz **kök sınırında** uygulanıyor, çünkü sınıf yalnız orada
biliniyor — ek fazına geçince hangi kökten gelindiği durumda taşınmıyor.
Kabul edilen boşluk: ettirgenle türetilmiş gövdeye (`çalıştır`) geniş zaman
gelmiyor. Alternatifi durum uzayına sınıf bitleri eklemek ve bütün beam'i
büyütmekti.

`unknown` varsayılanı **"üretme"** demek, "tahmin et" değil: bilinmeyen kökte
tahmin, yanlış yüzeyi beam'e sokmak olurdu (§5c).

### Okunuşa göre ek

Türkçe eki sesin ardından seçiyor, harfin değil. `sql` "sikuel" okunuyor ve
`sql'leri` alıyor. Otomat uyumu kök yürüyüşünde **harflerden** biriktirdiği
için `sql`de hiç ünlü göremiyor ve başlangıç değerinde (kalın) kalıyordu.

`Root.pronunciation` eklendi ve uyum kök sınırında ondan kuruluyor. Alan
`nil` ise yazılış okunuş sayılıyor — Türkçe kelimelerin tamamı böyle; alan
yalnız kısaltmalar ve yabancı markalar için var.

Ölçüm bir veri hatası da gösterdi: `api` ve `database`'e telaffuz yazmak
**zararlıydı**. Yazılışları zaten doğru uyumu veriyor (`api` → `apide`), ve
uydurulmuş bir okunuş yazılışla çelişen bir uyum kuruyordu.

Kök paketi v2'ye çıktı: `flags` u8 → u16 (sınıflar için 4 bit gerekiyordu,
u8'de yalnız 4 boştu) ve okunuş ayrı bir CSR bölümü olarak eklendi. v1
paketleri **okunmuyor** — eski pakette sınıf yok ve `unknown` varsaymak
sessizce yanlış çekim üretirdi.

TSV ayrıştırıcısında bir hata da buradan çıktı: `split` boş alanları atıyordu
ve yalnız okunuş yazılmış bir satırda okunuş `aorist` sanılıyordu.

### Kök verisi

30.064 → **36.672** kök. Kaynak: 12 meslek alanı (tıp, hukuk, mühendislik,
finans, tarım, inşaat, eğitim, sanat, ulaşım, kimya, spor, mutfak) artı Türkçe
kişi adları ve teknoloji terimleri. İçe aktarım **doğrulamalı**: biçim, POS,
alternasyon ve alfabe süzgecinden geçmeyen 280 satır reddedildi; özel adlarda
fonolojik bayrak zorla `none 0` yapıldı (üretimde sızıyordu).

İsimlerin köke girmesinin doğrudan sonucu: `mustafam`, `ahmete`, `zeynepten`
artık **morfolojiden** türüyor, yani `isInVocabulary` ile θ=∞ koruması
alıyorlar. Eşiğin onları koruması gerekmiyor.

### θ ve beam

`kbdiag --theta` bugünkü ölçümde "korunmalı" ailesini 14.60'ta bitiriyor:
typo'ların %87'si düzelir, doğru yazılmış kelimelerin **%0**'ı bozulur. Eski
değer 17.0 idi ve %82'ye razı oluyordu. **θ = 14.60.**

Gerçek pay ölçümden daha geniş: teşhis aracı yalnız form trie ile karakter
modelini yüklüyor, kök paketini görmüyor — o ailenin asıl büyük kısmı çekimli
isimlerdi ve artık sözlükte.

Beam taraması (yeni grafla): 128 → %88.02, 512 → %88.27. **Beam'in bıraktığı
pay +0.25 puan**, yani beam sınırlayıcı değil ve genişletmek üç kat gecikmeye
değmiyor. Karşılaştırma için: aynı tarama değişiklikten önce 128'de %86.87
veriyordu.


### Yapım ekleri, edilgen ve daralma — B'nin kapanışı

**Yapım ekleri** (`-lI`, `-sIz`, `-CI`, `-lIk`, `-lA`, `-lAş`, `-lAn`) çevrimin
ikinci kaynağı: `göz → gözlük → gözlükçü → gözlükçülük` kapalı bir döngü, ve
`-lA` isim tarafından fiil tarafına geçiriyor.

İlk sürüm onlara çekim ekleriyle aynı maliyet bandını (2.2-2.4) verdi ve top-1'i
**0.8 puan** düşürdü: çok üretkenler ve türettikleri yüzeyler gerçek sözlük
kelimeleriyle eşit maliyetle yarışıyordu. Doğru araç eki kaldırmak değil
**fiyatlamak** oldu — 4.2-4.4 bandında aday olarak duruyorlar ama sözlüğü
dövemiyorlar. Puanın yarısı geri geldi, kapsam ise tamamen korundu
(`gözlükçülük`, `evsizlere`, `kitapçıdan` hâlâ morfolojiden).

**Edilgen** kendi durumunu aldı (`afterPassive`). İlk denemede `verbRoot`'a
dönüyordu ve kendisiyle yığılıp `gelililmen` üretiyordu; Türkçe'de edilgen bir
kez geliyor (`yazıl` var, `yazılıl` yok). Bu durumdan normal çekimin tamamı
geliyor ama çatı gelmiyor. Ekler **elle kopyalanmadı**: `passiveInflection`
onları `verbRoot` tablosundan türetiyor, yani iki tablo ayrışamıyor.

**Fiil daralması** (`başla → başlıyor`) trie varyantı olarak geldi. Kural
düzenli — `a`/`e` ile biten fiil kökü — dolayısıyla sözlüksel bayrak
gerektirmiyor. Ama `droppedVowel`'dan **ayrı** bir varyant olmak zorundaydı: o
"ünlüyle başlayan her ek" diyor, daralma ise tek bir ekin kuralı. `başlıyor`
doğru, `başlır` değil (`başlar` doğru). `Suffix.isProgressive` bayrağı kapıyı
tek eke daraltıyor.

### Kapsam dışı bırakılanlar — gerekçeli

**Soru parçacığı `mI`**: ayrı kelime yazılıyor (`geliyor muyum`), yani klavye
için ayrı token. Grafa eklemek `geliyormuyum` üretip yanlış yazımı teşvik
ederdi. Yeri form listesi.

**Özel ad kesme işareti** (`Ankara'ya`): kullanıcıların çoğu kesmesiz yazıyor
ve o hâl zaten çalışıyor. Kesmeli hâl apostrofun token ayırıcı sayılmamasını
gerektiriyor — `ComposingSession`'ın token sınırı kuralı, morfolojinin değil.

**İşteş/dönüşlü ayrımı** (`-Iş` işteş): `-In` dönüşlüyle aynı durumu
paylaşıyor ve ayrım anlamsal; yüzey zaten üretiliyor.

### Sonuç ve kalan

| | önce | sonra |
|---|---|---|
| morfolojiden türeyen (20 form) | 1 | 13 |
| kök sayısı | 30 064 | 36 672 |
| ek sayısı | 40 | 99 + edilgen kopyaları |
| top-1 | %89.2 | %88.1 |
| temiz yazımda hata | %1.30 | %1.20 |
| tuş başına p99 | 1.40 ms | 2.11 ms (bütçe 8) |

top-1'deki 0.7 puan **açık bir borç**. Kaynağı kılavuzsuz kalan ekler:
yeterlilik ve sıfat-fiiller `verbRoot`/`nounRoot`'a dönerken izin maskesi
taşımıyor. Envanterin `derivationMask`/`voiceMask` önerisi bu boşluğun adı.

Kapsam dışı kalanlar (envanterin 15 ailesinden): edilgen/dönüşlü/işteş çatı,
fiil daralması (`başla→başlıyor` sözlüksel istisnalarıyla), soru parçacığı
`mI`, özel ad kesme işareti, isimden fiil yapım ekleri (`-lA`, `-lAş`).

**Kod ve otomat soruları kapandı; veri bekleyen iki soru açık** (2026-08-01).

Kapananlar üç farklı biçimde kapandı ve fark önemli: biri **evet/hayır**
(`atWordStart`), ikisi **ölçüm** (`surfaceId` bedeli, `MAX_SURFACE_LEN`), biri
**üst sınır** (fragmentasyonun zararı — doğrudan ölçülemedi, sınırlandı).
Hiçbiri "artık düşünmeye gerek yok" demek değil: üçü de bugünkü leksikona ve
morfoloji grafına bağlı, ve her birinin arkasında Faz 4'te yeniden koşacak bir
test var.

Açık kalan ikisinin ortak yanı, kapanamamalarının sebebinin **kod değil veri**
olması: ikisi de §12'nin gerçek dokunma verisini bekliyor. Sentetik dokunmayla
ölçmek, Gaussian bir decoder'ı Gaussian gürültüyle sınamak olurdu — `kbbench`
çıktısının kendi uyarısı da bunu söylüyor.

Kapanan bir soru silinmiyor, **üstü çiziliyor**: sorunun bir zamanlar açık
olduğu ve neyle kapandığı, cevabın kendisi kadar bilgi.

| Soru | Nerede kapanır / kapandı |
|---|---|
| ~~`atWordStart` `node`'dan türetilebilir mi?~~ | **evet** — ve bilerek türetilmiyor, aşağıda |
| ~~`surfaceId`'nin beam birleşme oranına maliyeti~~ | **ölçüldü** — aşağıda |
| ~~`surfaceId`'nin tuttuğu %37 yuva **aday kaybettiriyor mu**?~~ | **sınırlandı** — beam'in bıraktığı toplam pay +0.50 puan, aşağıda |
| ~~`MAX_SURFACE_LEN` = 40 yeterli mi?~~ | **ölçüldü** — aşağıda |
| `σ_min` değeri ve `−log p` alt sınırı | **açık** — kalibrasyon verisi, `-1A₁` |
| Hangi edit sınıfları başlangıçta birleşik kalmalı | **açık** — ablation, ilk gerçek veri (§12) |

### `atWordStart` türetilebilir — ve bilerek türetilmiyor

Soru "bu alan anahtardan düşebilir mi" diye sorulmuştu. Cevap iki parçalı ve
ikinci parça birinciyi geçersiz kılmıyor, tamamlıyor.

**Türetilebilir.** Bit yalnız tohum kurucusunda `true`, `advance` daima `false`
yazıyor. Yani iddia:

```
atWordStart  ⟺  (automaton, node) ∈ startPositions()
```

Üretim leksikonunda sınandı (`AtWordStartDerivableTests`, 12 kelime,
**291 133 durum**): iki yönde de sıfır ihlal.

İki yön eşit ağırlıkta **değil** ve testin bunu ayırt etmesi gerekiyordu:
"bit `true` ⇒ konum tohum" yapı gereği doğru, hiçbir şey kanıtlamıyor. Yük ters
yönde: **"konum tohum ⇒ bit `true`"**, yani hiçbir arkın tohum konumuna geri
dönmemesi. Form trie'de bu trie tanımından geliyor (kök düğüme dönen ark yok),
morfolojide kök trie'sinin aynı özelliğinden. Üçüncü bir sayaç da gerekliydi:
iki ihlal sayacı da sıfırsa test hiçbir durum tohum konumuyla **eşleşmediği**
için de geçebilirdi.

**Ama düşürülmüyor.** Türetmenin bedeli, tuttuğundan büyük:

| | Bit kalırsa | Türetilirse |
|---|---|---|
| `omissionCost` girdisi | bool okuması | `startPositions` küme sorgusu, **omission başına** |
| Anahtar boyutu | 86 bit | 85 bit — §4'ün `UInt64` hedefine yine uzak |
| Bağımlılık | yerel | `omissionCost` global bir kümeye bağlanır |

§4 zaten anahtarın tek `UInt64`'e sığmadığını kaydediyor (`-1A₂`: morfoloji
düğümü 35 bit). Bir bit kazanmak o tabloyu değiştirmiyor, sıcak yola küme
sorgusu ekliyor.

Kayıt bu yüzden şöyle: **soru kapandı, alan kaldı.** Türetilebilirliğin
kendisi yine de değerli — testi invariantı sabitliyor ve Faz 4 morfoloji
grafında bir ark tohuma dönerse orada kırılır. O kırılma "türetim artık
mümkün değil" demekle kalmaz, otomatın çevrimsizlik varsayımının bozulduğunu
da haber verir.

### `surfaceId`'nin beam bedeli — ölçüldü, **tahminden büyük**

Dedup anahtarı (§4) `surfaceId` taşıyor: aynı otomat düğümüne farklı
yüzeylerle varan iki yol birleştirilmiyor. Form trie'de bedava (düğüm öneki
tekil belirler, `surfaceId ≡ node`); morfolojide değil, çünkü aynı düğüme
farklı yüzeylerle ulaşılıyor.

**Ölçümün ilk tasarımı çöptü ve bu bir bulgu.** Budamayı kapatıp dedup'ın saf
yapısal etkisini ölçmek istedik; üretim leksikonunda (70k form + 30k kök)
budamasız decode **10 dakikada bitmedi**. `disablePruning` §5.4/2'nin
eşdeğerlik kapısı için var ve orada oyuncak leksikonlarla koşuyor — üretim
ölçeğinde budamasız arama diye bir rejim yok. Soru bu yüzden üretim rejiminde
soruldu: *beam'in fiilen tuttuğu yuvaların kaçı yalnızca `surfaceId` ayırdığı
için ayrı duruyor.*

Ölçüldü (2026-08-01, gerçek `tr-TR` paketi, budama açık, 12 kelime):

| | tutulan | `surfaceId`'siz | fark |
|---|---|---|---|
| toplam | 12 800 | 10 079 | **+2 721** (%27.0) |
| morfoloji durumları | 7 303 | 4 582 | **+2 721** (%59.4) |
| form trie durumları | 5 497 | 5 497 | 0 |

İki sonuç:

1. **Bedel küçük değil.** İlk tahmin "yüzde birkaç"tı; ölçüm çürüttü. Morfoloji
   beam'i `surfaceId` yüzünden **1.6 katına** çıkıyor — tutulan morfoloji
   yuvalarının **%37'si** yalnızca yüzey ayrımı için duruyor.
2. **Farkın tamamı morfolojinin.** İki fark birebir aynı ve form trie tarafı
   tam sıfır: §4.2'nin "form trie'de düğüm öneki tekil belirler" iddiası
   üretim leksikonu üzerinde doğrulandı.

**Bu bir tasarruf fırsatı değil.** `surfaceId` çıkarılırsa farklı yüzeyler tek
duruma katlanır ve `reconstruct` hangi yüzeyi yazacağını bilemez — §4.2'nin
yasakladığı şey. Ölçülen şey doğruluğun fiyatı.

**Doğruluk kaybı ölçümü de değil.** Beam kapalı olduğu için bu yuvalar başka
adayların yerini alıyor *olabilir*, ama hangi adayın kaybedildiği bu ölçümde
görünmüyor. Karşı-olgu da aynı koşu üzerine izdüşüm: `surfaceId`'siz gerçek bir
arama farklı durumlar tutardı, ve onu koşmak karşılaştırmayı iki farklı
algoritma arasına taşırdı.

`SurfaceIdMergeTests` oranı bekçiliyor: eşik bir hedef değil patlama alarmı.

#### Peki bu %37 aday kaybettiriyor mu — **sınırlandı**

Doğrudan ölçülemez: `surfaceId`'yi anahtardan çıkaran bir kol koşulamıyor,
çünkü çıkarmak `reconstruct`'ı bozuyor (§4.2). Ama fragmentasyonun zarar
verebilmesi için **beam'in bağlıyor olması** gerekir — yuvalar ancak dolu bir
beam'de birbirinin yerini alır. Dolayısıyla soru yerine konabilir: *beam
genişletilince ne kazanılıyor?* Kazanılan şey, fragmentasyonun yol açabileceği
kaybın **üst sınırıdır**.

`kbbench --beam-sweep` (release, 2000 kelime, tr formlar + 30k kök + en formlar,
gerçekçi simüle dokunmalar):

| genişlik | top-1 | top-3 | kelime başına |
|---|---|---|---|
| 32 | 85.41% | 91.93% | 1.49 ms |
| 64 | 86.47% | 93.58% | 2.85 ms |
| **128 (üretim)** | **86.87%** | **94.29%** | **5.29 ms** |
| 256 | 87.17% | 94.59% | 9.66 ms |
| 512 | 87.32% | 94.69% | 17.63 ms |
| 1024 | 87.37% | 94.84% | 31.33 ms |

**Beam'in bıraktığı toplam pay: +0.50 puan.** Sekiz kat genişlik ve altı kat
gecikme, yarım puan getiriyor; eğri 256'dan sonra fiilen düz (256→1024 arası
+0.20 puan).

Üç sonuç:

1. **`surfaceId`'nin zararının üst sınırı 0.50 puan.** Bu sınır tüm beam
   basıncını kapsıyor — omission dalları, eşdeğerlik sınıfları, ikinci dil.
   `surfaceId`'nin payı bunun **bir parçası**, tamamı değil. Yani %37'lik
   yuva işgali gerçek ama bedeli yarım puanın altında.
2. **`beamWidth = 128` ölçülmüş bir çalışma noktası oldu.** 256'ya çıkmak
   +0.30 puan için gecikmeyi 1.8 katına çıkarıyor ve sözleşme tuş başına
   p99 < 8 ms istiyor; o bütçe bu takası ödemiyor.
3. **Soru kapandı ama cevabı bir eşitlik değil bir sınır.** "Fragmentasyon
   zararsız" demiyoruz; "zararı ölçülebilir tavanın altında" diyoruz. Fark
   önemli: Faz 4 morfoloji grafını büyütürse hem %37 hem tavan değişir ve
   ölçüm tekrarlanmalıdır.

### `MAX_SURFACE_LEN` = 40 — ölçüldü, ama cevap **bugüne ait**

Sınır iki yerde bağlıyor ve ikisi de kullanıcıya "bu kelimeyi yazamıyorsun"
olarak dönüyor: pakete girmeye çalışan uzun yüzey reddediliyor (I1,
`BuildError.tooLong`), morfolojiden türetilen uzun yüzey ise **hiç
üretilemiyor** — `Decoder` emisyon sayısını aynı sınırla kapıyor. İkincisi
sessiz, o yüzden ölçülmesi gereken asıl taraf o.

İki bağımsız üst sınır ölçüldü (2026-08-01):

| Kaynak | n | En uzun | Örnek |
|---|---|---|---|
| tr form listesi | 70 009 | **22** | `gerçekleştirilmektedir` |
| en form listesi | 60 000 | **21** | `charadriiformesfamily` |
| tr kök sözlüğü | 30 041 | **21** | `erkanıharbiyeiumumiye` |

Türetilmiş yüzeyler için sayım değil **yapısal** sınır: morfotaktik graf
çevrimsiz (ölçüldü), dolayısıyla en uzun ek zinciri tanımlı ve
`-lAr + -(I)mIz + -DAn` ile **10 karakter**. Ek başına katkı `pieces.count`
ile üstten sınırlanıyor — her parça en fazla bir karakter üretiyor, çoğu zaman
hiç üretmiyor, yani gerçek zincir bundan kısa olabilir, uzun olamaz.

```
en uzun kök 21  +  en uzun ek zinciri 10  =  31   ≤   40
```

**Bu bir "tam Türkçe" cevabı değil.** Bugünkü graf bilinçle dar
(`TurkishMorphotactics` kapsam matrisi: tam graf ~200 morfem, Faz 4) ve
türetim ekleri (isimden fiil, fiilden isim) tam da **çevrim** adayı — çevrim
girdiği anda "en uzun zincir" tanımsızlaşır ve yukarıdaki hesap çöker.

Bu yüzden soruyu kapatan şey cevabın kendisi değil, cevabın bayatladığını
haber veren bekçi: `SurfaceLengthBoundTests` üç şeyi birden sınıyor — liste
yüzeyleri, grafın çevrimsizliği, ve kök + zincir toplamı. Faz 4 grafı
büyüttüğünde test kırılacak ve soru burada yeniden açılacak.

## 12. Gerçek dokunma verisi — toplama protokolü

> **Neden normatif.** §8.3, §8.5 ve §8.6'daki kalibrasyon ve ağırlık ölçümlerinin
> **tamamı sentetik** ve her biri kendi içinde *"gerçek kabul kapısı gerçek dokunma
> verisiyle kurulacak"* diyor. Bu bölüm o veriyi toplama kurallarını sabitliyor.
> Şema ve uygunluk kuralları veri toplanmadan **önce** yazılıyor: sonradan yazılan bir
> kural, görülmüş sonuca göre seçilmiş olur.

### 12.1 Birincil amaç: **tekrarlanabilir regresyon**

Bu aracın birinci işi bir doğruluk kapısı kurmak değil, iki somut ihtiyacı karşılamak:

1. **Karar teşhisi.** Klavye hangi kararı neden verdi — hangi dokunmada hangi adaylar
   vardı, `Δ` ve `θ` neydi, commit neye göre yapıldı. Şu an bu bilgi hesaplanıp atılıyor.
2. **Tekrarlanabilir test.** Bir kez kaydedilen gerçek yazım, sonraki her değişikliğe
   karşı **yeniden oynatılır** ve fark ölçülür. §8.3/§8.6'nın tamamı sentetik olduğu için
   bugün "bu değişiklik gerçek yazımda neyi bozdu" sorusunun yanıtı yok.

İkincisi şemanın en sert kısıtını doğuruyor: **kayıt, decode'u birebir yeniden
üretebilecek kadar eksiksiz olmalı.** Motor durumu (paket hash'leri, ağırlıklar, `θ`,
kalibrasyon anlık görüntüsü) ve decoder'a fiilen verilen dokunma noktası kayda girmezse
replay farkı "değişiklik mi, ortam mı" ayırt edilemez. Golden round-trip testi (§12.7)
bu yüzden zorunlu.

Kayıt bir **fixture**'dır: `kbbench --sessions` onu sentetik simülatörün yanına, gerçek
veri kolu olarak koyar.

### 12.2 Bu veri neyi kanıtlar, neyi kanıtlamaz

| Kanıtlar | Kanıtlamaz |
|---|---|
| **Bu rejimdeki** uzamsal dokunma dağılımı ve tuş başına sapma | Kullanıcının **serbest yazımdaki** dağılımı (aşağıdaki varsayım) |
| Kalibrasyon kollarının aynı veri üzerinde **göreli** karşılaştırması | Kullanıcı **popülasyonu** üzerinde kazanç (§8.6'nın p10/medyan/p90 dağılımı) |
| §6.2'nin istediği **elle doğrulanmış hizalama seti** | Ürün UX'i ya da yanlış-düzeltme oranı |
| Klavyenin verdiği kararın gerekçesi (`Δ`, `θ`, adaylar) | Zamanlama eşikleri (`τ_fast`, `d_near`, §8.5) |
| Değişiklik öncesi/sonrası **regresyon farkı** (§12.1) | Gecikme — kayıt ana uygulamada, host içindeki uzantıda değil |

**Zamanlama satırının gerekçesi:** hedef metni okuyarak yazmak tempoyu bozar (hedefe
bakmak için duraklama, sonra patlama hâlinde yazım). `F_ins_near` ve `F_ins_rep` `Δt`
dağılımına dayanıyor; transkripsiyon verisi o dağılımda temsili **değildir**. §8.5'in
bıraktığı borç bu araçla kapanmaz.

**Uzamsal dağılım da rejime bağlıdır — ve bu bir varsayımdır, kanıt değil.**
İlk yazımda "uzamsal dokunma dağılımı" koşulsuz *kanıtlar* sütunundaydı; yanlıştı.
Hız-doğruluk takası uzamsalı da etkiler: kelime kelime, yazdığını görmeden, temposu
kırık yazım gerçek kullanımdan **daha dikkatli** dokunma üretebilir. Kelime başı
dokunmalar da boşluk geçişini değil "yeni kelimeyi okuma" duraklamasını izliyor.

Kalibrasyon kollarının **göreli** karşılaştırması bundan etkilenmez (aynı veri, aynı
rejim). Ama toplanan sapmanın kullanıcının üretim dağılımının tahmini olduğu bir
**varsayımdır**. Sıfır maliyetli geçerlilik kontrolü mevcut: uzantının `.bkl`
deposundaki serbest-yazım güçlü örnekleri, aynı kullanıcının hedefli-kayıt dağılımıyla
karşılaştırılabilir.

**Tek kullanıcı kabul kapısı değildir.** N=1 ile en fazla *"bu kullanıcıda işe yarıyor"*
denir. Kapıya dönüşme koşulları §12.8'de.

### 12.2.1 Bu veriyle YAPILMAMASI gerekenler

Bir metrik ölçülebilir olması onu geçerli yapmaz. Aşağıdakiler hesaplanabilir ama
yorumlanamaz:

- **`wrongAutocorrects` bir doğruluk kapısı değildir.** Kalibrasyon koşulunda otomatik
  düzeltme hiç ateşlenmez (`fieldProtectsLiteral`), dolayısıyla bu sayı yalnız `behavior`
  koşulundan gelir — yani `sequential`, **zayıf** hizalamadan. "Klavye doğruyu bozdu"
  iddiası güçlü hizalama ister; güçlü hizalamanın olduğu koşul ise düzeltme üretmez.
  Teşhis olarak okunur, kapı olarak değil.
- **`shown` bayrağı kalibrasyon koşulunda `false`'tur.** Öneri çubuğu gizli olduğu için
  "kullanıcı öneriyi gördü ve görmezden geldi" analizi o koşulda kurulamaz.
- **Gecikme ölçümü.** Kayıt ana uygulamada; gerçek uzantının host IPC'si, bellek
  bütçesi ve süreç sınırı yok.

### 12.3 İki koşul — karıştırılmaz

Aynı araçla iki farklı soru sorulur ve **hangisinin sorulduğu kayda yazılır**:

| Koşul | Ne görünür | Model | Ne için |
|---|---|---|---|
| `calibrationReplay` | Yazılan metin ve öneriler **gizli**; otomatik düzeltme **uygulanmaz** | **donmuş** | Uzamsal dağılım ve kalibrasyon |
| `behavior` | Gerçek klavye: öneri çubuğu dokunulabilir, düzeltme uygulanır | donmuş | Karar davranışı |

`calibrationReplay`'in geri bildirimi gizlemesi kasıtlıdır: kullanıcı kendi bozuk metnini
görürse düzeltmeye çalışır, ve düzeltme sonrası yeniden basılan harfler bilinen biçimde
**daha dikkatli** basılır. Bu, `committed == literal` süzgecinin zaten kayıtlı olan
sıfıra-zayıflatma yanlılığının (§8.3) üstüne ikinci bir katman bindirir.

**Model her iki koşulda da donmuş.** Kayıt sırasında öğrenme çalışırsa (a) oturum içinde
davranış kayar, (b) hedefli yazım örnekleri kullanıcının gerçek `.bkl` profilini kirletir,
(c) *"kalibrasyon işe yarıyor mu"* sorusu kalibrasyonun açık olduğu bir kayıtla sorulmuş
olur — tedavi ölçüm setinin içine gömülür.

### 12.4 Hizalama **çıkarılmaz, kurgulanır**

§6.2 hizalamayı decoder'dan çıkarmayı yasaklıyor (döngüsellik). §8.3 aynı kuralı
kalibrasyon için tekrarlıyor. Bu araç hizalamayı **UI kurgusuyla** kayda dönüştürür:

- `calibrationReplay`'de hedef **kelime kelime** gösterilir. Kullanıcı bir kelime yazar,
  boşluğa basar, sonraki kelime gelir. Hangi dokunmanın hangi hedef kelimeye ait olduğu
  bir çıkarım değil, **UI durumunun kaydıdır**.
- `behavior`'da cümlenin tamamı görünür; hizalama `sequential` etiketiyle ve **daha zayıf**
  kaydedilir, sapma bayrağıyla birlikte.

`alignmentSource` alanı `constructed | sequential | none` değerlerinden birini alır.
Analiz tarafı hangi kanıt gücüyle çalıştığını bilmek zorundadır.

### 12.5 Etiket gücü — üretim kuralıyla aynı değildir

Üretimde boşlukla değişmeden commit edilen token **`.weak`** sayılıyor
(`InputCoordinator.space`, gerekçe: *"kullanıcı düzeltmeye üşenmiş olabilir"*) ve
hiyerarşik tahmin yalnız `.strong` kabul ediyor. Hedefli kayıtta durum farklıdır:

> `calibrationReplay` koşulunda, hedef kelime **kelime kelime** gösterilmişse ve
> `literal == hedef` ise, o token **`strong`** sayılabilir — çünkü niyet gözlemden değil
> **protokolden** bilinir.

Bu **yeni bir normatif kuraldır** ve yalnız bu bölümün tanımladığı koşulda geçerlidir;
ürün öğrenicisinin kuralını değiştirmez. Her token kayda `labelSource`
(`protocol | production`) ve `confidence` ile yazılır.

### 12.6 Kayıt birimi ve değişmezlik

**Kayıt birimi bir *deneme*dir (attempt), bir oturum değil.** Her deneme başlarken
`attemptID` alır ve **başlar başlamaz** diske düşer.

> **Vazgeçilen deneme de kaydedilir.** Yalnız tamamlananları saklamak seçim yanlılığıdır:
> kullanıcı kötü denemeleri atıp iyileri saklarsa abort oranı görünmez olur ve elde kalan
> küme tarafsız bir popülasyonmuş gibi sunulur. `status` alanı
> `completed | aborted | interrupted | invalid` değerlerinden birini alır ve analiz abort
> oranını raporlamak zorundadır. Kullanıcının silme hakkı ayrıdır ve toptandır.

**Günlük değişmezdir.** `actions[]` append-only bir olay dizisidir; token görünümü
**Mac tarafında türetilir**. Sebep somut: boşluğu silmek önceki kelimeyi dokunmalarıyla
birlikte geri açabiliyor (`ComposingSession`), dolayısıyla ilk commit kaydı artık nihai
token değildir. Cihazda token listesi tutmak yanlış sayım üretir.

### 12.6.1 Kayıt biçimi — olgular, çıkarımlar değil

Şema **v3** (`CanonicalSession`). Tek normatif kural: *bilinmeyen, bilinen gibi
kaydedilmez.* `Epistemic<T>` üç durum taşır — `known`, `unknown`, `notApplicable` —
çünkü tek bir `nil` üç ayrı şeyi karıştırıyordu: "uygulanmaz", "eski şemada yoktu" ve
"bozuk kayıtta eksik". `-1`, `""`, `[:]` gibi nöbetçiler yasaktır: tüketici onları
yasal veriden ayırt edemez.

> **v3 hiçbir `.unknown` üretmez.** `.unknown` yalnız v2 migrasyonundan çıkar ve
> `.unknown` taşıyan kayıt kalibrasyondan dışlanır, golden'da `unverifiable` sayılır.

**Karar veren, olguyu yazar.** Geri açma ve kanıt kopması kararları
`ComposingSession`'ın: belge bağlamına bakıyorlar (`contextBeforeInput`,
`hasSuffix(" ")`, tam token eşitliği) ve saf bir katlayıcı bunları **türetemez**.
Türetmeye çalışmak §6.2'nin yasakladığı çıkarımdır. Bu yüzden yıkıcı işlemler
`DestructiveEffect` döndürür: bekleyen kanıta ne olduğu, silinen aralıkların
token'lara atfı ve kanıtın işlem **sonrasındaki** durumu.

`evidenceStateAfter` bir olay bildirimi değil **post-state** olmak zorundadır: canlı
oturum `isDetached`'i üç ayrı yerde temizliyor ve yalnız "koptu" demek, katlayıcının
kopukluktan **çıkışı** hiç görmemesine ve sonraki bütün harfleri düşürmesine yol açardı.

**Token kimliği.** Commit edilen her token deneme içinde monoton, benzersiz ve asla
yeniden kullanılmayan bir `TokenID` alır. Kimlik olmadan "son token" ifadesi art arda
silmede belirsizdir. Silinen aralıkların atfı **belge defterinden** yapılır: yazdığımız
her parça (`token` / `separator`) sırayla tutulur ve silinen karakter sayısı sondan
geriye yürütülerek hangi token'ın hangi kısmının gittiği **sayılır**. Geri dönüş
yığınıyla yüzey eşitliğine bakmak iki yerde yanlış olguyu doğrulanmış gibi yazıyordu:
belgede aynı metnin başka bir örneği varsa eski kimlik yeni konuma bağlanıyor ve yığın
sekiz girişle sınırlı olduğu için daha eski token'ların atfı kayboluyordu.

**Konteyner.** `*.bkj` — append-only, `magic | containerVersion | schema` başlığı ve
`type | length | crc32 | payload` çerçeveleri. `containerVersion` şemadan ayrıdır:
çerçevelemeye dokunmayan bir şema değişikliği tek sürüm numarasıyla eski dosyaları
okunamaz yapardı. **Yalnız eksik son frame kurtarılır** ve bu ayrı bir olgu olarak
raporlanır; ortadaki bozuk frame yükleme hatasıdır — atlamak, kaydın ortasından bir
olayı silmek ve katlamayı yanlış sonuca götürmek olurdu.

**Dayanıklılık operasyonel olarak tanımlıdır.** Normal `write` tamamlanması dayanıklılık
değildir. `attemptStarted` ve terminal frame `F_FULLFSYNC` ile senkronlanır; yeni dosya
için ayrıca **üst dizin** fsync'lenir, çünkü yalnız dosyayı senkronlamak dosyanın var
olduğunu garanti etmiyor ve `attemptStarted` kaybolursa vazgeçilen deneme abort oranının
**paydasından tamamen düşer**.

**Belge metni taşınmaz.** Her action'a tam metin yazmak `O(n²)` idi. Yerine action başına
`DocumentMutation` + FNV-1a 64 özet; metin okuyucuda türetilir ve her adımda özetle
doğrulanır. Silme birimi **grapheme**, UTF-16 birimi değil: `"\r\n"` tek `Character`.

**İki biçim birlikte okunur.** Yeni uzantıya geçmek diskteki `*.json` kayıtlarını
görünmez bırakırdı; tek okuyucu (`RecordingLibrary`) ikisini de kanonik tipe çevirir ve
okunamayan dosyayı **atlamaz, raporlar**.

### 12.7 Ne kaydedilir

**Dokunma yaşam döngüsü.** `KeyHit.point` `touchesBegan`'da kurulur, `touchesMoved`'da
değişir ve `touchesEnded`'da yeniden hesaplanmaz. Yani "dokunmanın yeri" tek anlamlı
değildir. Kayıt bu belirsizliği çözmek zorunda:

```
touchID, downRaw, downT, upRaw, upT, majorRadius, majorRadiusTolerance,
decoderSample      ← decoder'a FİİLEN verilen nokta
outcome            ← committed | cancelled | leftBounds | repeated
```

`decoderSample` ayrı tutulur: ham noktayla aynı olmayabilir ve replay'in birebir
eşleşebilmesi için decoder'ın gördüğü değer gerekir.

**Motor durumu.** `codeRevision`, `buildConfiguration`, paket SHA-256'ları, ağırlık seti,
`beamWidth`, `θ` parametreleri, dil durumu ve **uygulanan kalibrasyon anlık görüntüsü**.
`appVersion` yetmez: aynı binary farklı paketle koşabilir.

Temiz bir commit de **tekil binary tanımlamaz**: aynı kaynak farklı Swift sürümü, target
triple, mimari ya da optimizasyon seviyesinde farklı sonuç verebilir ve bu kod
regresyonu sanılırdı — `-Onone` ile `-O` arasında **13 kat** gecikme farkı ölçüldü. Bu
yüzden derleme manifesti (`swiftVersion`, `targetTriple`, `arch`, `optimization`,
`xcodeVersion` ve kirli ağaçta **içerikten** hesaplanan kaynak özeti) build fazında
pakete yazılır.

Motor anlık görüntüsünün kendisi daima bilinir; **konfigürasyonu** bilinmeyebilir:
deneme paketler yüklenmeden başlayabilir ve o durumda `beamWidth: 0` gibi bir yer
tutucuyu gerçek konfigürasyon diye taşımak, olmayan bir motoru olgu gibi kaydetmek olurdu.

**Paket topolojisi.** Ad ve hash topolojiyi kanıtlamaz: aynı dosya farklı rolde, farklı
dilde ya da farklı kaynak sırasında yüklenebilir ve replay'in birebirliği üçüne de
bağlıdır. Rol kapalı bir kümedir.

**Layout parmak izi.** `layoutID` tekil değildir — aynı kimlikle tuş **sırası**, geometri
ve `asciiBase` değişebilir ve bu replay'de kod regresyonu diye sınıflanırdı. Kaydedilen:
tüm tuşların `(char, center, width, height)` dizisi ve `asciiBase` üzerinden hesaplanan
kanonik metin ile onun özeti. Metin de saklanır: yalnız özetle elde "farklı" bilgisinden
fazlası olmaz.

> **Kod farkı ≠ ortam farkı.** Kaydın revision'ı ile güncel revision'ın farklı olması
> regression replay'in **amacıdır**. Ortam uyuşmazlığı üç şeydir: paket hash'i, layout
> parmak izi, ya da çözülemeyen paket. Bu ayrımı yapmayan bir replay her kod
> değişikliğini "ortam bozuk" diye elerdi.

**Geometri.** `bounds{x,y,w,h}` (normalizasyon `minX/minY` de çıkarıyor), ekrandaki frame,
safe-area, `screenScale`, yönelim. Yalnız `viewSize` ham → normalize dönüşümünü
kanıtlamaz.

**Öneriler.** Kayıt sırası bağlayıcıdır: ham dokunma **önce** yakalanır, girdi işlenir,
adaylar **işlemden sonra** bir kez anlık görüntülenir. Ters sırada kaydedilen top-3 bir
önceki prefix'e ait olur. Ayrıca decoder'ın ham adayları ile kullanıcıya **gösterilen**
yüzeyler ayrı alanlardır (ikincisi maliyet penceresi ve genişletmeleri içerir).

**Commit kararı.** `InputCoordinator` `TokenCommitReport` döndürür: `literal`,
`displayBefore`, `committed`, `kind` (`literal | autocorrect | suggestion | expansion |
casing`), `delta`, `theta`, `language`. Dışarıdan yeniden hesaplamak **yasak** — §8.1'de
aynı hatanın bedeli kayıtlı: iki yerde hesaplanan bir eşik sessizce ayrışır.
`committed != literal` tek başına otomatik düzeltme demek **değildir**: `Ali`'de literal
`ali`, display `Ali`.

### 12.8 Uygunluk, split ve kabul

**Korpus.** Gömülü prompt listesi **tuş kapsayışı hedefiyle** kurulur. Gerekçe sayısal:
Faz 3 ince katmanı tuş başına `n ≥ 20`, satır başına `n ≥ 30` istiyor (§8.6) ve doğal
Türkçe Zipf dağılımlıdır — `ğ, ö, ç, j, f` gibi tuşlar rastgele cümlelerle o eşiğe **hiç
ulaşmayabilir**. Manifest tuş kapsama raporunu taşır.

**Split veri görülmeden sabitlenir.** `train | dev | test` prompt manifestinde yazılıdır;
oturum sonucuna bakılarak atanamaz (§6: ağırlıklar dev'de fit edilir, test'te asla).

**Kabul kapısı** ancak şunların hepsi sağlanınca kurulur:

1. Oturum-ayrık train/test (aynı oturumun kelimeleri iki tarafa bölünmez)
2. Metrik ve eşik veri toplanmadan **önce** yazılı
3. Abort oranı raporlanmış
4. Replay birebir doğrulanmış (§12.1) — en az bir *golden* kayıtta, dosyadaki adaylar/maliyetler/
   commit kararları importer'ın ürettikleriyle **aynı**
5. Kullanıcı-genel iddia için birden çok katılımcı

Yazıcı ve okuyucu birlikte gider: importer (`kbbench --sessions`) olmadan format hataları
ancak pahalı cihaz verisi toplandıktan **sonra** bulunur.

### 12.9 Gizlilik

Ham dokunma koordinatı bu depoda zaten kişisel veri kabul ediliyor (`CalibrationStore`
yedeği dışlıyor ve file protection uyguluyor); **elle girilen hedef metin daha da
hassastır**. Kayıtlar `Application Support/typing-sessions` altında tutulur, yedeğe
gitmez, file protection uygulanır; ilk kayıtta açık bilgilendirme ve "tümünü sil" sunulur.

### 12.10 Toplama reçetesi — katılımcı başına

Şema ve araç, *neyin* kaydedileceğini tanımlıyor; bu bölüm *ne kadarının* ve *nasıl*
toplanacağını tanımlıyor. Reçetesiz toplama, ölçüm kurulamadan biten bir veri yığını
üretir: kullanıcı aynı prompt'u on kez yazabilir ve eksik ancak import sırasında
anlaşılır.

**Hedef hacim.** Faz 3'ün ince katmanı tuş başına `n ≥ 20`, satır başına `n ≥ 30`
istiyor (§8.6) ve §8.6'nın ölçüm rejimi 400 eğitim + 400 test kelimesiydi. Gerçek
veriyle eşdeğer bir ölçüm için:

| | hedef |
|---|---|
| Kalibrasyon koşulu | korpusun tamamı (76 prompt, ~477 kelime), prompt başına **bir** deneme |
| Davranış koşulu | en az 20 prompt |
| Toplam güçlü örnek | ≥ 2000 dokunma (rezervuar kapasitesi) |
| Tuş başına | ≥ 20 (`q`, `w`, `x` hariç — §PromptCorpus) |

**Sıra.** Prompt'lar manifest sırasıyla ve **birer kez** yazılır. Aynı prompt'un
tekrarı motor öğrenme ve ezber yanlılığı üretir; tekrar gerekiyorsa ayrı bir
`sessionOrdinal` ile ve ezberin kaydedildiği bilinerek yapılır.

**Duruş blokları.** El duruşu dokunma sapmasının baskın belirleyicisidir ve oturumlar
arasında değişir. Tek bir duruşla toplanan veri, o duruşun kalibrasyonudur:

> En az iki blok: `twoThumbs/seated` (temel) ve ikinci bir duruş (`oneThumb` ya da
> `walking`). Blok içinde duruş sabit tutulur; blok ortasında değiştirmek iki rejimi
> tek oturuma karıştırır ve ayrıştırılamaz.

**Günlere yayma.** §8.3'ün "zamanla değişen sapma" senaryosu ancak birden çok güne
yayılmış oturumlarla sınanabilir. Tek oturumda toplanan veri o senaryo hakkında hiçbir
şey söylemez.

**Bitiş ölçütü ölçülür, tahmin edilmez.** `kbbench --sessions` tuş başına kapsayışı ve
eşiğin altında kalan tuşları raporluyor; toplama o rapor yeşile dönene kadar sürer.

---

## 10. Değişiklik kaydı

| Tarih | Değişiklik |
|---|---|
| 2026-08-04 | **§8.12 — Faz 4 morfolojisi, sözlüksel sınıflar ve okunuş; ve bir sıra hatası.** Başlangıç ölçümü: 20 günlük Türkçe formdan **yalnız 1'i** morfolojiden türüyordu, dili 70k düz liste taşıyordu. Ek 40 → 89, kök 30 064 → 36 672 (12 meslek alanı + kişi adları + teknoloji), morfolojiden türeyen 1 → 13. `-ki` grafa **gerçek bir çevrim** soktu (`evdekilerinki…` ilkece sınırsız); `maxSurfaceLen` artık dilbilgisel sınır değil beam bütçesi ve çevrimsizlik testi tersine döndü. **Bulunan sıra hatası:** fiil ekleri eklenince top-1 %89.2 → %87.4 düştü; sebep geniş zaman ve ettirgen seçiminin **sözlüksel** olması (`gel-ir` ama `yaz-ar`) — iki yüzeyi birden üretmek her fiile yanlış aday ekliyordu. Yani C (kök özellik alanları) B'nin **önkoşuluymuş**; plan A→B→C→D idi, doğrusu A→C→B→D. `Root.aoristClass`/`causativeClass` eklendi, ekler kılavuzlu geri geldi. İki hata daha: ek-fiilde `bufferIfVowel` ünsüzden sonra ünlü sayılıp `kitabmış` üretiliyordu (açık geçersiz kılma alanı eklendi); edilgen `-Il` `verbRoot`'a dönünce yığılıp `gelililmen` üretiyordu (çıkarıldı). `Root.pronunciation` ve kök paketi v2 (`flags` u8→u16 + okunuş CSR bölümü): `sql` "sikuel" okunduğu için `sqlleri` alıyor. TSV ayrıştırıcısında `split` boş alanları atıyordu. θ **17.0 → 14.60** (ölçülen %0-hasar noktası; gerçek pay daha geniş çünkü çekimli isimler artık `isInVocabulary` ile korunuyor). Beam taraması: 128 → 512 arası yalnız +0.25 puan. **Kalan borç: top-1'de 0.7 puan**, kaynağı kılavuzsuz kalan yeterlilik/sıfat-fiil ekleri. |
| 2026-08-03 | **§8.11 üç turluk dış review'dan geçti; ikisi kendi düzeltmemin açtığı hatalar.** Bulunanlar: (1) ardışık karelerde bayat proxy bağlamı — bağlam artık jest başında **bir kez** okunuyor ve hedef mutlak; (2) `didMove` gerçekleşeni bilmeden işaretleniyordu — alan `didRequestMove` oldu ve dokümantasyonu ne söyleyip ne söyleyemediğini açıkça yazıyor (`adjustTextPosition` sonuç döndürmüyor, "imleç oynadı" gözlemlenemez); (3) ikinci parmak jest sahipliğini çalıyordu — `startRepeat`'teki guard eklendi; (4) composing senkron kapatılmıyordu, ertelenmiş `readSelection`'a güveniliyordu — ikinci parmağın araya girdiği pencere kapandı; (5) `noteStateChangedOutsideTheLog` sonrası rollover erteleniyordu. **Sonra düzeltmenin kendisi bir hata açtı:** sahiplik guard'ı ikinci jesti engelliyordu ama ikinci parmağın *commit'ini* değil, ve o commit sabit bağlamı geçersiz kılıyordu — kip artık açıldığında klavyenin tek sahibi. Ayrıca ofsetler grapheme yerine **UTF-16** sayıyor (emoji'de imleç kelimenin ortasına düşerdi), düşürülen parmaklar `.leftBounds` yerine `.cancelled` kaydediliyor (bu yalan `cancelAllTouches` yolunda zaten vardı), ve mantık `CursorDragSession` olarak çekirdeğe taşındı — controller'da kalan tek iş ofseti proxy'ye vermek. |
| 2026-08-03 | **§8.11 eklendi — boşlukta imleç sürükleme, ve yedek koordinatörde bulunan bir hata.** Boşluk basılı tutulup sürüklenince imleç geziyor: yatay kelime kelime, dikey o kelimenin **içinde** karakter karakter, aynı jestte tek eksen. Kilit zorunlu — parmak hiçbir zaman saf yatay gitmiyor, iki eksen birlikte çalışsaydı kullanıcı hangi hareketin ne yaptığını ayırt edemezdi. Dikey eksen kelimeyi değiştirmiyor: sınırlar jest başında bir kez okunuyor ve hedef ofset oraya **kırpılıyor** (adıma değil hedefe, yoksa sınır ötesinde harcanan mesafe birikip geri dönüşü geciktirirdi). Adımlar mutlak ötelemeden hesaplanıyor: artımlı toplamda yuvarlama artıkları birikiyor ve parmağı geri getiren kullanıcı başladığı yere dönemiyordu. Çok kelimelik atlama **tek** bağlam okumasından hesaplanıyor — `adjustTextPosition` proxy'yi anında güncellemiyor ve ikinci adım bayat konumdan hesaplanırdı. Kayıt bu jesti anlatamıyor (`ReplayCommand` karşılığı yok, uydurulan bir ofset başka bir belgede başka yeri gösterirdi): `noteStateChangedOutsideTheLog` denemeyi kapatıyor, kayıt ekranında jest hiç açılmıyor. **Bulunan hata:** `readSelection` yalnız kaydedicinin koordinatörünü uyarıyordu ve kaydedici çoğu oturumda yok — imleç oynayınca yedek koordinatörün composing token'ı yerinde kalıyor, öneri seçimi `display.count` kadar silip metni bozuyordu. Kusur yeniydi değil (host'a dokunmak da aynı yoldan geçiyordu); sürükleme onu **sık** yaptı — §8.9'daki örtü panel dersinin birebir tekrarı. Kazanç **ölçülmedi**; ölçülen tek şey aritmetik. |
| 2026-08-03 | **§8.10 eklendi — nokta tuşu, ve ızgaraya yuva eklemenin ölçülemeyen bedeli.** 3. satır 9 yuvadan 10'a bölündü: `ç`'nin yanına nokta girdi, harfler %10 daraldı (0.889 → 0.80 birim). Genişliğin `⇧`/`⌫` yerine harflerden alınması bir tercih: o iki tuş **düzeltilemez** (yanlış basılan `⌫` bir karakter siler), harfteki hata ise decoder'ın çözmek için var olduğu problem. **Bedel ölçülmedi ve ölçülemez**: `TouchSimulator` sapmayı `sigmaXFactor × key.width`'ten üretiyor, yani tuş daralınca simüle parmak da daralıyor ve benchmark ölçek-değişmez çıkıp "fark yok" diyor — §8.1.1'in tam merkeze konan dokunmalarla ölçüm yapma hatasının aynısı. Sayı uydurmak yerine ölçülemediği yazıldı; gerçek bedel §12 verisiyle görülecek. `idSuffix`'e **kuşak damgası** (`-g2`) eklendi: `⇧`/`⌫` hiç değişmeden harf merkezleri kaydığı için eski kimlik yeni geometriye birebir benziyordu ve eski kalibrasyon profili sessizce bağlanırdı (v2 kayıtlarında parmak izi de yok — tek koruma kimlik). Damgasız ve bilinmeyen kuşaklı kimlikler artık reddediliyor; bedeli, nokta tuşundan önceki profillerin kullanılmaması. Uzun basma → virgül, `⌫` tekrarından **ayrı** bir tek atışlık eşikle (tekrara bağlansaydı parmak kalkana kadar virgül yağardı). |
| 2026-08-01 | **§8.9 gerçek bir erişilebilirlik istemcisiyle doğrulandı; tezgahta bir kusur çıktı.** Etiketler ve öğe listesi `swift test` altında koşamıyor (UIKit) ve o ana kadar yalnız **okunarak** doğrulanmıştı — okuyarak üç kusur bulunmuş olması yöntemin yetersizliğini zaten gösteriyordu. `AccessibilityUITests` ağacı XCUITest ile, yani VoiceOver'ın kullandığı yoldan soruyor: işlev tuşlarının Türkçe okunması, harf etiketinin shift'i izlemesi, düzlem değişiminde öğelerin yenilenmesi, 29 harfin ulaşılabilirliği. İki test ilk koşuşta kırmızı yandı ve sebep erişilebilirlik kodu değildi: **tezgah `⇧` ve `123` tuşlarını `default: break` ile yutuyordu**, yani o tuşlara basan kullanıcı hiçbir şey olmadığını görüyordu. Test, sınamak istediğinden başka bir kusuru ortaya çıkardı. `accessibilityActivate()` yolu hâlâ kapsam dışı (XCUITest `.tap()` gerçek dokunma sentezliyor) ve cihazda VoiceOver turunun yerini tutmuyor. |
| 2026-08-01 | **§9'un son sorusu kapandı: `atWordStart` türetilebilir, ama alan kalıyor.** Yüklem `atWordStart ⟺ (automaton, node) ∈ startPositions()` üretim leksikonunda sınandı (291 133 durum, iki yönde sıfır ihlal). İki yön eşit değil: "bit true ⇒ tohum" yapı gereği doğru ve bir şey kanıtlamıyor; yük "tohum ⇒ bit true" tarafında, yani hiçbir arkın tohum konumuna dönmemesinde. Alan yine de düşürülmüyor — türetmek `omissionCost`'a omission başına küme sorgusu ekler ve kazanç 86 bitten 85 bite inmek, ki §4 zaten `UInt64`'e sığmadığını kaydediyor. Soru kapandı, alan kaldı; test invariantı Faz 4 için sabitliyor. §9'da **kod ve otomat** soruları bitti; açık kalan iki madde (`σ_min`, edit sınıfı ablation'ı) kod değil **veri** bekliyor — ikisi de §12'nin gerçek dokunma verisine bağlı. |
| 2026-08-01 | **`surfaceId` fragmentasyonunun zararı sınırlandı; `beamWidth = 128` ölçülmüş çalışma noktası oldu.** Doğrudan karşı-olgu koşulamıyor (`surfaceId`'yi çıkarmak `reconstruct`'ı bozar), ama fragmentasyon ancak beam bağlıyorsa zarar verir — dolayısıyla "beam genişletilince ne kazanılıyor" sorusu kaybın **üst sınırını** veriyor. `kbbench --beam-sweep` eklendi: 128 → 1024 arasında top-1 %86.87 → %87.37, yani **+0.50 puan**, karşılığında 6 kat gecikme. Eğri 256'dan sonra düz. Üç sonuç: `surfaceId`'nin zararı bu yarım puanın (üstelik onun bir parçası) altında; 128 artık tahmin değil ölçüm (256 +0.30 puan için gecikmeyi 1.8 katına çıkarıyor, p99 < 8 ms bütçesi ödemiyor); ve cevap bir eşitlik değil **sınır** — Faz 4 grafı büyütürse tekrarlanmalı. |
| 2026-08-01 | **§9'un `surfaceId` sorusu ölçüldü — tahmin çürüdü.** Ölçümün ilk tasarımı da çöptü ve o bir bulgu: budamasız decode üretim leksikonunda 10 dakikada bitmiyor, yani `disablePruning` bir ölçüm rejimi değil yalnız eşdeğerlik kapısının aracı. Soru üretim rejiminde soruldu. Gerçek pakette `surfaceId` beam'i **%27** genişletiyor, morfoloji tarafında **1.6 katına** çıkarıyor — tutulan morfoloji yuvalarının %37'si yalnızca yüzey ayrımı için duruyor. "Yüzde birkaç" tahmini yanlıştı. Farkın **tamamı** morfolojinin (form trie tarafı tam sıfır), yani §4.2'nin tekillik iddiası üretim leksikonunda doğrulandı. Bedel bir tasarruf fırsatı değil — `surfaceId` doğruluk için zorunlu; ama "bu %37 aday kaybettiriyor mu" **yeni bir açık soru** olarak §9'a girdi. |
| 2026-08-01 | **§9'un `MAX_SURFACE_LEN` sorusu ölçüldü.** Sınır kod çözme anında da bağlıyor, dolayısıyla soru "paket kurulur mu" değil "kullanıcı bu kelimeyi yazabilir mi". Liste yüzeyleri sınırın çok altında (tr 70 009 form → en uzun 22, kök 30 041 → 21). Türetilmiş yüzeyler için sayım değil **yapısal** sınır kuruldu: graf çevrimsiz, en uzun ek zinciri 10 karakter, kök 21 + zincir 10 = **31 ≤ 40**. Cevap bugüne ait: graf bilinçle dar ve Faz 4'ün türetim ekleri çevrim adayı — çevrimde "en uzun zincir" tanımsızlaşır. Soruyu kapatan şey cevap değil, `SurfaceLengthBoundTests` bekçisi. |
| 2026-08-01 | **§8.9'a bir hata kaydedildi: kaydedici kelime ortasında bırakılınca yarım token düşüyordu.** Yedek koordinatör boş başlıyor ama belgede yarım bir yüzey duruyor; o andan sonra yedek yol yalnız yeni kısmı kendi token'ı sanıyordu. İki ölçülen zarar: parçaya uygulanan otomatik düzeltme (`Δ = −4.11` ile karar gerçekten kuruluyordu) ve `kalem` önerisinin belgeyi `lslkalem` yapması. VoiceOver yeni bir tetikleyici; kusur `writeFailed` yolunda zaten vardı. Kapatma yeni kavram gerektirmedi — gereken durum zaten tanımlıydı: yüzey biliniyor, kanıt bilinmiyor = `isDetached`. Yarım token kopuk olarak devralınıyor ve mevcut kapıların hepsi kendiliğinden kapanıyor. |
| 2026-08-01 | **§8.9 eklendi — erişilebilirlik.** VoiceOver etkinleştirmesi bağlandı: tuşlar artık okunuyor **ve** yazıyor. Asıl karar noktası koordinatın nereden geldiği: sentetik dokunmanın sapması tanım gereği sıfır ve onu gözlem saymak öğrenilmiş parmak sapmasını sıfıra çekerdi (§8.1.1'in ölçümü bozan durumunun ürün hâli). Kanıtın türetilmiş olduğu `KeyActivation` ile motora kadar taşınıyor ve orada iki şeyi kapatıyor: otomatik düzeltme ve kalibrasyon öğrenmesi. Öneri kapatılmıyor — otomatik karar kanıt ister, kullanıcının kendi kararı istemez (§5c). Leke token başına ve geri açmada geri geliyor; `beginEditingSelection`'ın "biz yazdık ⇒ kanıt gerçek" çıkarımı da düzeltildi. Kayıt ile VoiceOver **birbirini dışlıyor**: kayıt her harfe bir dokunma olgusu bağlamayı şart koşuyor ve etkinleştirmenin dokunması yok (§12.6.1). Kazanç **ölçülmedi**; yapılan iş modelin bozulmamasını garantiye almak. |
| 2026-07-31 | **§8.6'ya bir hata kaydedildi: devretme kalibrasyonu yürürlükten düşürüyordu.** Kaydedici 512 KB'lık tampon sınırında yeni denemeye devrediyor ve koordinatörü sıfırdan kuruyor; uzantı `applyCalibration`'ı yalnız paket yüklemesinde ve profil değişiminde çağırdığı için yeterince yazan kullanıcı öğrendiğini sessizce kaybediyordu — dosya diskte duruyor, canlı motor kalibrasyonsuz koşuyordu. İkinci sonucu: kayıt `applied: false` yazarken motor kalibre koşuyordu, yani kayıt kendi motorunu yanlış anlatıyordu. Rezervuar artık `configure`'ın parametresi ve snapshot'tan önce uygulanıyor. |
| 2026-07-31 | **§8.8 eklendi — `F_ctx` mekanizması.** Öznitelik 13 sözleşmenin ilk sürümünden beri tanımlıydı; artık paket formatı (`.bkg`), decoder + literal kanalı entegrasyonu, oracle karşılığı, bağlamın yaşam döngüsü ve üretim aracı var. **Model yok**: depoda Türkçe bigram verisi bulunmuyor ve uydurulmuş bir tablo, ölçülmemiş bir modeli ölçülmüş gibi gösterirdi. Paket yokken `F_ctx ≡ 0` ve motor bugünkü davranışını birebir koruyor. Paket olasılık değil **delta** saklıyor (§2.1 tek sahiplik); görülmemiş çift 0 alıyor (§5c: kanıtın yokluğu ceza değil). `Δ`'nın iki tarafı da terimi taşıyor — yalnız decoder'a eklemek `θ`'yı sessizce düşürürdü. Gecikme ölçüldü (1M çiftlik pakette p99 +0.015 ms); doğruluk kapısı veri gelene kadar **kurulmadı**. |
| 2026-07-31 | **§8.7'ye korpus içe aktarımı eklendi.** Kullanıcı kendi metnini bir alana yapıştırıp toplu öğretebiliyor; metinde üç kez geçen sözlük dışı yüzey kabul ediliyor — yazarak öğrenmeyle **aynı eşik**, yeni sabit yok. Katkı doyuruluyor ve puan düşürülmüyor: aynı metni iki kez aktarmak idempotent, ve sık geçen bir kelime eviction sıralamasında yazarak öğrenilenleri ezmiyor. Bölme tek tokenizer'la (§2.3). Kaynak alanın kendisi, pano değil: pano Tam Erişim ve sistem onayı isterdi. |
| 2026-07-31 | **§8.7 eklendi — kişisel sözlük.** Kullanıcının sözlük dışı kelimeleri üç literal commit sonrası `V`'ye giriyor: `θ = ∞` koruması **ve** decoder kaynağı. Kanıt kuralı `θ`'nın sonlu olmasına bağlandı — klavye yargılamadıysa "değiştirmedi" olgu değil. `F_lex` çıpasının ilk hâli (14.6, "en nadir paket kelimesinden nadir") tutarlı bir gerekçeyle seçilmişti ve **ölçüm onu çürüttü**: o değerde dikkatle yazılan kişisel kelimenin yalnız %56'sı geri geliyor. `kbbench --personal` taraması mıknatıs etkisinin 14.6–10.0 aralığında **tam olarak sıfır** olduğunu, ilk zararın 9.0'da başladığını gösterdi; çıpa platonun içinden, tanınmaya göre 11.5 seçildi. Kaynak `role: personal` bir `PackRef` olarak kayda giriyor — yazılmasaydı kayıt kendi motorunu eksik anlatır ve replay farkı "kod regresyonu" diye okunurdu (§12.1). |
| 2026-07-29 | **§12 eklendi — cihazda gerçek dokunma verisi.** Amaç iki somut ihtiyaç (§12.1): klavyenin hangi kararı neden verdiğini görmek, ve bir kez kaydedilen gerçek yazımı sonraki her değişikliğe karşı yeniden oynatıp farkı ölçmek. İki bağımsız inceleme turu üç KRİTİK boşluk buldu ve hepsi kapatıldı: kayıt ürün yolunu kullanacaktı (kalibrasyon ölçüm setine gömülüyordu → ham modelle kaydet, kalibrasyonu replay'de uygula), hedef hizalaması yoktu (→ kelime kelime gösterim, hizalama UI kaydı), ve kesme yanlılığı kapatılmamışken kapatıldığı iddia ediliyordu (→ dokunma HEDEF tuşa atanıyor, dışlama sayılıyor). §12.2 tablosu da düzeltildi: uzamsal dağılımın rejime bağımsızlığı bir **varsayım**, kanıt değil. |
| 2026-07-29 | **§8.6 eklendi — Faz 3 uygulandı.** Hiyerarşik sapma (`b_c = g + r_row + d_c`) ürün yoluna bağlandı. Shrinkage elle seçilmiş `κ` yerine ampirik Bayes; `τ̂²` için muhafazakâr indirim (güven sınırı **değil** — varsayımlar sağlanmıyor, garantinin yerini null ölçümü aldı). Ölçüm: yapı varken +3–5 puan, yapı yokken Faz 1'e iniyor, 24 kullanıcının **hiçbiri** zarar görmüyor. Ölçüm rejiminin kendisi dört yerde düzeltildi (§8.3'ün "en kötü tuş" metriği, simülatör birimleri, kirli eğitim etiketleri, kullanıcı havuzlaması). "En kötü tuş" artık teşhis, kapı değil — gerekçe hedef fonksiyonu uyuşmazlığı. |
| 2026-07-28 | İlk sürüm. Log-linear normatif seçim; prefix-causality; `editContext` sadeleşmesi; `TR` gecikme sonucu; oracle recurrence. |
| 2026-07-29 | **§8.5 eklendi.** Gayrıresmî katman: `F_ins,rep` sınıfı (ağırlık taramayla seçildi), argo sözlüğü ayrı kaynak, `.bkx` genişletme haritası. Oracle da yeni sınıfı modelliyor — eşdeğerlik testi ayrışmayı yakaladı. |
| 2026-07-29 | **§8.4 eklendi.** iOS seçim API'si cihazda ölçüldü: `selectionDidChange` hiç çağrılmıyor, `selectedText` çalışıyor, hata senkron uzlaştırmanın geçmişi silmesiydi. |
| 2026-07-29 | **§8.1.1 eklendi — kapı AÇILDI.** §8.1'deki ölçümün dokunmaları tuş merkezine koyup ayırt edici uzamsal sinyali yok ettiği bulundu. Gerçekçi dokunmalarla yeniden ölçüldü: θ = 17'de typo %82 düzeliyor, doğru yazılmış OOV %0 bozuluyor. `LiteralChannel.autoCorrectsOutOfVocabulary` açıldı. |
| 2026-07-28 | **§8.3 eklendi.** Kalibrasyon Faz 1 (global sapma) uygulandı: `KBLearning` modülü, `.bkl` kalıcı depo, profil ayrımı. Hizalama kuralı Codex turunda düzeltildi (uzunluk eşitliği hizalamayı kanıtlamıyor). Zarar metrikleri ölçüldü: p10 kullanıcı +0.0 ama 2/24 kullanıcı ve en kötü tuş −8.3 → hiyerarşik model (Faz 3) gerekçesi. |
| 2026-07-28 | **§8.2 eklendi.** Çoklu dil uygulandı: `LexiconSet` kaynak listesine genelleştirildi (dil kaynağın kendisinden gelir), `F_lang` bağlandı, `en-US` paketlendi. Ölçek uyumu 12 108 ortak yüzeyde ölçüldü (`offset_en = −0.20`); doğruluk bedeli ve gecikme raporlandı. |
| 2026-07-28 | **§8.1 eklendi.** Literal kanalı uygulandı (üçlü karakter modeli, `.bkc`, `V` = form listesi ∪ morfoloji). `kbdiag --theta` ölçümü `θ`'nın typo ile doğru yazılmış OOV'yi ayıramadığını gösterdi; OOV otomatik düzeltme kapısı kapalı, gerekçe ve açılma koşulu §8.1'de. |
| 2026-07-28 | **Codex tartışması sonrası revizyon.** `tr()` indis düzeltmesi; `F_om_gem` pozisyonel tanım + `lastEmitted` → `lastSurfaceSymbol` yeniden adlandırma ve güncelleme kuralı; `surfaceId` alanı (farklı yüzey önekleri birleştirilemez, form listesi trie olmalı); sonlanma invariantları (I1) `MAX_SURFACE_LEN` + (I2) emisyon başına pozitif maliyet ve bunun `w_len < 0`'a koyduğu kısıt; `w_len` gerekçesi ampirik prior'a indirildi (yoğunluk 1'i aşabilir); `sub = min(direct, eq)` ve `base()` yasallık fonksiyonu; 15 serbest skaler parametre; DP sınır koşulları ve `om(1)`/`ins(1)` sıralaması; maliyet itme sözleşmesi (ham delta, `w_lex > 0`); `c_unk`/`c_tail`/`c_oov_char` paket sabiti; oracle testi budamasız aramaya bağlandı; `σ_min` kovaryans alt sınırı. |
