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

**Toplu mimari değerlendirme:** 1–140 turlarının çözüm planı `docs/keyboard-architecture-review.md`, turdan çözüm alanına eşleme `audits/architecture-review-index.json` içindedir. Bu plan uygulama öncesidir; aşağıdaki tarihsel bulguların tamamlandığı anlamına gelmez.

**2026-10-10 — açık literal seçimi:** Eşik tek başına bütün doğru OOV'leri
korumuyor: gerçek tr+en paketleriyle tuş merkezlerinden `qrmenü → arkeni`,
`cepmenü → gelmeni`, `dijitalmenü → dijitalleşmeni`, `zeynepcim → zeynepim`
üretildi. Otomatik düzeltme açık kalır; öneri çubuğunun ilk yuvası her zaman
yazılan yüzeye ayrılır. Bu yüzeyin seçimi `.literal` kökeniyle kayda girer ve
tek güçlü gözlemle kişisel sözlüğe kabul edilir (§8.7). Sonraki yazışta `V`
üyeliği korur. Bu, tüm OOV'lerin ilk yazışta doğru sınıflandırıldığı iddiası
değildir; kullanıcıya kendi yazımını açıkça seçme ve kalıcı öğretme yoludur.

**2026-10-10 — Türkçe ek taraması:** `TurkishSuffixAuditTests` gerçek tr+en
paketleriyle 127 metni üç dokunma konumunda (merkez ve x/y yönünde ±0.2 tuş
ölçüsü) çalıştırır. TDK örneklerinin kaynağı CSV'de, kalan örnekler `synthetic`
olarak işaretlidir. İlk 381 koşuda 66 metin değişti; bunların 13'ü bilerek
hatalı yazılmış beş kontrol kelimesinin düzeltilmesidir, 53'ü istenmeyen
metin değişimidir. Bu bir kullanıcı hata oranı veya rastgele örneklem değildir.
Gelecek zamanın ünlü sonrası kaynaştırma `y`'si eklendi; kesmeye bağlı ek,
belge bağlamı görülebildiğinde bağımsız kelime olarak otomatik düzeltilmez.
Düzeltme sonrası istenmeyen değişim 53 → 49 koşu oldu; iki değişiklikle
yedi koşunun çıktısı iyileşti, üçünün aynı cümlede başka hatası kaldı.
Bilerek hatalı kontrol kelimelerindeki 13 düzeltme korundu. Diğer
morfoloji/OOV sorunları sürer. Önce/sonra kayıtları `audits/` altında;
yeniden çalıştırmak için `KB_SUFFIX_AUDIT=/absolute/report.csv swift test
--package-path Packages/KeyboardCore --filter TurkishSuffixAuditTests`.

**2026-10-10 — ikinci tarama:** `audits/turkish-suffix-round2-corpus.json`
üzerindeki 369 senaryoda, tuş merkezlerinde 98 metin değişimi görüldü.
Ek aileleri için ünlü uyumu korunarak üretilmiş hedefli örneklerdir; kullanıcı
hata oranı değildir. `sokaktaydım → almaktaydım`,
`gelemiyormuşsunuz → gelmiyormuşsunuz`, `gelmemişsiniz → gelmekmişsiniz`
ve `üzgün müymüşler → üzgün miymişler` yeniden üretildi. Öğretilmiş köklerle
20 senaryonun 7'si hâlâ değişti; kökü öğrenmek ekli biçimi V'ye katmıyor.

İki ayrı koruma açığı kod yoluyla eşleştirildi: `CorrectionPolicy` büyük harf
bilgisi taşımayan `session.literal` aldığı için `QRmenü → Arkeni`; semboller
önceden token'ı kapattığı için `@qrmenü → @arkeni`, `123qrmenü → 123arkeni`
oluşuyor. İkinci takip dosyasında 25 böyle örneğin üç konumdaki 75 koşusu da
değişti; iki TDK kontrolünün altı koşusu korundu. Bu tur koruma politikası
veya morfoloji değiştirilmedi; bulgular açık. Dosyalar `audits/` altında
`round2` önekiyle, nedenler `turkish-suffix-round2-summary.json` içinde.

Tarayıcı artık `KB_SUFFIX_CORPUS=/absolute/corpus.json` ile dış örnek kümesi,
`KB_SUFFIX_OFFSETS=0` ile merkez ölçümü ve senaryo başına `learnedBase` ile
önce açık kullanıcı seçimiyle öğrenme, sonra temiz oturumda deneme destekler.

**2026-10-10 — üçüncü tarama, yalnız bulgu:** 135 metin × üç konum = 405
koşuda 175 metin değişimi. Ayrıca `TurkishInteractionAuditTests` 40 düzenleme
akışından 224 anlık görüntü kaydetti (`KB_INTERACTION_AUDIT=/absolute/out.json`).
Yedi sorunlu kelimede boşluğu geri silince özgün literal bellekte kalıyor,
ama ilk öneri düzeltilmiş `display` oluyor; kullanıcı özgün yazımını listede
bulamıyor. Tüm kelimeyi silip tekrar yazmak yedi örnekte de yeniden düzeltildi.
Önceden açık literal seçimi yapılan yedi kelime ve `kitap` kontrolü geri açma /
yeniden commit akışında korundu. `kitap` için yeni harf yazılmadan boşluğu
silip eklemek kalibrasyon örnek sayısını 5 → 10 yaptı; doğruluğa etkisi henüz
ölçülmedi. Yeni ek örnekleri: `hissedemiyormuşsunuz → hissediyormuşsunuz`,
`doktorunuzdum → doktordunuzdum`, `yapabileceklerimizle → yapabileceklerimize`.
Bulgular ve sınırlamalar `audits/turkish-round3-summary.json` içinde. Kullanıcı
isteği gereği bu tur üretim algoritmasına düzeltme uygulanmadı.

**2026-10-10 — dördüncü tarama, yalnız bulgu:** `TurkishBoundaryAuditTests`
75 senaryoyla seçim, harf büyüklüğü, kısa host bağlamı ve detached yedek yolu
ölçtü. Mevcut metinde `qrmenü` / `cepmenü` seçilip literal öneriye basılınca
öğrenme olmuyor (`pickSuggestion` seçim dalında `.empty` döndürüyor).
Dışarıdan gelen büyük harfli 11 seçim önerisiz; aynı kelimelerin bu oturumda
izlenmiş 11 seçimi önerili. Sentetik `centerTouches` büyük harfi küçük tuş
anahtarına çevirmiyor. `ankara’daymışız`, +0.2 kaymada host yalnız son 4/8/9
karakteri verdiğinde `ankara’faymışız` oluyor; tam veya 10+ karakter bağlamında
korunuyor. Belirli bir uygulamada bu pencere boyutlarının kullanıldığı iddia
edilmiyor. Detached durumda gösterilen literal öneriyi seçmek iki örnekte de
no-op ve öğrenmesiz; testte durum doğrudan kuruldu, gerçek kayıt hatası
üretilmedi. Ayrıntılar `audits/turkish-round4-summary.json` içinde. Normal
yazmada açık literal seçimi 13 örneğin harf biçimini korudu. Üretim algoritması
bu tur da değiştirilmedi.

**2026-10-10 — beşinci tarama, yalnız bulgu:** `TurkishImportAuditTests`
13 yapay aktarım/geçmiş senaryosu kaydetti. Genel medya filtresi sıradan
`dahil edilmedi` / `omitted` içeren veya `<3` ile başlayan mesajları siliyor.
Tanınmayan sistem satırları önceki gönderene ekleniyor. Telegram `from_id`
atıldığı için aynı görünen adlı iki hesap tek seçenek oluyor. Akıllı kesme
ve bölünmez tire, ASCII karşılıklarından farklı olarak kelime sayılmıyor;
sonraki kelime çiftleri öğrenilmiyor. `PersonalHistory.merge` yeni yazılışı
almadan sayım/yaş güncelliyor. ZIP için üretimdeki enum aynen derlenerek ayrı
bir macOS sürecinde çalıştırıldı: geçerli kontrol başarılı, merkezi dizindeki
ad uzunluğu dosyayı aşan 68 baytlık yapay ZIP bounds trap ile çıktı (-5).
Uygulama veya kullanıcı arşivi kullanılmadı. Tekrar üretim betiği
`audits/probe_zip_reader.py`; bulgular `audits/turkish-round5-summary.json`.
Üretim kodu değiştirilmedi, hata arama hedefi aktif.

**2026-10-10 — altıncı tarama, yalnız bulgu:** Üretimdeki `TypingHistory`
gövdesi otomatik çıkarılıp yalnız deposu bellek içi karşılıkla değiştirilerek
12 senaryo çalıştırıldı (`audits/generate_history_audit.py`). Fazladan boşluk
aynı kelime/çifti tekrar sayıyor: `dün akşam` + 1/2/3 boşluk → sayım 3.
Aynı history örneği alan değişiminde yaşarsa tekrar yazılan tek kelime
`merhaba` sayılmıyor (boş/bitmemiş metin lastObserved'u sıfırlamıyor).
Canlı yazım satır sonundan önceki ve sonraki kelimeyi bağlıyor; toplu içe
aktarma aynı metinde bağlamıyor. Kişisel sözlük ingest'i [1,1,1] veya [2,1]
ayrı parçalardaki gözlemleri toplamıyor; [3] tek parça kabul ediliyor. Tekrar
aktarma idempotence'i ile farklı parçaların toplamı ayrıştırılmalı; bu bulgu
WhatsApp geçmiş aktarımıyla karıştırılmamalı. Silme ekranındaki ilk 30 kelime
sınırı ayrıca kod incelemesinde saptandı, UI doğrulaması bekliyor. Kanıt ve
sınırlamalar `audits/turkish-round6-summary.json` içinde. Üretim koduna dokunulmadı.

**2026-10-10 — yedinci tarama, akış modeli:** Kısayol aday üretim gövdesi
üretimden alınarak, uygulama sırası gerçek koordinatör + FakeDocument ile
sekiz senaryoda modellendi. Çok kelimeli tetikleyicide çift boşluk veya satır
sonu aday üretirken sadeleşiyor, silme sırasında gerçek sonek ile eşleşmeyip
no-op oluyor. Belge sonunda `trXYZ` içindeki `XYZ` seçiliyken, modelde soldaki
`tr` kısayolu öneriliyor ve uygulama `t🇹🇷` üretiyor: ilk backspace seçimi
siliyor, kalan döngü tetikleyicinin yalnız bir kısmını tüketiyor. Bu bulgu
UIKit/recorder zamanlamasıyla henüz doğrulanmadı, UI teyidi bekliyor. TAB ve
NBSP aday üretiminde ayırıcı sayılmıyor. Kontroller: normal `tr` ve tek boşluklu
çok kelimeli tetikleyici düzgün değişti. `audits/turkish-round7-summary.json`
sınırlamaları ve kanıtı ayırır. Üretim kodunda düzeltme yok.

**2026-10-10 — sekizinci tarama, morfoloji kapsamı:** Üretim paketiyle 45
sonlu-durum kabul sorgusu ve merkez dokunma + boşluk denemesi yapıldı.
Edilgen grupta dört doğru yüzey değişti: `yazılmayacakmışsınız →
yazılamayacakmışsınız`, `yazılabilecekmişsiniz → yazışabilecekmişsiniz`,
`okunmayacakmışız → olunamayacakmışız`, `söylenmemişsiniz → söylenmekmişsiniz`.
`passiveInflection` kaynak listesi temel olumsuzluk/zaman eklerini taşıyan
`nominalSuffixes` tablosunu almıyor; yeterlilik geçişini de hedefi `verbRoot`
olduğu için dışlıyor. Türetilmiş gövdelerde kök sınıfı kaybolduğu için geniş
zaman kılavuzu da kapanıyor: `yapabilirseniz`, `gelebilirseniz`, `yaptırırsanız`
morfolojide ve birleşik sözlükte yok, fakat bu merkez denemelerinde değişmedi.
Kapsam eksikliği tek başına yazılamama sayılmadı.

Diğer yönde, ortak `afterPerson` durumu üçüncü çoğula özel olduğu açıklanan
ek-fiil geçişlerini tüm şahıslara açıyor. `geldimdimdim` ve `yaptımdımdım`
morfoloji tarafından kabul edildi. Yanlış aday gerçek düzeltmeye de sızdı:
`gelmişindim → gelmişimdim`, `geldikdik → geldimdik`. Normal `gelmiştim` ve
`gelmişlerdi` kontrolleri kabul edildi. Standart birleşik çekimin referansı
[EBA Ek Eylem](https://img.eba.gov.tr/388/18e/1b8/364/95a/4a4/514/ba9/f7f/ea1/410/95e/d5e/366/006/38818e1b836495a4a4514ba9f7fea141095ed5e366006.pdf?name=Ek+Eylem.pdf).
Sonuçlar `audits/turkish-round8-summary.json` ve ham JSON'da. Bu tur UIKit
etkileşimi ölçmedi; üretim kodunda düzeltme yapılmadı.

**2026-10-10 — dokuzuncu tarama, kişisel öğrenmede tekrar sayımı:** Gerçek
paketle 24 düzenleme dizisi / 96 durum kaydedildi. `yapabilirseniz`,
`gelebilirseniz`, `yazılmadı`, `okunmamış` yalnız birer kez yazıldıktan sonra
boşluk silme ve yeniden boşluk ekleme döngüsü kişisel puanı `1 → 2 → 3`
yaptı; üçüncü kapanışta dört kelime de kabul edildi. Yeni harf gözlemi ya da
açık öneri seçimi yoktu. Üç ayrı kelime yazma kontrolü aynı puanları üretiyor;
yalnız fazladan boşluk ekleme kontrolü ise `1` puanda kalıyor. Alan koruması
kişisel öğrenmeyi engelledi; bilinen `kitap` kişisel sözlüğe girmedi, otomatik
değişen `qrmenü` de öğrenilmedi. Bu, §8.7'deki bağımsız zayıf kanıt niyetinin
yeniden kapanışla aşılmasıdır. Yanlış yazımın bu yolla kabul edilme riski var,
fakat bu turdaki kabul örnekleri doğru yüzeylerdir. Kalibrasyon örneklerinin
de yeniden sayılması üçüncü tur bulgusunu doğruladı, yeni hata sayılmadı.
`audits/turkish-round9-summary.json` ve ham sonuçlar kaydedildi. UIKit testi
ve üretim düzeltmesi yapılmadı.

**2026-10-10 — onuncu tarama, silinen kelimenin dil durumu:** Dört hedef,
yedi geçmiş koşulu ile 28 üretim-paketi denemesi yapıldı. `the ` yazıldıktan
sonra kelime silme, tek tek silme, host'un belgeyi boşaltması + seçim
uzlaştırması ve `invalidateComposing` yollarının dördünde de önceki dil
İngilizce kaldı. Belge boşken `qrmenü → armenia`; temiz başlangıçta aynı
harf/dokunma dizisi `qrmenü → arkeni`. `sokaktaydım` ise silinmiş İngilizce
geçmişiyle korunurken temiz başlangıçta `almaktaydım` oluyor. Yani fark her
zaman ek zarar değil; gözlenen sorun, artık belgede olmayan kelimenin karar
üzerindeki etkisi. `gelemiyormuşsunuz` ve `kitabımdı` kontrol hedeflerinin
çıktıları bu geçmişten etkilenmedi. Toplam sekiz boş-belge koşulu temiz
başlangıçtan farklı sonuç verdi.

`forgetContext` yalnız sözcük bigram bağlamını siliyor, `previousLanguage`
kalıyor; silme yolu da dil bağlamını geri almıyor. `LanguageModel.previous`
sözleşmesi bunu önceki **kelimenin** dili diye tanımlıyor. Alanlar arası
kalıcı dil tercihi ayrıca tanımlanmış değil; bu nedenle UI alan değiştirme
iddiası değil, aynı koordinatörde doğrulanmış durum kalıcılığı olarak
kaydedildi. `audits/turkish-round10-summary.json` sınırlamaları içerir.
Üretim düzeltmesi yapılmadı.

**2026-10-10 — on birinci tarama, aynı seçimi onaylama:** Üretim paketi ve
koordinatörle 15 dizi çalıştırıldı. Belge sonundaki `kitap`, `qrmenü` veya
`sokaktaydım` seçiliyken görünür literal öneriye basmak core seçim kipini
kapatıyor fakat host seçimini tüketmiyor. Ardından `lar` yazılınca `önce kitap`
örneği `önce lar` oluyor. Araya `handleSelection` uzlaştırması eklemek de
sonucu değiştirmedi (altı literal seçim dizisi). `commitSelectionEdit`, yüzey
aynıysa host'a hiç yazmadan durumu temizliyor. Mevcut aynı-yüzey testi yalnız
ilk anda metnin korunmasına bakıyor, sonraki yazmayı sınamıyor.

Farklı yüzey kontrolünde doğrudan `pickSuggestion("kalem")` seçimi tüketiyor
ve devamı `önce kalemlar` oluyor; bu kontrol `kalem`in görünür aday olduğu
iddiası değildir. Öneriye basmadan seçimin üstüne yazmak normal olarak seçimi
değiştirdi. Boşluk yolu da seçimi koruyor, ancak bu mevcut kodun açık tercihi
olduğundan ayrı yeni hata sayılmadı. FakeDocument yalnız belge sonu seçimleri
için kullanıldı; kelime ortası imleç ve UIKit teyidi bu turda yok. Kanıt ve
sınırlar `audits/turkish-round11-summary.json` içinde. Düzeltme yapılmadı.

**2026-10-10 — on ikinci tarama, gerçek simülatör seçimi:** iPhone 17 Pro /
iOS 26.5 üzerinde uygulamanın deneme alanı ve gerçek klavye uzantısı CUA ile
kullanıldı. Kurulu uzantı ikilisi DerivedData ürünüyle SHA-256 düzeyinde aynı.
Ekran tuşlarından boşluksuz `kitap` yazılırken ilk öneri `kitap` görünüyor;
kelime seçilince öneri satırı boşalıyor. Çift dokunmanın sistem düzeltme
vurgusu olabilmesi nedeniyle ayrıca yalnız `kitap` içeren alanın tümü seçildi;
seçim tutamaçları ve Kes/Kopyala menüsü görüldüğü halde öneriler yine boştu.
Bu yüzden on birinci turun aynı-yüzey öneri seçimi gerçek UI'da teyit edilmiş
sayılmadı: önkoşulu olan öneriye bu host'ta ulaşılamadı. Seçim geri çağrısı /
proxy durumu kök nedeni henüz ayrıştırılmadı, gözlem yeni kesin kök hata
sayısına eklenmedi. Başlangıçtaki görünmeyen klavye simülatörün donanım-klavye
kipiydi; uygulama donması değildi. Tam Erişim açılmadı. Ayrıntılar
`audits/turkish-round12-simulator-selection.json` içinde; düzeltme yok.

**2026-10-10 — on üçüncü tarama, seçim kaybının üretim sırası:** Gerçek
`ProductionRecorder` + `RecordingEngine` ve dil paketleriyle üç kelimenin
ikişer seçim geri çağrısı çalıştırıldı. `selectionChanged` sonrası literal
öneri altısında da var; ardından uzantının yaptığı gibi `rollOverIfNeeded`
çağrılınca motor değişiyor ve altısında da öneriler boşalıyor. Host seçimi
aynı kalıyor. Aynı seçimi tekrar bildirmek de aynı yenileme/kayıp döngüsünü
üretiyor. Kayda sığmayan seçim `stateChangedOutsideTheLog` bayrağını açıyor;
yenileme yeni koordinatör kuruyor fakat seçimi ona aktarmıyor. Yalnız çekirdek
testinin göremediği, kaydedici etkin yola ait entegrasyon kusuru.

Bu sonuç on ikinci turun gerçek ekran gözlemini açıklayan yeniden üretimdir;
UI'daki geri çağrı iç durumları ayrıca ölçülmedi. Boş çubuk belirtisi ve bu
kök neden iki ayrı hata sayılmadı. On birinci turdaki aynı-yüzey onayı hâlâ
ayrı, yalnız çekirdekte doğrulanmış bulgudur. Sonuçlar
`audits/turkish-round13-summary.json` içinde; üretim koduna dokunulmadı.

**2026-10-10 — on dördüncü tarama, uzunluk sınırı kontrolü:** `ev` + tekrarlı
`dekiler` zincirinin 37/39/40/41/44/72/120 karakterlik önekleri, boşluk,
literal öneri seçimi ve son harfi silip boşluk yollarında 21 dizide sınandı.
Yazma sırasında tüm metinler aynen kaldı; literal seçimlerinin tamamı
orijinali korudu. Fiilen 40 karakteri aşan tüm commit'ler literal korumada
kaldı. 40 karakter üstü özgün öneri seçilebilir fakat kişisel sözlüğe
alınmıyor: `PersonalLexicon.maxLength` açıkça 40. Bu mevcut politika sınırı,
yeni bozulma diye sayılmadı. Bazı kesilmiş yapay önekler düzeltildi; bunlar
dilbilgisel doğru kelime kontrolü olmadığından yanlış düzeltme sayılmadı.
Bu kapsamda yeni metin kaybı gösterilmedi. 120 karakter üstü veya gecikme
hakkında sonuç çıkarılmadı. `audits/turkish-round14-summary.json` ve ham
sonuçlar saklandı; üretim düzeltmesi yok.

**2026-10-10 — on beşinci tarama, noktalamayı silip eke devam:** On kelime,
doğrudan yazma / boşluk-silme / nokta-silme / virgül-silme ile 40 dizide
sınandı. Son boşluktan önce belgelerin tamamı amaçlanan kelimeyle aynıydı.
Nokta veya virgül silinen 20 dizinin tamamında önceki kök composing'e geri
alınmadı; ilk öneri yalnız ek parçası oldu. Dört dizide iki yeni bozuk çıktı:
`yazıl` + nokta/virgül + geri sil + `mayacakmışsınız` →
`yazılkayacakmışsınız`; `okun` + aynı akış + `mayacakmışız` →
`okunkayacakmışız`. Boşluk-silme kontrolü tam kelimeyi geri açıyor.
`restorePreviousWord` yalnız tek boşluk ayırıcıyı kabul ediyor; diğer silme
yolu history'yi atıyor ve yeni harfler bağımsız token başlatıyor.
Doğrudan yazmadaki önceden belgelenmiş yanlış düzeltmeler yeniden yeni hata
sayılmadı; bazı parçalı yolların bunları tesadüfen engellemesi de iyileşme
iddiası değil. Bu tur UIKit veya ek parçasını açıkça öğretme yolunu sınamadı.
`audits/turkish-round15-summary.json` ve ham kanıt kaydedildi; düzeltme yok.

**2026-10-10 — on altıncı tarama, otomatik büyük harf:** Gerçek `ShiftPolicy`
ile controller'ın harf/sınır çağrı sırası modellendi; sekiz yazma dizisi ve
on iki bağlam sorgusu çalıştırıldı. Host `.allCharacters` isterken başlangıç
`.oneShot` oluyor, ilk harfte düşüyor ve bir sonraki sınıra kadar açılmıyor:
`izmir istanbul → İzmir İstanbul`. Aynı girdide açık caps-lock kontrolü
`İZMİR İSTANBUL` verdi. Controller yalnız sınırda otomatik karar yeniliyor;
bu tur gerçek UIKit `.allCharacters` alanı ve geri çağrı zamanlaması sınanmadı.

Cümle sonunu izleyen kapanış tırnağı (`Merhaba." `, `Merhaba!” `, `Merhaba?» `)
ve cümle başındaki açılış tırnağı (`“`, `"`, `Merhaba. “`) büyük harfi
engelliyor. Çıplak nokta/ünlem/soru + boşluk ve satır sonu kontrolleri doğru
olarak büyük harf istedi; virgül istemedi. Kural yalnız son boşluk-dışı
karaktere bakıyor. Alıntı parçalarının tümü için dilbilgisel iddia kurulmadı;
bulgu cümle başı otomatiğinin tırnaklı sınırları kaçırmasıdır. Ayrıntılar
`audits/turkish-round16-summary.json` içinde; düzeltme yapılmadı.

**2026-10-10 — on yedinci tarama, geçmişte tipografi ve tek harf:** Gerçek
`PersonalHistory` ile 17 örnek çalıştırıldı. `bana “merhaba” dedi` ve
`bana ‘merhaba’ dedi` içindeki dış tırnaklar kırpılmıyor; kelime harf-dışı
token sayılıyor ve iki yanındaki kelime çiftleri öğrenilmiyor. Düz çift
tırnak, «guillemet» ve parantez kontrolleri normal öğreniyor. Üç yazım
birleştirildiğinde `merhaba` sayımı 2, `“merhaba”` sayımı 1 olarak ayrı kaldı;
ikincisi hatırlama token'ı hâline geldi. Bu, beşinci turdaki kelime içi
kesmeden farklı olarak `tokenEdges` dış sınır kapsamasıdır.

İki harf alt sınırı ayrıca `bu o` ve `ben o dedim` içinde `o` hedefini
öğrenmiyor; `o geldi` içinde `o → geldi` öğrenilebiliyor. Açık min-length
politikasının Türkçe zamir için işlevsel kapsam eksikliği olarak kaydedildi.
`bu odur` ve `ben onu dedim` hedefleri çalıştı. Büyük-küçük harf negatif
kontrolleri (`İZMİR/İzmir/izmir`, `IŞIK/ışık`) aynı anahtara ve doğru sonraki
kelimeye ulaştı. Ham kanıt ve sınırlar `audits/turkish-round17-summary.json`
içinde; UI aktarımı veya üretim düzeltmesi yapılmadı.

**2026-10-10 — on sekizinci tarama, açık öğrenme ve kapasite:** Üretim paketli
koordinatörde 511/512 sentetik kişisel kayıtla üç kurulum, 13 kontrol noktası
çalıştırıldı. Kayıtlar public gözlem API'sinden üretildi: zayıf + güçlü kanıt
4 puan, yalnız güçlü kanıt 3 puan. 512 girdinin tamamı 4 puandayken yeni
`qrmenü` literal seçimi 3 puanla eklenip anında en zayıf olarak dışarı atılıyor.
Üç ardışık açık seçimde de metin doğru yazıldı fakat kelime öğrenilmedi;
puan her seferinde sıfıra döndü. Eski bir kelime silinince sonraki seçimde
kabul edildi. 511 girdilik kontrol ve 512 adet 3-puanlı girdi kontrolünde
ilk seçim öğrenildi; ikinci kontrolde en eski kayıt düştü.

Önceden belgelenen dolu sözlükte zayıf kanıtın düşmesi politikasının açık
kullanıcı seçimini de engellediği gösterildi; bu, "ilk öneriden seçince hemen
öğrenilir" arayüz vaadiyle çatışıyor. Sıklığı gerçek kullanıcı verisiyle
ölçülmedi. Silme kontrolünde hedef hem kişisel kümeden hem motor sözlüğünden
çıktı. `audits/turkish-round18-summary.json` ve ham sonuçlar kaydedildi;
UIKit bildirimi/persist testi veya üretim düzeltmesi yapılmadı.

**2026-10-10 — on dokuzuncu tarama, kip birleşimleri:**
[KTÜ Türk Dili ders içeriğindeki](https://www.ktu.edu.tr/turkdili/guzdonemidersicerikleri)
birleşik çekim kuralı ve örnekleri referans alınarak 82 yeni paradigma örneği
yazıldı; önceki korpus JSON'larıyla aynı yüzey çıkmadı. Üretim paketi, taze
profil ve tuş merkezlerinde 15 yüzey değişti. Şart birleşimlerinde 8/24,
yetersizlik geniş zamanda 7/20 değişim; gereklilik 0/18 ve olumsuz emir/istek
0/20. Örnekler: `gelseymişsiniz → geleymişsiniz`, `gitseymişsiniz →
gitsemmişsiniz`, `gelemezmişsiniz → gelmezmişsiniz`, `yapamazdınız →
yapamazsınız`, `okuyamazmışsınız → okuyamadımmışsınız`, `söyleyemezmişsiniz →
söyleyemedimmişsiniz`. Anlam, zaman ve ek sırası değişimleri var.

Kaynak incelemesi şartın `afterPastTense`'e çıkıp rivayet ekinin oradan
başlamamasını ve yetersizlikten sonra geniş zaman `z` devamının eksikliğini
aday nedenler olarak gösteriyor; bu tur ayrı otomata yol sorgusuyla
izole edilmediler. Bozuk şahıs yığılmaları sekizinci turla ilişkili. Bunlar
15 ayrı kök hata diye sayılmadı, 15 yeni karşı-örnek olarak kaydedildi.
`audits/turkish-round19-summary.json` tüm sonuçları ve sınırları içerir;
üretim düzeltmesi yapılmadı.

**2026-10-10 — yirminci tarama, kip yollarının izolasyonu:** 29 yüzey, üretim
morfolojisi ve aynı ek tablosuyla kurulan dört-köklü bağımsız otomat üzerinde
harf harf yürütüldü; tüm kabul kararları eşleşti. `gelse/gelseniz` kabul
edilirken `gelsey…` geçişi yok; `gelmese` sonrası `gelmesey…` de kesiliyor.
`gelemez`/`yapamaz` içindeki `z` geçişi de yok; buna karşılık
`gelmezmişsiniz`, `gelemedim`, `gelemeyeceğim` kontrolleri kabul edildi.
Böylece on dokuzuncu turun iki kaynak hipotezi üretim otomatında doğrulandı.

`gelseydi`, `gelemez`, `gelemem`, `gelemeyiz`, `yapamazdı`, `yapamazsınız`
morfolojide yokken birleşik sözlükte var: hazır yüzey listesi ek eksiklerini
bazı kısa biçimlerde gizliyor. Önceki turda düzeltme sonucu çıkan
`okuyamadımmışsınız` ve `söyleyemedimmişsiniz` hem üretim hem izole otomat
tarafından kabul ediliyor; sekizinci turun şahıs yığılması bulgusuyla aynı
kök sorun. Bu tur yeni düzeltme sayımı yapılmadı; kanıtın amacı eksik doğru
biçim / kabul edilen bozuk biçim ayrımını kurmak. Sonuçlar
`audits/turkish-round20-summary.json` içinde; üretim düzeltmesi yok.


**2026-10-10 — yirmi birinci tarama, iyelik ve hâl ekleri:** Önceki korpus
JSON'larında bulunmayan 60 yazılmış paradigma, üretim paketi ve tuş merkezleriyle
sınandı. Üç değişim bulundu: `bahçesindeymişsiniz → bahçesindekiymişsiniz`,
`bahçelerinizdeymişim → bahçelerinizdekiymişim`,
`bahçelerimizdeydiniz → bahçelerimizdekiydiniz`. Üçünde de istenmeyen `ki`
ekleniyor; diğer 57 örnek korunuyor. Üç sorunlu yüzey ve üç oda-köklü kontrol
±0.2 ve merkez konumlarında tekrar sınandı: 18 koşunun dokuzunda aynı üç bozulma
tekrarlandı, dokuz kontrol korundu. Bu, gerçek motorun boşlukta yaptığı değişim;
simülatör testi değil. Üç bağımsız kök neden iddiası yok ve neden henüz izole
edilmedi. `audits/turkish-round21-summary.json` karar farklarını ve tüm tekrar
sonuçlarını içerir. Üretim düzeltmesi yapılmadı.


**2026-10-10 — yirmi ikinci tarama, satır sonu bağlamı:** Gerçek paket ve
ayrı bigram-etkin kontrollü kurulumda toplam 16 yol çalıştırıldı. Kontrollü
kurulumda `ve` sonrasında doğrudan Enter bağlamı temizlerken boşluk→Enter,
virgül→Enter ve öneri seçimi→Enter yolları `ve` bağlamını koruyor.
`newline` boş token erken dönüşü `closeToken(... context: .forget)` yolunu
atlıyor. Ayrı sınır yolu tutarsızlığı: `insertText("\n")` tek karakter
olduğundan sembol yoluna gidiyor ve bağlamı koruyor; `insertText("\n\n")`
bağlamı temizliyor. Nokta kontrolü temizliyor, yalnız boşluk kontrolü beklendiği
gibi koruyor.

Sınır: gerçek üretim paketinde bigram yok; bu nedenle mevcut paketle bu testte
bağlam sızıntısı veya yanlış düzeltme gözlenmedi. Kontrollü kurulumun varsayılan
bağlam ağırlığında ölçülen leksikal maliyetler de değişmedi. Bunlar etkin
bağlamlı motorun durum yönetimindeki gizli hatalar; kullanıcının güncel kelime
bozulmalarına neden oldukları iddia edilmiyor. Ham sonuçlar
`audits/turkish-round22-newline-context.json`, kapsam ve sınırlar
`audits/turkish-round22-summary.json` içinde. Üretim düzeltmesi yok.


**2026-10-10 — yirmi üçüncü tarama, öğrenilmiş yüzeyin kapsamı:** Altı özel
kelime için kök, baş harfi büyük, tamamı büyük ve üç ekli biçim; öğrenilmemiş /
özgün öneri seçilerek öğrenilmiş eşleriyle 72 koşu. Öğrenilmiş yalın biçimler
6/6, harf biçimleri 12/12 korundu. Öğrenilmiş tabanların 18 ekli biçiminden
üçü hâlâ değişiyor: `qrmenüden → arkenizden`, `cepmenümüz → cepkenimiz`,
`cepmenüden → gelmenizden`. Öğrenilmemiş eşlerinde de aynı üç değişim var.
Ekli yüzeyin kendisi ayrıca seçilip öğretildiğinde bu üç kelimenin küçük,
baş harfi büyük ve tamamı büyük dokuz kontrolü de korundu.

Kaynak nedeni: `PersonalLexiconSource` yalnız kabul edilmiş tam yüzeylerden
trie kuruyor; kişisel kelimelere morfolojik kök eklemiyor. İkinci turun ekli
kelime açığı genişletildi, yeni bağımsız kök hata diye sayılmadı. Özel kelimeler
standart birleşik yazım iddiası taşımayan kullanıcı kelimesi örnekleridir.
Gerçek paketle merkez dokunmaları kullanıldı; kalıcılık veya simülatör testi
yapılmadı. `audits/turkish-round23-summary.json` tüm sayıları içerir;
üretim düzeltmesi yapılmadı.


**2026-10-10 — yirmi dördüncü tarama, aktarım sırası:** Gerçek
`PersonalHistory.merge` ile 41 kontrollü koşu. Kaynakta eşit sayılı dört
`yarın → kelime` çiftinin yakınlık sırası `gece, akşam, öğle, sabah`.
JSON yükleme tek başına bu sırayı 30/30 koruyor. Boş geçmişe birleştirme
30/30'da değiştiriyor: aynı kaynak veriden bu koşuda iki farklı sıra çıktı.
Sayımlar korunuyor. Neden: `merge`, gelen `Stat.seq` sırasını kullanmadan
sırasız sözlük dolaşımında yeni sıra numaraları atıyor.

Kapasite kontrolünde iki kez görülen eski tek kayıt ile birer kez görülen
3000 sıralı ithal kayıt birleştirildi. Eski sık kayıt ve 3000 sınırı korundu;
amacı en az sayımlı/en eski kaydı atmak olan seçimde `audit0000@local.test`
yerine 10/10'da `audit1329@local.test` silindi. Hatırlama birincisi de kaynakta
`audit2999@local.test` iken `audit2350@local.test` oldu. Bunlar bu çalıştırmada
görülen örnekler; sözlük dolaşım sırasına bağlı olarak başka süreçte değişebilir.
Tek kök sorun, sıralama ve kapasite etkileri ayrı hata sayılmadı. Aynı geçmişi
iki kez birleştirmek sayımları topluyor (1→2); bu tek başına yeni hata diye
sayılmadı. Uygulama aktarımı ve klavye bekleyen aktarımı bu birleştirme metodunu
kullanıyor; tam UI/dosya aktarım testi yapılmadı. Bulgular
`audits/turkish-round24-summary.json` içinde; üretim düzeltmesi yok.


**2026-10-10 — yirmi beşinci tarama, sayı ve sembol sınırları:** Gerçek paket,
merkez dokunmaları, tam host bağlamı ve normal korumasız metin alanı modeliyle
50 örnek; 48 korundu. Sayı/kesme 10/10, ölçü 10/10, kapanış tırnak/parantezli
özel kelime 10/10 ve kısaltma/kesme stres örnekleri 8/8 korundu. Kısaltma
örnekleri standart yazım iddiası değil, sınır sondalarıdır. Kimlik/adres/saat
12 örneğinden iki URL yolu bozuldu: `https://example.com/qrmenü →
https://example.com/arkeni`, `https://example.com/cepmenü →
https://example.com/gelmeni`. İkinci turun işaret sonrası token bölünmesi
bulgusuna ek kanıt; yeni kök hata diye sayılmadı. Özel URL/e-posta alanlarının
koruması bu çalıştırmada sınanmadı. Kapanış sembollerinin kelimeyi düzeltmeden
kapatması bu örneklerde koruma sağlıyor; tüm noktalama akışlarının doğru olduğu
anlamına gelmiyor. `audits/turkish-round25-summary.json` sonuç ve sınırları
barındırır; üretim düzeltmesi yapılmadı.


**2026-10-10 — yirmi altıncı tarama, açılım önerileri:** Üretim paketinin
kendi açılım haritasıyla sekiz kısaltma (`slm`, `mrb`, `nbr`, `kib`, `bb`,
`sagol`, `napıyon`, `tmm`) üç harf biçiminde sınandı. Küçük harf 8/8 açılım
sunuyor; baş harfi büyük ve tamamı büyük 16/16 açılımı kaybediyor. Örneğin
`slm | selam` yerine `Slm | slm` / `SLM | slm` geliyor. `SuggestionPresenter`
`session.display` yüzeyini aratıyor; `ExpansionMap` yalnız NFC normalizasyonu
yapıp büyük/küçük harfe duyarlı arıyor. Bu nedenle harf biçimi açılım erişimini
kesiyor. Otomatik büyük harfli UI dizisi değil, bu yüzeyleri yazan gerçek motor
komutları sınandı.

İkinci şüphe olumsuz sonuçlandı: beş çok-kelimeli açılım öneriden seçilip
son boşluğu geri silindikten sonra kelime silme uygulandı. Beşinde de yalnız
son kelime silindi; aynı metnin hazır metin olarak eklenmesi kontrolleriyle
eşleşti (`kendine iyi bak → kendine iyi ` gibi). Fazladan kelime silme hatası
iddiası yok. Toplam 34 gözlem, `audits/turkish-round26-summary.json` içinde;
üretim düzeltmesi yapılmadı.


**2026-10-10 — yirmi yedinci tarama, kişisel sözlük silme/kalıcılık:** Yeni
hata doğrulanmadı. Dört özel kelime, küçük/büyük harf ve ayrıştırılmış Unicode
silme biçimleriyle 12 gerçek dosya gidiş-dönüşünde sınandı. Özgün öneri seçimiyle
öğrenme ve kaydetme sonrası yeni motorda tanındılar; silme ve yeniden yükleme
sonrasında 12/12 kişisel kabul ve sözlük üyeliği kalktı. Son kayıt silindiğinde
dosya da 12/12 kaldırıldı. Dört ayrı çok-kayıt kontrolünde bir kelime silinince
diğer üçü kaydetme/yükleme sonrasında korundu. Geçici test klasörü kullanılıp
silindi; kullanıcı deposuna dokunulmadı.

Sınır: gerçek `PersonalLexiconStore` ve koordinatörler kullanıldı; son kayıt
kaydetme/silme seçimi `InputSession` ile aynı biçimde testte yönlendirildi.
Tam InputSession/UI veya ortak snapshot akışı, başarısız yazma ve süreç ölümü
sınanmadı. Uygulamanın Öğrenme listesi salt okunur; burada klavye ayarlarındaki
silme yolunun çekirdek/depo kısmı kapsandı. 16 sonuç
`audits/turkish-round27-summary.json` içinde; üretim düzeltmesi yok.


**2026-10-10 — yirmi sekizinci tarama, zarf-fiil aileleri:**
[MEB ek listesi](https://ogmmateryal.eba.gov.tr/panel/upload/etkilesimli/kitap/defterim/10/tde/files/basic-html/page59.html)
referansıyla yazılan ve önceki korpus JSON'larında bulunmayan 78 örnek sınandı.
Merkezde yedi bozulma: `gelebildikçe`, `gidebildikçe`, `yapabildikçe`,
`okuyabildikçe`, `söyleyebildikçe`, `anlayabildikçe`, `yazabildikçe`
yüzeylerinin `-dikçe` sonu `-dikler`e çevrildi. Diğer 71 örnek korundu.
`görebildikçe` de sözlük dışı olmasına rağmen merkezde korunuyor; yalnızca
sözlük üyeliği farkı açıklamıyor. Sekiz `-bildikçe` örneği üç konumda tekrarlandı:
24 koşuda 18 değişim. Konuma göre ayrıntılar JSON'da; hepsinin her konumda
bozulduğu iddia edilmiyor.

Üretim zarf-fiil tablosunda `-DIKçA` kuralı yok; bu tur ayrı otomat yol
izolasyonu yapılmadı. Yedi örnek ayrı kök hata sayılmadı. Kaynak yalnız ek
aileleri için kullanıldı, test kelimeleri alıntı değil. Daha seyrek yetersizlik
+ `-meksizin` örnekleri stres sondasıydı ve hata örneği olarak kullanılmadı.
Gerçek paket/merkez ve ±0.2 konumları; simülatör değil.
`audits/turkish-round28-summary.json` kanıtları içerir; üretim düzeltmesi yok.


**2026-10-10 — yirmi dokuzuncu tarama, zarf-fiil yol izolasyonu:** 28 yüzey,
üretim morfolojisi ve aynı değişmemiş ek tablosuyla dört köklü bağımsız otomat
üzerinde yürütüldü; tüm kabul kararları eşleşti. `gel/yap/oku/söyle` köklerinin
kısa `-DIKçA` ve yeterlikli `-abilDIKçA` biçimleri `ç` harfinde kesiliyor.
`gelebildikler`, `yapabildikler`, `okuyabildikler`, `söyleyebildikler`
rakipleri model tarafından kabul ediliyor. Böylece önceki turun kaynak
hipotezi doğrulandı; yeni otomatik düzeltme sayımı yapılmadı.

`gelirken/yaparken/okurken/söylerken` biçimleri de morfolojide `k` harfinde
kesiliyor fakat dördü hazır sözlükte var. `geldikçe` hazır sözlükte varken
`yaptıkça/okudukça/söyledikçe` orada da yok; önceki turda korunmaları otomatik
olarak morfolojide tanındıkları anlamına gelmiyor. `-ince`, `-erek` ve yeterlikli
`-erek` kontrolleri kabul edildi. `-ken` kapsama açığı ayrı gerçek yazım
bozulması diye sunulmadı. Sonuçlar `audits/turkish-round29-summary.json` içinde;
üretim düzeltmesi yok.


**2026-10-10 — otuzuncu tarama, uzun -ken biçimleri:** Önceki korpus
JSON'larından farklı 74 yüzey merkez dokunmalarıyla sınandı. Yalnız
`söyleyemezken → söyleyemesen` değişti; diğer 73 yüzey korundu. Tek kelime,
`bunu söyleyemezken`, `henüz söyleyemezken` ve `söylemezken` kontrolü üç
konumda tekrarlandı: 12 koşuda yedi değişim. İlk üçü merkez ve -0.2'de aynı
bozulmayı verdi, +0.2'de korundu. `söylemezken` yalnız -0.2'de `söylemeksen`
oldu; merkezde doğru kaldı.

Dört yüzeyin üretim ve izole otomat izlemesi eşleşti. `söyleyemezken`
daha `z` harfinde kesiliyor (`-ken`e ulaşmıyor); bu yüzden bozulmayı yalnız
`-ken` açığına bağlamak yanlış olur. `söylemezken` ise `k` harfinde kesiliyor.
Rakip `söyleyemesen` kabul ediliyor. Mevcut yetersizlik/geniş zaman ve `-ken`
kapsama açıklarının yeni karşı-örnekleri; bağımsız yeni kök hata sayılmadı.
`audits/turkish-round30-summary.json` tüm sonuçları içerir; üretim düzeltmesi yok.


**2026-10-10 — otuz birinci tarama, soru ekleri:** 69 yeni ifade merkezde
sınandı; iki bozulma: `görmüş müymüşsünüz → görmüş nüymüşsünüz`,
`üzgün müymüşsünüz → üzgün nüymüşsünüz`. Diğer 67 örnek korundu. Dört ünlü
biçimi (`miymişsiniz/mıymışsınız/muymuşsunuz/müymüşsünüz`) ve iki cümle üç
konumda tekrarlandı; 18 koşuda dokuz değişim. `müymüşsünüz` tek başına ve iki
ifadede her üç konumda bozuldu: merkez/-0.2 `nüymüşsünüz`, +0.2
`miymişsiniz` üretti. Diğer üç ünlü biçimi korundu.

Kaynak envanterinde `mi` ve `nü` isim kökü var, `mı/mu/mü` kökleri yok; yalın
dört soru biçimi ve `nü` yüzey listesinde bulunuyor. Bu asimetri aday neden;
bu tur ayrı üretim otomatı yol sorgusu yapılmadı. İki cümle aynı soru biçimi
bozulmasının örnekleri, iki ayrı kök hata sayılmadı. Gerçek paket/denetimli
dokunmalar kullanıldı, simülatör testi değil. Soru-şart örnekleri stres sondası
olarak tutuldu ve hata örneği sayılmadı. `audits/turkish-round31-summary.json`
ayrıntıları içerir; üretim düzeltmesi yok.


**2026-10-10 — otuz ikinci tarama, soru kökü izolasyonu:** 26 biçim üretim
morfolojisi, yalnız `mi/nü` isim kökleriyle bağımsız model ve test belleğinde
`mı/mu/mü` de eklenmiş karşı-olgusal modelle karşılaştırıldı. Üretim ve iki
köklü model tüm kabul kararlarında eşleşti. `miymişsiniz` ile `nüymüşsünüz`
kabul edilirken `müymüşsünüz` reddediliyor; önceki turun asimetri hipotezi
doğrulandı. Eksik üç kökü ekleyen deneme modeli rivayet biçimlerini kabul
edebiliyor; üretim dosyaları değiştirilmedi.

Ancak `miyim/mıyım/muyum/müyüm` beş köklü modelde de reddediliyor. Dördü
hazır sözlükte bulunduğundan bu yüzeylerde yeni yazım bozulması iddiası yok.
Bu, kökleri eklemenin bütün soru eki kapsamını çözmediğini gösteriyor;
kökleri gelişigüzel isim saymak da güvenli bir nihai çözüm olarak önerilmedi.
Ham biçimler ve karşılaştırma `audits/turkish-round32-question-paths.json`,
kapsam `audits/turkish-round32-summary.json` içinde. Yeni otomatik düzeltme
sayımı veya üretim düzeltmesi yok.


**2026-10-10 — otuz üçüncü tarama, isim yüklemleri ve iyelik:** 73 yeni
biçim merkez dokunmalarıyla sınandı, yedisi değişti. `öğretmensiniz →
öğretmendiniz`, `üzgünsünüz → üzgündünüz`, `yorgunsunuz → yorgundunuz`
şimdiki isim yüklemini geçmişe çeviriyor. `öğrencisiymişiz → öğrenciymişiz`
ve `yolcusuymuşuz → yolcuymuşuz` iyelik bilgisini düşürüyor.
`ütücüymüşüm/ütücüymüşüz → sürücüymüşüm/sürücüymüşüz` kökü değiştiriyor.
Diğer 66 örnek korundu.

Yedi örnek üç konumda tekrarlandı: 21 koşuda 20 değişim. `öğretmensiniz`
-0.2'de korundu; diğer iki konumda değişti. Ütücü biçimleri +0.2'de
`büyücüymüşüm/büyücüymüşüz` oldu; öbür konumlardaki sürücü sonucundan farklı
ama yine yanlış yüzey. Diğer dört kelime üç konumda aynı bozulmayı verdi.
Yedi karşı-örnek ayrı kök hata sayılmadı; bu tur ek yolları ayrı izole
edilmedi. `audits/turkish-round33-summary.json` tüm sonuçları içerir;
üretim düzeltmesi yapılmadı.


**2026-10-10 — otuz dördüncü tarama, isim yüklemi nedenleri:** 24 yüzey
üretim otomatı ve ek tablosu değiştirilmeden sekiz açık isim köküyle kurulan
izole modelde karşılaştırıldı. Önceki yedi örnek üç mekanizmaya ayrıldı:
`öğretmensiniz/üzgünsünüz/yorgunsunuz` her iki modelde reddedilirken kökleri
ve geçmiş zaman rakipleri kabul ediliyor. `öğrencisi/yolcusu` kabul edilirken
`öğrencisiymişiz/yolcusuymuşuz` iyelik sonrası `y` harfinde kesiliyor;
iyeliksiz rivayet biçimleri çalışıyor. `ütücü` ise üretim kök/yüzey listelerinde
yok, yol `ütüc`te kesiliyor. Yalnız testte açık kök sağlanınca `ütücüymüşüm`
ve `ütücüymüşüz` mevcut ek tablosuyla kabul ediliyor.

Üretim/izole kabul farkları yalnız bu üç ütücü yüzeyinde; diğer 21 karar
eşleşiyor. Üzgün/yorgun üretimde sıfat, izole testte isim kökü olarak aynı
nominal devam davranışıyla sınandı; test modelinin tüm metadata bakımından
üretimle aynı olduğu iddia edilmedi. Bu, düzeltme önerisinin uçtan uca testi
değil, önceki karşı-örneklerin neden ayrımıdır. Sonuçlar
`audits/turkish-round34-summary.json` içinde; üretim düzeltmesi yok.


**2026-10-10 — otuz beşinci tarama, gündelik sıfat yüklemleri:** 64 yeni
ikinci çoğul kişi biçimi merkezde sınandı; 13'ü değişti. Örnekler:
`haksızsınız → haksızdınız`, `mutsuzsunuz → mutsuzdunuz`, `çalışkansınız →
çalışkandınız`, `yalnızsınız → yalnızdınız`, `suçsuzsunuz → suçsuzdunuz`.
`uykusuzsunuz → uymuşuzdunuz` ve `şanssızsınız → şansmışsınız` da gözlendi. Diğer 51 örnek korundu. 13 sorunlu yüzey üç
konumda tekrarlandı: 39 koşuda 37 değişim. Kaynak yüzey listesi yalnız 13/64
girdiyi içeriyor; bu sayı üretim birleşik sözlük kapsamıyla aynı kabul edilmedi.
Gündelik kelime seçimi nitel bir seçimdir, kullanım sıklığı ölçümü değildir.
Önceki isim kişi eki sorununun daha geniş karşı-örnekleri; 13 ayrı kök hata
sayılmadı. `audits/turkish-round35-summary.json` tüm yüzeyleri içerir;
üretim düzeltmesi yapılmadı.


**2026-10-10 — otuz altıncı tarama, gerçek simülatör doğrulaması:** Device Hub
üzerindeki iPhone 17 Pro / iOS 26.5, BestKeyboard ana ekranı DENE alanında
`yalnızsınız` ekran klavyesinin 11 harf tuşuna basılarak yazıldı. Boşluktan önce
metin `yalnızsınız`, öneriler `yalnızsınız | yalnızdınız` olarak görüldü.
Ekran boşluk tuşuna basınca metin `yalnızdınız ` oldu. CUA önce/sonra
screenshot'ları konuşma araç çıktısında; iOS iç AX metni bulunmadığından
metin görsel olarak doğrulandı. Donanım yazımı/yapıştırma kullanılmadı.

Bu, otuz beşinci turun bir karşı-örneğinin gerçek uzantı UI doğrulamasıdır;
diğer 12 kelime için UI kapsamı iddia edilmiyor. Mevcut simülatör profili
kullanıldı, Tam Erişim kapalı kaldı. Yalnız yerel deneme alanı değişti.
Yüklü uzantı dosyası özeti ve adımlar
`audits/turkish-round36-simulator-autocorrect.json` içinde; üretim düzeltmesi yok.


**2026-10-10 — otuz yedinci tarama, simülatörde yeniden düzeltme:** Önceki
turun `yalnızdınız ` sonucundan ekran geri silme tuşuna bir kez basıldı.
Belgede `yalnızdınız` kaldı ve öneri çubuğunda yalnız `yalnızdınız` görüldü;
özgün `yalnızsınız` yoktu. Ardından son beş karakter `dınız` tek tek silinip
`sınız` ekran tuşlarından yazıldı. Belge yeniden `yalnızsınız`, öneriler
`yalnızsınız | yalnızdınız` oldu. Boşluk tuşuna basınca metin tekrar
`yalnızdınız ` oldu.

Üçüncü turun özgün öneriyi kaybetme/yeniden düzeltme ailesine gerçek UI
kanıtı; bağımsız yeni kök hata sayılmadı. Bu tur öneriden açık özgün seçim
uygulanmadı, yalnız elle ek düzeltme sınandı. Tek kelime/tek akış; tüm geri
alma yollarının başarısız olduğu iddia edilmiyor. CUA önce/sonra görüntüleri
araç çıktısında; adımlar `audits/turkish-round37-simulator-reedit.json` içinde.
Yerel deneme alanı kullanıldı, üretim düzeltmesi yapılmadı.


**2026-10-10 — otuz sekizinci tarama, simülatörde özgün öneriden öğrenme:**
Önceki yanlış `yalnızdınız ` sonucu elle tekrar `yalnızsınız`a getirildi.
Bu kez boşluk yerine ilk öneri `yalnızsınız` seçildi. `Kelime öğrenildi`
bildirimi görüldü; ardından aynı kelime yeni token olarak 11 ekran harf
tuşuyla yeniden yazılıp boşlukla kapatıldı. Belgede `yalnızsınız yalnızsınız `
kaldı. Bu akışta yeni hata yok; açık özgün seçim aynı kelime için döngüyü
kırabiliyor. Önceki turdaki yanlış düzeltme sonrası özgün önerinin kaybolması
sorunu bundan çözülmüş sayılmadı.

Önemli test durumu: simülatörün mevcut profilinde `yalnızsınız` artık öğrenilmiş;
sonraki taramalarda bu kelime öğrenilmemiş kontrol olarak kullanılamaz.
Yeniden başlatma/kalıcılık veya ek genellemesi bu UI turunda sınanmadı.
Adımlar `audits/turkish-round38-simulator-learning.json` içinde;
üretim düzeltmesi yapılmadı.


**2026-10-10 — otuz dokuzuncu tarama, simülatörde büyük harf/açılım:** Aynı
DENE alanında `yalnızsınız yalnızsınız ` bağlamından sonra `slm` ekran
tuşlarıyla yazıldı; öneriler `slm | selam` oldu. Son üç harf silindi, Shift'e
bir kez basılıp `Slm` yazıldı; öneriler `Slm | slm` oldu ve `selam` kayboldu.
Yalnız baş harf biçimi değişen gerçek UI karşılaştırması, yirmi altıncı turdaki
açılım arama hatasını doğruluyor; yeni bağımsız kök hata sayılmadı. Hiç öneri
seçilmedi, bu tur yeni kelime öğrenilmedi. CUA görüntüleri araç çıktısında,
adımlar `audits/turkish-round39-simulator-expansion.json` içinde;
üretim düzeltmesi yok.

**2026-10-10 — kırkıncı tarama, sayılar ve ekler:** Gerçek üretim paketiyle,
her ifade için temiz profilde 66 merkez dokunuş denemesinin 2’si değişti:
`3 numaradaymışız → 3 numaraymışız` ve `2020lerdeymişiz → 2020perdeymişiz`.
İkinci örnek gündelik kesmesiz giriş stresidir; doğru yazım iddiası değildir.
16 ifadeli üç ofsetli takipte 48 koşunun 28’i değişti. Kesmesiz yıl örneği
üç ofsette de bozulurken `2020’lerdeymişiz` üçünde de korundu. Tek başına
`lerdeymişiz` aynı `perdeymişiz` düzeltmesini alıyor: sembolle bölünen token’ın
rakam korumasını kaybetmesi önceki koruma ailesini doğruluyor.

`numaradaymışız`, `numaradaysak`, `numaradaymışım`, `numaradaymışsınız` ve
`arabadaymışız` üç ofsette de `da` kaybetti; `sıradaymışız` üçünde de
`sıradağmışız` oldu. Bu ikinci grubun kesin morfoloji nedeni henüz izole
edilmedi; bağımsız yeni kök hata sayılmadı. İki hedefli tanı testi geçti;
bu, kaydedilen yanlış çıktıları başarılı ürün davranışı yapmaz. UI testi
ve üretim düzeltmesi yok. Girdiler, CSV sonuçları, sınırlar ve sonraki adım
`audits/turkish-round40-summary.json` ile ilişkili dört dosyada kayıtlı.

**2026-10-10 — kırk birinci tarama, bulunma hâli → ek-fiil yolu:**
`numara/araba/sıra/masa/oda` için 30 yüzeyin üretim morfolojisi ile yalnız
bu beş açık kökü kullanan değişmemiş ek kuralları karşılaştırıldı. Kök,
`-da` biçimi ve doğrudan `-ymışız` biçimi olan 15 kontrol tanınıyor.
`-daymışız/-daydık/-daysak` birleşimli 15 yüzey iki otomatta da `y` harfinde
kesiliyor ve üretim sözlüğünün tamamında da tanınmıyor. Kaynakta ek-fiil
geçişleri `nounRoot/afterTense/afterPerson` çıkışlı; `afterLocative` ve
`afterNominalCase` çıkışları yok. Sorun kökün sözlükte bulunmaması değil,
hâl ekinden ek-fiile geçişin eksik olması.

Bu, kırkıncı turdaki yanlış değişimlerin nedenini daraltıyor; 15 bağımsız
hata sayılmadı. Tanınmamak her örneğin otomatik bozulacağı anlamına gelmez:
önceki turda `numaradaydık` korunmuştu. Hedefli yol testi ve 30 satırlık
sonuç doğrulaması geçti. UI ve değiştirilmiş ek tablosu karşı-deneyi yok;
üretim düzeltmesi yapılmadı. Kanıt ve sonraki kapsam adımı
`audits/turkish-round41-summary.json` ile ilgili girdi/yol dosyalarında.

**2026-10-10 — kırk ikinci tarama, diğer isim devamları:** 36 yüzeyin
merkez dokunuş taramasında 8 değişim: `evdeymişiz → evetmişiz`,
`evdenmişiz → evsenmişiz`, `eveymişiz → evetmişiz`,
`arabadaymışız → arabaymışız`, `arabadanmışız → arabaysanmışız`,
`arabayaymışız → arabaymışız`, `arabalarmışız → aransalarmışız`,
`arabammış → arabanmış`. Her ifade temiz profilde gerçek üretim paketiyle
sınandı; bu tur simülatör doğrulaması yapılmadı.

Aynı 36 yüzeyin yol karşılaştırmasında 21 birleşik biçimin tamamı yalnız
`ev/araba/çocuk` kökleriyle çalışan değişmemiş ek grafında reddediliyor;
üretim morfolojisi bunların 20’sini reddediyor. `evinmiş` üretimde başka
bir kök/yol üzerinden kabul ediliyor; bu alternatif analiz henüz açılmadı.
Eksik çıkışlar bulunma hâliyle sınırlı değil: diğer hâller, genitif, çoğul,
1./2. ve 3. şahıs iyelik durumlarından ek-fiile geçiş yok. Önceki turlarla
aynı devam eksikliği ailesi; sekiz yeni bağımsız hata sayılmadı. Reddedilen
her biçim otomatik değişmiyor. İki hedefli tanı testi geçti; üretim kodu
aynı. Girdi, çıktı, yol ve sınırlar `audits/turkish-round42-summary.json`
ve ilişkili dört dosyada kayıtlı.

**2026-10-10 — kırk üçüncü tarama, kelimeyi kapatma karşılaştırması:**
Beş kelime × beş sınır yolu × üç ayrı yazım ile 75 gözlem kaydedildi.
Boşluk `qrmenü → arkeni`, `evdenmişiz → evsenmişiz` yaparken nokta, virgül,
satır sonu ve nokta+boşluk özgün yüzeyi koruyor. Ancak gerçek yazım yanlışı
`geliyprum` da bu yollarda düzelmiyor; yalnız boşluk `geliyorum` yapıyor.
`yapabilirseniz` üç boşlukla kapanan kullanımda 3 puanla öğreniliyor;
diğer dört yol sıfır puanda kalıyor. Noktadan sonraki boşluk geriye dönük
karar veya kişisel öğrenme üretmiyor.

Bu davranış kaynakta açıkça belgelenmiş politika: düzeltme sorulmayan
sınırdan kişisel sözlüğe zayıf kanıt alınmıyor. Dolayısıyla bu tur yeni
bağımsız uygulama hatası sayılmadı; ürün davranışı farkı ve mevcut yanlış
boşluk düzeltmesine kontrol kaydedildi. Tanı testi geçti, UI sınanmadı,
üretim kodu değişmedi. Kanıt `audits/turkish-round43-boundaries.json`,
yorum ve sınırlar `audits/turkish-round43-summary.json` içinde.

**2026-10-10 — kırk dördüncü tarama, olumsuzluk ve yokluk:** 57 merkez
koşusunda 6 değişim kaydedildi: `değilmişsinizdir → değilmişsinizdi`,
`yoksaydınız → yoksayınız`, `yapamazsanız → yaşamazsanız`,
`okuyamazsanız → okuyamasanız`, `söyleyemezseniz → söyleyemeseniz` ve
`yapamazsanız söyleyin → yaşamazsanız söyleyin`. 13 yüzeyin üç ofsetli
kontrolünde 39 koşunun 14’i değişti; tüm satırlar kaydedildi.

Yetersizlik/geniş zaman örnekleri önceki eksik `z` ailesiyle ilişkili;
`yoksaydınız` ve `değilmişsinizdir` için kesin yol nedeni henüz izole
edilmedi. Kaynakta ayrı bildirme `-DIr` kuralı görünmüyor ve `değil`
kökünün sınıfı ayrıca incelenmeli; bunlar henüz bu iki çıktının kanıtlanmış
nedeni sayılmadı. İki hedefli tanı testi geçti. UI testi veya üretim
kodunda düzeltme yok. Kanıt ve sonraki adım
`audits/turkish-round44-summary.json` ile dört korpus/sonuç dosyasında.

**2026-10-10 — kırk beşinci tarama, bildirme eki ve şart devamı:**
27 yüzeyde yol karşılaştırması yapıldı. `değilmişsinizdir`, `evmişsinizdir`,
`öğrenciymişsinizdir` üretimde ve açık isim kökleriyle son `r` harfinde
kesiliyor; `...di` rakipleri kabul ediliyor. Kaynakta ek-fiil bildirme
`-DIr` yok, yalnız fiilden ettirgen `-DIr` var. `değil`i isim kökü olarak
tanımlamak da bu eksikliği gidermiyor. `gelmiştir/yapmıştır` kısa yüzeyleri
düz sözlük korurken üretim morfolojisi bunları da son `r`de reddediyor.

14 merkez takip koşusunda 6 değişim: `evmişsinizdir → evmişsinizdi`,
`öğrenciymişsinizdir → öğrenciymişsinizdi`, `gelmişsinizdir → gelmişsinizdi`,
`gitmişsinizdir → gitmişsinizdi`, `okumuşsunuzdur → okumuşsunuzdu`,
`yoksaydınız → yoksayınız`. `yoksa` kabul edilirken şart sonrası ek-fiil
izole yolda `y`de kesiliyor; bu önceki şart devamı ailesi. Üretimde kabul
edilen `varsaydınız`, izole `var` isim kökünden üretilemiyor; kök tablosunda
ayrı `varsay` fiili bulunduğundan bu kabul, şart devamının çalıştığına
kanıt sayılamaz. Üretim `yoksaydınız` yolunun kesilmesi `d` harfinde;
izole yolla birebir aynı önek diye raporlanmadı.

İki hedefli tanı testi geçti. İzole otomatta fiil kökü bulunmadığından
`gel/yap` satırlarının izole sonucu kanıt sayılmadı; onların üretim yolu
incelendi. UI veya değiştirilmiş ek tablosu karşı-deneyi yok, üretim
kodu aynı. Kanıtlar `audits/turkish-round45-summary.json` ve ilişkili
dört girdi/sonuç dosyasında.

**2026-10-10 — kırk altıncı tarama, kök değişimleri:** 64 merkez koşusunda
bir değişim oldu: keşif amaçlı, seyrek `yokunuzdan → yolunuzdan`. Bu biçim
gündelik doğru yazım hatası sayısına eklenmedi. Diğer 57 yumuşama,
yumuşamama ve ünlü düşmesi kontrolü korundu; bu sonuç kök kurallarının
bütün biçimlerde doğru olduğunu kanıtlamaz.

Çift ünsüzlü köklerden 18 birleşik biçimle yapılan takipte iki değişim:
`sırrımdakiler → sırtımdakiler`, `zannımdakiler → sanımdakiler`. Kök
tablosundaki `sır/zan` alternasyonu `none`; çift ünsüz ile ek devamı
nedenleri henüz yol incelemesiyle ayrılmadı, bağımsız kök hata sayısı
atanmadı. İki hedefli tanı testi geçti. UI testi, ofset takibi ve üretim
düzeltmesi yok. Kanıt ve sonraki adım `audits/turkish-round46-summary.json`
ile dört girdi/sonuç dosyasında kayıtlı.

**2026-10-10 — kırk yedinci tarama, çift ünsüz nedeninin ayrılması:**
26 yüzey iki kez izlendi: açık `sır/zan/hak/his` kökleri ve yalnız deney
amaçlı `sırr/zann/hakk/hiss` gövdeleri. Ek kuralları değiştirilmedi.
`sırrı/sırrım/sırrımda/sırrımdaki/sırrımdakiler` ve beş eş `zann` biçimi
üretim morfolojisinde reddediliyor; çift ünsüzlü deney gövdesiyle 10/10
kabul ediliyor. Böylece önceki yanlış değişimin kök çiftleşmesi kapsamıyla
ilişkisi ayrıldı: sonraki ek zinciri mevcut kurallarla kurulabiliyor.

`sırrı/sırrım` düz sözlük sayesinde korunuyor, uzun devamları korunmuyor;
beş `zann` biçimi de sözlük dışı. Yanlış `sırtımdakiler/sanımdakiler`
rakipleri üretimde tanınıyor. `hak/his` kontrolünde sade kök yolları
reddederken üretim tanıyor; tabloda ayrıca `hakkı` özel adı ve `hissi`
sıfatı var, fakat kesin alternatif analiz açılmadığından bunlar tek neden
diye raporlanmadı. Üretimin ilk kopuşu `sırrı/zannı`, sade kök deneyinin
kopuşu `sırr/zann`: aynı önek sayılmadı.

Ham çiftleşmiş kök eklemek yalnız ayırıcı deney; yalın `sırr/zann` gibi
geçersiz biçimleri de kabul ettirebileceği için çözüm olarak önerilmedi.
İki hedefli yol testi ve 10 biçim karşılaştırması geçti. Üretim, UI ve
sıralama değişikliği yok. Kanıt `audits/turkish-round47-summary.json`
ve üç korpus/yol dosyasında.

**2026-10-10 — kırk sekizinci tarama, zamir ve ilgi eki zincirleri:**
60 merkez koşusunda 13 değişim. Örnekler `kendisininkilerden → kedisininkilerden`,
`kendiminkilerden → memsiminkilerden`, `kendilerininkilerden → mendillerininkilerden`,
`herkesinki → heroesinki`, `herkesinkilerden → heroesinkilerden`,
`birbirimizinki → birebirimizinki`, `şunlardakilerden → şulardakilerden`.
Önceden bulunan `sizinkilerden → sisinkilerden` de tekrarlandı.
13 değişen biçim ve 3 kontrolün üç ofsetli takibinde 48 koşunun 38’i
değişti. Bütün girdi/çıktılar saklandı; örnekler tek tek kök hata sayılmadı.

Kök envanteri, zamir çekimi ve başka dilden aday etkisi henüz ayrılmadı.
`birilerinki` yalnız keşif girdisi, normatif doğru kelime iddiası değil.
İki hedefli tanı testi geçti; UI, gerçek kullanıcı hata oranı veya üretim
düzeltmesi iddiası yok. Kanıt ve takip adımı
`audits/turkish-round48-summary.json` ile dört korpus/sonuç dosyasında.

**2026-10-10 — kırk dokuzuncu tarama, zamir kökü ve zamir gövdesi:**
32 yüzeyin üretim/izole yol karşılaştırmasında `kendi/herkes/siz/birbiri`
ile başlayan 22 yüzey üretim morfolojisinde reddedilip açık deney isim
kökleriyle kabul edildi. Bunların 9’u düz sözlükte de yok. Bu grupta
sonraki ek kuralları mevcut; kök envanteri eksikliği ayrıldı.

`şu` ise üretimde mevcut. `şunlar/şunlarda/şunlardakilerden` hem üretim
hem açık `şu` köküyle reddediliyor; izole kopuş `şunl`. Yanlış n’siz
`şulardakilerden` iki otomatta da kabul ediliyor. Kısa `şunlar` düz
sözlükle korunuyor. Bu, kök yokluğundan farklı bir zamir gövdesi devamı
sorunu. Ayrıca `heroesinki` üretim morfolojisinde tanınıyor ve Türkçe
kök tablosunda `hero/heroes` isimleri 30000 frekansla mevcut; önceki
çıktı yalnız çalışma zamanı İngilizce dil seçimine bağlanamaz. Tam
kazanan analiz/maliyet açılmadı, köklerin toptan silinmesi önerilmedi.

Hedefli yol testi ve 22 biçim karşılaştırması geçti. Deney isim kökleri
tam zamir dilbilgisi çözümü değil; üretim kökleri, sıralama ve UI
değişmedi. Kanıt `audits/turkish-round49-summary.json` ve iki girdi/yol
dosyasında.

**2026-10-10 — ellinci tarama, kök verisinin yerel geçmişi:** Güncel
kök dosyası 50.573 satır; `1d36b2f` öncesi sürüm 30.041 satır. Yüzey+tür
kimliğiyle karşılaştırmada 20.525 yeni kimlik var; bunların 853’ünde sayım
30.000. `hero/heroes/mems` önceki sürümde yok, güncelde 30.000 sayımlı isim
kökleri. Dolayısıyla bu eklemeler özgün Zemberek dönüşümünün çıktısı diye
nitelendirilemez; ekleme kaynağının ayrıntısı bu turda doğrulanmadı.

Paket derleyicisi sayımı `-log(count/total)` ile maliyete çeviriyor; sayım
sıralamaya etki eder. Ancak bu tek başına ideal frekansı veya kök silmenin
sonucu düzelteceğini kanıtlamaz. Yerel dönüşüm notu zamir POS’unun baştan
kapsam dışı bırakıldığını söylüyor; önceki turdaki eksikliğin geçmişini
açıklıyor, bugünkü doğru kelime bozulmasını çözmüyor.

Eklenen fiil satırlarında `öğrenmek/öğretmek/okumak` gibi mastar biçimleri
var. Belgelenmiş kök çıkarma kuralıyla olası uyumsuzluk; geçersiz çekim
üretip üretmedikleri sonraki turda sınanacak, şimdiden tamamı hata sayılmadı.
Bu tur kaynak ve Git geçmişi incelemesi; UI/üretim değişikliği yok.
Sayısal karşılaştırma ve satır örnekleri `audits/turkish-round50-summary.json`
içinde saklandı.

**2026-10-10 — elli birinci tarama, mastarın fiil kökü sayılması:**
24 yüzeyde üç yol karşılaştırması yapıldı. `öğrenmekiyor`, `öğretmekiyor`,
`okumakıyor`, `yazmakıyor`, `anlamakıyor`, `anlatmakıyor`, `açıklamakıyor`,
`düşünmekiyor`, `hatırlamakıyor`, `unutmakıyor` geçersiz şimdiki zaman
biçimlerinin 10/10’u üretim morfolojisinde ve sözlükte kabul ediliyor.
Aynı ek kurallarıyla açık mastarlı fiil kökleri bunları üretiyor, doğru
fiil gövdeleri ise 10/10’unu reddediyor. Böylece veri dönüşümünün geçersiz
çekim üretme etkisi ayrıldı. Tanınan yüzeyler mevcut karar kuralında
sözlük koruması alır; bu tur doğru yazının bu biçimlere düzeltildiği veya
bunların birinci öneri olduğu iddia edilmedi.

`öğrenmekti/okumaktı` geçerli mastar+ek-fiil biçimleri olabilir, hata
sayılmadı. Doğru şimdiki zaman eşleri üretimde tanınıyor. Açık doğru-kök
deneyi daralma gibi metadata taşımadığından bu deneyin doğru biçimler
üzerindeki kapsamı iddia edilmedi. Tanı aracına açık fiil kökü değişkeni
eklendi; üretim kodu aynı. Üç hedefli test ve 10 karşı-deney kontrolü
geçti. Kanıt `audits/turkish-round51-summary.json` ve dört girdi/yol
dosyasında, UI doğrulaması yok.

**2026-10-10 — elli ikinci tarama, geçersiz çekimin öneri/commit etkisi:**
Tanı dışa aktarımına son boşluktan önceki öneriler sütunu eklendi. Beş
fiil için tam geçersiz biçim, doğru biçim ve eksik harfli kontrollerle
25 merkez koşusu çalıştı. 10 geçersiz-biçime-yakın girdinin tamamında
geçersiz çekim özgün öneri dışında da sunuluyor. Bunların 6’sı boşlukta
otomatik tamamlandı: `öğrenmekiyo/öğrenmekyor → öğrenmekiyor`,
`okumakıyo/okumakyor → okumakıyor`, `düşünmekiyo/düşünmekyor → düşünmekiyor`.

Beş doğru şimdiki zaman kontrolü korundu; bu kontrollerde incelenen
geçersiz biçimler önerilmedi. Tam geçersiz biçimlerin beşi de korundu;
ilk özgün önerinin gösterilmesi tek başına sistemin onayı sayılmadı.
Bu, elli birinci turdaki yanlış kök üretiminin öneri/commit yoluna
ulaştığının kanıtı; yeni bağımsız hata değil. Yapay eksik harfli girdiler
kullanıldı, doğru gündelik biçimlerin bunlara dönüştüğü iddia edilmedi.
Hedefli test geçti, UI/üretim değişikliği yok. Kanıt
`audits/turkish-round52-summary.json` ve korpus/CSV dosyalarında.

**2026-10-10 — elli üçüncü tarama, gereklilik ve olumsuz olasılık:**
46 merkez koşusunda değişim yok. Ancak `gelmemeliyim/gelmemeliyiz`,
`okumalıyız/anlamalıyız` ve altı olumsuz olasılık biçimi üretim sözlüğünde
tanınmıyor. Bu 10 biçimin ±0,2 tuş boyu ofset takibindeki 20 koşuda
0 değişim kaydedildi. Korunma, morfolojinin çalıştığına kanıt sayılmadı.

Kaynakta `afterTense` birinci kişi ekleri açık kaynaştırma `y` içermiyor;
yeterlilik eki de yalnız `verbRoot` çıkışlı. Bunlar henüz yol izolasyonuyla
bu örneklere bağlanmamış ipuçları; yeni kök hata sayısı atanmadı. İki
hedefli tanı testi geçti. UI/üretim değişikliği yok. Kanıt, tüm ofset
çıktıları ve sonraki adım `audits/turkish-round53-summary.json` ile beş
girdi/sonuç dosyasında.

**2026-10-10 — elli dördüncü tarama, ünlü sonrası birinci kişi:**
22 yüzeyin yol karşılaştırması `-mAlI/-mAktA` sonrası birinci kişi
kaynaştırmasını ayırdı. Doğru `gelmeliyim/gelmeliyiz/gelmemeliyim/okumalıyız/
gelmekteyim/gelmekteyiz` üretim ve izole grafında reddedilirken yanlış
`gelmeliim/gelmeliiz/gelmemeliim/okumalıız/gelmekteim/gelmekteiz` kabul
ediliyor. Kopuş doğru yüzeyde `y`den sonraki ünlüde; kişi ekleri 70/72
`afterTense` üzerinden doğrudan ünlü ekliyor, kaynaştırma `y` yok.
Kısa `gelmeliyim/gelmeliyiz` düz sözlükle korunuyor.

Olumsuz olasılık `gelmeyebiliriz/yapmayabilirsiniz/okumayabilirsiniz`
izole yolda `b`de kesiliyor; üretim de reddediyor. Yeterlilik kuralı
`verbRoot` çıkışlı, olumsuzluk sonrası yol yok. Olumlu yeterlilik
kontrollerinin de önceki türemiş geniş zaman metadata sınırı bulunduğu
için bunlar tümüyle çalışan morfoloji kontrolü sayılmadı.

16 merkez takip koşusunda yanlış değişim yok; geçersiz iki kontrol de
korundu. Bu tur ek kapsamı/aşırı üretim kanıtı, kullanıcı metninin bu
örneklerde bozulduğu iddiası değil. İki hedefli tanı testi geçti;
UI/üretim değişikliği yok. Kanıt `audits/turkish-round54-summary.json`
ve dört girdi/sonuç dosyasında.

**2026-10-10 — elli beşinci tarama, olumsuz kibar emir:** 56 merkez
koşusunda `dinlemeyiniz → dinlemeğiniz` değişimi bulundu. 12 biçimin yol
karşılaştırmasında altı olumsuz kibar emir (`dinlemeyiniz/beklemeyiniz/
unutmayınız/dokunmayınız/söylemeyiniz/okumayınız`) üretim ve açık fiil
kökleriyle `n` harfinde kesiliyor. Kısa `dinlemeyin` morfolojide reddedilip
düz sözlükle korunuyor. Yanlış rakip `dinlemeğiniz` iki otomatta da
kabul ediliyor; tam ek analizi henüz açılmadı. Olumlu `dinleyin/dinleyiniz`
yüzeylerinin kabulü, bütün emir paradigmasının mevcut olduğunu göstermez.

10 takip biçiminin ±0,2 ofsetli 20 koşusunda 2 değişim daha
kaydedildi; tam liste CSV’de. Çoğu ilk örnek korundu, bütün emirlerin
yazılamadığı iddia edilmedi. Üç hedefli tanı testi geçti; UI ve üretim
kodu değişikliği yok. Kanıt `audits/turkish-round55-summary.json` ile
altı girdi/sonuç dosyasında.

**2026-10-10 — elli altıncı tarama, birinci kişi istek:** 48 merkez
koşusunda değişim yok; 27 girdi sözlük dışı. 12 yüzeyin yol kontrolünde
izole `gel/yap` fiil kökleri `gelelim/yapalım/gelebilelim` üretirken
`geleyim/yapayım/gelebileyim` üretemiyor. Kaynakta çoğul istek 103 var,
karşılık gelen tekil istek eki yok. Olumsuz çoğul ve yetersizlik çoğul
biçimleri de reddediliyor; emir/istek kuralları `afterNegation` çıkışlı
değil. Bu ikinci durum elli beşinci turdaki devam ailesiyle örtüşüyor.

Kısa bazı biçimler düz sözlükle korunuyor. Üretimde `yapayım` ayrıca
morfolojide tanınıyor, izole `yap` kökünde tanınmıyor; kesin alternatif
yol açılmadı. Kapsam eksikliği ile gözlenen metin bozulması ayrı tutuldu.
İki hedefli tanı testi geçti; ofset/UI testi veya üretim değişikliği
yok. Kanıt `audits/turkish-round56-summary.json` ve dört girdi/sonuç
dosyasında.

**2026-10-10 — elli yedinci tarama, aktarımın kalıcı yazım hatası:**
Üretimdeki `PersonalHistoryStore` yükle/kaydet/sahiplen ve `JSONFile`
gövdeleri tanı testine çıkarıldı. Yalnız geçici dizinler, adları değiştirilmiş
depolar, yayınlamayan görünüm ve seri kilit kullanıldı. Başarılı kontrolde
üç `qrmenü` sayımı kaydedilip yeniden yükleniyor. Kalıcı hedef yoluna dosya
yerine dizin konulan hata enjeksiyonunda ilk yükleme bellekte üç sayımı
veriyor, fakat bekleyen aktarım silinmiş ve kalıcı kayıt yazılmamış oluyor;
ikinci yükleme sıfır sayım döndürüyor.

Neden: `claim` veriyi döndürmeden sahiplenilmiş dosyayı siliyor; `save`
JSON yazımının başarısızlık sonucunu yok sayıyor. Böylece kaydetme hatasında
otomatik yeniden deneme kaynağı kalmıyor. Uygulamanın ayrı aktarım kataloğu
bulunabilir, bu depo onu kendiliğinden yeniden aktarmıyor. Gerçek cihazda
kendiliğinden oluştuğu iddia edilmedi; yayın/yarış/UI bu testin kapsamı
dışında. Hedefli iki senaryo geçti, kullanıcı verileri ve üretim kodu aynı.
Kanıt `audits/turkish-round57-durability.json`, yöntem ve sınırlar
`audits/turkish-round57-summary.json`, yeniden üretici
`audits/generate_import_durability_audit.py` içinde.

**2026-10-10 — elli sekizinci tarama, başarısız kayıttan sonra yeniden deneme:**
Üretim `TypingHistory` gövdesi aynı geçici dosya tanı ortamına çıkarıldı.
Üç senaryo: normal yazım sonrası sayım 1→1; yazma hatası, engeli kaldırma
ve tekrar `flush` sonrası 0→0; hata sonrası yeni kelime gözlemi ve `flush`
sonrası 0→1. Başarısız `save` sonucunu alamayan `flush`, `unsaved` sayacını
sıfırlıyor; ortam düzelince yalnız tekrar kaydet çağrısı yetmiyor.

Bellekteki veri hemen silinmiyor: yeni gözlem ve başarılı kayıt onu
kurtarabiliyor. Risk, bundan önce sürecin kapanıp yeniden yüklenmesi.
Bu normal yazma geçmişi tetikleyicisi, önceki aktarım kaybıyla ilişkili
yazım sonucu/yeniden deneme ailesi; bağımsız kök sayısı şişirilmedi.
Üç hedefli tanı senaryosu geçti. Geçici hata enjeksiyonu, yayın ve yarış
kapsam dışı; kullanıcı dosyaları/üretim kodu değişmedi. Kanıt
`audits/turkish-round58-write-retry.json`, sınırlar ve sonraki adım
`audits/turkish-round58-summary.json` içinde.

**2026-10-10 — elli dokuzuncu tarama, aktarım kataloğu yazım hatası:**
Uygulamanın gerçek `importMessages/importText` gövdeleri geçici dosya
ortamında sınandı. Normal kontrolde bekleyen aktarım ve kaynak kataloğu
üç sayım içeriyor. Yalnız katalog yolu dizinle engellenince bekleyen dosya
üç sayımla yazılıyor, katalog sıfır kalıyor, çağrı yine başarı dönüyor.
Bekleyen dosya engellenince ise doğru biçimde hata bildiriliyor.

Neden: ilk JSON yazımının sonucu kontrol edilirken katalog yazımının
sonucu yok sayılıp başarı dönülüyor. Kaynak bazlı liste ile klavyeye
gönderilen kayıt ayrışabiliyor. Öğrenme ekranının katalog boşken bekleyen
dosyaya yedeği bulunduğundan kelimenin hemen bütün ekranlardan kaybolduğu
iddia edilmedi; aktarım alındıktan sonra ayrı geçmiş görünümü de olabilir.
UI render edilmedi, gerçek cihazdaki hata sıklığı ölçülmedi. Üç hedefli
senaryo geçti; üretim ve kullanıcı verileri aynı. Kanıt
`audits/turkish-round59-catalog-failure.json`, sınırlar
`audits/turkish-round59-summary.json` içinde.

**2026-10-10 — altmışıncı tarama, öğrenilecek veri olmadan başarı:**
Gerçek içe aktarma gövdeleriyle beş geçici senaryo çalıştı. Boş metin,
yalnız boşluk, yalnız noktalama ve filtrelenen 16 rakamlı sentetik değer
başarı döndürüyor; bekleyen dosya/katalog sıfır token içeriyor. Geçerli
`qrmenü qrmenü` kontrolü bir ayrı token kaydediyor. Sayı filtresinin
çalışması hata sayılmadı.

`LearningView` kaynak akışında boş metin için Öğren düğmesi kapatılmıyor;
`importText` hata atmayınca koşulsuz `Metinden öğrenildi` bildirimi
atanıyor. Bu, hiç öğrenme olmadığı hâlde yanıltıcı başarı bildirimi.
Bu tur UI render edilmedi ve önceki kayıtların silindiği iddia edilmedi;
her senaryo boş test deposunda başladı. Beş hedefli senaryo geçti,
üretim/kullanıcı verisi aynı. Kanıt `audits/turkish-round60-empty-import.json`,
sınırlar `audits/turkish-round60-summary.json` içinde.

**2026-10-10 — altmış birinci tarama, başarısız yapıştırmada taslağın silinmesi:**
`LearningView` Öğren düğmesinin işlem gövdesi aynen tanı ortamına çıkarıldı;
gerçek içe aktarma ve dosya yazımıyla başarı/hata karşılaştırıldı. Bekleyen
dosyaya yazma hatasında mesaj yakalanıyor ama ardından koşulsuz
`pasted = ""; pasting = false` çalışıyor. Kaydedilmiş token sıfırken
yapıştırma taslağı boşalıyor ve sayfa açık durumu kapanıyor. Başarılı
kontrolde dört token kaydoluyor ve aynı temizleme beklenen biçimde oluyor.

Bu, ekran içinde elle düzenlenen metnin hata sonrası yeniden deneme için
korunmaması. Panodaki özgün içerik test edilmedi; panonun silindiği iddia
edilmedi. Enjekte edilen dosya yazma hatası ayrıca uygulama/klavye bağlı
değil mesajına çevriliyor. Bu tur SwiftUI render değil işlem/durum testi;
liste yenileme sayaçla, başarı mesajının son eki sabit test metniyle
yer değiştirildi. İki hedefli senaryo geçti. Üretim ve kullanıcı dosyaları
aynı. Kanıt `audits/turkish-round61-paste-recovery.json`, yöntem/sınırlar
`audits/turkish-round61-summary.json` içinde.

**2026-10-10 — altmış ikinci tarama, sayı düzleminden öneriyle dönüş:**
Kaynak çağrı yollarında doğrudan boşluk ve Return, harf düzlemine dönüyor.
Sonraki-kelime önerisi seçimi ise `insertPredicted` üzerinden metin ve
`session.perform(.space)` çağırıp `didInsertAtBoundary` yoluna geçiyor;
görünümün harf düzlemine dönüş ataması yok. Kelime sınırında tahmin varken
123’e geçmek metni değiştirmediği için `refreshUI` tahmini koruyabiliyor.
Bu yol kullanıcıya özgü geçmiş tahminiyle simülatörde ayrıca denenmeli.

Kanıt düzeyi kaynak çağrı yolu ve yapısal kontroller; ekranda sayı
düzleminde kalma henüz gözlenmedi. Önceki düzeltmenin tüm yolları kapattığı
varsayımı bu yolla sınırlandı. Ayrı şüphe olan Return sonrası shift
zinciri, `autoCapitalize` zaman damgasını temizlediği için hata sayılmadı.
Üretim değişmedi. Kaynak özeti, SHA ve yeniden üretim adımları
`audits/turkish-round62-summary.json` içinde.

**2026-10-10 — altmış üçüncü tarama, sayı ekranı simülatör doğrulaması:**
iPhone 17 Pro / iOS 26.5 simülatöründe mevcut DENE alanına ekran tuşlarıyla
`yalnızsınız ` yazıldı. Görünen sonraki-kelime `yalnızsınız` tahmini varken
123’e geçildi; tahmin çubuğu kaldı. Tahmine dokununca kelime belgeye eklendi
ama sayı/sembol tuşları ve ABC düğmesi görünür kaldı. Ardından gerçek
boşluk tuşuna dokununca harf tuşları ve 123 düğmesi geri geldi.

Bu, altmış ikinci turdaki kaynak bulgusunun gerçek UI karşılaştırması;
ayrı yeni kök hata sayılmadı. Tek tahmin yolu sınandı; bütün öneri türleri
hakkında genelleme yok. Tam Erişim kapalı kaldı, profil sıfırlanmadı,
yazım doğal olarak yerel geçmişi güncelleyebilir. Üretim düzeltmesi yok.
CUA önce/sonra görüntüleri araç çıktısında; adımlar ve son durum
`audits/turkish-round63-simulator-plane.json` içinde.

**2026-10-10 — altmış dördüncü tarama, zamir hatası gerçek klavyede:**
iPhone 17 Pro / iOS 26.5 simülatörünün mevcut DENE alanında on ekran harf
tuşuyla `herkesinki` yazıldı. Boşluk öncesinde belge doğru, öneriler
`herkesinki | heroesinki` idi. Boşluk tuşuna dokununca belge `heroesinki `
oldu. Böylece kırk sekizinci turdaki sentetik dokunma bulgusu gerçek
klavye UI’ında doğrulandı; yeni bağımsız kök hata sayılmadı.

Tek kelime/bağlam, genel kullanıcı hata oranı iddiası yok. Öneri seçimi
ve özgün kelimeye açık öğrenme yapılmadı. Tam Erişim kapalı kaldı, profil
sıfırlanmadı, üretim değişmedi. CUA önce/sonra görüntüleri araç çıktısında;
adımlar `audits/turkish-round64-simulator-pronoun.json` içinde.

**2026-10-10 — altmış beşinci tarama, olumsuz zarf-fiiller:** 42 merkez
koşusunda yalnız bağlamsal `beklemedenmiş → beklemesenmiş` değişimi bulundu;
kesin yol nedeni bu turda ayrılmadı. 12 yüzeyin yol karşılaştırmasında
`gelmeksizin/yapmaksızın/okumaksızın`, üç `-meyerek/-mayarak` biçimi ve
üç yetersizlik karşılığı üretim ve izole fiil kökleriyle reddediliyor.
`gelmeden/yapmadan/okumadan` kontrolleri iki otomatta da kabul ediliyor.

Çoğu sözlük dışı biçim korunuyor; kapsam eksikliği, bu kelimeler kesin
yazılamaz anlamına getirilmedi. Seyrek bildirilen biçimler stres girdisi,
gündelik kullanım sıklığı iddiası değil. İki hedefli test geçti; ofset/UI
tekrarı ve üretim değişikliği yok. Kanıt `audits/turkish-round65-summary.json`
ve dört girdi/sonuç dosyasında.

**2026-10-10 — altmış altıncı tarama, ters ünlü uyumu:** 42 merkez
koşusunda 9 değişim: örneğin `alkolümüz → alkollümüz`,
`kontrolünüz → kontrollünüz`, `gollerinizden → göllerinizden`,
`kontrolümüzdekiler → kontrollümüzdekiler`. Sekiz doğru/yanlış yüzey
çiftinin üretim ve açık kök karşılaştırmasında doğru ince ünlülü biçimler
morfolojide reddedilirken yanlış kalın ünlülü biçimler kabul ediliyor:
`saatim/saatım`, `saatlerimiz/saatlarımız`, `rolüm/rolum`,
`kontrolümüzdekiler/kontrolumuzdakiler` gibi. Bazı kısa doğruları düz
sözlük koruyor; uzun devamlar korunmuyor.

Üç değişen biçimin ±0,2 ofset takibindeki 6 koşuda 6 değişim daha
kaydedildi. Ters uyum kök/gerçekleme kapsamı, önceki çift ünsüz sorunundan
ayrı; dokuz çıktı ayrı kök hata sayılmadı. Rakiplerin tam ek analizi ve
UI bu turda sınanmadı. Açık kalp kökü yumuşama metadata’sı taşımıyor,
ancak karşılaştırılan çoğul biçimlerde yumuşama gerekmiyor. Üç hedefli
tanı testi geçti, üretim değişmedi. Kanıt `audits/turkish-round66-summary.json`
ile altı girdi/sonuç dosyasında.

**2026-10-10 — altmış yedinci tarama, uyum durumuyla karşı-deney:**
Önceki turun 16 yüzeyi aynı ek kurallarıyla yeniden izlendi. Yalnız
izole deney köklerinde var olan okunuş mekanizması üzerinden yapay ince
ünlü uyum durumu verildi. Sekiz doğru biçimin tamamı kabul, sekiz yanlış
kalın ünlülü biçimin tamamı ret oldu; önceki izole sonuçlar bütünüyle
döndü. Bu, incelenen asimetrinin kök sınırındaki uyum durumuyla
ayrılabildiğini gösteriyor; bu örneklerde sonraki ek zinciri mevcut.

`set/röl/kontröl/herf/kelp/alköl` değerleri yalnız deneysel durum girdileri;
gerçek okunuş veya üretim sözlüğü düzeltmesi diye sunulmadı. Son ünsüz ve
ilgili yuvarlaklık korunarak karşılaştırıldı; geniş yan etki taraması yok.
Tam decoder sıralaması ve UI sınanmadı. Hedefli test ve 16 eş karşılaştırma
geçti, üretim değişmedi. Kanıt `audits/turkish-round67-summary.json`,
`audits/turkish-round67-harmony-paths.json` ve önceki turun girdi/yol
kayıtlarında.

**2026-10-10 — altmış sekizinci tarama, ek uyumu hatası simülatörde:**
iPhone 17 Pro / iOS 26.5 mevcut DENE alanında on bir ekran tuşuyla
`kontrolünüz` yazıldı. Belge doğruyken öneri çubuğu
`kontrolünüz | kontrollünüz | kontrolümüz` gösterdi. Boşluk tuşuyla
belge `kontrollünüz ` oldu; fazladan `l` eklendi. Altmış altıncı turun
merkez dokunuş çıktısı gerçek UI’da tekrarlandı. Altmış yedinci turun
kök uyumu karşı-deneyi ayrı kanıt olarak duruyor.

Tek kelime/bağlam; yeni bağımsız kök sayılmadı. Özgün öneri seçilmedi,
açık kişisel öğretme yok. Tam Erişim kapalı kaldı, profil sıfırlanmadı,
üretim değişmedi. Önce/sonra CUA görüntüleri araç çıktısında; adımlar
`audits/turkish-round68-simulator-harmony.json` içinde.

**2026-10-10 — altmış dokuzuncu tarama, düzensiz su/ye gövdeleri:**
46 merkez koşusunda 11 değişim: altı `su` devamı (`suyumuzdan → duyumuzdan`
gibi), beş `ye` devamı (`yiyebileceksiniz → giyebileceksiniz`,
`yiyemedikleriniz → giyemedikleriniz` gibi). `de/ne` grubunda bu örneklerde
değişim yok; morfolojik tamlık çıkarımı yapılmadı.

12 yüzeylik `su` yol incelemesinde kök mevcut, doğru `suyum/suyumuz/
suyumuzdan/suyumuzdaki/suyunuzunki` üretim ve açık `su` köküyle reddediliyor;
y’siz `sum/sumuz/sumuzdan/sumuzdaki/sunuzunki` ise türetiliyor. Kısa doğru
`suyum/suyumuz` düz sözlükte, uzun devamları sözlük dışı. Bu `su`ya özgü
iyelik devamı kapsamı; `sum`un başka dilde ayrı kelime olabileceği için
global geçersizlik iddiası değil. `Ye` örneklerinin nedeni henüz ayrılmadı.
İki hedefli test geçti; ofset/UI kontrolü ve üretim değişikliği yok.
Kanıt `audits/turkish-round69-summary.json` ve dört girdi/sonuç dosyasında.

**2026-10-10 — yetmişinci tarama, ye/de özel gövde değişimi:**
16 yüzey iki kök kümesiyle izlendi: `ye/de` ve yalnız deney için `yi/di`.
İncelenen 11 doğru yi/di biçiminin tamamı sade köklerle reddedilip özel
gövdeyle aynı ek kurallarında kabul edildi. Üretim bunların 10’unu
morfolojide reddediyor; kısa `yiyecek` başka bir analizle kabul ediliyor.
Yanlış düzenlileştirilmiş `yeyeceksiniz/yeyebileceksiniz/yeyemeyeceksiniz`
üretim ve sade köklerle kabul ediliyor. Rakip `giyebileceksiniz` ve
`giyemeyeceksiniz` üretimde tanınıyor.

Bu, önceki turun yeme→giyme değişimlerinde özel gövde kapsamını ayırıyor.
Kısa `yiyeceksiniz/diyeceksiniz` düz sözlükle korunuyor. Ham `yi/di`
eklemek çözüm diye sunulmadı; dönüşüm koşullu olmalı, `yedi/dedi` gibi
biçimler korunmalı. İki hedefli test ve 11 karşı-deney kontrolü geçti.
Decoder sıralaması/UI veya üretim değişikliği yok. Kanıt
`audits/turkish-round70-summary.json` ve üç girdi/yol dosyasında.

**2026-10-10 — yetmiş birinci tarama, birleşik isim kök kapsamı:**
36 merkez koşusunda `başucunuzdakiler → haluğunuzdakiler` değişimi bulundu.
`Başucu/gökyüzü/hanımeli` grubundaki 18 yüzey üretim morfolojisinde
reddediliyor; açık deney isim kökleriyle aynı ek kurallarında 18/18 kabul
ediliyor. Bu grupta yalnız yalın `gökyüzü` düz sözlükle korunuyor.

Yeni kök yokluğu örnekleri, önceki üretken kök kapsamı ailesiyle ilişkili;
18 ayrı hata sayılmadı. Açık isim kökü, birleşik ismin bütün özel çekim
kurallarını doğru modelleyen çözüm değildir. Özgün `CompoundP3sg` filtresi
ile tek tek bu satırlar arasında kaynak zinciri bu turda kurulmadı.
Diğer 35 girdi korundu; sözlük dışı olmak bozulma sayılmadı. İki hedefli
test ve 18 yol çifti kontrolü geçti. UI/ofset/üretim değişikliği yok.
Kanıt `audits/turkish-round71-summary.json` ve dört girdi/sonuç dosyasında.

**2026-10-10 — yetmiş ikinci tarama, birleşik isimde n ve aşırı üretim:**
30 merkez koşusunda `başucundakilerden → haluğundakilerden` ve
`hanımelindekilerden → banımdakindekilerden` bulundu; önceki eksik kök
ailesiyle ilişkili. 16 eş yüzeyin açık normal isim kökleriyle tamamı kabul
edildi: hem doğru n’li biçimler hem yanlış düzenli-isim alternatifleri.
Üretimde mevcut `zeytinyağı/yeryüzü` kökleri, doğru biçimlerin yanında
`zeytinyağıya/zeytinyağıda/yeryüzüye/yeryüzüdeki` biçimlerini de tanıyor.

Başlangıçtaki genel n üretilemiyor şüphesi doğrulanmadı: doğru yüzeyler
açık kökle üretilebiliyor, tam alternatif iyelik analizi henüz açılmadı.
Ancak eksik birleşik kökleri normal isim diye eklemek yanlış
`gökyüzüdeki/başucudaki/hanımelideki` biçimlerini de tanıtır; önceki
kök karşı-deneyi doğrudan çözüm sayılamaz. Yanlış eşler morfoloji probu,
doğru yazıdan otomatik çıktıkları iddia edilmedi. İki hedefli test ve
16 kabul kontrolü geçti. UI/ofset/üretim değişikliği yok. Kanıt
`audits/turkish-round72-summary.json` ve dört girdi/sonuç dosyasında.

**2026-10-10 — yetmiş üçüncü tarama, üleştirme ve grup biçimleri:**
60 merkez koşusunda değişiklik yok; 30 `-li/-lik` türevi sözlük dışı.
18 ekli girdinin üç dokunma konumundaki 54 koşusunda 22 değişiklik görüldü.
Merkezde örnekler: `üçerlilerden → içerilerden`, `beşerlilerden → geçerlilerden`,
`ikişerlilerdekiler → iliştekilerdekiler`. Bunlar bağlama göre adlaşmış grup
biçimleriyle hazırlanmış stres örnekleri; kullanım sıklığı iddiası yok.

Dokuz yol probunda `ikişer/üçer/onar` ve `-den/-dan` biçimleri kabul;
`ikişerli/üçerli/onarlı` hem üretimde hem açık kökle reddediliyor.
Kökler mevcut. `Morphotactics.swift` yapım eklerini ölçülmüş maliyetler
nedeniyle açıkça kapsam dışı bırakıyor; bu bulgu yeni bir üleştirme kökü
hatası değil, yapım kapsamı boşluğunun yazmaya etkisi. Sadece sözlük dışı
olmayı hata saymadık. [TDK](https://tdk.gov.tr/icerik/yazim-kurallari/sayilarin-yazilisi/)
yalın üleştirme yazımını destekler; ekli örnekler bize ait.
İlk oluşturulan arka ünlülü örneklerin ek uyumu düzeltilip test yeniden
çalıştırıldı; kayıtlı sonuçlar düzeltilmiş girdilere ait. Üç hedefli test
geçti; UI doğrulaması ve üretim değişikliği yok. Kanıtlar
`audits/turkish-round73-summary.json`, iki korpus/CSV çifti ve yol JSON çifti.

**2026-10-10 — yetmiş dördüncü tarama, yaygın türemiş sıfat kontrolleri:**
68 merkez koşusunun 64’ü korundu. Dört değişiklik `glutensiz` ve ekli
biçimlerinin `glütensiz` biçimine dönüşmesi; yazım varyantı olduğu için
kesin yanlış düzeltme sayılmadı. Yeni doğrulanmış metin bozma yok.
10 yol probunda mevcut `ücretsiz/şekersiz` kökleri çekimi destekliyor;
`renkli/kablosuzluk/sessizlik/renklilik` eksik kökleriyle ilgili altı
yüzey üretimde reddedilip açık test kökleriyle kabul ediliyor, fakat
bu tur yazarken değişmiyor. Diğer iki prob gluten yazım varyantına ait.
Bu sonuç, 73. turu bütün uzun türemiş sıfatlara genellememeyi gerektiriyor.

İlk girdi üreticisindeki `-dakilar` hatası `-dakiler` olarak düzeltilip
bütün yazma testi yeniden çalıştırıldı; üreticinin yanlışları ürün hatası
sayılmadı. Son 68 koşu ve yol testi geçti. Ofset/UI/üretim değişikliği yok.
Kanıt: `audits/turkish-round74-summary.json`, korpus/CSV ve yol JSON çifti.

**2026-10-10 — yetmiş beşinci tarama, olumsuz gelecek sıfat-fiili:**
48 merkez koşusunda `reddedemeyeceğiniz → reddedemeyeceğimmiş` görüldü.
Sekiz girdilik üç ofsetli takipte 24 koşudan dokuzu değişti:
`reddedemeyeceğiniz` ve `reddedemeyeceğimiz → reddedemeyeceğimmiş`,
`reddedemeyeceğin → reddedemeyeceğim`; her biri üç konumda da tekrarlandı.

20 yol probu kök t/d değişimi şüphesini desteklemedi: olumlu kontroller
ve yanlış yumuşamamış biçimleri reddetme çalışıyor. Asıl ayrım:
`yapacağınız/geleceğiniz` hem üretim hem açık kökte kabul edilirken
`yapmayacağınız/gelmeyeceğiniz/yapamayacağınız/gelemeyeceğiniz` reddediliyor.
`-(y)AcAk/part` 132 yalnız `verbRoot`tan isim tarafına geçiyor;
`afterNegation` karşılığı yok. Gelecek zamanın kişi ekleri, sıfat-fiilin
iyelik eklerinin yerini tutmuyor. Önceki y kaynaştırması probleminden
ayrı geçiş eksikliği; reddedilen her biçim otomatik bozuluyor denemez.

İlk üreticideki tat- olumsuz biçimlerinin ünlü uyumu düzeltilip 48 koşu
yeniden çalıştırıldı. Son iki yazma testi ve 20 yol testi geçti.
İzole varsayılan kökler gel/yap/oku/söyle; diğer köklerin izole reddi
kanıt sayılmadı. UI/üretim değişikliği yok. Kanıtlar
`audits/turkish-round75-summary.json`, iki korpus/CSV çifti ve yol JSON çifti.

**2026-10-10 — yetmiş altıncı tarama, olumsuz isim-fiil ve yanlış aday:**
46 merkez koşusunda `okumamanızdan → okumakmanızdan` ve
`okumayışınızdan → okumaktığınızdan` bulundu. Dört girdinin üç ofsetli
12 takip koşusunda beş değişiklik: ilki üç, ikincisi iki konumda tekrarlandı.
`gelmemenizden/yapmamanızdan` bu koşullarda korundu.

46 yol probunun 38’i üretimde reddediliyor. Altı olumlu kontrol
(`gelmeniz/yapmanız/okumanız/gelişiniz/yapışınız/okuyuşunuz`) üretim ve
izole köklerde kabul. `gelmem/yapmam` yüzeylerinin başka anlamları da var;
kabul edilmeleri olumsuz isim-fiil desteğini kanıtlamıyor. Bazı kısa
biçimleri düz sözlük koruyor. 135/136/137 numaralı isim-fiil geçişleri
yalnız `verbRoot`tan; olumsuzluk sonrası karşılıkları yok.

İki bozuk çıktı ayrıca hem üretimde hem yalnız `okumak` fiil köküyle
kabul edildi. Üretimde `okumak verb 50000` satırı mevcut. Bu, 51/52.
turdaki yanlış mastar kökünün doğru girdiyi bozmasıyla birleşen bir örnek;
kazananın tam üretim analizi açılmadığından tek mümkün yol denmedi.
Dört hedefli test geçti; UI/üretim değişikliği yok. Kanıtlar
`audits/turkish-round76-summary.json`, iki korpus/CSV çifti, ana yol
ve yanlış aday yol JSON çiftleri.

**2026-10-10 — yetmiş yedinci tarama, olumsuz isim-fiil gerçek UI:**
Device Hub iPhone 17 Pro / iOS 26.5 simülatöründe BestKeyboard DENE
alanına 12 harf tuşuyla `okumamanızdan` yazıldı. Boşluk öncesi öneriler
`okumamanızdan / okumakmanızdan / okumakmamızdan`; boşluk sonrası
`okumakmanızdan` oldu. Klavye kapatılarak örtülen üçüncü metin satırı
görünür yapıldı ve çıktı ekran görüntüsünde doğrulandı.

76. turdaki çekirdek bozulması kurulu klavye arayüzünde de tekrarlandı;
ayrı kök neden sayılmadı. Önceki test metni/profili korundu, temiz profil
iddiası yok. Tam Erişim ve Capture Keyboard kapalı kaldı. Üretim değişikliği
yok. Görüntüler konuşma araç çıktısında, kalıcı gözlem kaydı
`audits/turkish-round77-simulator-negative-noun.json` dosyasında.

**2026-10-10 — yetmiş sekizinci tarama, olumsuz mastar sınırı:**
48 merkez ve 16 kaymış dokunma koşusunun tamamı korundu; yeni yanlış
metin değişikliği yok. Gel/yap/oku/söyle ailelerinin 48 yol probunda
16 olumlu biçim kabul, 32 olumsuz/yetersizlik biçimi hem üretim hem
izole köklerde ret. `yapmamak/söylememek` düz sözlükte ayrıca tanınıyor.
135 numaralı `-mAk` geçişinin `afterNegation` karşılığı bulunmaması,
76. turdaki kapsam boşluğunun mastar tarafını doğruluyor; ayrı kök neden
sayılmadı. Ret tek başına yazılamama olarak raporlanmadı.
İki yazma ve bir yol testi geçti; UI/üretim değişikliği yok. Kanıtlar
`audits/turkish-round78-summary.json`, iki korpus/CSV çifti ve yol JSON çifti.

**2026-10-10 — yetmiş dokuzuncu tarama, -ince ve -inceye kadar:**
33 merkez ve 18 kaymış dokunma koşusunun tamamı korundu. 33 yol probunda
sekiz olumlu yalın zarf-fiil kabul, 25 olumsuz/yetersizlik veya uzatılmış
biçim ret. `gelmeyince/alamayınca/vermeyince/gelinceye` düz sözlükle
ayrıca tanınıyor. 122 numaralı `-(y)IncA` yalnız `verbRoot`tan çıkıyor;
olumsuzluk karşılığı yok (65. tur ailesi). Ayrıca terminalde bitmesi
`gelinceye/yapıncaya/okuyuncaya` biçimlerini y’de kesiyor. Bu ikinci
kısıt olumsuz kök eksikliğinden bağımsız devam sınırı.

Yol reddi yazılamama olarak sayılmadı: 51 koşuda yeni metin bozulması yok.
Varsayılan izole kökler yalnız gel/yap/oku/söyle; diğer kökler üretim
izleriyle değerlendirildi. Üç hedefli test geçti. UI/üretim değişikliği yok.
Kanıt `audits/turkish-round79-summary.json`, iki korpus/CSV çifti ve
ana yol JSON çifti.

**2026-10-10 — sekseninci tarama, öğrenme kurtarma sınırı:**
Altı hedef üç koşulda 18 kez yazıldı: tam yüzeyi açık literal öneriden
seçmek altısında da sonraki yazımı korudu; kısa tabanı seçmek altısında
da bozulmayı engellemedi; öğrenmesiz altı kontrol de aynı şekilde bozuldu.
Örnek: `okumamanızdan` seçilince korunuyor, yalnız `okumamanız` seçilince
`okumakmanızdan` oluyor. Diğer hedefler `okumayışınızdan`,
`reddedemeyeceğiniz`, `herkesinki`, `kontrolünüz`, `üçerlilerden`.

2/23. turdaki kişisel sözlüğün ekli biçimlere genellememesi bulgusunun yeni
örneklerle kontrolü; yeni bağımsız kök neden sayılmadı. Bazı kısa tabanlar
zaten paket sözlüğünde olabilir; hepsi yeni öğrenildi denmedi. Yeni
koordinatöre kişisel sözlük bellekte kopyalandı; disk/uygulama yeniden
başlatma dayanıklılığı testi değil. Hedefli test ve 0/6/6 değişiklik
sayıları doğrulandı. UI/üretim değişikliği yok. Kanıt
`audits/turkish-round80-summary.json`, korpus ve sonuç CSV dosyası.

**2026-10-10 — seksen birinci tarama, sayı/noktalama çekirdek kontrolleri:**
Ondalık, saat, tarih, sürüm, IP, telefon ve sayı+birim içeren 30 girdi
boşlukla kapanınca aynen korundu. Örnekler `3,14`, `1.234,56`, `12:30`,
`01.02.2026`, `v1.2.3`, `192.168.1.1`, `3,14kg`, `12mb`.
Türkçe Q çekirdek geometrisinde rakam yok; test bunları gerçekten sembol
sınırından geçiriyor. UI yönlendirmesinde de nokta sembol yoluna gidiyor.

Bu kontrol uzun basma süresini, tuş isabetini, sayı düzlemini veya otomatik
büyük harfi test etmiyor. Kullanıcının aralıklı virgül şikâyeti bu sonuçla
çözüldü sayılamaz; önceki alfasayısal önek koruma bulguları da geçerli.
Hedefli test ve 30 birebir çıktı kontrolü geçti. Üretim değişikliği yok.
Kanıt `audits/turkish-round81-summary.json`, korpus ve sonuç CSV dosyası.

**2026-10-10 — seksen ikinci tarama, nokta jesti ve yeniden açılma gözlemi:**
Kaynakta nokta eşiği sabit 0,5 saniye; virgül eşikte yazılıyor, bırakıştaki
nokta `alternateTouches` ile engelleniyor. Tuştan ayrılma zamanlayıcıyı
iptal ediyor; eşikten sonra zaten yazılmış virgül geri alınmıyor. Bu açık
tasarım davranışı tek başına yeni hata diye sayılmadı; yarış durumu yokluğu
kaynak okumayla kanıtlanmış değil.

77. turda araç çubuğundan kapatılan klavye, bu tur DENE alanına yeniden
dokununca açılmadı; imleç ve seçim menüsü görünüyor. Öğrenme ekranına gidip
geri dönmek de görünür klavyeyi geri getirmedi. Bu, simülatör/host/uzantı
ayrımı henüz yapılmamış gözlem; kesin ürün kök nedeni sayılmadı. Bu nedenle
zamanlı nokta/virgül UI denemesi tamamlanamadı. Sonraki adım görünürlüğü
simülatör arayüzü veya uygulama yaşam döngüsüyle geri getirip süreli denemeyi
yapmak. Üretim/izin/ayar değişikliği yok. Kanıt ve sınırlar
`audits/turkish-round82-summary.json` içinde; ekranlar konuşma araç çıktısında.

**2026-10-10 — seksen üçüncü tarama, UI devam denemesi kesildi:**
82. tur gözlemi için ana ekrana çıkıldı, uygulama değiştiricide BestKeyboard
kartı görüldü. Karttan uygulamaya dönüş doğrulanmadan CUA, Mac kilitli ve
fiziksel girdi nedeniyle otomatik açma duraklatıldı yanıtı verdi. Kilit
aşılmaya çalışılmadı. Nokta süre testi ve yeniden görünürlük kontrolü
halen tamamlanmadı; yeni kesin hata veya başarılı yeniden açılış denmedi.
Kaynakta `dismissWithPanels` yalnız paneli kapatıp sistemin
`dismissKeyboard()` metodunu çağırıyor; bu kök neden kanıtı değil.
Sonraki UI turu güncel ekranı yeniden okuyarak devam etmeli; çekirdek
incelemeleri bağımsız sürdürülebilir. Kanıt ve devam durumu
`audits/turkish-round83-summary.json` içinde. Üretim değişikliği yok.

**2026-10-10 — seksen dördüncü tarama, edilgen sonrası yeterlilik:**
43 merkez koşusunda `yapılabileceklerimizden → yapışabileceklerimizden`
görüldü. Altı uzun hedef üç dokunma konumunda ayrıca tarandı; bütün
çıktılar `turkish-round84-followup-results.csv` ve özette saklandı.
43 yol probunda `yapılacak` kabul, `yapılabilecek` b’de ret; izole yap
kökü aynı ayrımı gösteriyor. `passiveInflection`, `to == verbRoot`
geçişlerini elerken 110 numaralı yeterlilik ekini de eliyor. Yetersizlik
111’in hedefi `afterNegation` olduğundan aynı filtreden geçebiliyor.

`söylenebilecek/söylenebiliyor` üretimde kabul ama izole söyle kökünde
ret: üretimde bağımsız `söylen verb` kökü var. Tam kazanan analiz
çıkarılmadığı için tek yol olduğu iddia edilmedi. Olumsuz gelecek iyelik
reddi 75. turla ilişkili. İzole köklerde ettirgen metadata yok; yazdır/okut
izole retleri tek başına kanıt değil. İki yazma ve bir yol testi geçti.
UI/üretim değişikliği yok. Kanıt `audits/turkish-round84-summary.json`,
iki korpus/CSV çifti ve yol JSON çifti.

**2026-10-10 — seksen beşinci tarama, edilgen geçmiş kişi paradigması:**
36 merkez koşusunda metin değişikliği yok. 36 yol probunun 25’i üretimde
reddediliyor. Kabul durumunu dışa aktaran tanı alanı test aracına eklendi:
`yapıldık/yazıldık/okunduk/okutulduk/yazdırıldık` yalnız `nounRoot`
üzerinden kabul; geçmiş zaman kişi yolu üzerinden değil. Dolayısıyla
bu beş yüzeyin tanınması geçmiş zaman desteğini kanıtlamıyor.
`söylendi` ailesi bağımsız söylen köküyle normal geçmiş/kişi durumlarına
ulaşıyor; `söylendik` hem isim hem kişi durumunda kabul.

51 numaralı temel geçmiş eki `nominalSuffixes` içinde; edilgen kopyanın
kaynak listesi bu tabloyu içermiyor. 8. turda kaydedilmiş neden kişi
paradigmasıyla ayrıştırıldı. 84. turdaki yeterlilik bulgusu da 8. turda
vardı; 84 özeti bağımsız yeni neden sayılmaması için ilişkilendirildi.
Tanıdaki kabul durumu tam kök/ek analizi değil. Yazma ve güncellenmiş yol
testi geçti; üretim/UI değişikliği yok. Kanıt
`audits/turkish-round85-summary.json`, korpus/CSV ve yol JSON çifti.

**2026-10-10 — seksen altıncı tarama, bitişik ile anlam değiştiriyor:**
46 merkez koşusunda altı değişiklik: `kitabımızla/kitaplarımızla/kitaplarınızla`
ve `arkadaşımızla/arkadaşlarımızla/arkadaşlarınızla`, l düşürülerek yönelme
biçimine çevrildi. 30 takip koşusunda 24 değişiklik: altı kelime üç
konumda da bozuldu; `arkadaşlarımızla konuştuk → arkadaşlarımıza konuştuk`
ve `kitaplarımızla geldik → kitaplarımıza geldik` de üç konumda tekrarlandı.
Ayrı `ile` ile yazılmış iki eş cümle altı koşuda aynen korundu.

46 yüzeyin tamamı üretim morfolojisinde ret; 19’u düz sözlükte korunuyor.
İsim hâl tablosunda `-(y)lA` yolu yok; açık isim kökü kontrolleriyle de
geri gelmiyor. İzole kitap/zamir kökleri kurulmadığından onların izole
reddi kök neden kanıtı sayılmadı. [TDK ile yazımı](https://tdk.gov.tr/icerik/yazim-kurallari/ilenin-yazilisi/)
bitişik/ayrı yazımı destekliyor; stres cümleleri bize ait.
İki yazma ve bir yol testi geçti. 46 ayrı hata değil, bir eksik ek ailesinin
örnekleri. UI/üretim değişikliği yok. Kanıt
`audits/turkish-round86-summary.json`, iki korpus/CSV çifti ve yol JSON çifti.

**2026-10-10 — seksen yedinci tarama, günlük ile örnekleri:**
40 merkez girdinin dokuzu l düşürülerek yönelmeye dönüştü: telefonumuzla,
telefonlarımızla, telefonlarınızla, bilgisayarımla, bilgisayarımızla,
bilgisayarlarımızla, bilgisayarlarınızla, öğretmenlerimizle, kardeşlerimizle.
Dokuzunun da iki ek ofsette tekrarı aynı değişimi verdi. Üç kısa kontrol
(`telefonumla/bilgisayarla/öğretmenimizle`) merkez ve ofsetlerde korundu.
Toplam 64 koşuda 27 değişiklik; 86. tur ailesinin yeni örnekleri,
dokuz bağımsız neden değil.

`bilgisayarımla` merkez farkı 14,7597; eşik 14,6. Tek başına bu veri genel
eşiği artırmak için yeterli gerekçe değil. Uzunlukla değişen örnekler var,
ama tek bir evrensel uzunluk sınırı kurulmadı. İki hedefli test geçti.
UI/üretim değişikliği yok. Kanıt `audits/turkish-round87-summary.json`
ve iki korpus/CSV çifti.

**2026-10-10 — seksen sekizinci tarama, -ca/-ce süre ifadeleri:**
47 merkez koşusunda `saniyelerce → saniyelerde` bulundu. 18 takip
koşusunda yedi değişiklik: saniyelerce yalın ve `saniyelerce bekledim`
cümlesinde merkez/eksi ofsette bozuldu, artı ofsette korundu;
`milisaniyelerce → milisaniyelerde` üç ofsette de tekrarlandı.
Dakikalarca/saatlerce ve `dakikalarca bekledim` kontrolleri korundu.

Açık taban isim kökleri 47 yüzeyin hiçbirini üretmedi; üretim 29 yüzeyi
kabul ediyor. `dakikalarca/saatlerce` ayrı kök kayıtları var; saniye var,
saniyelerce yok. Üretken ek boşluğunu hazır kayıtlar kısmen gizliyor.
-ca/-ce birden fazla işlevli; tek evrensel kural kuruldu denmedi. İzole
zamir kökleri eksik; bunların retleri kök neden kanıtı değil. İki süre
kelimesinin bozulması, 47 bağımsız hata değil. İki yazma ve bir yol testi
geçti; UI/üretim değişikliği yok. Kanıt
`audits/turkish-round88-summary.json`, iki korpus/CSV çifti ve yol JSON çifti.

**2026-10-10 — seksen dokuzuncu tarama, zaman bildiren -ki biçimleri:**
50 merkez koşusunda `bugünküler → bugünmüşler`,
`bugünkülerden → bugünlüklerden`, `sonrakilerden → sondakilerden` bulundu.
Yedi girdinin üç konumlu 21 takibi ve cümle örnekleri ayrıca kaydedildi.
Yalın bugünkü/dünkü/sonraki düz sözlükte korunuyor, üretken kökleri yok.
Bozulan üç biçim üretim morfolojisinde ret, açık test isim köküyle kabul.
50 açık kök probunun 40’ı kabul; 10 `-lerle` ret örneği 86. turdaki ile
boşluğunun tekrarı. Diğer üretim kabullerinde tam kök analizi çıkarılmadı;
her kabulün amaçlanan zaman eki yolu olduğu söylenmedi.

Eksik üretken kök ailesine bağlı yeni yüzeyler; açık kök karşı-deneyi
üretim çözümü değildir. İki yazma ve bir yol testi geçti. UI/üretim
 değişikliği yok. Kanıt `audits/turkish-round89-summary.json`, iki
korpus/CSV çifti ve yol JSON çifti.

**2026-10-10 — doksanıncı tarama, sıra bildiren kök kontrolleri:**
11 kökün beşer biçimiyle 55 merkez koşusunda iki değişiklik:
`dördüncülerle → dördüncülere`, `sekizincilerle → sekizincilere`.
11 kökün tamamı üretim TSV’sinde mevcut. Çoğul/iyelik/ayrılma dahil
44 ile’siz biçim hem üretim hem açık test kökünde kabul; 11 ile’li biçim
iki tarafta da ret. Yeni bir sıra kökü hatası doğrulanmadı; 86. tur
birliktelik eksikliğinin iki yeni örneği. Üretken sıra sayısı oluşturmanın
bütünü doğru denmedi; yalnız listelenen kökler kontrol edildi.
Yazma ve yol testleri, 44 kabul ve iki otomattaki eş sonuçlar doğrulandı.
Ofset/UI/üretim değişikliği yok. Kanıt `audits/turkish-round90-summary.json`,
korpus/CSV ve yol JSON çifti.

**2026-10-10 — doksan birinci tarama, küçültme/sevgi biçimleri:**
45 keşif girdisi merkez dokunuşta aynen korundu. 15 yaygın yüzeyin üretim
yol kontrolünde küçücük/ufacık/minicik ve seçilen çekimleri (dokuz yüzey)
kabul. Anneciğim/babacığım/yavrucuğum ailelerinden altı yüzey morfolojide
ret; kısa anneciğim/babacığım düz sözlükle korunuyor. Ek kapsamı boşluğu
bu turda otomatik metin bozulmasına dönüşmedi.

Köpekçiğim gibi seyrek keşif girdilerinin normatif yazımı ayrıca
kanıtlanmadı; bunlardan hata iddiası çıkarılmadı. İzole köklerde yumuşama
metadata yok; küçücüğümüz vb. izole retleri ürün kanıtı sayılmadı.
Yazma ve yol testleri,45 değişmeyen çıktı kontrolü geçti. Ofset/UI/üretim
 değişikliği yok. Kanıt `audits/turkish-round91-summary.json`, korpus/CSV
ve yol JSON çifti.

**2026-10-10 — doksan ikinci tarama, olumsuz duyulan geçmiş:**
44 merkez koşusunda altı bozulma: `gelmemişsiniz → gelmekmişsiniz`,
`okumamışız → okumakmışız`, `okumamışsınız → okumakmışsınız`,
`okumamışlar → okumakışlar`, `okumamıştınız → okumakıştınız`,
`söylememişsiniz → söylemekmişsiniz`. Altı hedefin iki ek ofseti ayrıca
kayıtlı. 44 yol probunda altı olumlu kontrol kabul, 38 olumsuz biçim
üretim ve açık fiil köklerinde ret; yedi kısa olumsuzu düz sözlük koruyor.

52 numaralı -mIş yalnız verbRoottan; afterNegation karşılığı yok.
İsim/ek-fiil -(y)mIş yolları bunun karşılığı değil. Gelmemişsiniz önceki
erken taramada da vardı; yeni bağımsız sorun diye sayılmadı, nedeni kişi
paradigmasıyla ayrıştırıldı. Bozuk adayların mastar görünümü önceki kök
kirlenmesiyle ilişkili, fakat tam kazanan kök analizi bu tur çıkarılmadı.
İki yazma ve bir yol testi geçti; UI/üretim değişikliği yok. Kanıt
`audits/turkish-round92-summary.json`, iki korpus/CSV çifti ve yol JSON çifti.

**2026-10-10 — doksan üçüncü tarama, yetersizlik + şimdiki zaman:**
48 kısa biçim merkezde korundu; 16 birleşik zamanın yedisi bozuldu.
Örnekler `yapamıyordunuz → yaşamıyordunuz`,
`söyleyemiyormuşsunuz → söyletmiyormuşsunuz`,
`anlayamıyormuşsunuz → anlatmakıyormuşsunuz`,
`göremiyormuşsunuz → görmüyormuşsunuz`.
`gelemiyormuşsunuz → gelmiyormuşsunuz` erken taramadaki bulgunun tekrarı.

Açık temel köklerle 48 biçim ret; üretimde yalnız altı bilemiyor biçimi
kabul. Üretimde bağımsız `bile verb` kökü var; bu meşru ayrı fiil,
kök kirlenmesi değil. Kabulü bil+yetersizlik yolunun çalıştığını
kanıtlamıyor. Kaynaşmış -(y)AmIyor yolu yok; -(y)AmA sonrası uygun
şimdiki zaman devamı da yok. Tanınmama kısa örneklerde değişikliğe
 dönüşmedi; birleşik zamanlarda yedi bozulma görüldü.
İki yazma ve bir yol testi geçti. Ofset/UI/üretim değişikliği yok.
Kanıt `audits/turkish-round93-summary.json`, iki korpus/CSV çifti ve
ana yol JSON çifti.

**2026-10-10 — doksan dördüncü tarama, yetersizlik anlamı cümlede kayboluyor:**
Beş yetersizlik cümlesi ve beş normal olumsuz eş, üç dokunma konumunda
30 kez yazıldı. Yetersizlik grubunun 15 koşulundan 14’ü bozuldu; normal
olumsuz 15 kontrolün tamamı korundu. `ekranı göremiyormuşsunuz` ve
`sesimi duyamıyormuşsunuz` üç konumda da görmüyormuşsunuz/duymuyormuşsunuz
oldu. `adını söyleyemiyormuşsunuz` iki konumda söyletmiyormuşsunuz,
birinde söylemiyormuşsunuz oldu. `bunu yapamıyordunuz` iki konumda
yaşamıyordunuz oldu, birinde korundu. Konuyu anlayamıyormuşsunuz üçünde
de anlatmakıyormuşsunuz oldu.

93. turun cümle/ofset doğrulaması; ayrı kök neden sayılmadı. Ön sözcükler
korundu, ancak cümle anlamının model tarafından çözümlendiği veya
bağlamın nedensel etkisi olduğu iddia edilmedi. 30 koşulu hedefli test ve
14/15–0/15 sayım kontrolleri geçti. UI/üretim değişikliği yok.
Kanıt `audits/turkish-round94-summary.json`, korpus ve sonuç CSV dosyası.

**2026-10-10 — doksan beşinci tarama, sözlüksel yumuşama bayrağı:**
40 merkez koşusunda beş değişiklik görüldü: yetersizliğinizden→yetersizliğinden,
belirsizliğimizden→belirsizlikimizden, belirsizliğinizden→belirsizlikinizden,
güvensizliklerimizden→güvencesizliklerimizden,
dikkatsizliğimizden→dikkateksikliğimizden.

Belirsizlik ve işsizlik kökleri mevcut fakat alternasyonları none.
Altı eş biçim kontrolünde doğru yumuşamış üç yüzey üretimde ret,
yanlış k’li üç yüzey kabul. Yalnız test köklerine k→ğ verildiğinde
altı sonuç da tersine döndü. Eksik kökten ayrı, mevcut kökün özellik
verisi problemi. Diğer üç değişikliğin tümü bu nedene bağlanmadı.
Tanı aracına isteğe bağlı `KB_COMPOUND_PATH_SOFT_K_ROOTS` eklendi;
üretim köklerine dokunulmadı, aday sıralaması düzeldi iddiası yok.
Yazma ve iki yol testi, altı karşı-deney kontrolü geçti. Ofset/UI yok.
Kanıt `audits/turkish-round95-summary.json`, korpus/CSV, ana yol ve
softening yol JSON çiftleri.

**2026-10-10 — doksan altıncı tarama, yumuşama verisinin sistematik kapsamı:**
-lık/-lik/-luk/-lük ile bitip alternasyonu none olan 225 isim satırı
aday olarak çıkarıldı; 225 doğrulanmış hata değildir. Sık adaylardan
seçilen 20 kökün doğru ekli biçimlerinin tamamı üretimde ret, yanlış k’li
karşılıklarının tamamı kabul. Yalnız test köklerine k→ğ verilince 20 doğru
biçim kabul, 20 yanlış biçim ret oldu.

20 merkez yazma koşusunun dokuzu bozuldu: şampiyonluğumuzdan→şampiyonlukumuzdan,
beraberliğimizden→beraberlikimizden, doğruluğumuzdan→doğruluşumuzdan,
bozukluğumuzdan→bozulmuşumuzdan, yoksulluğumuzdan→yolsuzluğumuzdan,
zenginliğimizden→zenginlikimizden, yüksekliğimizden→yükselişimizden,
taşımacılığımızdan→taşımacılıkımızdan, egemenliğimizden→egemenlikimizden.
95. turun aynı veri ailesi; aday listesi rastgele örneklem değil.
Karşı-deney kabulü doğruluyor, üretim sıralamasının düzeldiğini değil.
Yazma/yol testleri ve 40 karşı-deney sonucu doğrulandı. Ofset/UI/üretim
 değişikliği yok. Kanıt `audits/turkish-round96-summary.json`, aday kök
JSON’u, korpus/CSV ve yol JSON çifti.

**2026-10-10 — doksan yedinci tarama, eksik bayrakların kaynak zinciri:**
96. turdaki 225 adayın 219’u `1d36b2f` genişlemesinde yeni yüzey/POS
kimliği olarak eklenmiş; altısı ebeveynde de var. Aday satırlarının tamamı
bu commit’teki satırlarla birebir aynı. Önceki turda davranışla doğrulanan
20 kökün tamamı yeni 219 kaydın içinde ve none bayrağıyla eklenmiş.

Eski altı aday malik/memluk/halik/mahluk/süluk/temlik: yazı sonuna bakarak
bütün adayları -lik türevi saymak veya hepsine yumuşama vermek yanlış
bir yöntem olur. 219 sayısı doğrulanmış hata sayısı değildir. packbuild
geçerli alternasyon etiketini doğrudan köke taşıyor, binary dönüşte
aynılığını kontrol ediyor; none geçerli veri olduğu için dilsel yanlışlığı
reddetmiyor. Bozulmanın dosya girdisinde olduğu sınırlandı; kaydın kim
veya hangi üretici tarafından hazırlandığına dair ek iddia yok.
Ebeveyn/commit/güncel karşılaştırmaları ve 20 yeni kimlik kontrolü geçti;
üretim değişikliği yok. Kanıt `audits/turkish-round97-summary.json` ve
ayrıntılı provenance JSON’u. Davranış kanıtı 96. turda.

**2026-10-10 — doksan sekizinci tarama, yinelenen kök kayıtları:**
Aynı yüzey/POS için 10 yinelenen kimlik bulundu. İlk karşılaştırmadaki
7 metadata farkının 4’ü, isteğe bağlı boş sütunların eksik/yazılmış
olmasından kaynaklanıyor; bunlar hata değil. Normalize edilmiş gerçek
farklar branch, karbondioksit ve peroksit kayıtlarında.

branch’ın bir noun kaydı okunuşu brenç olarak belirtiyor, diğeri boş
bırakıyor. Üretim motoru branchı/branchi, brancha/branche,
branchlar/branchler, branchımızdan/branchimizden çiftlerinin tamamını
kabul ediyor. Aynı üretim okunuşuyla tek köklü deney yalnız ön ünlülü
biçimleri kabul ediyor: yinelenen kayıt, tanımlı okunuş kısıtını deliyor.
karbondioksit/peroksit için tToD ve none birlikte bulunuyor, t/d biçimleri
ikisi de kabul ediliyor; bu turda dilsel doğrulukları doğrulanmadı.
12 merkezden yazma denemesi de olduğu gibi kaldı; yeni boşlukta değiştirme
vakası gösterilmedi. İki test çalışması geçti; üretim kodu değişmedi.
Kanıt: `audits/turkish-round98-summary.json`, duplicate-roots JSON’u,
path-corpus/paths JSON’ları ve corpus/results CSV çifti.

**2026-10-10 — doksan dokuzuncu tarama, okunuşlu köklerin kontrolü:**
Okunuş alanı dolu 12 kök için çoğul + iyelik + ayrılma ekli doğru-uyum ve
ters-uyum çiftleri denendi. Kaynak okunuşa uygun 12 biçimin tamamı üretim
morfolojisinde kabul edildi ve merkezden yazımda korundu. Ters uyumlu
12 girdinin 9’u değişti; kasıtlı kontrol girdileri olduğundan bunlar doğru
kelime bozulması sayılmıyor. branch’ın ters uyumu 98. turdaki çift kayda
bağlı. restore ise noun/restor okunuşu yanında adjective/restore kaydı da
barındırıyor; ayrı anlam ve POS nedeniyle yeni hata olarak sınıflanmadı.
İki test geçti, üretim değişikliği yok. Kanıt `audits/turkish-round99-summary.json`
ve aynı turdaki korpus, paths JSON ve sonuç CSV dosyaları.

**2026-10-10 — kullanıcı gereksinimi, boşluk yerine komşu harfe basma:**
Kullanıcı boşluk yerine çevresindeki bir harfe yanlışlıkla basılınca
birleşen iki kelimenin anlaşılmasını ve iki kelimelik tahmin sunulmasını
istedi. Önce mevcut aday üretimi, sözcük sınırı ve dokunma geometrisi
incelenecek; örnekler gerçek tuş komşuluğuyla test edilecek. Henüz
uygulandı veya doğrulandı iddiası yok. Önceki hata bulguları korunacak.

**2026-10-10 — yüzüncü tarama, kaçırılan boşluktan iki kelime önerme:**
Kullanıcı isteği için beş cümle (merhaba dünya, nasıl gidiyor, eve geliyorum,
seni seviyorum, yarın görüşürüz), doğru boşluk / boşluk yok / boşluk yerine
v-b-n olmak üzere 25 denemede çalıştırıldı. Doğru boşluklu beş kontrol
korundu. Komşu alt sıra harfleriyle 15 birleşik girdinin hiçbirinde beklenen
iki kelimelik öneri çıkmadı; boşluksuz beş girdide de çıkmadı.
merhabadünya ayrıca son boşlukta merhabasına oldu. Diğer birleşik girdiler
korunsa bile doğru iki kelimelik alternatif sunulmadı.

Bu, tuş merkezleriyle çekirdek motor testi: gerçek boşluk sınırı dokunması
ve simülatör deneyi değil. Öneri sunucusu bütün token decoder adayları ve
hazır genişletmelerle çalışıyor; genel iki sözcüğe bölme yolu görülmedi.
Düzeltme fazına açık gereksinim: boşluk yerine yanlış harf olayını, yalnız
boşluk atlamasından ayrı ele almak; dokunma konumunu kullanmak; her iki
kelimeyi birlikte önermek ve seçimle birleşik metni doğru değiştirmek.
Bilerek yazılan tek kelimeleri bölmeme, Türkçe ekler, seçim/geri alma ve
gecikme kontrolleri gerekli. Kullanıcı otomatik uygulama eşiğini belirtmedi;
isteği iki kelimelik tahmin sunulması. Henüz uygulama yapılmadı.
Kanıt `audits/turkish-round100-summary.json`, korpus ve sonuç CSV’si.

**2026-10-10 — yüz birinci tarama, boşluğun gerçek üst sınırı:**
Yeni opt-in MissedSpaceAuditTests, üretim geometrisindeki varsayılan boşluk
çerçevesinden noktalar üretiyor. Harf merkezi x konumunda, sınırın harf
satırı yüksekliğinin %1’i kadar üstü content/ilgili harf; aynı miktar altı
space olarak doğrulandı. Küre kapalıyken z/x/c/v/b/n/m/ö merkezleri boşluk
genişliğine denk geliyor, açıkken x/c/v/b/n/m/ö. Bu liste kısmi yatay
örtüşmelerin veya tüm kullanıcı ölçülerinin tam taraması değildir.

İki cümle, iki küre durumu ve harf merkezi/sınıra yakın konumla 60 yazım
denemesi: doğru iki kelimelik öneri 0/60. Girilen birleşik metinler son
boşlukta korundu. 30 merkez/sınır çiftinin 9’unda öneriler farklıydı;
konumun önerilere etkisi var ama iki sözcüğe bölme eksikliği sürüyor.
Bu 100. turdaki gereksinimin geometri kanıtı, ayrı hata sayılmamalı.
Gerçek cihaz/simülatör dokunması değil. Test geçti, üretim kodu değişmedi.
Kanıt `audits/turkish-round101-summary.json`, sonuç JSON’u ve
`MissedSpaceAuditTests.swift` test aracı.

**2026-10-10 — yüz ikinci tarama, çok kelimeli önerinin devamı:**
Üretim açılım haritasından slm/kib/bb gerçek öneri seçimi ile aynı yüzeyin
elle yazılması, üretim ve kontrollü bigram olmak üzere 12 yolda karşılaştırıldı.
kib → kendine iyi bak ve bb → bay bay seçimi sonrası geri silme yalnız
son boşluğu doğru siliyor fakat açık token boş kalıyor. Elle yazılan
kontrollerde bak/bay geri açılıyor. Tek sözcüklü slm seçimi selam’ı, özgün
slm literal’iyle geri açıyor. Çok kelimeli history.display, restorePreviousWord
son-token eşitliği kontrolünden geçemiyor. Metin kaybı gösterilmedi; 26. turdaki
kelime silmenin doğru çalışmasıyla çelişmiyor. İki sözcüklü yeni öneride
bütün cümleyi tek sözcük kanıtıyla geri açmak çözüm sayılmamalı.

Kontrollü bigramlı motorda çok kelimeli öneri önceki bağlama bütün cümleyi
koyuyor: kendine iyi bak / bay bay, beklenen bak / bay yerine. Bu iki
örnekte kalem için bağlam katkısı 0; elle yazım kontrollerinde -1.7793369.
Tek kelimeli selam kontrolü iki yolda eşit. Üretim paketinde bigram yok;
mevcut kullanıcının önerilerinde bu skor etkisi var denmiyor. Gelecek
iki kelimelik öneri için de son-kelime bağlamı açık gereksinim.
İlk teşhis maliyet çağrısında token argümanı yoktu; eklenip test tekrar
çalıştırıldı. Son test geçti. Üretim değişikliği yok. Kanıt
`audits/turkish-round102-summary.json`, results JSON’u ve
`MultiwordContextAuditTests.swift`.

**2026-10-10 — yüz üçüncü tarama, açılımın içinden kelime seçimi:**
slm/kib/napcaz açılımları ve elle yazılmış kontrollerde son kelime seçildi.
Altı durumda da öneri ve düzenleme açıldı. Çok kelimeli açılımdan seçilen
bak/yapacağız türetilmiş kanıtla, elle yazılmışları gerçek kanıtla açılıyor;
kısaltmanın dokunmalarını kelimeye atamamak doğru. Doğrudan API ile kalem
kontrolü altısında da yalnız seçili kelimeyi değiştirdi. Kalem’in çubukta
sunulduğu iddiası yok. Yeni hata yok; FakeDocument testi geçti. Kanıt
`audits/turkish-round103-summary.json`, results ve MultiwordSelectionAuditTests.

**2026-10-10 — yüz dördüncü tarama, kullanıcı seçimde öneri kaybı bildirimi:**
Kullanıcı Tam Erişim verdiğini, buna rağmen bazen kelime seçiminde öneri
çıkmadığını belirtti. Geçmişte bulunmayan 16 seçili yüzey üretim çekirdeğine
verildi. Altı yüzey öneri gösterdi, onu göstermedi. kalem çalışırken
Kalem/KALEM çalışmıyor; istanbul/qrmenü çalışırken İstanbul/QRmenü çalışmıyor.
Bu 4. turdaki büyük harf kusurunun tekrar doğrulanması, yeni bağımsız hata
sayısı değil. Baştaki/sondaki boşluk, sondaki NBSP, ankara'nın/ankara’nın,
e-posta ve covid19 da önerisiz. Ayrıştırılmış Unicode çağrı kontrolü çalıştı.

Seçili yüzey, geçmişten geri kurulamıyorsa doğrudan centerTouches’a gidiyor;
büyük harf normalizasyonu ve harf dışı karakter desteği bu yolda yok.
Kenar boşluğu ayrıca bilinçli reddediliyor: çözüm seçimi körlemesine kırpıp
boşlukları silmemeli. İncelenen çekirdek seçim yolunda Tam Erişim kapısı yok.
Bu test host selectedText teslimini varsayıyor; gerçek uygulamaların geri
çağrı zamanlaması veya aralıklı UI yenileme sorununun tamamını açıklamaz.
Kullanıcı gereksinimi: seçili kelimede uygun öneriler görünmeli; önceki
bulgularla birlikte düzeltme fazında ele alınacak. Test geçti, üretim değişmedi.
Kanıt `audits/turkish-round104-summary.json`, results ve SelectionSurfaceAuditTests.

**2026-10-10 — yüz beşinci tarama, ilk seçim çalışıp ikincisi kayboluyor:**
Gerçek harf olaylarıyla önce + kalem/Kalem/İstanbul/QRmenü yazıldı; yazım
sonu literal korunarak seçim davranışı ayrıştırıldı. Dört kelime için ilk
seçim, aynı seçimin tekrar bildirimi ve seçimi kaldırıp yeniden seçme olmak
üzere 12 gözlem alındı. İlk iki aşamada dört kelime de öneri gösterdi.
Yeniden seçimde Kalem/İstanbul/QRmenü önerisiz kaldı; kalem çalıştı.
Belge hiçbir aşamada değişmedi. Tekrarlı aynı bildirim tek başına kusur değil.

İlk seçim geçmişi tüketiyor; seçim kapanınca açık durum temizleniyor.
İkinci seçim türetilmiş yola kalıyor ve büyük harf eşlemesi burada yok.
Bu, 4/104. turdaki kusurun aralıklı görünmesine yol açan doğrulanmış bir
akış; ayrı kök neden diye sayılmamalı. FakeDocument üzerinde gerçek
seçim kaldırma/yeniden seçme sınandı; belirli bir uygulamanın geçici nil
bildirimi gönderdiği iddia edilmiyor. Test geçti, üretim değişikliği yok.
Kanıt `audits/turkish-round105-summary.json`, results JSON’u ve
SelectionCycleAuditTests.swift.

**2026-10-10 — yüz altıncı tarama, sözlükteki şapkalı kelime seçilemiyor:**
Geçmiş dışı seçimde hâl/imkân/kâr/kâğıt/rüzgâr/hikâye/millî/resmî ve
şapkasız karşılıkları 16 denemede sınandı. Şapkalı sekiz biçimin tamamı
üretim sözlüğünde biliniyor; sekizinde de öneri yok. Şapkasız sekiz kontrol
öneri gösteriyor. Sözcük çiftlerinin anlam eşitliği iddiası yok. Kesin tuş
merkezi eşlemesi â/î tuşu bulamıyor: 104. turdaki harf kapsamı eksikliğinin
başka bir Türkçe örnek sınıfı. Yalnız büyük harfleri küçültmek bu kapsamı
çözmeye yetmeyecek. Canlı host bildirimi veya yazarken şapkalı aday üretimi
bu deneyin konusu değil. Test geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round106-summary.json`, korpus/results ve genişletilmiş
SelectionSurfaceAuditTests.swift.

**2026-10-10 — yüz yedinci tarama, şapkalı adayların yazımda erişimi:**
Sekiz şapkalı hedefin şapkasız tuş merkezi girdileri doğrudan üretim
decoder’ında ilk 20 adayla ölçüldü. Yedisi yok, rüzgâr 11. sırada var;
“hiç üretilemez” iddiası yanlış olur, başka edit yolları erişim sağlıyor.
TurkishQ.asciiBase haritasında â/î/û yok. Yalnız test düzeninde bu harflere
a/i/u tabanı eklendiğinde sekizi de ilk 20’ye, altısı ilk üçe girdi.
Üretim paketleri ve tuş konumları aynı, değişen yalnız test eşleme haritası.
Bu, seçimdeki exact keyIndex yolunu düzeltmez; ayrıca ele alınmalı.

Doğrudan decoder ilk üçü öneri çubuğuyla aynı değil: maliyet penceresi ve
literal yuvası ayrıca uygulanır. Şapkasız kelimeler başka anlamda doğru
olabilir; otomatik değiştirme önerisi yok. resmîi üretimde resmi girdisinin
ilk üçünde görüldü; morfolojiye ayrıca bakılacak, bu turda bağımsız hata
diye sınıflanmadı. Test geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round107-summary.json`, results ve CircumflexDecodeAuditTests.

**2026-10-10 — yüz sekizinci tarama, î ünlü sayılmıyor:**
Phonology.vowels kümesinde î yok; State.absorb son-harf-ünlü bayrağını
false yapıyor. Üretimdeki millî/ferdî/resmî köklerine -yi/-ye/-nin ve
hatalı -i/-e/-in çiftleriyle 18 yol denendi. Doğru dokuz yüzey reddedildi,
hatalı dokuz yüzey kabul edildi (resmîyi yerine resmîi gibi). Testte tek
köklü nominal devam yolu ve milli/ferdi/resmi okunuşları verildiğinde doğru
dokuz kabul, hatalı dokuz ret oldu. Üretim adjective kökleri de nominal
devam yolunu kullanıyor. Bu, 107. turdaki eksik ASCII eşlemesinden ayrı
morfolojik sınıflama kusuru; eşleme eklemek ünlü-sonu bilgisini düzeltmez.

TDK düzeltme işareti kaynağı nispet î’sini ve Türkçe ek geldiğinde işaretin
korunmasını açıklıyor: https://tdk.gov.tr/icerik/yazim-kurallari/duzeltme-isareti/
Buradaki çiftler tanı için yazılmış örnekler; kaynaktan alıntı değiller.
Kabul testi boşlukta gerçek değiştirme ölçümü değildir; resmîi’nin adayda
çıkması 107. turda gözlendi. Kök başına okunuş eklemek yalnız tanı deneyi,
bütün şapkalı harf sorununa çözüm iddiası yok. Test geçti, üretim değişmedi.
Kanıt `audits/turkish-round108-summary.json`, path-corpus ve paths JSON’ları.

**2026-10-10 — yüz dokuzuncu tarama, â/û atlanınca yanlış ünlü uyumu:**
rüzgâr/imkân/mekân/tezgâh/güzergâh/mahkûm/inkâr/nikâh kökleri için kısa
belirtme eki ve uzun iyelik-ayrılma biçimleri, hatalı uyum karşılıklarıyla
32 yolda sınandı. Doğru 16 biçim üretimde reddediliyor, hatalı 16 kabul
ediliyor. Örnekler rüzgârımızdan → ret / rüzgârümüzden → kabul;
mahkûmumuzdan → ret / mahkûmımızdan → kabul. â veya û atlanınca önceki
ünlünün durumu kalıyor: örneğin rüzgâr’da ü, mahkûm’da a.

Aynı yazılı köklere testte rüzgar/mahkum vb. okunuşlar verilince doğru 16
kabul, hatalı 16 ret. Bu 108. turdaki şapkalı ünlü sınıflamasının kelime
sonundaki kaynaştırmadan iç ünlü uyumuna uzanan etkisi; bağımsız 32 hata
sayısı değil. Şapkayı üretim metninden silmek çözüm olarak önerilmiyor;
alıntı kelime istisnaları ve yazım korunmalı. Boşlukta otomatik değiştirme
ölçümü yapılmadı, bunlar morfoloji kabul sonuçları. Test geçti, üretim
kodu değişmedi. Kanıt `audits/turkish-round109-summary.json`, path-corpus
ve paths JSON’ları.

**2026-10-10 — yüz onuncu tarama, isimdeki ünlü düşmesi fiile taşınmış:**
Kök verisinde bağır ve devir’in hem noun hem verb satırlarında dropsVowel=1.
Üretim morfolojisi bağırıyor/bağırıyorum/bağıracak/bağıracağım/bağıran ile
deviriyor/deviriyorum/devirecek/devireceğim/deviren biçimlerinin onunu da
reddediyor; kısaltılmış bağr-/devr- yollarını kabul ediyor. Testte aynı fiil
kökleri düşmesiz verilince doğru on biçim kabul, kısaltılmışlar ret oldu.
Ünsüzle başlayan bağırdı/devirdi iki yolda da kabul; isim bağrı/devri üretimde
kabul. devren gibi bağımsız doğru sözcükler bulunduğundan bütün kısaltılmış
yüzeyleri bağlamdan bağımsız yanlış yazım diye nitelememek gerekli.

TDK yayını bağırıyor kullanımını, TBMM tutanağı deviriyor kullanımını
belgeliyor; bağlantılar tur özetinde. Diğer çekimler tanı için oluşturuldu.
12 merkezden yazma denemesi tamamı korundu; morfoloji reddi burada otomatik
bozulmaya dönüşmedi. İki test geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round110-summary.json`, path-corpus/paths, corpus/results.

**2026-10-10 — yüz on birinci tarama, düşme işaretli bütün fiiller:**
Üretimde dropsVowel=1 olan 14 fiil çağır/çevir/ayır/bağır/buyur/evir/devir/
çığır/sıyır/kavur/savur/kıvır/soğur/kayır. Her birinde şimdiki zaman ikinci
çoğul ve gelecek zaman birinci tekil olmak üzere 28 doğru çekim üretim
morfolojisinde reddedildi; testte düşmesiz kökler 28’ini kabul etti.
Kısaltılmış 28 karşılığın 26’sı üretimde kabul, kavruyorsunuz/savruyorsunuz
ise ret: bütün karşılıklar kabul denmiyor. Bazı türev/edilgenlerde düşme
meşru olabileceğinden bütün bayrakları silmek çözüm sayılmaz; ek bağlamına
göre sınıflama gerekir. 110. turdaki isim-fiil eşsesli köklerin ötesine
uzanıyor; işaretlerin tarihsel olarak nasıl atandığı henüz araştırılmadı.

28 merkezden yazma denemesinde bir değişiklik: soğuruyorsunuz → doğuruyorsunuz.
Diğer 27 korundu. MEB fizik materyalinde soğur- kullanım kanıtı mevcut;
bağlantı özette, deneydeki çekimler tarafımızca oluşturuldu. İki test geçti,
üretim değişikliği yok. Kanıt `audits/turkish-round111-summary.json`, kök
adayları, path-corpus/paths ve corpus/results dosyaları.

**2026-10-10 — yüz on ikinci tarama, soğur- anlamını kaybediyor:**
16 girdi üç konumda (merkez ve ±0,2 tuş eni/boyu) 48 kez yazıldı; 21 değişti.
Yedi girdinin her biri üç konumun tamamında soğur- yerine doğur- aldı:
soğuruyorsunuz, ışığı soğuruyorsunuz, enerjiyi soğuruyorsunuz,
soğuruyorlardı, soğuruyormuşsunuz, soğuracaksınız, soğurabileceklerimizden.
Doğuruyorsunuz/çağırıyorsunuz/çeviriyorsunuz kontrolleri ve sınanan diğer
altı soğur çekimi korundu. Dolayısıyla bütün çekimler bozuluyor denmiyor.

Root alternation kodunda dropsVowel işaretli düz kök bütün ünlü başlangıçlı
eklerden dışlanıyor; hangi ekin düşme gerektirdiği ayrıştırılmıyor.
Bu tur üretim paketini değiştirip aday sıralamasını karşılaştırmadı: tek
bayrak düzeltmesinin sonucu tamamen onaracağı henüz kanıtlanmadı. Cümle
örnekleri anlamlı olsa da üretimde bigram yok; semantiğin karara etkisi
olduğu iddia edilmiyor. Çekirdek testi geçti, üretim değişikliği yok.
Kanıt `audits/turkish-round112-summary.json`, korpus ve sonuç CSV’si.

**2026-10-10 — yüz on üçüncü tarama, düşen ünlünün uyumu da kayboluyor:**
Dokuz edilgen biçim ve düşmesiz karşılığı ilk 18 yolda denendi. Test köklerinde
düşme bayrağını kaldırmak doğru ayrılan/çevrilen/devrilen/savrulan/kavrulan/
kıvrılan/sıyrılan/çağrılan/soğrulan biçimlerini reddedip düşmesiz karşılıklarını
kabul ettirdi: bütün bayrakları silmenin çözüm olmadığı somutlaştı.

Test aracına kök bazlı düşme bayrağı eklendi, iki ek karşılıkla 20 yol daha
çalıştı. savur/kavur kökünde u düşürülünce kalan a uyumu belirliyor; savrılan/
kavrılan kabul, savrulan/kavrulan ret. Üretimde ayrı savrul kökü doğru biçimi
kurtarıyor; kavrulan üretim morfolojisinde de yok. Altı merkezden yazımda
kavrulanlarımızdan → kavrılanlarımızdan bozuldu; diğer beş kontrol korundu.
Bu, ek bağlamından bağımsız düşme problemine ek olarak düşen ünlünün uyum
bilgisinin saklanmaması. Kök düzeyinde doğru bayrak bile tek başına yetmiyor.

İlk 18 yolun korpusu no-drop-corpus, sonraki 20 yolun korpusu path-corpus
olarak ayrı kaydedildi. Üç test geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round113-summary.json`, iki yol çıktısı ve yazım CSV’si.

**2026-10-10 — yüz on dördüncü tarama, isimde düşen ünlünün uyumu:**
12 kökte kısa ve uzun doğru/hatalı uyum çiftleriyle 48 yol sınandı:
vakit/hapis/bahis/hacim/nakil/azim/kabir/kavim/haciz/vahiy/zulüm/lütuf.
Doğru 24 yüzeyin 18’i üretimde ret, altısı kabul; hatalı uyumlu 24’ün tamamı
kabul. vakti/nakli/kavmi ve uzunları üretimde de tanınıyor; aynı yüzeylerin
bağımsız kök kayıtları bulunuyor ve alternatif nominal yol sağlayabiliyor.
Bu yüzden yaygın birkaç örneğin çalışması genel kuralın doğru olduğunu
kanıtlamıyor. Testte düşme bayrağı korunup özgün kök okunuşuyla uyum
başlatılınca doğru 24 kabul, hatalı 24 ret.

24 merkezden yazma denemesinde haczimizden → havaimizden değişti;
diğer 23 korundu. 113. turdaki uyum durumunun kaybının isimlere uzanımı,
ayrı 48 hata değil. İki test geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round114-summary.json`, path-corpus/paths, corpus/results.
Test aracına isim kökünde de seçilebilir dropsVowel desteği eklendi.

**2026-10-10 — yüz on beşinci tarama, hacz- iki farklı yoldan bozuluyor:**
14 girdi üç konumda 42 yazım denemesi; 22 değişim. haczimizin/haczinizin/
haczimiz üç konumun tamamında haczımızın/haczınızın/haczımız oluyor.
haczimizden/haczinizden/haczimizde/haczinizde/haczimize merkez ve negatif
ofsette havai- türevlerine kayıyor. dosyadaki haczimizden üçünde de değişiyor;
pozitif ofsette nazimizden, diğerlerinde havaimizden. Beş kontrol tüm
konumlarda korundu: hacizlerimizden, hapsimizden, hacmimizden, kabrimizden,
havaimizden.

havaimizden/havaim tek başına havai köküyle de kabul ediliyor; üretimde havai
noun kaydı mevcut. Sonuç hava kelimesine bozuk ek diye sınıflandırılmamalı.
Bu kontrol olası türetim yolunu gösterir, kazanan adayın tam geriye izini
çıkarmadık. Kullanıcının hacz- niyetinden uzaklaşması yine gerçek bozulma.
Cümle sonucu anlamsal bağlam modeli kanıtı değil. İki test geçti, üretim
değişikliği yok. Kanıt `audits/turkish-round115-summary.json`, iki korpus,
yol çıktısı ve sonuç CSV’si.

**2026-10-10 — yüz on altıncı tarama, iki kök değişimi birleşmiyor:**
RootTrie yumuşama ve ünlü düşmesi varyantlarını özgün kökten ayrı ayrı
kuruyor; birlikte değişmiş varyantı eklemiyor. kayıp/kayıt/nakit/akit/ahit
üzerinden 30 yol ölçüldü. kaybı/kaybımızdan/kaydımızdan üretim morfolojisinde
yok; kaypı/kayıbı/kaytı/kayıdı ve uzunları kabul ediliyor. Diğer doğru
birleşik yüzeylerin bazısı alternatif üretim yollarıyla kabul; yüzeyin
kabulü ilgili kökün birleşik değişim ürettiğini kanıtlamıyor.

Testte açık kayb/kayd/nakd/akd/ahd gövdeleri ve özgün kökün uyum bilgisi
verilince on doğru hedef kabul. Bu gövdeleri bağımsız sözcük diye sözlüğe
ekleme önerisi değil. nakti/akti/ahti retleri ayrıca önceki uyum kaybıyla
ilişkili. On merkezden yazımın tamamı korundu; otomatik değiştirme vakası
gösterilmedi. İki test geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round116-summary.json`, iki korpus, paths ve results CSV.

**2026-10-10 — yüz on yedinci tarama, birleşik kök değişimi yazıyı bozuyor:**
Kayıp/kayıt uzun çekimlerinden 44 merkez yazımında üç değişim:
kaybımızdakiler → kayıbımızdakiler, kaybınızdakilerden → kayıbınızdakilerden,
kaydınızdakilerden → kayıdınızdakilerden. Üçü, cümle örneği ve bir kontrol
üç konumda tekrarlandı: 15 denemenin 12’si değişti. Pozitif ofsette iki
kayb biçimi kayn biçimine kayıyor; kayd biçimi üçünde de kayıd oluyor.
ses kaydınızdakilerden üçünde de ses kayıdınızdakilerden; çoğul kök
kontrolü kayıtlarınızdakilerden üçünde de korundu.

Bu 116. turdaki birleşik kök yolu eksikliğinin yazımda görünen etkisi.
Takip başarısız örneklerden seçildi; 12/15 genel hata oranı değil. İki
çalışmanın merkez tekrarları bağımsız yeni örnek sayılmamalı. Üretim paketi
onarılıp karşılaştırılmadı; düzeltme henüz doğrulanmış değil. İki test geçti,
üretim değişikliği yok. Kanıt `audits/turkish-round117-summary.json`, ilk
ve followup korpus/CSV çiftleri.

**2026-10-10 — yüz on sekizinci tarama, uygulanamaz yumuşama bayrakları:**
Bütün kök satırlarında alternasyon kaynak harfi ile son harf karşılaştırıldı.
İki tutarsızlık: muhasib (b ile bitiyor, pToB) ve kopmatokluğu (u ile bitiyor,
kToGSoft). RootTrie kaynak harf uyuşmazsa yumuşamış varyant üretmiyor;
plain yol ise bayrak var diye ünlü başlangıçlı eklerden kısıtlanıyor.
On yol testinde muhasibi vb. üretimde yine kabul: ayrı muhasip/pToB kaydı
mevcut. kopmatokluğu ek testleri üretimde ret, bayraksız test kökünde kabul.
Bu tartışmalı yüzeyin doğru Türkçe olduğunu iddia etmiyoruz; bulgu verinin
kendi kurallarıyla çelişmesi, yeni kullanıcı yazım bozulması değil.

Simülatör erişimi de yeniden kontrol edildi: DeviceHub ve BestKeyboard
kartı açıldı, önceki Mac kilidi bu işlemi engellemedi. DENE alanında yazılım
klavyesi görünmediği için Slm seçimi sonrası öneri çubuğu doğrulanamadı.
Simülatörün Tam Erişim uyarısı kullanıcının kendi cihazındaki izin hakkında
kanıt değil. Canlı seçim testi tamamlanmadı; ayrı ürün hatası sayılmadı.
Seçim öğrenme yolu için planlanan ek inceleme bu turda yapılmadı.
Çekirdek yol testi ve diff kontrolü geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round118-summary.json`, alternation-mismatches ve paths.

**2026-10-10 — yüz on dokuzuncu tarama, emoji silip kelimeye devam:**
On kök/ek çifti 🙂, aile ZWJ emojisi ve Türkiye bayrağıyla 30 akışta sınandı:
kök yaz → emoji ekle → geri sil → eki yaz → boşluk. Otuzunda da önceki
composing yüzeyi geri açılmadı; belge doğru birleşmiş kelimeyi gösterirken
ilk öneri yalnız yeni yazılmış eki içeriyor. Altı akış son boşlukta bozuldu:
yazılmayacakmışsınız → yazılkayacakmışsınız ve okunmayacakmışız →
okunkayacakmışız; her üç emoji türünde aynı iki sonuç.

Bu önceki noktalama sınırını silip devam etme kusurunun emojiye uzanımı;
her emoji ayrı kök neden değil. FakeDocument bir Swift Character siliyor;
gerçek host’un UTF-16/emoji silme davranışı bu testle doğrulanmış sayılmaz.
Test geçti, üretim değişikliği yok. Kanıt `audits/turkish-round119-summary.json`,
results JSON’u ve mod seçimi genişletilmiş PunctuationResumeAuditTests.

**2026-10-10 — yüz yirminci tarama, iki boşluğu silince önceki kelime kopuyor:**
On kök/ek çifti doğrudan, tek boşluk silme, iki boşluk silme ve üç boşluk
silme ile 40 akışta sınandı. Tek boşluk kontrolü 10/10 composing kökü geri
getiriyor; iki/üç boşluk 0/10. Çoklu boşluk silme sonrası ilk öneri yalnız
eki temsil ediyor; her iki kipte yazılmayacakmışsınız → yazılkayacakmışsınız
ve okunmayacakmışız → okunkayacakmışız bozuluyor.

Doğrudan ve tek-boşluk sonuçları birebir aynı; her birinde önceki tam-kelime
düzeltme sorunlarından yedi değişim var. Çoklu-boşluk kipinde iki değişim
olması iyileşme kanıtı değil; kopan bağlamın davranışı farklı. Test çekirdek
space çağrılarıyla yapıldı, UI çift-boşluk jesti/otomatik nokta simülasyonu
değil. Önceki sınır geri açma kusurunun başka tetikleyicisi. Test geçti,
üretim değişikliği yok. Kanıt `audits/turkish-round120-summary.json`, results
ve PunctuationResumeAuditTests’e eklenen iki mod.

**2026-10-10 — yüz yirmi birinci tarama, rakam/tire/kesme silme:**
On kök/ek çifti yanlışlıkla 1, tire veya kıvrık kesme ekleyip geri silme
ile 30 akışta sınandı. Otuzunda da önceki composing kökü geri açılmadı;
her türde yazılkayacakmışsınız ve okunkayacakmışız olmak üzere toplam altı
bozulma. Ortak insertAtBoundary yolu token’ı kapatıyor, tek-boşluk geri açma
koşulu bu ayırıcıları kapsamıyor. Önceki noktalama/emoji/çoklu boşluk
bulgusunun aynı ailesi; üç yeni bağımsız hata değil.

Bu test düzlem geçişi veya fiziksel tuş hedeflemesi değil, çekirdek komut
akışı. Ayırıcı çeşitlerini daha fazla çoğaltmak yerine artık başka alanlara
geçilecek. Test geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round121-summary.json`, results ve üç yeni audit modu.

**2026-10-10 — yüz yirmi ikinci tarama, silmenin kapsamı iki depoda farklı:**
Kişisel sözlükteki sil düğmesi yalnız session.forgetPersonal çağırıyor;
engine/fallback sözlükleri güncellenip kaydediliyor, bağımsız TypingHistory
silinmiyor. Sonraki kelime önerileri predictNext açıkken bu geçmişi okuyor.
Dört özgün kelime gerçek literal önerisiyle öğrenildi, aynı yüzey ayrı
PersonalHistory’de gözlendi; kişisel silme sonrası dördü de sözlük/V’den
çıktı fakat sonraki kelime sonucu dördünde kaldı. Geçmiş JSON gidiş-dönüşünde
de kaldı. Önek hatırlama kontrolleri bu dört örnekte boştu.

Bu kendiliğinden sözlüğe geri kabul değil, kaynaklar arası silme kapsamı
sınırlaması. Düğme kişisel sözlük bölümünde olduğundan bütün öneri kaynaklarını
susturmasının istenip istenmediği ürün kararı; tek başına veri kaybı veya
kalıcılık arızası diye sınıflanmadı. Gözlem çekirdek depolarına doğrudan
verildi, uygulama bağlantısı kaynak koddan izlendi; canlı UI düğme testi
değil. Test geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round122-summary.json`, results ve ForgetAcrossStoresAuditTests.

**2026-10-10 — yüz yirmi üçüncü tarama, bağlantıda yanlış harf eşleme:**
Türkçe IŞIK/ışık ve İSTANBUL/istanbul geçmiş kontrolleri geçti. Bağlantı
hatırlamada ise https://INFO.example/page kaydı küçük info önekiyle
bulunamıyor, tersi de bulunamıyor; aynı harf biçimi kontrolü çalışıyor.
Diğer yönde https://example.com/Page ve /page tek anahtara çöküyor;
son küçük harfli yüzey kalıyor, büyük P öneğine de o öneriliyor.

PersonalHistory bütün token ve önekleri TurkishText.key ile normalize
ediyor. URL’nin host kısmı ASCII harf duyarsızken path bileşeni genel
olarak duyarlı; aynı dönüşüm ikisine de uygun değil. Kaynak RFC3986 §6.2.2.1:
https://www.rfc-editor.org/rfc/rfc3986.html#section-6.2.2.1
İlk Item/item çifti Türkçe I nedeniyle ayrı anahtar oluşturdu; çakışmayı
ayrı sınamak için Page/page ile değiştirilip tekrar koşuldu. Altı son gözlem
kaydedildi. Gerçek URL açılmadı; otomatik düzeltme veya canlı kısayol seçimi
iddiası yok. Test geçti, üretim değişikliği yok. Kanıt
`audits/turkish-round123-summary.json`, results ve HistoryCaseAuditTests.

**Tur 124 — URL uç noktalaması:** 24 geçmiş gözleminde 12 tam yüzey kaybı. `https://example.com/a(b)` → `https://example.com/a(b`; sondaki `!`, `.` ve `;` de kesiliyor. Dört kontrol URL üç sarmalama biçiminde korunuyor. Bağlamdan bağımsız token kenarı temizliği; canlı otomatik düzeltme testi değil. Kanıt: `audits/turkish-round124-summary.json` ve `turkish-round124-results.json`. RFC3986 §2.2/3.3 ilgili karakterlerin URL bileşenlerinde kullanılabildiğini doğruluyor; cümle noktalaması ile URL sonu bazı durumlarda belirsiz.

**Tur 125 — IT/developer ifadeleri:** Üretim paketleriyle 197 merkez-dokunuş yazımında 7 istenmeyen değişim: `http→btp`, `https→battle`, `mqtt→matt`, `amqp→anap`, `csrf→card`, `graphql→grapha`, `index.tsx→index.tax`. `tcp/ip`, `TCP/IP` ve örnek IPv4 yazımları korunuyor; genel güvence değil. Ayrı geçmiş testindeki 183 tek token'ın 17'si aynen saklanmıyor: `.env→env`, `.gitignore→gitignore`, `../src→/src`, `foo()→foo` gibi uç işaret kaybı; `::1` kenar temizliğinden sonra tek karaktere düşüp eleniyor. Uzun IPv6 ve `192.168.100.200:65535` 12-rakam filtresine takılıyor; kısa `C++`, `C#`, `F#` recall alt sınırına takılıyor. Son ikisi otomatik metin bozma değil, mevcut koruma/öneri kurallarının kapsama eksiği. Kaynak biçim doğrulaması: RFC4291 §2.2, RFC3986 §3.3. Kalıcı kanıt: `audits/turkish-round125-{corpus,history,summary}.json` ve `turkish-round125-results.csv`. Çözüm fazında birkaç kelimelik istisna listesi yerine teknik biçimlerin bütünlüğü ele alınmalı; bu tur üretim kodu değişmedi.

**Tur 126 — teknik ifade takip testi:** Tur125'te bozulan yedi ifadeyi tek başına, Türkçe devam/ön bağlamla ve büyük harfle 28 girdiye genişletip üç basış ofsetinde denedik: 84 yazımın 70'i değişti; 28 girdinin her biri en az bir ofsette bozuldu. Merkezde **28 denemenin 26'sı** değişti. `HTTPS→BATTLE`, `MQTT→MATT`, `INDEX.TSX→INDEX.TAX`: büyük harf korumuyor. `sunucu https` ve `sunucu csrf` merkezde korunurken başka ofsetlerde değişiyor. Bilinen bozuk örneklerden seçilmiş takip kümesi; %83 genel teknik kelime hata oranı diye yorumlanamaz. Kanıt: `audits/turkish-round126-summary.json`, korpus ve CSV. Üretim kodu değişmedi.

**Tur 127 — teknik önerinin yazarken kaybolması:** 15 teknik token'ın 156 öneki sınandı. 19 önekte çekirdek geçmiş önerisi var ama uygulamanın `TypingHistory.recall` normalizasyon/son-ek kontrolü öneriyi engelliyor. `192.168.`, `127.0.0.1:`, `fe80::`, `https:` örnekleri. Sonraki rakam/harf yazıldığında öneri geri gelebiliyor. Noktalama temizliğiyle aynı kök aile, öneri yönlendirmesinde ayrıca gözlenen sonuç. Üretim çekirdeği + uygulamadan modellenmiş guard; canlı UIKit testi değil. Kanıt: `audits/turkish-round127-{results,summary}.json`.

**Tur 128 — 2.000 teknik girdi / 4.000 ayrı kontrol:** On aile × 200 sentetik varyant: IPv4, IPv4:port, IPv6, e-posta, artı etiketli e-posta, telefon, göreli yol, URL, kod adı, CIDR. Normal metin alanı ve merkez dokunuşlarda 200 göreli yolun tamamı `./src/moduleN/index.tsx → ./src/moduleN/index.tax` değişti. Bağımsız geçmiş testinde aynı 200 yol `./src/... → /src/...` kaydedildi. Kalan dokuz ailedeki 1.800 örneğin yazımı ve kayıt yüzeyi bu koşullarda korundu. 200 ayrı kök neden değil; önceki iki sorunun sistematik varyantları. Geçmişe hatalı yazım çıktısı değil, özgün korpus verildi; iki hatanın uçtan uca birleşimi bu testin iddiası değil. `audits/turkish-round128-summary.json`, korpus, yazım CSV ve geçmiş JSON kalıcı kanıt. Simülatör testi değil.

**Kullanım kolaylığı adayları (uygulanmadı):** (1) Tur127'de doğrulanan IP/URL nokta/iki-nokta sınırlarında hatırlama teklifini koruma. (2) Bağlama göre IP işaretlerine ve e-postada `@`/alan adı tamamlamaya kolay erişim; mevcut sembol düzeninden çıkan tasarım adayı. (3) Gruplu telefon girişinde boşluğun sayı düzenini gereksiz kapatmaması: controller her boşlukta harflere dönüyor; varsayılan sayı satırı mevcut, gerçek kullanım sürtünmesi UI'da ayrıca sınanmalı. Normal yazıda kullanıcının istediği harflere dönüş davranışı korunarak düşünülmeli. (4) Teknik ifadeyi parçalamadan koruma ve öğrenme.

**Tur 129 — teknik koruma kuralları gerçek girdiyi göremiyor:** Yedi bilinen bozuk dizinin sekiz biçimiyle 56 merkez yazımı. `CorrectionPolicy.isProtectedToken` bütün girdiye uygulanınca 47'sini koruyor; gerçek `session.literal` üzerinden bu 47 korumanın tümü kayıp, 43 girdide gerçek değişim var (toplam 56 denemenin 52’sinde değişim). Büyük/karışık harf kuralı küçük harfe indirgenmiş literal'i görüyor; `@`, `#`, `_`, rakam ve `/` ise token'ı kapatıp yalnız son harf grubunu bırakıyor. `HTTP→BTP`, `@mqtt→@matt`, `test_graphql→test_graphical`, `v2http→v2btp`, `api/tsx→api/tax`. Bu, koruma kuralını yazmanın yetmediğini ve bütün teknik girdinin karar yoluna taşınmadığını kanıtlıyor. Dört koruma kaybında başka puanlama koşulları girdiyi tesadüfen korumuş; koruma kaybı ile gerçek değiştirmeyi ayrı saydık. Önceden bozulduğu bilinen dizilerin hedefli testi, genel hata oranı değil. Kanıt: `TechnicalProtectionAuditTests.swift`, `audits/turkish-round129-{results,summary}.json`. Üretim kodu değişmedi; canlı UI testi değil.

**Tur 130 — gruplu telefon numarası hatırlama:** 13 sentetik biçim, gerçek geçmiş gözlemi + JSON kaydet/yükle + recall. Altı boşluklu/NBSP gruplu biçim bütün numara olarak öğrenilmiyor: `0532 123 45 67` yalnız `0532` saklayıp öneriyor; `+90 532 123 45 67` ve `+90 (532) 123 45 67` hiçbir token saklamıyor. Kısa sayısal parçalar dört-karakter recall alt sınırına takılıyor, sayı grupları kelime olmadığı için sonraki-parça çiftleri de oluşmuyor. Ek olarak `(0532)1234567` tek açılış parantezini kaybedip `0532)1234567` saklanıyor (önceki noktalama ailesi). Altı bitişik/tireli/noktalı kontrol biçimi aynen saklanıp öneriliyor. Gruplu telefon desteği kullanıcı tarafından istenen kolaylaştırma için doğrulanmış kapsama eksiği; yazarken numaranın bozulduğunu iddia etmiyoruz. Doğrudan çekirdek recall ile uygulama normalize edilmiş öneki ayrı: parantezli girdinin UI'da hiç önerilmediği sonucu çıkarılamaz. Kanıt: `audits/turkish-round130-{results,summary}.json`, `PhoneFormatHistoryAuditTests.swift`.

**Tur 131 — e-posta anlamı ve öğrenme:** 11 hedefli geçmiş senaryosu. `Smith@example.com` ve `smith@example.com` tek kayda çöküyor; `Smith@` artık küçük harfli olanı öneriyor. Tersine `dev@INFO.example`, `dev@info` ile bulunmuyor ve iki alan adı biçimi ayrı kayıt oluyor; `EXAMPLE/example` kontrolü normal eşleşiyor. Üç tırnaklı yerel bölüm örneğinde açılış tırnağı siliniyor; `"a b"@example.com` yalnız `b"@example.com` saklanıyor. Artı etiketli iki adres ayrı kalıyor; artı/nokta/IP literal dört yüzey kontrolü korunuyor. RFC5321 §2.4 yerel bölümün harf biçiminin korunmasını, alan adının harf duyarsızlığını; §4.1.2 tırnaklı bölümde boşluğu doğruluyor. Her sağlayıcının Smith/smith ayrımı yaptığı iddia edilmiyor. URL tur123'teki normalizasyon ve tur124/130'daki token bölme/kenar temizliği ailelerinin e-postaya etkisi; yeni her örneği ayrı hata sayma. Kanıt: `audits/turkish-round131-{results,summary}.json`, `EmailHistoryAuditTests.swift`. Gerçek mail gönderilmedi; yazım otomatik düzeltmesi ve UI değil.

**Tur 132 — imleç adresin ortasındayken hatırlama uygulaması:** IP/e-posta/URL/yol × sonda/ortada/boşluktan önce = 12 senaryo. Dört orta-imleç senaryosunda teklif tüm token'ı getiriyor ama uygulama yalnız sol öneki siliyor; sağdaki mevcut devam yineleniyor: `dev@exa|mple.com → dev@example.commple.com`, `192.16|8.1.10 → 192.168.1.108.1.10`. Sekiz sonda/boşluktan önce kontrolü beklendiği gibi; ön/son çevre metni korundu. `refreshShortcut` ve `TypingHistory.recall` yalnız önceki bağlamı, `applyShortcut` yalnız `deleteTrailing` yolunu kullanıyor. Uygulama yönlendirmesinin kaynakla eşleşen modeli + gerçek çekirdek düzenleme; UIKit/canlı cihaz kanıtı değil. Güvenli beklenti uygunsuz öneriyi bastırmak veya mevcut devamı hesaba katmak; sağdaki keyfî metni silmek değil. Kanıt: `audits/turkish-round132-{results,summary}.json`, `TechnicalRecallCursorAuditTests.swift`. Önceki seçili metin sorunu yeniden sayılmadı; bu tur seçim olmadan orta-imleç.

**Tur 133 — teknik noktalama sonrası büyük harf, negatif bulgu:** Üretim `ShiftPolicy.shouldCapitalize` ile 16 boşluksuz teknik bağlam (`dev@example.`, `index.`, `fe80::`, `https://` vb.) ve dört gerçek cümle/satır-sonu kontrolü sınandı. Hepsi beklenen sonucu verdi: teknik noktalama sonrası büyük harf açılmıyor, dört cümle kontrolünde açılıyor. Şüphe doğrulanmadı, hata sayısına eklenmeyecek. Cümle modu önce boşluk gerektiriyor. Önceki allCharacters/alıntılı cümle sorunlarını veya alan başı davranışını çözmüş saymıyoruz. Kanıt: `audits/turkish-round133-{results,summary}.json`, `TechnicalCapitalizationAuditTests.swift`; çekirdek politika testi, canlı UI değil.

**Tur 134 — ortak önekte alternatif adreslerin görünürlüğü:** E-posta/IP/URL için 12 kontrollü gözlem. Çekirdek `limit:3` ile üç kayıt döndürebiliyor; uygulama varsayılan tek sonucu alıp tek shortcut yuvasına koyuyor. 20 kez kullanılan eski adres, yeni adres 19 kez kullanılmış olsa da tek teklif; sayılar 20'de eşitlenince yeni olan kazanıyor. Ayırt edici öneki uzatmak üç kontrolde de istenen adresi getiriyor. Dolayısıyla “öğrenmiyor” veya “hiç erişilemiyor” değil. Mevcut frekans-öncelikli tek-öneri tasarımıyla tutarlı; hata toplamına eklenmeyen kullanım kolaylığı fırsatı: aynı önekte birkaç kayıtlı adresi seçilebilir sunmak, güncellik ağırlığını ayrıca değerlendirmek. Kanıt: `audits/turkish-round134-{results,summary}.json`, `RecallChoiceAuditTests.swift`; çekirdek + incelenen UI yönlendirme kodu, canlı UI testi değil.

**Tur 135 — kesilmiş host bağlamından sahte teknik kayıt:** Üç uzun teknik token (URL 101, e-posta 76, kod adı 88 karakter) × tam/son32/son48 bağlam = dokuz senaryo. Tam bağlamda üç token 64 karakter kabul sınırınca saklanmıyor; altı kesilmiş bağlamda son parça bağımsız token sanılıp saklanıyor ve recall ediliyor. Örnek e-postanın 32 karakter bağlamı `seruseruseruseruser@example.com` kaydediyor; URL `gment/segment/segment/file.json` oluyor. `TypingHistory.observe` görünen bağlamın başlangıcındaki parçanın gerçek kelime başı olup olmadığını ayırt etmiyor. 32/48 uzunluklar kontrollü enjekte edildi, iOS'un gerçek pencere boyutu diye sunulmuyor; uygulama çıkarım modeli + gerçek geçmiş kodu, canlı host doğrulaması değil. Her ilk token'ı atmak doğru çözüm sayılmaz: gerçek belge başı ile bilinmeyen kesilme sınırı ayrılmalı. Kanıt: `audits/turkish-round135-{results,summary}.json`, `TruncatedHistoryAuditTests.swift`.

**Tur 136 — hazır tamamlama sonrası düzenleme, negatif bulgu:** Altı yüzey × tümünü sil / boşluk-ekle-sil / son karakteri silip x yaz ve boşluk = 18 üretim çekirdeği denemesi. Hepsinde beklenen metin ve önündeki `önce ` korundu; ek karakter kaybı veya yanlış değiştirme çıkmadı. Gerçek dil paketi + FakeDocument; test hazır metnin eklenmesiyle başlıyor, öneri ön-ek silmesi veya UIKit akışı değil. Native undo denenmedi. Önceki orta-imleç veya seçim hataları bu sonuçla geçersiz sayılmaz. Kanıt: `audits/turkish-round136-{results,summary}.json`, `RecallEditingAuditTests.swift`; yeni hata sayısına eklenmeyecek.

**Tur 137 — teknik terim + Türkçe ek:** 20 teknik taban × bitişik/düz kesme/eğri kesme/büyük taban+düz kesme = 80 merkez yazımı. Beş bitişik form değişti: `graphqlden→graphtakiden`, `mqttye→matthe`, `httpde→battles`, `httpste→battleste`, `deploymenttan→deploymentsin`. Kalan 15 bitişik form ve 60 kesmeli form korundu. Girdiler teknik sohbetteki sentetik kullanımlar; ek okunuşu/yazımı için normatif doğru listesi diye sunulmuyor. Sonuçlar yalnız noktalama düzeltmesi değil, teknik tabanı da değiştiriyor. Bilinen teknik OOV/ek koruma açığının kapsamı; yeni bağımsız beş kök neden değil. Kesme koruması bu kümede çalıştı; çözüm olarak her teknik terime zorunlu kesme önermek çıkarılamaz. Kanıt: `audits/turkish-round137-{corpus,summary}.json`, `turkish-round137-results.csv`. Üretim çekirdeği ve dil paketi, canlı UI değil.

**Tur 138 — istenen IntelliSense tipi tamamlamanın kapsamı:** Sekiz çekirdek recall senaryosu. Dört tam-önek kontrolü öneri getiriyor; aynı kayıttaki parçayı başka girdide kullanmaya yönelik dört senaryo getirmiyor. `alice@example.com` kayıtlıyken `bob@exa` alan adını tamamlayamıyor; URL'den şemasız alan adı, farklı şemada yol veya başka IP'de port tamamlaması da yok. Mevcut sistem bütün token öneki eşleştiriyor; bu yeni talebin yetenek açığı, mevcut davranıştan yeni doğruluk hatası sayılmadı. İlk IP kontrolü bilinen 12-rakam sınırına takıldığından daha kısa `10.0.0.1:8080` ile izole edilip tekrar çalıştırıldı. **Kullanıcı talebi kalıcı:** teknik türü/bileşeni anlayan, birkaç seçenek gösteren, yalnız açık seçimle uygulanan tamamlama; sağdaki mevcut metni korumalı. Kayıtlı tam adres ile parçalardan yeni kurulan öneri ayrılmalı, yeni adresin gerçekten var olduğu varsayılmamalı; şema/port sessiz değiştirilmemeli. Kanıt: `audits/turkish-round138-{results,summary}.json`, `TechnicalComponentRecallAuditTests.swift`. Henüz üretim özelliği uygulanmadı.

**Tur 139 — doğrudan teknik karakter erişimi:** Üretim Türkçe Q, Türkçe shift dönüşümleri, sayı/sembol düzlemleri ve boşluk/enter/nokta/virgül envanterinde 99 karakter sınandı. 95 yazdırılabilir ASCII'nin 94'ü mevcut, U+0060 ters tırnak yok. Tab ve `â/î/û` için de doğrudan tuş yok. `KeyboardView.startHolds` yalnız globe/nokta/boşluk, geri silme tekrarı ayrı; incelenen giriş yolunda harf/sembol alternatif menüsü bulunmuyor. Doğrudan yazım kapsama eksiği; panodan/özel kısayoldan/öneriden/başka klavyeden üretilemez iddiası değil. Şapkalı harf kısmı tur106/107 ile örtüşüyor, yeniden ayrı hata sayılmayacak. Tab geliştirici kullanım gereksinimi olarak değerlendirilmeli, evrensel mobil klavye zorunluluğu diye sunulmuyor. Kanıt: `audits/turkish-round139-{results,summary}.json`, `TechnicalKeyCoverageAuditTests.swift`. Canlı UI değil; kaynak+üretim geometri testi.

**Tur 140 — sürüm/etiket/branch/CLI:** 40 merkez yazımının 39’u korundu; `feature/graphql→feature/graphical`. Bilinen teknik token parçalanmasının branch adına etkisi, yeni kök neden değil. Kanıt: `audits/turkish-round140-{corpus,summary}.json`, `turkish-round140-results.csv`. Kullanıcı bu tur sonunda tüm bulguları mimari düzeyde gözden geçirip çözüm planını önce düşünmemizi istedi; yeni taramadan konsolidasyon/tasarım fazına geçildi.

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
| Güçlü kanal (2026-10-10) | İlk öneri yazılan yüzeydir. `.literal` kökenli açık seçim, tek güçlü gözlemle kişisel sözlüğe kabul edilir; kayıt ve replay bu kökeni taşır. |
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


**2026-10-10 — 141. tarama, kaynaklar arası güncellik:** Kaynak katkıları ayrıldıktan sonraki üretim kodunda 18 gözlemden 9'unda eşit sayımlı adresler gerçek aktarım sırasına göre sıralanmıyor. WhatsApp → Telegram → Metin sırasıyla birer adres aktarıldığında en yeni Metin adresi, ilk iki teknik önerinin dışında kalıyor; canlı durum, JSON yeniden yükleme ve ilgisiz bir kelime yazımından sonra aynı sonuç var (3 gözlem). Ters aktarım sırası kontrolleri geçiyor; sayaçların hepsi 1, veri kaybı veya çift aktarım gösterilmedi.

Neden: `HistoryArchive.rebuildHistory` kaynakları alfabetik sırayla birleştiriyor; `PersonalHistory.merge` bu sırada yeniden sıra numarası atıyor. Sonuçta eşit sayımda güncellik yerine kaynak adı sıralamayı belirliyor. Gerçek çekirdek completion sağlayıcısı kullanıldı; arayüzün iki tamamlamayı göstermesi koddan doğrulandı, canlı UI karşı-deneyi yapılmadı. Tanı testi yeşil olması hatanın kapandığı anlamına gelmez. Tek kök neden, üretim düzeltmesi yok. Kanıt: `audits/turkish-round141-summary.json`, `turkish-round141-results.json`, `turkish-round141-test.log`.


**2026-10-10 — 142. tarama, unutma kimliği ve parçalı öğrenme:** Türkçe büyük/küçük harf, e-posta alan adı, URL alan adı ve iki telefon biçimi olmak üzere beş unutma → JSON yeniden yükleme → yeniden aktarım kontrolünün hepsi geçti. Silinen yüzeyler geçmişe/kaynak kataloğuna dönmedi; farklı kullanıcı kısmı, farklı URL yolu ve farklı numara kontrolleri korundu. Yeni unutma hatası bulunmadı.

Eski 6. turdaki `split_import_evidence_not_accumulated` güncel kodda tekrarlandı: tek `[3]` parça 3 puanla kabul, `[1,1,1]` parçaları 1 puanla ret, `[2,1]` parçaları 2 puanla ret; `[3,3]` 3 puanda kalıyor. `PersonalLexicon.ingest` max kuralı değişmemiş. Bu yeni bağımsız hata sayılmıyor: arayüz tek metinde üç tekrar isterken koordinatör ve alan aktarımı açıklamaları parçalı birikim vaat ediyor. İşlem kimliği olmadan doğrudan toplamak tekrar-aktarım kontrolünü bozacağından davranış sözleşmesi açık kalıyor. Sohbet aktarımıyla kişisel alandan öğrenme farklı yollar; bu sonuç WhatsApp sayımları için iddia değildir. Üretim düzeltmesi yok; kanıtlar `audits/turkish-round142-*` dosyalarında.


**2026-10-10 — 143. tarama, gruplu numaranın canlı öğrenilmesi:** Aynı metnin tek seferde aktarılmasıyla karakter karakter yazılması karşılaştırıldı. 14 koşulun 8'inde canlı yazım fazladan numara parçaları kaydetti; 6 koşulda bu parçalar gerçek completion sağlayıcısının ilk iki teklifine girdi. Örnek: `+90 532 123 45 67` yazılırken `+90 532 123` ve `+90 532 123 45` da öğreniliyor; `+90 532` önekinde tam numaranın yanında ikinci parça öneriliyor. JSON yeniden yükleme bunu temizlemiyor. Yerel `0532 123 45 67` örneğinde `0532` ayrıca kalıyor.

Tam numara 14/14 durumda korundu; altı bitişik/parantezli bitişik kontrol fazladan parça üretmedi. `numaram ` ön eki sonucu değiştirmedi. Neden, her iç boşlukta gözlenen geçici parçanın bağımsız tamamlanmış olay sayılması ve numara büyüdüğünde önceki parçanın yerini aldığının kaydedilmemesi. Bu otomatik metin bozulması veya tam numara kaybı değil, yarım numara önerisi hatasıdır. Gerçek çekirdek sınıfları ve üretim callback sırasının modeli kullanıldı; canlı UI testi yok, iki teklif sınırı controller kodundan doğrulandı. Tek hata ailesi; üretim değişikliği yok. Kanıt: `audits/turkish-round143-summary.json`, `turkish-round143-results.json`, `turkish-round143-test.log`.


**2026-10-11 — 144. tarama, telefon tamamlamasında son ayırıcı:** Dört telefon biçimi ve e-posta kontrolü, yedi farklı sonlandırmayla 35 koşulda sınandı. 16 koşulda öneri, tamamlanmış numaranın sonundaki boşluk/noktayı değiştirme aralığına dahil etti. `ara +905321234567. ` metninde `+905321234567` teklifini seçmenin modellenen sonucu `ara +905321234567`: nokta ve boşluk kayboluyor. Bu 16 işlemin tamamı gerçek `Completion.matches` kontrolünden geçiyor; bayat aday koruması sınır hatasını yakalamıyor.

Numaranın ayırıcısız tam hâli, virgül+boşluk, satır sonu ve yedi e-posta kontrolü bu gereksiz teklifi üretmedi. Her koşul yalnız doğru tam numarayla başlatıldığı için 143. turun yarım numara öğrenmesinden bağımsızdır. Neden, telefon öneki taramasının imlece kadar olan boşluk/noktayı biçimlendirme kabul etmesi; controller bu önekin tamamını silip saklanan yüzeyi yazıyor. Gerçek completion sağlayıcısı ve snapshot kapısı kullanıldı, seçim sonucu controller işlemlerinin modeliyle hesaplandı; yeni native UI deneyi yok. Otomatik değişim değil, açık öneri seçimi hatası. Üretim kodu değişmedi. Kanıtlar `audits/turkish-round144-*` dosyalarında.


**2026-10-11 — 145. tarama, tırnaklı e-posta tamamlaması:** Yedi öğrenilmiş adresin 143 eksik öneki kontrol edildi. 36 önekte tam adrese ulaşan teklif yok. Boşluklu yerel kısım, normal completion yolunda son boşluktan bölünüyor: `"First Last"@example.com` için altı ara önekte teklif kayboluyor; alan adı yazılınca bazıları yalnız son parçadan kurulan adayla geri geliyor. Bu son-parça adayının modellenen uygulama sonucu doğru tam adres; salt farklı aday yüzeyi metin bozulması sayılmadı.

Ayrıca tam önekle doğrudan recall dahi 10 durumda başarısız. İzole `"First@Last"@example.com` adresinin beş öneki bulunamazken küçük harfli `"first@last"@example.com` kontrolünde hiç kayıp yok. `technicalSearchKey` tırnak içindeki `@` işaretini henüz gerçek alan adı ayracı yazılmadan sınır sayıp devamını küçültüyor. Normal `dev@example.com` ve boşluksuz noktalı tırnaklı adres kontrolleri geçti. Tam kayıtlar doğru ve yeniden yüklemede korunuyor. Bu öneri erişimi/önek normalizasyonu bulgusu; otomatik metin bozulması veya tam kayıt kaybı gösterilmedi. Gerçek çekirdek, controller değiştirme aralığının modeli; native UI yok. Üretim değişikliği yok. Kanıtlar `audits/turkish-round145-*` dosyalarında.


**2026-10-11 — 146. tarama, yapılı token ortasında imleç:** Zaten tam yazılmış sekiz adres/numaranın 123 imleç konumu kontrol edildi. 12 konumda gereksiz tamamlama mevcut sağ kuyruğu yineliyor. Örnek `+90| 532 123 45 67` → öneri seçimiyle `+90 532 123 45 67 532 123 45 67`. Tırnaklı `"First| Last"@example.com` da tam adresin sonuna ` Last"@example.com` eklenmiş sonucu veriyor. 12 teklifin tamamı snapshot eşleşmesinden geçiyor.

Boşluksuz telefon, normal e-posta, URL ve dosya yolundaki 57 konumda bu teklif yok; birer doğru tam kayıt kullanıldı. Neden, `rightToken`ın ilk boşlukta bitmesi: numara/e-posta içindeki boşluk token sonu sanılınca zaten var olan kuyruk hesaba katılmıyor. 132. turun imleç-ortası ailesinin yapılı/boşluklu tokenlarda kalan kapsamı; 143–145 ile de metin aralığı çözümlemesi ilişkili. 12 ayrı hata sayılmıyor. Gerçek core completion ve snapshot kapısı, controller düzenlemesinin modeli; yeni native UI testi yok. Yalnız açık seçimde; üretim kodu değişmedi. Kanıtlar `audits/turkish-round146-*` dosyalarında.


### Round147 — source aggregate capacity
12 observations:3 lose the shared target despite retained source count4, because intermediate pruning removes count2 before another source adds2. Evidence: audits/turkish-round147-results.json. Latest user now requests implementation closure for all recorded findings, including missed-space suggestions. Resumed audit-only phase is superseded by that request.


### Closure revision — rounds141–147 verified
All seven remaining audit areas are implemented and their recorded cases replayed without the old failure: source chronology18/18, forget/split-import9/9, live-phone14/14, separator35/35, quoted-email143/143, middle-cursor123/123, aggregate-capacity12/12. Ten permanent HistoryClosureRegressionTests cover these and migration/retry/independent-evidence controls. Full Release:545 XCTest,48 exporters skipped,0failures;402 SwiftTesting passed,899 executed passes total. Simulator:15 Decode/Accessibility tests passed including real extension missed-space and selected-word confirmation. Space geometry60/60; technical2000inputs0changes; historical631 confirmed inputs preserved at3offsets. Exploratory yokunuzdan remains excluded per originalround46. Evidence: audits/closure2-summary.json; request checklist: audits/closure2-request-checklist.json. Initial unfiltered UI run was interrupted after entering unrelated AI screenshot tests; the required keyboard suites were then run to completion. Latest phone installation is recorded separately.

Closure2 delivery: latest signed Release installed on connected iPhone14Pro and app launch succeeded (previous lock blocker no longer present). Evidence: audits/closure2-installed-build.json. Physical typing has not been claimed as automated UI evidence.


### Round148 — earlier newlines disable provisional phone replacement
After closure2, the active search goal continued.48 live/persisted-vs-bulk cases expose16 failures: an earlier newline in the message disabled all subsequent provisional-phone supersession. Example: selam\n+90 532 123 45 67 learns two shorter prefixes in addition to the full number. Correction now examines only the current trailing whitespace boundary. Core regression fails before the patch; full validation running. Evidence: audits/turkish-round148-before.json and turkish-round148-summary.json. This qualifies the prior closure claim: prior tested scopes passed, this newly expanded multiline scope did not.

Round148 complete:48/48 cases pass;546XCTest with57diagnostic skips and402SwiftTesting pass (891executed),0failures. Signed Release installed and launched on the physical iPhone. No new native UI evidence is claimed for this learning-only patch; closure2 UI evidence remains its own revision. Evidence: audits/turkish-round148-summary.json.


### Round149 — phone followed by prose punctuation
72 live-vs-bulk/reload cases:32 differ before the patch.28 retain intermediate international phone fragments;8 ending in 。 fail to observe the full phone (4 of these also retain fragments). Comma,semicolon,colon,exclamation,question,ellipsis each expose4 affected grouped-international cases;space/dot controls pass. Observation now tries the intact phone span first, then removes trailing Unicode punctuation while retaining its exact offset; final punctuation closes the provisional occurrence. Validation running. Evidence: audits/turkish-round149-before.json and summary.

Round149 complete:72/72 pass after correction;547XCTest (57diagnostic exporters skipped) +402SwiftTesting,0failures,892executed passes. Signed Release installed and app launch succeeded on physical iPhone. Core callback evidence does not claim a new native UI replay. See audits/turkish-round149-summary.json.


### Round150 — live quoted-mail phantom word/pair evidence
54 cases (7emails +2quoted-prose controls,3leading contexts,2endings).24cases retain extra words from internal quoted mailbox spaces;14retain extra pairs. `mail "First Last"@example.com ` emits mail,First,full address and produces an actual nextWords(after:mail) offer First. All36quoted-email cases retain the full address;12ordinary quoted-prose controls are clean. Phone-specific provisional rollback does not reconcile these word/pair observations. Separate control issue:3ordinary `dev@example.com, ` cases store the comma as part of the token in both live and bulk paths. This shows why live/bulk agreement alone is insufficient; exact address identity must also be asserted. No production edit or phone reinstall this round. Both findings remain open. Evidence: audits/turkish-round150-results.json and summary. Next implementation must retract exact occurrence token AND pair evidence without deleting independent evidence or harming ordinary quoted prose.

Round150 implementation: bounded per-document observation ledger retracts prior word AND pair counts when the full quoted mailbox becomes known;phone replacements keep that ledger consistent. Ordinary quoted prose and independent typed/imported counts are preserved. Shared email suffix normalization also migrates old punctuation-bearing entries and merges their counts;expanded IPv6 domain-literal controls exposed missing classification,now implemented. Initial focused run failed16assertions in the IPv6 control (all ordinary/quoted cases passed);full validation rerunning after that fix. Old phantom word/pair origins cannot be reconstructed,so existing unrelated-looking learned words are not mass-deleted.

Round150 verification:54/54 original replay cases clean,0extra tokens/pairs,42/42email surfaces retained. Permanent regression includes66quoted-mail/prose cases,independent typed/imported token/pair counts,document change,legacy merged counts,32email suffix cases andURL/local punctuation controls.553XCTest with57diagnostic skips plus402SwiftTesting =898executed passes,0failures. Two simulator tests passed (imported-word relaunch and native literal/space/numeric/period),not a native quoted-mail reproduction. Verified Release phone installation underway.

Round150 delivery complete:verified signed Release installed and app launched on physical iPhone. Summary includes binary hashes and logs. No mass deletion of old phantom word/pair records:original provenance was not stored. Active search remains authorized.


### Round151 — rollback retains phantom recency and display
36 comparisons across typed/source-only/mixed prior evidence and live/reloaded states:all token/pair counts match bulk final-text learning,but16suggestion rankings and4display surfaces differ. Quoted-mail pair example:expected sonra|first,actual first|sonra after writing mail "first Last"@example.com. Groupedphone example:expected second visible offer +90 532 999,actual older +90 532 123 after extending that number. `retract` decrements counts without restoring prior seq/surface. Source-only contributions and compact phone controls are clean. This qualifies the prior counts-preservation result;there is no count loss or text-edit corruption here. Confirmed open;no production change orphone reinstall. Next fix needs per-occurrence prior metadata,reverse repeated-key rollback,andprotection for intervening legitimate updates. Evidence:audits/turkish-round151-results.json andsummary.

Round151 implementation:per-occurrence IDs bind bounded transient undo receipts to exact token/pair snapshots. Reverse rollback restores prior metadata;intervening legitimate observations retain their newer display/sequence while counts lose onlythe provisional contribution. Forget andeviction invalidate token/pair undo independently.23focused tests pass,36/36rank/display comparisons nowmatch. Five permanent regressions cover repeated-key rollback,phoneformat/rank restoration,intervening update,forget/relearn,andtoken eviction while a provisional pair remains. Fullvalidation/delivery running. Oldpre-fix metadata cannotbe reconstructed;undo receipts are not persisted.

Round151 verification complete:36/36metadata comparisons match,including archive reload;54/54quoted-email replay remains clean. FullRelease559XCTest with57diagnostic skips plus402SwiftTesting gives904executed passes,0failures. Signed device build succeeds;delivery underway. No new nativeUI claims for this learning-metadata revision.

Round151 delivery:latest verified signedRelease installed andapp launched onphysicaliPhone. Binaryhashes/logs in audits/turkish-round151-summary.json. Active user-requested search remains in progress.


### Round152 — suffix backspace invalidates unrelated learning evidence
63traces with0/1/2trailing characters deleted before final email/phone completion:38learning mismatches,including14full final tokens not learned. All21no-deletion controls pass;all63finaltextstrings arecorrect. Earlier completed quoted-local words remain inthehistory after deleting justthe last typed character,because changed() drops allrecentIDs onany nonappend transition. The same branch resetsobservedStart;standalone emails/phones thenfail theunknown/truncated-start guard despitea modeled local suffix deletion. Four phone edits withpreceding words passbecausephone provisional linkage isseparate. Confirmedopen;production andphoneunchanged. Fixmustpreserve intact-prefix evidence anduse trusted local-edit information forknown-start preservation,notdisable thetruncationguard. Evidence:audits/turkish-round152-results.json andsummary;initial42case output retained separately.

Round152 fix:actual UIKit deleteBackward now records a bounded deletion witness with before/after/document identity. Only matching shortened-before +unchanged-after callbacks retain existing known-start evidence;unknown/truncated context is not promoted. Intact-prefix occurrence IDs survive suffix edits.63/63permanent edit cases pass;fullRelease565XCTest(57diagnostic skips)+402SwiftTesting=910executed passes. Actualextension UI regression now types qrmenüx,backspaces x,then verifies originalpick/numberboundary/period/missedspace;passed. Cancellation andcross-document controls strengthened to use otherwise-exact matching snapshots,focused replay running.


### Round152 delivery and user-request completeness check — 2026-10-10T21:44:55.563614+00:00

63/63 edited learning traces, 910 executed core checks, five strengthened local-deletion controls and the native keyboard extension backspace/literal/space/numeric/period scenario passed. Signed Release installed successfully on the connected iPhone. Launch was attempted but iOS denied it because the device is locked; do not report this build as launched. All recorded requests are mapped in audits/current-request-checklist.json and all 152 audit rounds in closure-review-matrix.json. No confirmed recorded defect remains open; documented historical-data/import-identity limitations remain. Missed-space repair is an explicit two-word offer (60/60 geometry probes and native merhababdünya → merhaba dünya selection), not forced autocorrection.


### Round153 — short and single-letter missed-space gaps

Production-pack coordinator probe: 88 inputs, 68 absent intended phrase offers; 58 have unknown joined tokens despite both components being known. Remaining 10 are known-word ambiguity cases, not counted as unambiguous failures. Examples: nebki → ne ki, iyiki → iyi ki, suiç → su iç, obzaman → o zaman. Length>=6 and minimum two-character split sides explain exclusions. Lower/title-case results agree. Earlier 60 geometry probes covered longer pairs and did not establish short-pair coverage. No production edits or new installation this round. See audits/turkish-round153-summary.json.


### Round153 fix and delivery — 2026-10-10T21:48:30.509248+00:00

Repair now includes short tokens and the single-letter Turkish pronoun o, while standalone symbols/letter names remain excluded. All 78 eligible unknown-joined-token cases offer the expected phrase and exact picks pass (58 previously missing). Ten valid joined-word ambiguity cases remain conservative; not claimed as repaired. Literal remains unchanged until explicit selection. 913 executed core checks pass; 2000 technical inputs unchanged. Native simulator extension iyiki → iyi ki and obzaman → o zaman picks pass alongside existing checks. Release installed successfully; no launch retry after previous locked-device denial. Mac Release suggestion p95 1.821 ms; not phone latency.


### Round154 — learned nominal forms excluded from phrase repair

216 production-pack coordinator probes across three roots, four forms, two phrase positions, three separators and three personal profiles. All 36 admitted base-word controls offer the phrase; all 72 unlearned controls exclude it. All 108 learned nominal continuation cases are recognized by personal morphology but lack the intended phrase offer. Examples: qrmenüdenbaç → qrmenüden aç; buqrmenüler → bu qrmenüler. Boundary search reads LiteralChannel only; personal inflection protection is a separate coordinator API. One integration gap, not108 independent bugs. Diagnostic evidence only; production remains deployed round153. Next:share bounded personal-form recognition/cost, test forgetting and unknown-root exclusions, measure latency.


### Round154 fix and delivery — 2026-10-10T21:52:20.857200+00:00

Boundary repair accepts a scoped personal lexical-cost provider, caches recognized and rejected substrings, and guards whole recognized forms from splitting. All 144 learned/imported phrases offer and select the exact result;72unlearned controls exclude them. Forget and no-automatic-replacement controls pass. 916 core executions pass; actual simulator extension qrmenüdenbaç → qrmenüden aç pick passes. 512admitted shared-prefix roots: Mac Release typing+suggestions p95 1.60ms, max1.68ms,144samples;not physical phone latency. Signed Release installed successfully; no launch retry after previous locked-device denial.


### Round155 — selected-word phrase repairs suppressed

36 production-pack coordinator traces: six ordinary/short/personal inputs across six modes. All12typing/reopened cases offer and pick the correct phrase;all18selected-word cases (typed,host,padded) lack it. Six detached controls remain intentionally excluded and are not defects. Cause:boundaryRepairs explicitly rejects selection despite verified selection edit machinery. Examples: select merhababdünya or qrmenüdenbaç and intended phrase disappears. One gate defect,not18bugs. No production changes or new deployment;current installed build154. Next:enable selection repair while preserving edge whitespace,exact replacement and stale-selection guards;keep detached safety gate.


### Round155 fix and delivery — 2026-10-10T21:55:06.488056+00:00

Removed only the selected-word exclusion from explicit phrase repair;detached guard retained. All18selection cases now offer and select expected phrases;36trace exact-text assertions pass including edge whitespace,typing,reopened and detached controls. Changed/cleared selection rejects stale picks;multiword selections are not resplit. 916executed core checks pass. Two actual simulator extension tests pass:UIKit double-tap selected phrase repair with continued typing,and original literal confirmation. Signed Release installed;no physical launch or typing claim.


### Round156 — long inflected phrase repair cutoff

48production-pack traces:allword components recognized andallliteral/document text exact. Eight combined inputs<=32 offer expected phrase;34inputs33–40 and6inputs>40 do not. Both typing and selection affected. WordBoundaryRepair hard32character limit excludes long Turkish inflected pairs before split search. One length gate,not40bugs;no text loss. Next:bounded two-word length contract derived from per-component lexical limits,exact-pick controls andworst-case latency. Production remains installed155.


### Round156 fix and delivery — 2026-10-10T21:59:00.679748+00:00

Explicit repair supports two lexical components of up to40characters each plus one optional adjacent-letter mistap(max81). Per-component limits remain enforced. All48production traces offer and pick exactly;boundary andnegative controls pass.919core checks pass;native simulator46character phrase pick passes. Mac Release typing+suggestions368samples:p95 1.763ms,max2.154ms;not phone or exhaustive81character performance. Latency scope label originally said44;corrected to46 without changing timings. SignedReleaseinstalled;no physical launch/typing claim.


### Round157 — phrase pick learns only final token

24production coordinator+extension-shaped history traces:four phrases,two contexts,typed/missing-space-pick/mistap-pick. All8typed controls matchfinal-text learning. All16picks omitfirst-token count;8with preceding önce alsoomit incoming pair andnextword suggestion. Example:önce merhaba dünya learns dünya andmerhaba→dünya butnot merhaba nor önce→merhaba. These failurecounts overlap. Allfinaltext correct;all24backspace tails correct. CurrentTypingHistory.observe calls one HistoryObservation.completed which emits only finalword. Corecallback evidence,notnative persistentstore proof. No productionchanges;installed156. Next:trusted explicit committed-span learning,exactly-once occurrence attribution,priorcounts,repeatedcallbacks,selection/reopen controls;do notbulk-rescanhostcontext. Initialozaman fixtureexcluded asalreadyknownjoinedword;finalprobeuses suiç.


### Round157 fix and delivery — 2026-10-10T22:07:29.074942+00:00

Explicit non-selection phrase picks provide a verified replacement span to history observation. Every inserted plain word andincoming pair is learned,normal final-boundary callback deduplicates,andreopening a previously observed typo retracts only that occurrence. Existing host prefix is not relearned. API bounded2–8words/256characters;selection edits/technical completions are separate existing paths. 24learning comparisons clean;923executed core checks pass. Initialnative test failed becauseUIKit reportsnil right context at end;boolean-only diagnostic established this. Optionalright snapshots nowcompared directly whilefullleftspan mustmatch. Temporarylogs removed. Finalnative test usesfresh randomprefix,assertsno priorprediction,thenverifiesnewmerhaba prediction afterphrasepick. Releaseinstalled;no physical launch/typing claim.


### Round158 — selected phrase history reconciliation

24production coordinator/extension-shaped observation traces:three inputs,two precedingcontexts,priorindependent evidence yes/no,selectedseparator yes/no. Everyfinaldocument correct. All24retain oneextra oldtyped occurrence andomitcorrected firstword. Twelvepreceded cases missincomingpair andnextword. Withpriorindependent oldword,thecorrectoldcount is1butactual2;do notdeletealloldword evidence. Selection currentlyexcluded fromphrase-learning hook,andcontextChanged atselectionstart discardsrecent occurrence linkage. Oneintegration/provenance gap;failurecounts overlap. No productionchange;installed157. Next:verifiedselectionreplacement witness preservingown-occurrence identity,stale/unknown-origin controls,padding andincoming/outgoing context.


### Round158 fix and delivery — 2026-10-10T22:18:17.822873+00:00

Immutable verified selection replacement witness captures anchored occurrence receipts. Unchanged visible before/selected/after snapshots retain linkage. Only owned oldtoken andowned outgoingpair occurrence are retracted;independent priorcounts retained. Every inserted word/incoming pair observed once;outgoing knownpair retargeted without nexttoken count duplication. Unknownorigin never causes speculative rollback. ActualUIKit emptycontext requires hasText=false witness;nil alone remainsunknown. Native diagnostics showed readSelection incorrectly calledlearning completion before supplyingselected snapshot;hostcursor/selection callbacks nowperform calibration boundary only thenfullcontext refresh. Alltemporary diagnostics removed.

LegacyFakeDocument putcaret atdocument end afterselection;newprivateSelectionCursorDocument preservestrue insertioncaret. Original24baseline retained;refinedlegacy-path replay gives24token and18pair mismatches. All24fixedcases nowmatchcounts. Outgoing,padding,independentcounts,repeated/stale/crossdocument/unknownorigin controls pass.926core executions pass. Twoactualsimulator tests pass: selected correction addsrightprediction andremovesoldwrongprediction usingfresh explicitlyaccepted context;plainphrase learning remainsworking. SignedReleaseinstalled;no physical launch/typing claim.

### Round159 — punctuation after a selected phrase repair

Rechecked all 12 user-request mappings and all 158 existing audit rounds: no missing index/matrix entries or missing indexed evidence files. Expanded the outgoing-pair selection test to 8 trailing punctuation variants × 2 selection padding shapes. Before the fix, 14 of 16 pair comparisons failed while all token counts matched: `merhababdünya → sonra` retained an extra occurrence and `dünya → sonra` was missing after selecting `merhaba dünya` before `sonra,`. Independent prior evidence and repeated replacement callbacks are included in each case.

The outgoing span now uses the ordinary history tokenizer for word identity while keeping its exact raw body for ownership verification. Only a matching owned occurrence is reconciled. Full core and native simulator verification are running; phone still has round158 until the new build is verified and installed. Evidence: `audits/turkish-round159-baseline.log`, `audits/turkish-round159-summary.json`.

### Round159 verification and delivery — 2026-10-10T22:22:55.748630+00:00

All16 punctuation/padding cases now have exact expected token and pair counts, preserving independent prior history and suppressing duplicate callbacks. Full suite:585 XCTest minus61 opt-in skips plus402 Swift Testing =926 executed checks,0failures. Two real simulator keyboard tests passed: literal/number/period/short and long phrase repairs, and selected phrase new/old prediction reconciliation. Signed Release build and connected iPhone install succeeded. No physical launch or typing claim. All12 user-request mappings updated and all159 audit rounds indexed; no confirmed open defects at this checkpoint. Search goal remains active.

### Round160 — punctuation immediately adjacent to selected source

24 production coordinator selection picks with full extension-shaped history callbacks:12 contexts × with/without independent prior evidence. All final texts exact.20 rejected learning witnesses,20 token and20 pair comparisons differ; these overlap and are not separate bug counts.16 first-word deficits and18 excess old-word counts. Plain whitespace4 controls pass. `önce merhababdünya, ` → selected repair → `önce merhaba dünya, ` leaves old count1 instead of0 and first count0 instead of1. Unlike round159, punctuation is directly outside selected source rather than on the following word.

Root cause: selection witness boundaries allow only whitespace/document edges. Broader guard alone would still fail occurrence ownership: the original completed body includes trailing punctuation. Safe fix needs exact span/receipt reconciliation and technical substring controls. Four curly/single-quote cases also expose plain tokenizer conventions, so their expected zero first-word counts must not be mistaken for desired behavior. Exporter success only confirms generated rows and exact final text, not clean learning comparisons. No production edits or phone reinstall this round; installed159. Confirmed open and request/closure records reopened. Evidence:audits/turkish-round160-summary.json and results/log.

### Round160 implementation — punctuation span ownership

Selection witnesses now inspect complete adjacent non-whitespace fragments: only prose opening/closing punctuation or a matched single-quote pair may surround the selected word. URL/email/path/extension/word/inflection fragments remain rejected. The witness captures the ordinary tokenizer identity and raw trailing punctuation. Old occurrence matching includes that punctuation; inserted-span replay includes it without modifying host text. Outgoing pair matching skips the old punctuation span, preserving exact body ownership.24focused comparisons now match independently typed final text, including4quote cases under existing tokenizer semantics. This does not claim to improve smart/single-quote lexical normalization itself. Full-suite and native tests running.

### Round160 verification and delivery — 2026-10-10T22:28:01.291438+00:00

All24 token/pair comparisons asserted and passed;10 URL/email/path/extension/partial-word/inflection boundaries rejected.928executed core checks pass (587XCTest−61opt-in skips+402SwiftTesting). Actual simulator keyboard period-adjacent selection test adds correct incoming prediction and removes old wrong prediction;plain selection control also passed. Release signed build and connected iPhone installation succeeded. No physical launch/typing claim. Recorded selection defect closed;quote tokenizer semantics remain a future investigation, not changed by this fix.

### Round161 — independent quoted-prose normalization oracle

72 comparisons:6quote/parens wrappers×3phrases(single word,multiword,internal Turkish apostrophe)×2prefixes×live/bulk learning. Expected history comes from independently typed unquoted prose, not the tokenizer output under test.32token and32pair mismatches overlap:straight single quote12/12,curly single quote12/12,curly double quote8/12. ASCII double quotes,guillemets,parentheses36/36pass. Twelve quoted-email,apostrophe-email/URL,Ankara'ya ande-posta identity controls pass. Example:“merhaba dünya” yields “merhaba anddünya” identities;ordinary merhaba→dünya prediction absent.

Root cause:per-whitespace-token balanced wrapper stripping cannot normalize a multiword curly quotation;single quote edges never stripped. Prior160 ensured selection matched independently typed text underexisting tokenizer;this neworacle exposes lexical normalization itself.32failures are not32bugs. Passing exporter only proves controls/evidence export,notclean comparisons. No production change orreinstall;installed160. Safe follow-up must preserve internal Turkish apostrophes,quotedemail localparts,URLs/paths andpartialtechnical contexts. Evidence:audits/turkish-round161-summary.json/results/log.

### Round161 implementation and core verification

For non-technical whitespace tokens, natural-word interiors now lose combined prose punctuation and straight/curly quote edges. Technical URL/email/path/dot-prefixed tokens retain previous behavior;quoted email grouping still precedes prose tokenization. Internal apostrophes are unchanged. Normalization is local to history tokenization,not global Punctuation orisWord semantics.72independent-oracle live/bulk comparisons nowassert exact token/pair counts andallpass. Twelve learning identity controls plus19additional direct tokenization cases cover internalapostrophes,URLs,paths,dotfiles,code,nested wrappers andpunctuation. Full suite589XCTest−61skips+402SwiftTesting=930executed passes. Simulator/import persistence anddevicebuild verification inprogress. Older archived quote-bearing identities are notmass-rewritten bythisfix.

### Round161 delivery — 2026-10-10T22:32:02.261490+00:00

Two simulator regressions passed:imported-word persistence afterrelaunch andactual keyboard punctuation-adjacent selection prediction reconciliation.72quote comparisons and930core executions pass;Release build/install succeeded. No physical typing/launch claim. Quote fix applies to newobservations;oldarchived quote-bearing entries notmass-rewritten. Allround161status/evidence records updated;search remainsactive.

### Round162 — internal curly apostrophes and missing history pairs

48cases:6suffixed names/terms×ASCII/U+2019apostrophe×quoted/unquoted×live/bulk. All48token surface counts exactly1.24ASCII controls haveexpectedincoming/outgoing predictions. All24curly variants failwordclassification andomit bothpair directions:oncehistorycontainsAnkara’ya,neitheronce→Ankara’ya norAnkara’ya→gittim isavailable. (Actualprefix infixture:önce.) PersonalHistory.isWord onlyacceptsASCIIapostrophe,forcingcurlywords throughtechnicalidentity classification. Counts overlap,not72bugs.

Exporter passing assertsASCIIcontrols andevidencegeneration only. This provescurlyspelling itself losesnaturalwordpairs,notthatASCIIandcurlyidentitiesmustmerge. No productionedit/reinstall;installed161. Follow-up musttestcase,archivedidentitymigration,forget,quotes andtechnicaltokenprotection. Evidence:audits/turkish-round162-summary.json/results/log.

### Round162 fix and delivery — 2026-10-10T22:35:27.585981+00:00

PersonalHistory.isWord acceptsU+2019onlybetweenletters;leading/trailing/doubledcurlyquotes remainnonword,technicalidentity preserved.48live/bulk quoted/unquoted cases nowassert bothpredictiondirections andexactcounts. Legacyuppercase tokenkeys merge usingexistingdecode migration;latest surface/counts retained. Newpairs survivearchiveroundtrip,uppercasequery andforget clearsbothdirections withoutdeletingneighbors. Technicalcurlymailbox/URLpath casevariants remainexact. Historical omittedpairs cannotbereconstructed,so nofabricatedcontext. ASCII/curly identities remainseparate.933coreexecutions pass (592XCTest−61skips+402SwiftTesting). SignedReleasebuiltandinstalled. No newnativeUIrun orphysicaltyping/launchclaim;latestUIevidence161. Allstatusrecords closedwithscoped evidence;searchremainsactive.

### Round163 — cursor return duplicates an already learned occurrence

24traces:6right contexts×independent prior evidence yes/no×directend/via-document-start cursor movement. Threeextra separators pertrace;nonew words. All24immediate post-selection repair token/pair comparisons assertcorrect. Aftercursorreturn,22traces emitoneextra event;tokenandpair counts eachdiffer in22cases. Straight plainend2controls clean;movingvia start can duplicateevenplainphrase. Punctuation andoutgoing-word casesduplicatewithoutthatdetour. Example:dünya count1 becomes2 afteronlycursor movement andspaces. Laterseparator callbacks do notmultiplyfurther.

Cause:lastCompletedContext clearswhen beforecontext shrinks;retained owned occurrence receipts existbutcompleted onlydeduplicates thatonestring. No nativeUIclaim;coreextension-shaped callbacks. Exporter pass validatesinitialstateandgeneratesdiagnostics,notpost-cursor correctness. No productionedit/reinstall;installed162. Fixmustuseverifiedsame-occurrenceidentity,notglobalworddedup,andpreservegenuinenewoccurrences,documentisolation,provisionalphone/email/localdeletion andtruncatedcontext controls. Evidence:audits/turkish-round163-summary.json/results/log.

### Round163 implementation — anchored occurrence deduplication

completed now consults retained exact-body occurrence receipts onlywhen observedStart anchors the document. This supplements thelastCompletedContext cache aftercursor/selection moves. Incompatible editprefixes invalidate receipts throughchanged;another genuineoccurrence hasadifferentfullprefix. Stableanchoredcursor moves alsokeep provisionalphone linkage,preventing partialnumber residue afterreturnandcontinuation.24post-cursor cases nowassert0events andexactcounts;newcontrols coverrepeatedword atnewposition,delete/retype,newdocument andprovisionalphone continuation. Fullcore/nativechecks running.

### Round163 verification and delivery — 2026-10-10T22:39:25.477324+00:00

All 24 traces now assert exact token/pair counts with zero extra observations across 72 separator callbacks. New occurrence at another position, deletion/retyping and another document still count independently. Cursor return during provisional phone entry preserves reconciliation. Full suite: 595 XCTest minus 61 skipped exporters plus 402 Swift Testing = 936 executed passes. Two actual simulator keyboard selection/prediction regressions passed. Signed Release build and connected iPhone installation succeeded. No physical typing or launch claim. Occurrence identity remains bounded and requires an observed document start; no unsafe global token deduplication. All round163 status records closed with scoped evidence; search remains active.

### Round164 — successive phrase selections, both orders

24 production coordinator traces: merhababdünya→merhaba dünya and iyiki→iyi ki, corrected in either order, with space/comma/semicolon separators, optional preceding word and independent prior history. UIKit-caret fixture supplies exact before/after selection snapshots. After each correction, learned token and pair counts compared against prior evidence plus independently learned current document. All 48 intermediate comparisons clean; all 24 final texts exact. Exported rows inspected directly.

This extends evidence for receipt rebasing and adjacent outgoing-pair reconciliation across two successive edits; it is not a proof for arbitrary edit sequences or a native UI run. No production change or phone reinstall. Installed production remains163, whose936core/2native verification remains the latest broad binary evidence. Goal continues. Evidence:audits/turkish-round164-summary.json/results/log.

### Round165 — prose-wrapped technical addresses lose exact recall

48 comparisons: URL, URL query with internal apostrophe, ordinary email and quoted-space mailbox × unwrapped/ASCII double/ASCII single/curly double/guillemets/parens × live/bulk learning. All 8 unwrapped controls assert correct count and exact observed completion.14 wrapped rows fail both address count and exact completion:12 ordinary URL/email variants retain outer ASCII quotes;2 live quoted-mailbox variants (single/curly outer quotes) omit the address entirely.

Distinct mechanisms: technical-token fast path preserves unrecognized outer wrappers; after grouped quoted-email extraction, a standalone closing single/curly quote survives token filtering and becomes completed's last token, so live observation misses the real address whereas bulk iteration learns it. Preserve inner quoted mailbox syntax and URL query/path apostrophes when fixing. Counts overlap, not28bugs. Exporter pass only establishes8controls andevidence generation;all48rows inspected. No production edit/reinstall;installed163. Evidence:audits/turkish-round165-summary.json/results/log.

### Round165 implementation — outer technical quotes and leftover markers

Recognized complete URL/email interiors may lose one balanced outer ASCII quote pair; a mailbox's own quotes end before @ and remain intact. Existing path/query/case spelling stays exact, and unbalanced wrappers remain untouched. Prose-only leftover quote fragments now disappear from tokenization, letting live grouped-address observation see the address. An additional ordinary-boundary guard rejects a separate punctuation-only final piece instead of relearning the preceding word; grouped phone formatting is handled before this guard.

Initial full suite passed (598 XCTest−62 skips+402 Swift Testing) and48 address comparisons were clean. Added the separate-closing-marker count regression and guard before final verification. Final full suite, simulator integration checks and device build running.

### Round165 verification and delivery — 2026-10-10T22:46:24.024587+00:00

All48 address identity and exact observed completion assertions passed; all exported stored surface lists contain only expected address,adres,sonra. No provisional First or quote artifacts. Added12 identity controls,7empty-fragment cases and4standalone closing-marker no-relearning cases. Final suite599XCTest−62skips+402SwiftTesting=939executed passes. Two simulator regressions passed: imported words after relaunch and real keyboard punctuation-adjacent selection learning. Release build/install succeeded. No physical typing or launch claim. Older malformed wrapper identities are not mass-rewritten by this tokenizer fix. Allround165status records closed with scoped evidence; search remainsactive.

### Round166 — punctuation outside a technical address wrapper

Expanded round165 to168comparisons:48previous controls plus120explicit wrapper+comma/period/semicolon cases. All48controls clean.90newcases lose both exactstored address andobserved completion:60URLs,30ordinaryemails.30quoted-mailbox suffixcases remainclean because grouped extraction identifies theaddress. Example:"https://example.com/Docs", retainsouterquotesandcomma,sohttps://example.com/D offersnothing.

Root cause:wrapper recognition requires closingdelimiter atabsolute tokenend;outside punctuation hidesit. Newcases haveexplicit enclosing delimiters,so thisauditdoesnotdeclareunwrapped URLcommas invalid. Correctfix mustparsewrapper+externalprosesuffix whilepreservinginternal URLquery/path punctuation andquotedmailbox syntax. Counts overlap,not180bugs. Diagnostic exporter success assertspreviouscontrols only;all168rows inspected. No production edit/reinstall;installed165. Evidence:audits/turkish-round166-summary.json/results/log.

### Round166 implementation — explicit wrapper and external suffix parser

A shared bounded helper recognizes explicit matching outer delimiters, skips only allowed punctuation outside the closing delimiter, and returns an interior only when it is a complete recognized URL/email. Up to8 nested wrappers are supported. Unbalanced or unwrapped URL tails are unchanged; historical prose/path fallback behavior remains separate. The previous ASCII-only address branch is replaced by this helper. All168 learning/completion cases now assert exact results on every normal test run. Additional25 nested/external-wrapper cases,5 bare-address identities and5 unbalanced/unwrapped tails protect URL parentheses,commas,query punctuation,apostrophes andcase. Core/native/device verification running.

### Round166 verification and delivery — 2026-10-10T22:51:58.233755+00:00

Initial expanded core run found one nested-email failure: (“Dev@example.com”); was classified before stripping inner Unicode quotes. Parser now peels all matched layers before URL/email classification, capped at8layers. Failure log preserved. Final168 identity/completion cases and35 additional boundary controls pass; all stored surface lists exact. Final600XCTest−62skips+402SwiftTesting=940executed passes. Two final-code simulator regressions passed; signed Release build/install succeeded. No physical typing or launch claim. Existing malformed archived wrapper entries are not rewritten. All round166 status records closed with scoped evidence; search remainsactive.

### Round167 — quoted-space mailbox with IP address-literal domain

RFC5321§4.1.2 allows quoted-string local parts and address-literal domains;§4.1.3 definesIPv4/IPv6forms. Primarysource:https://www.rfc-editor.org/rfc/rfc5321.html#section-4.1.2.48cases:4localparts×DNS/IPv4/IPv6domain×2endings×live/bulk. Allclassifyasemail.16normaldomain controls assertpass.16literal-domain cases withspace-bearing quotedlocalpart losewholeaddress learning andexactcompletion. Directly seedingthecorrectaddress stillfailscompletion inthose16rows,isolatingasecond parserpathissue.

PersonalHistory grouped-email regex excludesbracketeddomains;TechnicalTextSpan quotedlocal scanner permits onlyDNScharacters after@ andstopsat[. Bothfallbacks splitatlocalpart spaces. Nonspace quotedlocal andunquotedlocal forms pass. Failurecounts overlap,not48bugs. No productionedit/reinstall;installed166. No email sentorreachabilityassumption. Evidence:audits/turkish-round167-summary.json/results/log.

### Round167 implementation — bracketed email domains

Grouped quoted-email recognition includes IPv4 and tagged IPv6 bracketed domains; the existing complete-address classifier gates extracted groups. Quoted cursor scanning now distinguishes DNS and bracketed domain states and stops at the closing bracket, leaving prose outside the replacement. Joined non-prose text after a completed literal rejects that span. Complete email classification now validates bracket pairing and actual dotted IPv4/IPv6 syntax rather than accepting any dotted bracket content.

Initial48 learning/direct-completion cases now assert andpass. Added escaped/local-@ quoted mailbox middle-cursor letter/number omissions with exact right-tail preservation, invalid literal domains, mismatched tails andjoined suffix controls. Fullcore/native/device verification running.

### Round167 verification anddelivery — 2026-10-10T22:57:52.287076+00:00

All48cases nowassert exactaddress count,learned observedcompletion anddirectseeded completion. Allstoredsurface lists matchaddress+adres+sonra;no provisionalfragments remain.102letter/number omission repairs across6quoted mailbox/IPv4/IPv6addresses preserveexactrighttail andprose;7invalidliteral,3joinedtail and1mismatchedtail controls pass. Full603XCTest−62skips+402SwiftTesting=943executed passes. Two simulator integration regressions pass;Releasebuiltandinstalled. No physicaltyping/app-launch claim or email send. Historicalfragments notmass-deleted. Allround167records closedwithscoped evidence;searchremainsactive.

### Round168 — Turkish/Unicode domains with quoted-space mailbox

64cases:dev,çağrı,quoted First Last,quoted Çağrı Şen × example.com,örnek.com,mail.örnek.com,mail.api.örnek.com ×2endings×live/bulk. Allclassifieraccepted.16ASCIIdomain controls assertpass;24unquotedUnicode cases clean. All24quotedspace Unicode-domain cases failwholeaddresslearning andcompletion,includingdirectseededcompletion. Bulkcanlearn truncated "First Last"@mail.api plus .örnek.com ratherthanthefulladdress;live canretainFirst and.örnek.com fragments.

Grouped regex andquoted cursor scanner onlyallowASCIIDNScharacters. Regexcanaccept avalid-lookingASCIIprefix beforeaUnicode label;scannerfallsbackatlocalpartwhitespace. Primarysyntax source:RFC6531 https://www.rfc-editor.org/rfc/rfc6531.html (SMTPUTF8/U-labels). No maildelivery/reachabilityclaim. Failurecounts overlap,not72bugs. No productionedit/reinstall;installed167. Evidence:audits/turkish-round168-summary.json/results/log.

### Round168 implementation — Unicode domain characters

Grouped quoted-email DNS recognition now consumes Unicode letters,numbers andcombining marks instead of accepting only anASCII prefix. Quoted cursor DNS scanning accepts corresponding Unicode alphanumeric/mark scalars whilethe bracketed IP-domain branch remainsASCII.64learning/directcompletion cases nowassert exact fulladdress andexactly3history tokens (address+adres+sonra),preventing hiddenfragment entries. Initialfocused casespass. Additional domaincase/mailboxidentity/archive/forget andNFD/NFC/ASCIIrighttail checks added beforefull verification. Existing nonASCIIrighttail editing gate remainsunchanged.

### Round168 verification anddelivery — 2026-10-10T23:03:12.398304+00:00

All64cases assert exactaddress count andlearned/direct completion;history contains exactlyaddress+adres+sonra,withno truncatedASCII domain orprovisional localpart. Domaincase folding,mailboxcase distinction,archiveroundtrip,forget andNFD/NFC countmerging pass. Unicodeprefix+ASCIIrighttail completion preserves exactdocument;existingnonASCIIrighttail gate unchanged.606XCTest−62skips+402SwiftTesting=946executed core passes. Two simulator integration regressions passed;Releasebuilt/installed. No physicaltyping/app-launch ormail-delivery claim. Oldtruncated fragments notretroactivelydeleted. Allround168records closedwithscoped evidence;searchremainsactive.


## Round169 — Composite email learning and completion

672 combinations of quoted/ordinary local parts, Unicode/DNS/IPv4/IPv6 domains, wrappers, punctuation and live/bulk observation were inspected row by row. All retain the exact address once, produce no extra stored surfaces, and offer exact learned completion. No new defect or production change. Installed Release remains round168. Evidence: `audits/turkish-round169-summary.json`.


### Current request closure recheck

All12 recorded request headings were checked against implementation and closure evidence. Missing/mistapped-space, short phrases, personal inflections and selected-phrase regression suite:13 executed tests pass (2opt-in exporters skipped). Actual simulator keyboard tests for typed and selected phrase repair both pass, also exercising qrmenü and numeric return. No production change; installed Release remains round168. Known confirmed open defect list is empty, with historical data/ambiguous WhatsApp overlap limits retained. Evidence: `audits/current-request-closure-summary.json`.


## Round170 — Joined technical suffix creates a phantom imported email

96 live/bulk observations of quoted mailboxes with DNS/Unicode/IPv4/IPv6 domains followed by /path, _backup, =value, @other.com, #fragment or +tag. All48bulk observations wrongly learned the embedded address and offered it as observed;48live observations did not. The grouped regex accepted a prefix without validating its following boundary. The fix checks the next complete Unicode character and rejects joined technical tails, without copying the rest of the imported text. Baseline remains preserved; final validation pending in `audits/turkish-round170-summary.json`.

Round170 final:96/96 rows have zero phantom address counts and observed completions;947 executed core tests and2 actual simulator UI regressions pass. Signed Release installed on iPhone; no launch or physical typing claim. Baseline retained. Older erroneous entries without origin metadata are not mass-deleted. Summary: `audits/turkish-round170-summary.json`.


## Round171 — Joined prefix creates a phantom observed email

96 observations combine6technical prefixes(path/,user+,prefix,backup_,other@,value=),2quoted mailboxes,4DNS/Unicode/IP domains andbulk/live paths. All96learned the embedded address andoffered it as observed. Regex matching had no left boundary. Fix requires start,whitespace or opening prose delimiter before grouped email. Preserved baseline: `audits/turkish-round171-results.json`; validation tracked in `audits/turkish-round171-summary.json`.

Round171 verified:96negative rows have no phantom address or observed completion;672positive wrapper/domain rows retain exact address,count andcompletion.949core executions (including enabled composite exporter) and2simulator UI regressions pass. SignedRelease installed;no physical typing orlaunch claim. Existing untraceable phantom entries retained. See `audits/turkish-round171-summary.json`.


## Round172 — Known words must not be split

18words ×3profiles(none/accepted/imported) ×3caseforms =162production-pack cases. With real shifted-letter routing all162surfaces remain unchanged at space;153knownword rows produce no two-word offers.9unseeded unknown cases remain literal too;6may offer an explicit split,which is allowed. Initial fixture incorrectly sentuppercase to the unshifted API andshowed34apparent changes;those are harness artifacts,not counted product bugs. Corrected evidence:`audits/turkish-round172-corrected-harness.json`. No production change or reinstall;phone remains171.


## Round173 — Shifted missing/mistapped space offers and picks

360cases:12pairs ×10separator forms(missing or9adjacent letters) ×lower/title/caps. Real shifted-letter API used foruppercase.342eligible repairs allretain literalfirst,offer correctly cased two-word candidate andproduce exact chosen text.18knownjoined controls do not offer the split. Rows inspected independently of exporter exit. No product defect orproduction change;phone remains171. Evidence:`audits/turkish-round173-summary.json`.


## Round174 — Editing after phrase repair

144traces(sixphrases ×threecaseforms ×twoprefixes ×fouractions) preserve exact expected text.36space-cycle traces reveal firstreopen detached finalword,then empty composing state onsecond/third reopen. finishToken intentionally excludes detached tokens from evidence history;this explains transition but doesnot establish UI correctness. Native suggestion strip followup is pending,not counted as confirmed product defect. No production change;installed171. Evidence:`audits/turkish-round174-summary.json`.


## Round175 — Native confirmation of lost literal after repeated reopen

Round174 hypothesis confirmed by actual simulator keyboard:literal suggestion exists onfirst reopen but disappears oncycles2and3. A verified reopened detached surface is now retained with explicit detached provenance andrestored withouttouches orliteral evidence. Arbitrary adopted detached surfaces remain excluded.144core editing traces nowkeep exacttext andrestored finalword.949fullcore tests and2nativeUItests passed. Additional recorder cycle/reload validation running;summary:`audits/turkish-round175-summary.json`.

Round175 final:strengthened recordingtest passes after3additional reopen cycles,capture/reload andSessionValidator. SignedRelease installed onphone;no physicaltyping claim. Round174followup closed. All144traces nowpreserve finalword composing state. See `audits/turkish-round175-summary.json`.


## Round176 — Suffix edits after repeated phrase reopen

216production-pack traces:4phrase repairs ×3suffixes ×3caseforms ×3prior reopen counts ×2prefixes. Each row checks literalfirst availability,detached evidence withouttouches,exactcommit,exactreopen andexacttext aftersuffix removal. All1080checks clean. No production change orreinstall;phone remains175. Core evidence only. Summary:`audits/turkish-round176-summary.json`.


## Round177 — Symbols after reopened phrase repair

192core traces:4phrases ×3caseforms ×8symbol sequences ×2prefixes. Checks exact insertion/removal,literal availability,detached finalword restoration andexact continued typing. All960checks pass. Sequences include punctuation,digits,repeatedspace andfamilyemoji. Fixture grapheme deletion doesnot prove UIKit deletion;no newnative run. No production change;installed175. Summary:`audits/turkish-round177-summary.json`.


## Round178 — Actual compound emoji deletion

Native keyboard test inserts3catalog emoji(🇹🇷,🏳️‍🌈,🏴‍☠️) after repaired phrase,using bothnormalbackspace andemoji-panelbackspace.6scenarios retain exact surrounding text,remove thewhole selectedemoji withone delete,andappendx at correctposition.1UItest passes. This strengthens round177 UIKit coverage for3entries;familyemoji still onlycoretested. No production change/reinstall;phone remains175. Evidence:`audits/turkish-round178-summary.json`.


## Round179 — Repeated phrase reopen must not inflate learning

24traces(4phrases ×2contexts ×3typed/picked modes),8reopens each,3boundarycallbacks perreopen.192observations and576callbacks emit zeroadditional learning events. Independent bulk token/pair counts match;canonical personalhistory archive remains byteidentical;alltext exact. Actual deletion intent isregistered before eachbackspace. No production change;phone remains175. Core callback evidence,not newnativeUI. Summary:`audits/turkish-round179-summary.json`.


## Round180 — Genuine retyping still counts

24initial traces ×4fullfinalword retypes=96observations. Unlike separator toggling,a fullydeleted thenretyped word isindependently learned once. Token/pair counts match independently accumulated expected history;prefix/finaltext exact;3extra completioncallbacks preserve archive fields. All480row checks pass. Core fixture evidence;no production change;installed175. Summary:`audits/turkish-round180-summary.json`.


## Round181 — Missing @ after quoted mailbox discards right context

1096Unicode cursor combinations exposed8invalid observed completions. When @ wasomitted immediately afterclosing mailboxquote,the cursor scanner returned acomplete prefix span with empty righttoken despite anattached domain. Applying completion duplicated domaintext. Scanner nowinvalidates span onunexpected character there;conservativefallback preserves rightcontext. All8invalid offers removed;268valid observed offers retained;no changed snapshot accepted orredundantcomplete offer.950core executions and2native integration regressions pass;Releaseinstalled. Unicode behavior iscore evidence,not nativecursor orphysicaltyping. Missing@isnot automaticallyrepaired. Summary:`audits/turkish-round181-summary.json`.


## Round182 — Technical interruptions inside quoted-email DNS domains

72cases(2locals ×2domains ×3offsets ×6technicalmarkers) discarded attached rightdomain andoffered fulladdress before it. DNS span scanner nowinvalidates nonprose technical boundaries.72unsafe offers removed;1096Unicode cursor controls preserve268valid observed offers;672composite email learning/completion rows pass.952core executions(including enabledexporter),2native integration regressions pass;Releaseinstalled. IP literal branch separate;no physicaltyping claim. Summary:`audits/turkish-round182-summary.json`.


## Round183 — Invalid character inside IP email literal discards righttail

72cases(2quotedlocals ×2IPv4/IPv6literal domains ×3offsets ×6markers) reproduced unsafecompletion with empty righttoken. Parser nowinvalidates interrupted unclosedliteral ratherthan treating remainingliteral asprose.72unsafe offers removed;672composite email controls pass;953core executions and2native integration regressions pass. SignedReleaseinstalled. Native tests aregeneral regressions,not IPcursor typing;no physicaltyping claim. Summary:`audits/turkish-round183-summary.json`.


## Round184 — Phone completion must not discard attached technical tail

72cases exposed60unsafe completions;12were already withheld becauseprefix endedinspace. Phone scanner nowrejects nonprose character immediately after consumable rightdigits unlesswhitespace separates it. All72negative cases pass;4additional attached-tail controls and4separated-prose positives pass;35terminal boundary rows preserve separators.955core executions and2native integration regressions pass;Releaseinstalled. Phonecursor checks arecore,not physicaltyping. Summary:`audits/turkish-round184-summary.json`.


## Round185 — Single missing phone digit with prose onright

600cases across8phoneformats,cursor positions and8prose tails.528observed completions reconstruct exactnumber anduntouched prose.72cases withheld:8parenthesized prefixes withonly2digits,64NBSP righttails outsideexisting ASCII contract. No reconstruction/snapshot failures;nooffer cases not counted as completions. No productionchange;installed184. Core arithmetic evidence only. Summary:`audits/turkish-round185-summary.json`.


## Round186 — URL component isolation

128storedURL/typedprefix combinations coverauthority,scheme,port,credentials,query,fragment,Unicodehost,pathcase andpercentencoding.19synthesized componentoffers preserve intended authority/path rules andcopy noquery/fragment/credentials.11fullobserved recalls accounted separately,not misclassified ascomponent leaks. Zero violations;no productionchange;installed184. Core evidence only,no networktraffic. Summary:`audits/turkish-round186-summary.json`.


## Round187 — Personal forget and active composition reload

72cases:3roots ×4forms ×2admissionroutes ×3forget casing variants. Active phrase offer andpersonal morphology membership disappear onforget,otherroots remain,andbothrestore when deliberately loading saved pre-forget binarysnapshot. Alltext unchanged.432checks pass. Uses actual PersonalLexiconStore;initial Codable fixture compileerror corrected beforetestexecution,not aproductbug. No productionchange;installed184. Summary:`audits/turkish-round187-summary.json`.


## Round188 — Forgotten regular phrase suggestion callback

Apppath re-resolves surface fromcurrent engine/fallback suggestions beforedispatch.72core traces mirror thatlookup:allcached phrase surfaces unavailable afterforget,leaving textunchanged. Afterdeliberate pre-forget binarysnapshot reload,72current picks produceexacttext. Otherroots preserved. Trusted ReplayCommand bypass wasnot treated asUIpath;technical cache andnative timing notcovered. No productionchange;installed184. Summary:`audits/turkish-round188-summary.json`.


## Round189 — Unutmanın kalıcılığı ve aynı veriyi yeniden öğrenme

72 kök/ekli biçim/öğrenme kaynağı/büyük-küçük harf senaryosunda unutma sonrası gerçek ikili sözlük kaydedilip yeniden yüklendi. Silinen kök, ekleri ve iki kelime önerisi geri gelmedi; diğer kökler korundu. Aynı üç sözcüklük aktarım tekrar yapıldığında sözcük yeniden öğrenildi ve ikinci kaydetme/yüklemede korundu. Sekiz kontrolün her birinde 72/72 başarı; yeni ürün hatası bulunmadı. Kanıt: `audits/turkish-round189-summary.json`. Üretim kodu değişmedi; telefondaki son doğrulanmış kurulum round184. Bu kontrol çekirdek düzeyindedir.


### Kullanıcı isteği son kontrolü — boşluk tahmini

12 sohbet isteği kayıt ve kanıtlarıyla yeniden karşılaştırıldı; kayıtlı açık doğrulanmış hata veya bekleyen inceleme yok. Güncel kodda 12 odaklı çekirdek testi ve gerçek simülatör uzantısında seçili iki kelime düzeltmesi ile tekrarlı silip yeniden açma testleri (2/2) geçti. Loglar: `audits/current-request-final-core.log`, `audits/current-request-final-native.log`. Boşluk onarımı açık öneri seçimiyle uygulanır: eksik boşluk veya Türkçe Q alt sıradaki z/x/c/v/b/n/m/ç/ö yerine basış; iki tarafın tanınması gerekir. Son üretim kurulum round184, bu tur üretim kodu değişmedi. Fiziksel telefonda yazı yazma ve tüm uygulamalarda davranış doğrulanmış değildir. Genel hata arama hedefi aktif kalır.


## Round190 — İki kelime onarımından sonra unutma ve yeniden açma

72 senaryo: 3 kişisel kök ×4 ekli biçim ×2 öğrenme kaynağı ×3 unutma yazımı. Son kelimesi kişisel olan iki kelime önerisi seçildi, boşluk silinerek kelime yeniden açıldı ve kök unutuldu. Dört boşluk/silme döngüsünde (288 toplam) metin ve literal önerisi korundu; unutulan kök veya ekleri kendiliğinden öğrenilmedi, kişisel öğrenme puanı sıfır kaldı. Gerçek ikili depoya kaydetme/yükleme sonrası da unutma korundu. Altı kontrolün her birinde 72/72 başarı. Kanıt: `audits/turkish-round190-summary.json`. Yeni ürün hatası bulunmadı; üretim kodu değişmedi, kurulum round184 kaldı. Çekirdek deneyi; yerel ayarlar panelinin zamanlaması veya fiziksel telefon testi değildir.


## Round191 — Teknik ve Unicode çevrede seçili iki kelime onarımı

6 onarım ×8 çevre metni ×3 seçim kenarı (boş/boşluk/tab) =144 senaryo. IPv4, protokol, Unicode URL/e-posta, telefon, dosya yolu, satır sonu, birleşik emoji ve ayrık Unicode aksan çevreleri kullanıldı. Özgün öneri, onarım önerisi, tam metin, sağ bağlam, seçimin bitmesi, ardından x yazma ve silme olmak üzere yedi kontrolün tamamında 144/144 başarı. Kanıt: `audits/turkish-round191-summary.json`. Yeni ürün hatası bulunmadı; üretim ve telefon kurulumu round184 olarak kaldı. Çekirdek belge modeli grapheme konumları kullanır; native UTF-16 imleç hareketi veya fiziksel telefon kanıtı değildir.


## Round192 — Host metni değiştirdikten sonra eski öneri

6 iki kelime girdisi ×3 kip (yazarken/seçili/onarım sonrası yeniden açılmış) ×6 dış metin değişimi =108 senaryo. Host bildirimi kasıtlı geciktirildi; eski öneri yüzeyi üç kez güncel listeden arandı ve bulunursa yürütüldü. 324 arama denemesi; hepsi yürütülmüş öneri seçimi değildir. Metin, kişisel sözlük ve kalibrasyon değişmedi; host bildirimi sonrasında x doğru yere eklendi. Dört ölçütte 108/108 başarı. Extension ayrıca tam sunum bağlamını doğruluyor; bu deney çekirdekteki son korumayı sınar, native callback yarışı veya aynı sonekli farklı host metni hakkında kanıt değildir. Kanıt: `audits/turkish-round192-summary.json`. Yeni hata yok; üretim ve kurulum round184.


## Round193 — Teknik adreslerde harf duyarlılığı

8 çift ×2 ekleme sırası ×2 kalıcılık modu ×2 hedef sürüm ×3 önek uzunluğu =192 karşılaştırma. Türkçe/ASCII URL yolları, sorgu ve fragment, e-posta kullanıcı adı, dosya yolu ve geliştirici identifier çiftleri ayrı saklandı; istenen tam gözlenmiş adres önerildi, farklı harfli diğer gözlenmiş adres önerilmedi. Birini unutmak diğerini silmedi. JSON yeniden yükleme kontrolleri dahil dört ölçütte 192/192 başarı. Oluşturulan parça önerileri ayrıca kayıtta görünür; karşı sürüm dışlama ölçütü yalnız observed teklifler içindir. Kanıt: `audits/turkish-round193-summary.json`. Yeni hata yok; üretim değişmedi, son kurulum round184. Çekirdek deneyi; native UI veya fiziksel yazma testi değildir.


## Round194 — Gerçek klavyede emoji ve IP arasında onarım

Simülatörün gerçek BestKeyboard uzantısında 🇹🇷 emoji panelinden eklendi; merhababdünya ve 192.0.2.1 tuşlarla yazıldı. UIKit çift dokunmayla yalnız kelime seçildi. İki kelime önerisi seçilince metin tam olarak `🇹🇷 merhaba dünya 192.0.2.1 ` oldu. Ardından x doğru yerde eklendi ve bir silmeyle kaldırıldı; emoji ve adres değişmedi. `testNativePhraseSelectionBetweenEmojiAndIPAddress` geçti (1/1). Kanıt: `audits/turkish-round194-native.log`. Yeni ürün hatası yok; üretim kodu değişmedi, telefona yeniden kurulum yapılmadı (son round184). Tek native simülatör senaryosudur, fiziksel telefon veya tüm Unicode dizileri için garanti değildir.


## Round195 — Seçili boşluklu telefon ve tırnaklı e-posta önerisi

Yeni doğrulanmış kök neden: synthetic selection yalnız boşluksuz yüzey kabul ediyordu. 192 senaryonun 36 tanesinde (boşluklu iki telefon biçimi ve tırnaklı boşluklu e-posta) özgün öneri yoktu; bu nedenle seçimi öneriyle bitirip yazmaya devam etme akışı çalışmıyordu. ComposingSession sınıflandırılmış phone/email değerlerini de seçilebilir kabul ediyor; diğer sınırlar korunuyor. Dokunma verisi olmayan bu değerlerde özgün yüzey sunuluyor.

Düzeltme sonrası 192/192 senaryoda yedi kontrol geçti: öneri, tam metin, UTF-8 korunması, seçimin bitmesi, devam yazımı, silme ve kişisel kelime sözlüğünün kirlenmemesi. Test artık varsayılan pakette assert ediyor. Normal cümle ve bozuk/eksik teknik değerler için 7 negatif kontrol eklendi. 956 çekirdek yürütmesi (632 XCTest−78 opt-in atlama+402 Swift Testing) ve 2 gerçek uzantı UI regresyonu geçti. UI kapsamı seçili kelime onayı ve emoji/IP arasında iki kelime onarımı; yeni boşluklu teknik değerlerin kapsamı çekirdek testidir. Release derlendi, telefona kuruldu, kurulum JSONu ve ikili SHA-256ları kaydedildi. Yeni launch/physical typing iddiası yok. Kanıt: `audits/turkish-round195-summary.json`.


## Round196 — Boşluklu teknik seçimlerin native kanıtı

Round195 düzeltmesinin iki sınıfı gerçek simülatör uzantısında ayrıca sınandı. `0532 123 45 67` ve tırnaklı Türkçe e-posta tuşlara basılarak yazıldı; üçlü UIKit dokunuşu bütün değeri seçti. Özgün öneriye basınca metin değişmeden seçim kapandı, x değerin sonuna eklendi ve backspace ile yalnız x silindi. İki yeni UI testi de geçti: `testNativeGroupedPhoneSelectionConfirmation`, `testNativeQuotedEmailSelectionConfirmation`. Kanıtlar: `audits/turkish-round196-native.log`, `audits/turkish-round196-email-native.log`. Yeni ürün hatası yok; yalnız UI testleri eklendi. Telefonda son kurulum round195; fiziksel yazma iddiası yok.


## Round197 — Teknik seçimde öneri dışındaki tuşlar

6 yüzey ×4 seçim kenarı ×6 eylem =144 senaryo. Harf, backspace, kelime silme, nokta, newline ve boşluk ardından harf yolları doğru seçimi değiştirdi; çevredeki emoji/önce/sonra/IP metinleri korundu. Son seçim durumu kapalı kaldı; kişisel sözlük ve kalibrasyon örneği oluşmadı. Beş ölçütte 144/144 başarı. Boşluk tek başına mevcut politikayla host seçimini korur; bu deney boşluk ardından harfin sonucu için kanıttır. Çekirdek belge modeli kullanıldı, native hareket testi değildir. Yeni hata yok; üretim değişmedi, son telefon kurulumu round195. Kanıt: `audits/turkish-round197-summary.json`.


## Round198 — Değişmeyen teknik seçim onayında fazla öğrenme

Yeni doğrulanmış kök neden: parantezli çevrede kenar boşluğuyla seçilen telefon özgün öneriden onaylanınca metin aynı kaldığı halde history sınır gözlemcisi yeni bir occurrence üretiyordu. 144 senaryonun 8 tanesinde kullanım sayacı +1 arttı. Seçim sırasında tam görünür belge tanığı saklanıyor; aynı belgenin yalnız seçimi kaldırıldığında yeni öğrenme yapılmıyor. Gerçek metin veya belge kimliği değişince tanık geçersiz oluyor. Bilinmeyen sağ bağlam bu tanığı üretmiyor.

Düzeltme sonrası 144 senaryo/432 onay/1296 tekrar bildiriminde metin, kelime sayıları ve çift sayıları değişmedi. Gerçek yeni yazım ve başka alan öğrenmesi için kontroller eklendi. Test varsayılan paket içinde assert ediyor. İlk tam paket iki fixture varsayımı yüzünden başarısız oldu: sarılmış tcp/ip geçmişte `(tcp/ip),` olarak saklanıyor, çıplak yüzey varsayımı doğru değildi. Bu auditin metin/sayaç değişmezleri korunarak ilk geçmişin varlığı doğrulandı; ham gözlem alanı tutuldu. Bu ayrı tokenizer politikası bu tur değiştirilmedi. Son tam paket: 958 yürütme (635 XCTest−79 atlama+402 Swift Testing), sıfır hata. Gerçek uzantıda telefon ve tırnaklı e-posta onayı 2/2 geçti; sayaç kanıtı çekirdektedir. Release derlendi ve bağlı telefona kuruldu; JSON ve ikili hashler saklandı. Fiziksel yazma/launch iddiası yok. Kanıt: `audits/turkish-round198-summary.json`.


## Round199 — Değişmeyen onaydan sonra satır sonu ve yeni kelime

144 bağlamda üç onaydan sonra newline ve geldi yazıldı. Yeni kelime her durumda bir kez öğreniliyordu; ancak 14 parantezli, kenar boşluksuz seçimde eski teknik kayıt satır sonunda yeniden işleniyordu. Telefon/IP sayısı artabiliyor, bazı parçalı teknik biçimler eklenebiliyor, tırnaklı e-posta prefix geri çekmesi sonraki kelimenin eski receiptini de etkileyebiliyordu.

Kök neden: onay sonrası imleç seçili değerin hemen sonundayken whitespace guard erken dönüyor, unchanged selection prefixi lastCompletedContext içine yazılmıyordu. Kontrol ayırıcı kontrolünden önceye taşındı. Böylece bir sonraki newline aynı eski metni tekrar işlemez; gerçek yeni kelime farklı prefixle öğrenilir. Son 144/144 izde altı kontrol geçti: onaylar, ayırıcı sonrası eski sayılar, yeni kelime bir kez, tam metin, tüm son kelime sayıları ve çift sayıları. Test varsayılan pakete assertlerle eklendi. 959 yürütme (636 XCTest−79 atlama+402 Swift Testing) ve 2 native UI regresyonu geçti. Release telefona kuruldu; JSON/hashler saklandı. Yeni öğrenme/sayaç kanıtı çekirdekte, native testler telefon/e-posta seçimi onayında; fiziksel yazma iddiası yok. Kanıt: `audits/turkish-round199-summary.json`.


## Round200 — Onay sonrası gerçek silme ve yeniden yazma

8 teknik değer ×2 önceki bağlam ×2 sonraki bağlam ×3 silip yeniden yazma döngüsü =96 satır. Seçim onayı sayıları değiştirmedi. Her karakter silmesinden önce gerçek silme beklentisi kaydedilip değişen host snapshotı doğrulandı; ardından değer yeniden yazıldı. Her gerçek yeniden yazım tam bir yeni doğrudan token gözlemine eşit sayılar/çiftler üretti. 288 yinelenen completion bildirimi tam history eşitliğini korudu. Altı ölçütte 96/96 başarı; yeni hata bulunmadı. HistoryObservation deneyi, native veya fiziksel klavye testi değildir. Üretim değişmedi, son kurulum round199. Kanıt: `audits/turkish-round200-summary.json`. Round sayısı hata sayısı değildir.


## Round201 — Parça seçimi ardından gerçek yeni sınır

Round199 korumasının gerilemesi bulundu: 48 karşılaştırmanın seçim onaylı 24 tanesinde sonradan araya boşluk/newline eklenerek oluşan sol kelime öğrenilmiyordu; yalnız imleç taşınan 24 kontrol geçiyordu. Onaylanan prefix sağında kelimenin devamı olsa bile completed sayılıyordu. Artık önceden bir whitespace sınırı veya yalnız kapanış noktalamasından oluşan sağ parça varsa tamamlanmış prefix hatırlanıyor. Sağda harf, .com, kesme eki, alt çizgi veya yol devamı varken gerçek yeni sınır öğrenmeye açık kalıyor. Değişmeyen seçim onayı yine öğrenme üretmiyor.

80 genişletilmiş senaryo assertlerle varsayılan teste eklendi ve tamamı geçti. Önceki 198/199 onay ve devam değişmezleri de geçti. Genel paket 960 yürütme (638 XCTest−80 atlama+402 Swift Testing), iki native telefon/e-posta onay regresyonu başarılı. Release telefona kuruldu; kurulum JSON ve hashleri kaydedildi. Partial-boundary öğrenme kanıtı çekirdekte; fiziksel telefon yazımı iddiası yok. Kanıt: `audits/turkish-round201-summary.json`.


## Round202 — Unicode kapanış noktalamasında onay

İlk 128 senaryoda ], } ve ’ kapanışları için 24 kelime sayacı, bunların ikisinde çift sayacı sapması görüldü. Eksik whitelist yüzünden onaylanan eski prefix newline sonrasında yeniden işleniyordu. Unicode closePunctuation/finalPunctuation kategorileri ve açık cümle sonu işaretleri kullanıldı; teknik/harf devamı olan partial-prefix dışlaması korundu.

12 kapanış çiftiyle 192 senaryoya genişletilen test varsayılan pakette altı değişmezi assert ediyor; tamamı geçti. 201 partial-boundary ve önceki onay/öğrenme kontrolleri de başarılı. Genel paket:961 yürütme (639 XCTest−80 atlama+402 Swift Testing). İki gerçek telefon/e-posta seçimi onay testi geçti. Release telefona kuruldu; JSON ve ikili hashler saklandı. Noktalama sayacı kanıtı çekirdektedir; fiziksel yazma iddiası yok. Kanıt: `audits/turkish-round202-summary.json`.


## Round203 — Kaydediciden teknik seçim düzenlemesine devir

InputSession kaynak incelemesi: host seçimi mevcut journal şemasında replay edilemediği için continuationForUnrecordedEditing ile canlı koordinatör devralınıyor ve eski kaydedici ayrılıyor. Bu desteklenmeyen olayları kaydedilmiş gibi sunmuyoruz. 6 teknik değer ×2 kenar boşluğu ×2 önceki token durumu =24 devir deneyi yapıldı. Seçim/özgün öneri, onay, sonraki x ve silme doğru; eski recorder.documentText değişmedi; outside-log bayrağı kalktı; kalibrasyon ve kişisel sözlük kirlenmedi. Dokuz ölçütte 24/24 başarı. Kanıt: `audits/turkish-round203-summary.json`. Yeni hata yok; üretim değişmedi, son kurulum round202. Yeni dosya/replay doğrulaması veya native UI testi iddiası yok.


## Round204 — Nokta uzun basma ve sürükleme

Simülatör uygulama tezgahındaki üretim KeyboardView ile gerçek UIKit dokunuşları: kısa nokta basıp q üzerine sürükleme yalnız q yazdı; uzun basıp q üzerine sürükleme yalnız virgül yazdı. Kısa basıp klavye dışına sürükleme hiçbir şey eklemedi; uzun basıp dışarı sürükleme yalnız bir virgül bıraktı. Üç sonraki normal nokta basışı hep nokta yazdı; zamanlayıcı/alternate durumu sonraki dokunuşa taşınmadı. Tek UI testinde dört sürükleme ve üç toparlanma basışı geçti. Kaynakta touchesCancelled/cancelAllTouches sahiplik ve zamanlayıcı temizliği incelendi; bunlar bu UI testinde sistem iptaliyle tetiklenmedi. Kanıt: `audits/turkish-round204-summary.json`. Yeni hata yok; üretim değişmedi, son telefon kurulumu round202. Bu shared KeyboardView tezgahıdır, extension veya fiziksel telefon testi değildir.


## Round205 — Gerçek klavyede silme tekrarı ve dışarı kaydırma

Tezgah silme tekrarını bağlamadığı için gerçek simülatör uzantısı kullanıldı. Yirmi su kelimesi tuşlarla yazıldı. Backspace 1.1s tutulup editör içine/klavye dışına sürüklendi; metnin bir kısmı silindi ve testin sızıntıyı görebilmesi için bir kısmının kaldığı doğrulandı. Bıraktıktan sonra 700ms metin sabit kaldı. Sonraki 10ms kısa basış tam bir karakter sildi; x doğru yere eklendi. `testNativeBackspaceRepeatStopsAfterDraggingOutside` geçti. Geçerli simülatör hız ayarıyla tek native senaryo; bütün hızlar/çoklu dokunma/sistem iptali/physical typing iddiası yok. Yeni hata yok, üretim değişmedi, kurulum round202. Kanıt: `audits/turkish-round205-summary.json`.

## Round206 — Native vertical trackpad

Both ASCII and flag-emoji controls pass in the actual simulator extension. A space-key hold and upward drag preserves text without an extra space; the following q is inserted at the expected previous-line column. Evidence: `audits/turkish-round206-native.log`. No production change or reinstall; installed Release remains round202. Physical typing was not tested.

## Round207 — Current request closure and permanent space regression

Reviewed all 12 recorded requests against code and evidence; no recorded confirmed defect remains open. The 360-case shifted space matrix now runs and asserts in the normal test suite, including missing spaces, nine bottom-row substitutions and three Turkish casing forms. Current export independently checked:342 exact offers/picks,18 known-word no-split controls,zero failures. Full current suite reports639 XCTest with79 exporters skipped and403 Swift Testing passes,zero failures. Four current simulator tests pass: imported-word persistence, native qrmenü/numeric/period/space flow, repeated phrase reopening, selected-word two-word repair. Evidence: `audits/turkish-round207-summary.json`. This round changes tests only; latest production install remains202. No physical typing claim and no guarantee of all possible Turkish text or host applications. Historical limitations remain in the request checklist.

## Round208 — Two learned words in a space repair

288 production-pack cases combine four inflections each of qrmenü/mavilo, missing-space or b/n mistaps, lower/title/allcaps, and either forgotten root. Every row asserts:one missing root prevents the repair; both learned roots enable it; literal stays first; forgetting changes membership and revokes the repair; document stays unchanged; restoring both roots enables an exact phrase pick. All seven checks pass in every exported row. Evidence: `audits/turkish-round208-results.json` and `audits/turkish-round208-core-final.log`. Initial test compile missed KBSpatial import; fixed before final passing run. No production change/reinstall or new native/physical test. Installed Release remains202.

## Round209 — Editing repaired pairs of learned words

192 traces cover eight two-personal-word phrases with inflections and both root orders, three casing forms, two prefixes and four editing actions. Exact final text and personal admission set remain unchanged as expected;48space-cycle traces additionally check144reopened session displays with empty touch evidence. Other actions delete the final word, replace its last letter, or delete the full phrase while retaining preceding text. All exported checks pass. Evidence: `audits/turkish-round209-results.json` and `audits/turkish-round209-core.log`. This checks personal admission, not independent history frequency counts. No production change/reinstall or new native/physical typing validation; installed Release remains202.

## Round210 — Native numeric punctuation and plane retention

Actual simulator extension typed -12,50;192.168.1.1:8080;(532)123-45-67, checking exact text and numeric-plane retention after every character. Each following space returns to letters. Holding the numeric dot for0.8s inserts one dot, allowing1.5; Return then inserts a newline and returns to letters, where x continues correctly. One UI test passed in38.779s. Evidence: `audits/turkish-round210-native.log`. No production change or phone reinstall; installed Release202. Not a physical typing test or coverage of every host field type.

## Round211 — Native developer symbols across planes

One actual extension UI test types JSON-like text, an underscored identifier, a backslash path, backtick-wrapped tcp/ip and bracketed IPv6, checking each character and subsequent spaces. Tab and following x also preserve expected content. Initial locale-independent lowercase comparison mismatched auto-capitalized Turkish İ; corrected the fixture to tr_TR. All35initial assertion failures flowed from that comparison mismatch, not a demonstrated punctuation defect. After the failing test had completed, optional simctl diagnostics were terminated to release xcodebuild; the corrected run completed normally,1test/zero failures in44.319s. Evidence: `audits/turkish-round211-native-final.log`. Case-folded comparison does not prove exact casing. No production change/reinstall or physical typing test; installed Release202.

## Round212 — Structured text cursor deletion

849 cases enumerate each grapheme cursor boundary in16values with3surroundings:protocol,IPv4/IPv6,Unicode/percent/emoji URLs,quoted andaddress-literal email,grouped phone,path,identifier andflag. Backspace removes exactlyone preceding grapheme,insertText restores it,letter x inserts at the cursor andbackspace removes it. All6checks pass,including intact right context andempty personal lexicon. Evidence: `audits/turkish-round212-results.json` and `audits/turkish-round212-core.log`. The adapter keeps a fixed right context andstarts without composing state; this proves core editing behavior,not UIKit offset handling or physical typing. No production change/reinstall; installed Release202.

## Round213 — Structured editing with limited host context

10188cases extend the849structured cursor positions with independently limited left(nil/empty/1/8graphemes) andright(nil/empty/4graphemes) context. Backspace,restore via insertText,insert x andbackspace again preserve exact whole-document expectations andleave personal entries empty. Every exported row passes all5checks. Evidence: `audits/turkish-round213-results.json` and `audits/turkish-round213-core.log`. This uses a core adapter,fresh coordinator andfixed visibility per trace; it does not exercise real UIKit callback timing,cursor offsets or visibility changes mid-composition. No production change/reinstall; installed Release202.

## Round214 — Context visibility changes during composition

360traces type8words in plain,URL andemail surroundings,then switch context visibility to nil/empty/1/4/full characters before deleting one character,deleting the composing word,or inserting/deleting x. Full visibility then returns andinserting/deleting z preserves the result. All4checks pass,including exact entire document before/after andempty personal entries. Evidence: `audits/turkish-round214-results.json` and `audits/turkish-round214-core.log`. Only context visibility changes; no host document/caret mutation or UIKit callback scheduling. No production change/reinstall or physical typing claim; installed Release202.

## Round215 — Unicode-equivalent personal imports

96cases combine6OOV roots containing Turkish letters with4initial NFC/NFD/lower/upper variants and4forget variants. Production PromptTokenizer canonicalizes all variants. Reimporting all4forms preserves the exact personal state at1point; a distinct3-occurrence batch admits exactlyone canonical entry. Binary save/reload preserves recognition,variant forgetting succeeds andthe last-word deletion/reload branch yields no entry. All7exported checks pass. Evidence: `audits/turkish-round215-results.json` and `audits/turkish-round215-core.log`. Contract requires production tokenizer before ingest;raw unnormalized tokens are not covered. Not a nativeUI/physical test or multiword archive-retention test. No production change/reinstall; installed Release202.

## Round216 — Repeated deletion at Unicode line boundaries

400cases combine LF,CR,CRLF,NEL,VT,FF,LS,PS with no padding,space,tab,NBSP,thin-space; tails include Turkish words,URL,grouped phone andcompound emoji. Host-provided andinsertText-created text both tested. Each deleteWord command makes monotonic progress without crossing the prior-line barrier;the next command deletes onlythe newline,then the preceding word,then no-op atempty. All6checks pass. Evidence: `audits/turkish-round216-results.json` and `audits/turkish-round216-core.log`. No decoder or active composition; this tests core deletion commands,not native hold timing or physical typing. No production change/reinstall; installed Release202.

## Round217 — Native selected value deletion

Actual extension UI types qrmenü,0532 123 45 67,andhttps://ornek.com/a. Each entire value is selected through host gesture andoffered as a literal;one10ms backspace clears it. A following x inserts alone andanother shortdelete removes it. One UItest passed in46.042s. Evidence: `audits/turkish-round217-native.log`. Whole-editor selections only,not mid-document subranges;initial text uses Turkish casefold. No production change,reinstall orphysical typing test; installed Release202.

## Round218 — Middle selection deletion and native control

Initial BestKeyboard UItest expected both adjacent spaces retained after deleting middle qrmenü/kalem. Actual UITextView result removes leading space andleaves caret after önce,so x joins it. Six initial assertions failed. Apple keyboard control in the same host reproduces exactly the same result;1control test passes24.960s. An initial control setup used unavailable custom globe; corrected to the system Next keyboard button andverified Apple delete key/custom-key absence. Corrected BestKeyboard test passes40.623s for2words,preserving neighboringwords andsupporting subsequent insert/delete/paragraphclear. Evidence: `audits/turkish-round218-summary.json`. This is observedhost equivalence,not a newly fixed keyboard defect or a guarantee across all hosts. No production change/reinstall/physical typing; installed Release202.

## Round219 — History after selected word andspace deletion

72traces vary3leftwords,6selected ordinary/technical values,leading/trailing-space removal andseeded history. Selection/deletion plus3repeated completion callbacks doesnot changehistory. Appending x+space learns the resulting joinedword once forleading-space removal;isolated x in the trailing-space variant remains excluded byminimumlength. Counts andpairs match direct expected observations;5further callbacks leave fullhistory unchanged. All4checks pass. Evidence: `audits/turkish-round219-results.json` and `audits/turkish-round219-core.log`. Core observation simulation only,not native store integration or erased-history forgetting. No production change/reinstall; installed Release202.

## Round220 — Native circumflex typing andcontinuation

Actual extension types kârımızdan,resmî,sükûn,hikâyelerden using â/î/û keys onthe symbolplane andreturns toletter keys forcontinuation. Every character matches underTurkish casefold. Space preserves each complete word andreturns toletters;deleting andreadding that space doesnot alter theword. One UItest passes39.804s. Evidence: `audits/turkish-round220-native.log`. Fourwords,not exhaustive morphology or physical typing;casefold doesnotassert exact capitals. No production change/reinstall; installed Release202.

## Round221 — Circumflex symbols ignored Shift: fixed

Actual caps-lock typing produced KâR/RESMî/SÜKûN,with21cumulative native assertions failing. Symbol-letter keys bypassed the letter Shift path. Added shared ShiftPolicy.consumeSymbol: letter symbols honor Turkish casing andconsumeone-shot;locked remainslocked;punctuation/digits remainliteral andonlyinterrupttapchain. Both extension andrecorder useit withoutfabricatinglayout touches. Symbolkey rendering/accessibility now sharesletter casing/style andrefreshesonShift changes.

Two core regressions coverall3circumflex letters inoff/one-shot/locked modes plusnonletter controls. Fullsuite649XCTest−87skippedexporters+403SwiftTesting=965reportedexecutions,zerofailures. Four nativeUItests pass:3exactuppercasewords,one-shotÂthenb withlabelreset,4lowercasecircumflex words withreopen,andnumeric punctuation/IP/phone controls. SignedReleasebuild andphoneinstall succeed. InstallerJSON andbinarySHA256 savedin `audits/turkish-round221-summary.json`. No physicaltypingorlaunchattempt. Recorder sharesvalidatedpolicy andcompiles buthasnonewrecorder-specificnativeUItest. Initialfailedtest hadcompleted beforeoptionalsimctldiagnostics terminated;finaltestscompletednormally.

## Round222 — Circumflex Shift in production recordings

45cases combine5words,off/one-shot/lockedShift andspace/period/reopen boundaries. They issue actual letter-touch commands andsymbol commands through ProductionRecorder,savecapture totempdisk,reload,validate withlayout andreconstruct recorded document. All6checks pass:typed/final/stored text,validrecord,reconstructedtext,andexacttouchcount withoutinventing touches forsymbols. Evidence: `audits/turkish-round222-results.json` and `audits/turkish-round222-core.log`. Casing expectedfromsharedpolicy;independentuppercaseproof livesinround221native tests. Reconstruction appliesrecorded edits,not a seconddecoder;no RecorderViewControllerUI test. No productionchange/reinstall;installedRelease221.

## Round223 — Şapkalı kelimelerin alandan öğrenilmesi

Kayıt hizalaması için kullanılan PromptTokenizer, â/î/û karakterlerinde kelimeyi bölüyordu. Kişisel sözlük aktarımı artık ayrı importTokens kuralıyla tam kelimeyi koruyor. Önce 27 assertion başarısızdı; düzeltmeden sonra 969 core yürütmesi, 96 Unicode aktarım kontrolü, gerçek simülatör klavyesinde aktarım/seçili ekli kelime önerisi ve Shift kontrolü geçti. Release telefona kuruldu; fiziksel yazım denenmedi. Eski parçalanmış kayıtlar köken bilgisi olmadan topluca silinmedi.

Ayrı açık bulgu (Round224): Canlı yazımda şapkalı karakter token sınırı oluşturduğu için iki kelimelik öneri kayboluyor. Aynı tam sözcük seçildiğinde doğru öneri geliyor. Round223 native logları bunu gösteriyor; bu bulgu henüz kapanmadı.

## Round224 — Canlı tam kelime ve boşluk önerisi kapanışı

Round223 içinde açık kalan hata düzeltildi: â/î/û kayıt tokenını kapatsa da öneri çubuğu görünür tam kelimeyi koruyor. Özgün yüzey ilk öneri; eksik veya yanlış harfli boşluk için iki-kelime adayları ortak kuraldan geliyor. Değiştirme yalnız açık seçimde, belge/seçim/önce-sonra bağlamı ve güncel aday yeniden doğrulanınca gerçekleşiyor. Seçilen özgün tam kelime hemen kişisel sözlüğe alınır. Kayıt hizalaması ve gerçek dokunma kanıtı değişmedi.

90 yeni şapkalı kök/ek/boşluk/harf büyüklüğü örneği ve güvenli bağlam kontrolleri geçti. Tam core suite: 653 XCTest (87 tanısal exporter atlandı) + 404 Swift Testing, toplam 970 raporlanan yürütme, sıfır başarısızlık. 9 UI testi geçti: 6 gerçek klavye uzantısı, 1 uygulama öğrenme listesi, 2 ortak UIKit klavye testi. Önceki 360 eksik/yanlış boşluk assertion matrisi tam suite içinde çalışıyor.

Sohbetteki 12 istek kategorisi tekrar gözden geçirildi; doğrulanmış açık hata kalmadı. Tüm indeksli kanıt dosyaları mevcut. İmzalı Release bağlı iPhone 14 Pro'ya kuruldu. Telefon kilitli olduğu için uygulamayı açma denemesi reddedildi; fiziksel yazım testi yapılmadı. WhatsApp keyfî kısmi örtüşme ve köken bilgisi olmayan eski kayıtların temizliği gibi daha önce belgelenmiş sınırlar devam ediyor. Güncel kaynak: audits/turkish-round224-summary.json ve audits/current-request-checklist.json.

## Round225 - Circumflex whole-word punctuation boundaries

Two new boundary defects: opening quotes/parentheses suppressed complete word offers; checking only the first right character treated .com, :443, ?q=1 and apostrophe continuations as prose boundaries. The baseline 132 wrapper pairs and 9 technical tail controls produced 254 assertion failures, not 254 independent bugs.

Bounded scanning now separates opening punctuation and validates the complete adjacent right run. Explicit picks retain existing right punctuation/whitespace; a new space is appended only at the visible end. Technical prefix and long-input controls pass. Recording touch segmentation and automatic correction are unchanged.

655 XCTest executions (87 diagnostic exporters skipped) plus404 Swift Testing executions:972 reported executions,zero failures. Two actual simulator extension tests pass: ordinary live inflected repair and original acceptance/inflected repair under three opening wrappers. Right-tail suppression and punctuation-preserving replacement are core-level evidence. Signed Release installed on the attached phone; no physical typing or new launch test. Round224 launch was blocked by the device lock.

## Round226 - Whole-word picks, edits and production recording

72 traces: three learned circumflex roots, four opening wrappers, original/repair choice and three edit paths (three reopen cycles, last-character delete/retype, last-word delete/reinsert). The test mirrors controller close/delete/text commands using ProductionRecorder, a real host baseline and personal-state handoff. Capture is written to disk, read back and validated against the layout. All72 rows pass8 checks: picked/intermediate/final text, stable personal admission, learning after rollover, record validity, external-baseline privacy and honest reconstruction status.

No new defect or production change. Initial test compilation used negation on an optional Bool; the fixture was corrected to explicit false equality before execution. Nonempty external baseline intentionally yields unverifiable reconstruction, not a successful full-document replay claim. This is core recorder integration evidence, not UIKit or physical typing. Latest installed production remains225.

## Round227 - Whole-word cursor, stale context and forgotten roots

360 cases combine three learned circumflex roots, four opening wrappers, five right contexts, original/repair choice and three casing variants. The cursor-aware DocumentEditor retains independent left/right text. Tests check the original and repair offers, rejection of changed/unknown context or a selection, removal and restoration of an inflected repair after forgetting/relearning its root, exact replacement, intact right text, typing at the retained caret, undo and exact learned-word membership. All360 rows pass all9 checks.

No new defect or production change. This is core adapter evidence, not UIKit cursor gestures or physical typing. Snapshot and fresh-candidate gates are tested independently of the UI document-identity gate. The test verifies the retained caret before existing right text, without claiming advancement across existing whitespace. Latest installed production remains225.

## Round228 - Unicode composition before Turkic case folding

A 216-case NFC/NFD/case matrix found12 failing decomposed-uppercase cases (24 assertions). Lowercasing uppercase I plus a separate circumflex before NFC composition produced dotless i plus circumflex, losing the learned canonical root. WordBoundaryRepair and direct personal-inflection lookup now use TurkishText.key: NFC, Turkish lowercase, NFC. The displayed original is not rewritten.

All216 rows pass8 checks including original/replacement UTF-8 preservation, repair, deduplicated acceptance, suppression of splitting an accepted original, forgetting and repair restoration. A permanent12-case regression also checks direct personal-inflection recognition and offers. Full suite:658 XCTest (88 diagnostic exporters skipped),405 Swift Testing,975 reported executions,zero failures. Two actual simulator extension tests verify ordinary and locked-shift original acceptance/inflected repair with composed key input; NFD evidence is core-level. Signed Release installed on the attached phone; no physical typing or new launch claim.

## Round229 - Selected-word canonical identity

The remaining lower-before-compose paths were selection touch synthesis, synthetic selection literal and shared case-insensitive identity. Decomposed uppercase circumflex I lost its key mapping, producing no decoder alternatives; equivalent case variants also compared unequal. Two permanent tests exposed36 baseline assertion failures. These paths now use TurkishText.key while retaining original selected display.

36 selection variants (six words,three casing styles,NFC/NFD) preserve original bytes in the offer, derive equal decoder alternatives, preserve edge whitespace on confirmation and collect no calibration samples.128 positive canonical case comparisons and3 negative distinction controls pass. Full suite:660 XCTest (89 diagnostic exporters skipped),405 Swift Testing,976 reported executions,zero failures. Two actual extension tests pass: locked-shift learning/repair and four uppercase selected words with alternatives/confirmation/continued typing. Native keys emit composed text; NFD selection evidence remains core-level. Signed Release installed on attached phone; no physical typing or new launch claim.

## Round230 - Expansion casing entry-point protection

144 actual coordinator expansion picks combine eight values, NFC/NFD input, lower/title/all-caps trigger and three prefixes. All five production-path checks pass: typed source unchanged before choice, original available, expansion normalized on entry, exact cased commit and zero calibration samples for the nonaligned expansion.

Raw casing helpers differ from the canonical expected spelling in15 rows (five word/style combinations, repeated across three prefixes). This observation is preserved; it is not counted as a reproduced user-facing expansion failure because ExpansionMap composes its values before casing and all144 actual selections are correct. Core evidence only; no production change or phone reinstall. Latest installed production remains229. A separate unconfirmed follow-up concerns title-case corrections when selected text has leading whitespace.

## Round231 - Boundary whitespace must not determine word casing

The selection-whitespace follow-up is confirmed: casing inference used the whole selection, so leading whitespace hid a title-case initial; surrounding whitespace also made a single uppercase letter look like all caps. The baseline produced26 assertion failures. TurkishText.casing now trims boundary whitespace for inference only. Runtime replacement and UI history projection share this rule; actual selected whitespace is retained.

72 permanent cases combine three correction types, three casing styles and eight whitespace edge pairs, including tabs, newlines, NBSP and narrow NBSP. Four direct classification controls also pass. Full suite:663 XCTest (90 diagnostic exporters skipped),405 Swift Testing,978 reported executions,zero failures. Two actual extension tests pass: leading-space paragraph Kalen corrects to Kalem with whitespace intact and continued typing, plus four uppercase circumflex selected words. Signed Release installed on attached phone; no physical typing or new launch claim. History casing projection is checked here; full archive/count reconciliation remains covered by earlier rounds.


### Round232 - Single-word selected correction history

The selection history reconciler previously accepted only 2-8 replacement words, leaving owned old tokens and next-word pairs after single-word corrections. It now accepts 1-8 words, retaining the canonical unchanged-single-word no-op. A 96-case permanent matrix covers two corrections and an unchanged control, eight outgoing punctuation variants, selected whitespace, independent old occurrences, and repeated callbacks. Baseline: 160 assertion failures; after fix: all cases pass. Full core: 664 XCTest minus 90 skips plus 405 Swift Testing executions, zero failures. Two actual simulator extension tests pass, including single-word replacement with/without punctuation and the existing phrase history control. Signed Release installed on the connected phone; local installed-artifact hashes and installation JSON are in audits/turkish-round232-summary.json. Physical typing has not been verified. Additional request recheck is running.

Round232 request recheck completed: all 12 recorded categories reviewed; three additional UI tests passed (original qrmenue choice/numeric boundary/typed repairs, selected two-word repair, and imported learning entries after relaunch). Total current UI: four actual extension tests and one app test. All 360 asserted space cases passed in the full core run. No confirmed unresolved defect within documented scope; physical typing and previously documented provenance limits remain.


### Round233 - Successive single-word correction and restoration

A new permanent asserted regression exercises 96 histories and 576 edit stages: all six orders for three selected words, four trailing punctuation variants, padded/unpadded selections, and an optional independent old observation. Every word is corrected and then restored. At each stage, token and pair counts match an independently constructed expected history, and three duplicate completion/selection callbacks leave the whole history unchanged. All checks pass (one targeted XCTest, zero failures). No production change or reinstall; round232 remains installed. This is HistoryObservation/PersonalHistory integration evidence, not an additional native UI or physical typing claim.


### Round234 - Limited-context single-word correction history

216 asserted scenarios cover fresh observation, document switches, and truncated context; four prefixes including emoji, newline and URL; three right contexts including nil; padded selections; two corrections and an unchanged control. Expected history retains all unowned prior observations and adds only the corrected token/incoming pair. Token/pair counts match in every case, and three duplicate selection completions preserve the whole history. One targeted XCTest passes with zero failures. Permanent regression: UnanchoredSelectionHistoryTests. No production change; round232 remains installed. Core history evidence only, not a new native UI or physical typing result.


### Round235 - Unicode prose wrappers in selected correction history

A 432-case permanent regression found 252 missing selection witnesses across seven additional wrapper types (253 initial assertions including the case-count assertion). Selection boundary admission now recognizes Unicode open/close/initial/final punctuation. The first fix exposed a second inconsistency: natural words inside some wrappers retained the wrappers as token identity; full core had 24 confirmation/newline failures and the actual square-bracket correction failed next-word recall. PersonalHistory now strips Unicode prose edges only when the interior is a natural word, retaining its technical fast path. The strengthened regression explicitly checks unwrapped word identity. Final full core:667 XCTest minus90 skipped plus405 Swift Testing =982 reported executions, zero failures. Two actual extension UI tests pass, covering square-bracket selected correction with new/old next-word prediction checks and ordinary/punctuated single-word controls. Signed Release installed235 with JSON/hash evidence. Optional failed-run simulator diagnostics were terminated only after the initial UI suite was terminal. No physical typing verification; legacy provenance-free archive entries are not mass-rewritten.


### Round236 - IPv6 colon edges; native completion still open

Initial72 traces reproduced43 assertions: generic token-edge trimming removed IPv6 colons, and the all-colon address could disappear and incorrectly connect surrounding prose words. PersonalHistory now recognizes IPv6 before generic trimming, removing only unambiguous non-colon trailing prose punctuation. Expanded288 traces cover12 addresses,3 prefixes,2 line boundaries,4 punctuation suffixes; both bulk and live histories match independently constructed expected token/pair counts. Full core:668 XCTest minus90 skipped plus405 Swift Testing=983 reported executions, zero failures. Native developer-symbol test passes. New actual native IPv6 recall test FAILS: no 2001:db8:: completion after retyping its prefix. Captured hierarchy has no suggestion buttons. Hypothesis: nil right proxy context is rejected by completion; not yet verified. Release builds but is NOT installed. Round235 remains on phone. Optional failed-run diagnostics terminated only after native suite became terminal. Next work must investigate and fix native completion before closure; short IPv6 recall admission also needs review.


#### Round236 follow-up - Actual EOF completion resolved

A temporary exact-test-input diagnostic proved the address was learned: the proxy returned nil right context, actual candidates were empty, and the same history with a known-empty right context returned 2001:db8::. The diagnostic was removed from source after capture. New KBRuntime DocumentEndWitness accepts an observed empty field or explicit empty suffix, retains evidence through keyboard-owned insertion/deletion batches, and revokes it on changed visible context, selection, document identity or explicit cursor movement. The app uses the normalized right context only for technical completion and its final pick guard. Unknown nil context remains conservative. Two permanent witness tests cover continuity and revocation. Final core:670 XCTest minus90 skipped plus405 Swift Testing=985 reported executions, zero failures. Both actual IPv6 completion cases now offer and insert exact addresses. An erroneous UI expectation of an added trailing space was corrected to the existing no-extra-space completion contract; final IPv6 UI test passes. Developer-symbol UI also passed on the same production code. Signed Release installed236; hashes/JSON saved. No physical typing verification. Follow-up remains for short IPv6 recall admission and broader EOF completion UI scenarios.


### Round237 - Short IPv6 recall admission

90 bulk/live scenarios across5 valid short IPv6 addresses,3 left contexts,3 punctuation suffixes verify learned counts after archive reload, completion where a two-character prefix exists, and explicit forget. Six invalid short punctuation fragments remain non-recallable. Baseline162 assertions failed because the general four-character minimum excluded all short IPv6. isRecallable now admits sub-four-character strings only when classified as IPv6. Full core:671 XCTest minus90 skipped plus405 Swift Testing=986 reported executions, zero failures. Actual native test passes3 addresses including ::1 from :: and both previous longer IPv6 cases. Signed Release installed237 with JSON and local artifact hashes. The exact two-character :: is stored but one-character prefix completion is not promised; existing minimum prefix remains two. No physical typing verification.


### Round238 - Return to letters after technical completion

A new actual extension UI test exercises typed URL/email/phone observation, prefix recall, exact insertion and immediate letter continuation. URL/email stages passed; the phone stage completed the value but failed to find key.x because the observed-completion branch did not return to the letters plane. Two assertions failed at that same missing-key condition. The branch now sets keyboardView.plane to letters after prefix validation/deletion succeeds and before inserting the chosen completion. Existing original-literal, whole-word and normal suggestion branches already return to letters. IPv6 UI assertions were strengthened to require the letter plane after all three completions. Final native validation is in progress; no core package production code changed in this round.

Round238 final validation: both native tests passed, covering six address flows. URL/email/phone completion and x continuation are exact; all three IPv6 completions expose letters afterward. Signed Release installed238 with JSON/local artifact hashes. No core production change; last full core round237 remains986 reported executions. Physical typing untested.


### Round239 - Actual cursor movement after EOF technical completion

A new permanent actual-extension UI regression passes for IPv4 and email. It learns and completes the address at EOF, types a third line, moves vertically with the space trackpad into the completed address, verifies no redundant full-address offer, deletes its third character, restores through technical completion, and appends x at the restored address end. All six checks pass, including exact preservation of the right-hand suffix and following line. One native test passed; no production changes or reinstall. Round238 remains installed. Scope is known visible right suffix in the actual simulator host, not all unknown-context hosts or physical typing.


### Round240 - Completion history across nil context and quoted prefixes

96 histories/288 cycles cover8technical values, nil/empty right context, space/LF/NBSP boundaries and two leading contexts. Each cycle completes a known prefix, checks exact token/pair counts, repeats boundary callbacks, removes/re-adds the separator, then erases/retypes the value. Baseline132 assertions exposed nil-right deletion losing observed-start evidence and quoted-mail replacement discarding provisional name receipts. Backward deletion receipts now support optional right context. An immutable technical replacement witness preserves observations across deletion of the offered prefix, validates exact final text/context/document, accepts the transaction once, learns the complete value and retracts its provisional quoted-name observations. Intermediate validation exposed synthetic-boundary restoration dropping observed-start status; that is explicitly restored from the witness. Final full core:672 XCTest minus90 skipped plus405 Swift Testing=987 reported executions, zero failures. Two actual extension tests pass: URL/email/phone completion continuation and unique quoted-email provisional-name next-word cleanup. Signed Release installed240 with JSON/local artifact hashes. No physical typing verification. Middle-cursor replacements retain their existing path; historical provenance-free phantom entries are not mass-deleted.


### Round241 - Technical replacement witness lifecycle

54 histories cover ordinary/quoted/Unicode mailboxes, nil/empty/nonempty-whitespace right contexts, three leading contexts and independently seeded prior evidence. All216 invalid result attempts (wrong document, wrong final text, changed right context, unrelated replacement) are rejected without consuming the valid witness. Accepted completion preserves expected token/pair counts while retracting only provisional observations. All162 immediate and54 delayed duplicate calls return no event; subsequent word history remains intact. One targeted permanent XCTest passes, zero failures. No production change or reinstall; round240 remains installed. Core integration scope, not a new native or physical test.


### Round242 - Middle-cursor quoted-mail history reconciliation

72 modeled histories cover three quoted mailboxes, three insertion cuts, two leading contexts, two right tails and independent prior evidence. Baseline116 assertions reproduced phantom word/pair observations after deleting a quoted prefix when rightToken remained. The technical replacement transaction now verifies the existing rightToken, learns the complete value from inserted left text plus the retained right fragment, and preserves its receipt while restoring the actual interior cursor. Subsequent cursor movement and a separator therefore cannot count the completed address again. The UI uses this path for both EOF and middle-cursor completions. All72 text/token/pair checks pass. Full core:674 XCTest minus90 skipped plus405 Swift Testing=989 reported executions, zero failures. Two actual extension tests pass: quoted-mail completion before an existing domain suffix and EOF control; both verify provisional-name next-word cleanup. Signed Release installed242 with JSON/local artifact hashes. Historical provenance-free phantom entries remain untouched; physical typing untested.


### Round243 - NBSP phone completion right fragments

368 asserted histories cover six phone formats, eligible deleted-digit cuts, two leading contexts, two right tails and independent prior observations. Baseline56 missing-offer failures were all NBSP right fragments rejected by the generic ASCII-only cursor gate. Phone spans now also admit NBSP, a single UTF-16 unit; unsupported non-phone Unicode right fragments remain conservative. All368 text/count/pair/repeated-callback checks pass. Full core:675 XCTest minus90 skipped plus405 Swift Testing=990 reported executions, zero failures. Initial native clipboard-chip setup failed before completion; revised fixture prepares the NBSP text by explicit host Paste and field import. Actual keyboard trackpad movement, deletion, exact completion, right-tail preservation and following-letter position all pass. Signed Release installed243 with JSON/local artifact hashes. Physical typing untested.


### Round244 - Reformatted phone completion and request recheck

Completing a compact stored phone from a spaced prefix left an owned provisional short-phone occurrence in history. The completion provider compared normalized digits while the replacement witness required a literal prefix. The fix validates a phone digit prefix and retires only a provisional receipt belonging to this exact document/replacement start; independently learned instances remain.

The first draft used a trailing-space prefix, intentionally excluded by the phone boundary contract. The corrected digit-ending baseline produced 216 assertion failures. The permanent test covers 4 formats, nil/empty right context, 3 separators, 2 leading contexts and independent seed/no seed: 96 histories and 288 cycles with count, pair, callback, separator reopen and genuine retype assertions.

All 12 user-request categories were rechecked. All 934 indexed evidence files exist. The full core suite passed (676 XCTest, 90 skipped, 405 Swift Testing; 991 reported executions). The regenerated 360-case space matrix passed all assertions: 342 exact offers/picks and 18 known-word no-split controls. Final simulator and installation evidence is recorded in audits/turkish-round244-summary.json.

Round244 final: all four UI tests passed (three actual extension tests and one Learning UI test). Signed Release installed successfully on the connected iPhone. Physical typing remains untested. All 12 request categories are reconciled in current-request-checklist.json; no confirmed open defect remains within the documented scope.


### Round245 - Reformatted phone completion inside parentheses

The round244 phone format witness still normalized its inserted left fragment as a complete phone. For a cursor inside the area-code parentheses, the retained right token supplies the closing parenthesis. The offer provider correctly accepted this case, but the learning transaction returned nil until another boundary was typed. A permanent matrix exercises 288 middle-cursor histories across formatting, leading/tail contexts and independent history seeds; baseline produced 16 missing immediate reconciliation assertions.

The replacement transaction now uses the same partial phone-prefix parser as the offer provider, while still validating the whole completed phone, the exact retained right token and document snapshot. Tests assert immediate counts before cursor movement, exact final text/counts/pairs, and duplicate boundary idempotence. The actual simulator extension test starts with a typed compact prefix before an existing closing-parenthesis tail, selects the formatted phone, and verifies the right tail and subsequent letter position. Host paste and field import prepare the seed; our keyboard types the prefix and performs completion.

Final results and install evidence: audits/turkish-round245-summary.json.

Round245 final: 288 histories passed immediate and final count assertions; 992 reported core executions passed (677 XCTest minus 90 skips plus 405 Swift Testing). One actual simulator extension test passed. Signed Release installation succeeded on the connected iPhone; physical typing remains untested.


### Round246 - Case-insensitive address completion history

Recall uses component-aware identity for scheme/host/domain casing, but the technical replacement witness still required an exact textual prefix. Six URL/email variants across 144 histories and 432 cycles produced 1152 baseline assertion failures: immediate acceptance was skipped, and quoted-mail provisional observations could survive. Acceptance now compares the same technicalSearchKey used by recall; mailbox, credentials and URL path remain case-sensitive. Verified nonliteral replacements retain the observed document-start anchor, and quoted-mail receipt reconciliation still owns only the current occurrence. Three negative controls reject sensitive mailbox/path/username changes while permitting the valid counterpart through the same unconsumed witness.

Native initial fixture did not move from the empty trailing line to the intended URL fragment: the text assertion showed the typed prefix on the last line and no offer. The failed test is retained; its optional diagnostic was terminated only after the test was terminal. The revised fixture uses a nonempty third line and verifies exact right-fragment position before typing. Empty-line trackpad behavior remains a separate investigation, not a proven address-completion failure.

Final validation: audits/turkish-round246-summary.json.

Round246 final: 432 cycles and three sensitive-component negative controls passed; 994 reported core executions passed (679 XCTest minus 90 skips plus 405 Swift Testing). Actual native case-folded email completion/continuation passed. Both URL middle-cursor fixtures failed BEFORE completion and remain a separate trackpad investigation in turkish-round246-trackpad-investigation.json; neither is claimed passing. Signed Release installed on the connected phone. Physical typing remains untested.


### Round247 - Cursor boundary drag must not type a space

A simulator-only proxy trace resolved the round246 URL cursor discrepancy: at the end of `https://EXAMPLE.com/Page\n.com/Page\nabc`, UIKit exposed before=`abc`, after=nil. The upward drag requested exactly -3, reaching the beginning of the exposed last line. Earlier lines were absent from the public proxy context; the core cannot infer their contents or column positions. This is retained as a host-context limitation, not a URL completion failure. Temporary diagnostic code was removed before the final builds; the trace is saved in turkish-round247-proxy-diagnostic.json.

A separate native boundary test confirmed a real bug: after a stationary hold armed the space-key trackpad, deliberate drags in all four directions at an empty document returned zero displacement and committed a space on release. The view suppressed space only when the host cursor actually moved. The fix marks the gesture consumed when movement exceeds the existing 14-point drag intent threshold on either axis; haptics still require actual cursor movement. Stationary holds and ordinary taps retain their space behavior.

The permanent native regression tests four blocked drags plus a regular tap and stationary hold. Existing actual native vertical ASCII and emoji movement tests are rerun alongside the full core suite. Final results: audits/turkish-round247-summary.json.

Round247 final: all six native boundary/tap/hold checks passed; ASCII and emoji vertical movement controls passed (three native tests total). Full core passed 994 reported executions. Signed Release installed on the connected phone. The round246 cursor investigation is resolved by captured proxy truncation plus this boundary-space fix; hidden earlier lines remain a documented host-context limitation.


### Round248 - Unicode line endings in cursor movement

CursorTrackpad lineStart/lineEnd compared Character values only with LF. CR, CRLF (one Swift Character with two UTF-16 units), NEL, Unicode line/paragraph separators, vertical tab and form feed were ignored. The permanent oracle constructs logical rows independently and checks every column in four ASCII/emoji/combining/empty/unequal-line fixtures with eight separators in both directions: 752 moves. Baseline had 343 failing position cases (686 position/offset assertions).

The fix uses Character.isNewline for both scans, retaining the existing grapheme position and UTF-16 prefix-offset conversion. Eight multi-step cases additionally verify preferred-column recovery across a short middle row. The first preferred-column fixture used31-point steps with an incorrect reversal expectation that ignored residual drag carry; the final fixture uses exact30-point increments and increasing timestamps. The initial full run therefore had16 fixture assertion failures although all752 position cases passed; it is retained separately from the final full run.

Two actual host-paste probes (CRLF and Unicode line separator) failed the desired cross-line UI expectation. Simulator-only proxy captures showed before=x and after=nil in BOTH, so the earlier line and separator were unavailable to the extension. These are documented host-context limits, not claimed passing Unicode UI coverage. The exploratory native fixture is archived as turkish-round248-native-probe.swift.txt and temporary instrumentation removed. Existing actual native ASCII/emoji vertical movement and boundary drag behavior are rechecked after the core fix.

Final evidence: audits/turkish-round248-summary.json.

Round248 final: all752 line-position moves and32 preferred-column steps passed;996 reported core executions passed. Three native controls passed (boundary drag, ASCII vertical, emoji vertical). Unicode pasted cross-line probes are NOT passing evidence: raw context contained only x. Signed Release installed on the connected phone; physical typing untested.


### Round249 - Independent word-cursor oracle for technical and Unicode text

A permanent core test compares WordBoundaries with independently extracted ICU non-whitespace ranges. Sixteen tokens cover protocols, IPv4/IPv6, email/local tags/quoted mail, URL paths and queries, Windows/Unix paths, developer identifiers, flags, versions, SSH syntax, phones, Turkish inflections, combining accents and emoji. Eight separators and three surrounding contexts produce384 documents and8320 valid grapheme cursor positions. Negative/zero/single/multiple/Int.max steps plus current-word bounds produce133120 exact UTF-16 offset comparisons. All passed; no new defect found.

The declared navigation contract is maximal non-whitespace runs: internal spaces in quoted mail or formatted phones are navigation boundaries, while punctuation within a run is preserved. This is not a new technical-token segmentation policy. Only tests and the stale LF-only trackpad documentation comment changed. No new native test or phone install was necessary; round248 remains the installed production build and the last full validation (996 reported core executions and3native controls). Evidence: audits/turkish-round249-summary.json.


### Round250 - Paired-wrapper completion defect reopened

The earlier wrapper audits tested learning of wrapped addresses followed by recall from an unwrapped prefix. They did not prove completion while the cursor is still inside an existing wrapper. This matrix tests four stored addresses (plain URL, URL with f(x), ordinary email, quoted-local-part email), eight explicit wrapper pairs plus bare controls, EOF/middle fragments, two leading contexts and two tails:288contexts. All32bare controls passed. Of256wrapped contexts,252had no exact offer and4offered an incorrect reconstruction.

Concrete corruption: before=`(https://example.com/f(`, after=`)`, stored value=`https://example.com/f(x)`. Existing completion interprets the outer `)` as the URL's inner right token and produces `(https://example.com/f(x)` instead of `(https://example.com/f(x))`. Four leading/tail variants fail the permanent exact-preservation assertion. Missing offers are counted independently in turkish-round250-analysis.json; a passing probe would not imply those gaps were fixed.

Implementation remains pending. Represent the explicitly paired outer wrapper separately from the address prefix/right token, retain exact before/after snapshot validation, and carry the boundary through history reconciliation. An explicit technical pick must learn the address without swallowing wrappers or retaining provisional quoted-name history. Keep URL-internal punctuation, escaped/quoted email local parts and unbalanced/code contexts distinct; require all eligible matrix offers and add negative controls. Then run full core, actual native wrapped completion and signed device installation. Do not merely suppress the four unsafe offers and call the252missing suggestions solved.

The new preservation regression is currently red (4failures). No production behavior changed or build was installed in this round; phone remains round248. This is an open confirmed defect, superseding previous no-open-defect snapshots. Evidence: audits/turkish-round250-summary.json.


### Round251 - Paired wrapper spans and completion acceptance

TechnicalTextSpan now separates explicit outer wrapper boundaries from the address prefix/right fragment. Parsing is bounded to eight layers and uses paired delimiters at a visible token boundary; attached code suffixes are not discarded. Completion retains the exact host before/after snapshot and supplies a cursor advance covering the preserved right address fragment plus outer delimiters/punctuation. The UI advances over those delimiters after explicit completion or literal confirmation.

History captures the same wrapper boundary in its immutable replacement witness, validates the unchanged retained right text, and finalizes the complete wrapped occurrence once. Existing wrapped address normalization now includes square/curly brackets and backticks; quoted-mail boundary admission recognizes those explicit delimiters while preserving attached path/identifier rejection. This lets acceptance learn the inner address and retract only owned provisional quote fragments, with the ordinary separator callback remaining idempotent.

All288original completion contexts now require and produce exact offers/reconstructions. New tests exercise512history transactions with independent seed/no seed, immediate counts and pairs, repeated acceptance/callbacks, and cursor advancement. Eighteen nested-wrapper/prose suffix combinations and ten adjacent-code negative controls supplement that matrix. Actual native tests cover nested-parenthesis URL and quoted email completion followed by a letter outside the preserved delimiter. Final results will be recorded in audits/turkish-round251-summary.json.

Round251 follow-up: the first full run caught16backtick-wrapped quoted-mail count failures and a nested-quote offer failure. Standalone closing backtick fragments no longer hide the completed email, and outer quote layers use an address hint before recursive syntax validation. The corrected full run passed1000reported tests. Two initial native preparation strategies failed to position the cursor before punctuation-only content, before completion was reached; their logs are retained. The final native fixture uses an existing alphanumeric address tail plus outer delimiter and verifies the exact pre-pick text before acceptance. Both URL and email completion/continuation passed. A final bounded-work guard limits wrapper parsing to64candidate attempts across all recursive layers, with four adversarial contexts checked separately.

Round251 native stabilization: repeating the gesture-based setup failed again BEFORE completion, leaving the partial address after the intended right fragment. Added a simulator DEBUG-only native UITextView host selected by -nativeKeyboardFixture. It uses the installed keyboard extension (no custom inputView or decoder harness), learns the seed through keyboard taps, then a host button sets exact before/after text and UTF-16 selection for the actual pick. Its text/selection setup is test-only and excluded from Release/device builds. Two native wrapped flows passed with this host; final verification additionally includes both original closing-delimiter-only cases, so cursor advancement when rightToken is empty is exercised. All failed preparation logs remain evidence and are not counted as completion passes.

Round251 final: all288exact offers/reconstructions,512history transactions,18nested/prose cases,10adjacent-code negatives and4bounded-search controls pass. Final full core:686XCTest minus90skips plus405Swift Testing =1001reported executions,zero failures. Final native fixture passed four flows (URL/email,existing right fragment/closing-delimiter-only), including the original corruption shape. Signed Release installed successfully; physical typing untested. Round250 confirmed defect is resolved by this evidence.


## Round252 — paired-wrapper depth-limit fallback

A new384-case matrix covers1–12 outer layers,4wrapper pairs,4URL-internal parenthesis depths, and2leading contexts. Baseline produced8incorrect reconstructions:9–12 outer parentheses were consumed as part of stored URLs ending in12internal parentheses. At the recursion limit the generic parser stripped opening wrappers but treated their closers as URL data.

The shared span parser now refuses generic fallback after recognizing a paired address wrapper, including when its8-layer/64-candidate bounds are reached. All256supported cases offer exact reconstructions;128over-depth cases withhold completion. Existing288wrapper and512history cases remain green. Full core:687XCTest minus90skips plus405SwiftTesting =1002reported executions,0failures. Native simulator test passes4supported address completion/continuation flows; depth-limit regressions are core tests. Signed Release installed successfully on the connected phone; physical typing untested. Evidence: audits/turkish-round252-summary.json.


## Round253 — explicit completion in pre-existing fields

The80-case regression attaches directly to nonempty host contexts and selects URL, normal/quoted email, formatted phone andIPv6 completions. It varies leading prose, right prose, EOF/interior cursor and independent history. Baseline:40missing immediate learning events and16additional post-separator overcounts;136failing assertions total. These are two related observation-path defects, not136distinct bugs.

A host-verified explicit replacement now supplies only its exact completed technical token to private boundary processing. This narrow witness bypasses passive left-edge ambiguity without claiming the whole document start was observed. Bounded document-local explicit receipt IDs allow the existing occurrence guard to deduplicate later separators. Document changes/reset clear those IDs; incompatible edits still invalidate ordinary occurrence receipts.

All80histories now pass immediate token/pair counts, repeated acceptance rejection and3separator callbacks. Full core:688XCTest minus90skips plus405SwiftTesting =1003reported executions,0failures. Native simulator:4prefilled-field completion/text/continuation flows pass; counts are core evidence. Signed Release installed successfully; physical typing untested. Evidence: audits/turkish-round253-summary.json.


## Round254 — explicit technical receipts across cursor movement

The60-case lifecycle matrix covers5technical values,2leading contexts,2right contexts and3cursor destinations after an explicit completion in a pre-existing field. Baseline:40histories overcount the unchanged address after a cursor roundtrip;120assertions fail including downstream expected totals. Cause: unchanged-document receipt preservation depended solely on observedStart, so explicit receipts from unanchored fields were discarded.

The continuity guard now also accepts an owned explicit technical occurrence when document identity and the full visible snapshot are unchanged. This preserves ownership across cursor-only movement. All60cases now keep history exactly unchanged after the roundtrip and3separator callbacks; actual deletion/retyping and reset/new-document boundaries still add fresh occurrences.

Full core:689XCTest minus90skips plus405SwiftTesting =1004reported executions,0failures. Four native simulator completion/continuation flows pass. Cursor history counts are core evidence; physical typing untested. Signed Release installed successfully. Evidence: audits/turkish-round254-summary.json.


## Round255 — stale/partial result safety in pre-existing fields

Added80permanent histories spanning URL scheme/host case folding, mailbox domain case folding, quoted email, formatted phone andIPv6. Each varies leading prose, right prose, EOF/interior cursor and independent history. Four invalid result variants (truncated left, nil right, altered right, other document) are rejected without mutating the current witness state; the subsequent valid completion learns exactly once, with exact token/pair counts. Three duplicate callbacks then leave history unchanged.

Targeted test passes:320invalid results rejected,80valid completions accepted after rejections,240duplicate callbacks rejected. No new defect or production change. This run is not a new full-suite or native result; last full1004reported executions and4native flows are round254. Installed phone version remains254. Evidence: audits/turkish-round255-summary.json.


## Round256 — URL query/fragment punctuation inside wrappers

Added1728permanent cases:12query/fragment suffixes,2prefix positions,9wrapper choices (bare plus8pairs),EOF/interior cursor,2leading contexts and2right prose contexts. Values include literal parentheses,comma,semicolon,colon,exclamation,question mark,dot,apostrophe,percent-encoded parentheses,ampersand andfragment identifiers. Wrapped addresses followed by prose include an external comma.

All cases provide the exact expected completion and preserve original literal spans, external delimiters/right text and cursor advance distance. Targeted test passes with0failures. No production change; full core/native/device evidence remains round254 (1004reported executions,4native flows), and installed phone version remains254. Evidence: audits/turkish-round256-summary.json.


## Round257 — URL query/fragment learning identity

Added864permanent learning histories using12query/fragment suffixes,9wrapper choices,EOF/interior cursor,2leading contexts and2right contexts. Each selects a completion in a pre-existing field and checks exact event-token identity plus all token/pair counts against independent expectations. Three separator callbacks must not count the address again. A following natural word must learn once with the expected previous token. Independent seeded words/pairs must survive.

All864cases pass. No production change; this is targeted core evidence only. Latest full core/native/device evidence remains round254 (1004reported executions,4native flows), with installed phone version254. Physical typing untested. Evidence: audits/turkish-round257-summary.json.


## Round258 — Unicode right-tail completion and native cursor units

Refined84-case baseline reproduced72missing Unicode completions and preserved12ASCII controls. Coverage includes Turkish domains/paths,normal/quoted email,NFD combining letters andZWJ emoji,with bare/parenthesis/quote wrappers andleading/right prose. The earlier draft also included incomplete scheme/mailbox separator contexts and is retained separately.

Removed the obsolete ASCII-only right-tail gate; exact candidate suffix and snapshot checks still apply. Core reconstruction keeps grapheme-based slicing. A separate cursorAdvanceUTF16Count supplies UIKit offsets for technical completion and literal confirmation. The broader1096-context Unicode audit retains exact reconstruction,snapshot andno-redundant-offer checks; its old Unicode-withholding assertion was replaced with exact UTF16 cursor-distance validation. First full run had266old-policy assertion failures; final full run passes.

Final core:693XCTest minus90skips plus405SwiftTesting =1008reported executions,0failures. All84new cases pass;266broader contexts now have Unicode offers. Native simulator checks Turkish,NFD andZWJ paths atEOF andbefore following prose; text after completion andcontinued typing proves exact cursor placement without overshoot. Fourexisting wrapper flows also pass. Signed Release installed successfully on the connected phone; physical typing untested. User explicitly requested pausing the goal after this successful install. Evidence: audits/turkish-round258-summary.json.
