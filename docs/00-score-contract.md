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
- `min_A` bir yaklaşım değil, **skorun tanımıdır**. Dedup'ın durum başına en iyi yolu tutması
  tanımı gereği doğrudur.
- Dil sıcaklık/offset'i ve backoff skorları meşru ağırlık kalibrasyonudur.

### Bağlayıcı üç disiplin

1. **Tek sahiplik** — hiçbir kanıt iki özniteliğe birden girmez (§2).
2. **Tek kalibre karar** — kullanıcının hissettiği tek şey `θ`; kalibrasyonu ölçülür.
3. **Prefix-causality** — bir geçişin maliyeti yalnız `touchIndex`, **geçmiş** ve o geçişin
   *kendi tükettiği* gözlemlere bağlıdır. Gelecekteki gözleme bağlı öznitelik **yasaktır** (§3).

---

## 2. Öznitelik vektörü

```
cost(w, A, ℓ | T, ctx) = Σ_k  w_k · F_k
cost(w, ℓ)             = min_A cost(w, A, ℓ | T, ctx)        ← skorun TANIMI
```

**Düz vektör, tek seviyeli katsayılar.** Dış grup ağırlığı × iç ağırlık kullanılmaz — o kombinasyon
gauge serbestliği yaratır (aynı sıralamayı veren sonsuz katsayı seti).

**Ölçek sabitleme:** `w_spa ≡ 1`. Diğer tüm ağırlıklar buna göre fit edilir.

| # | Öznitelik | Tip | Ağırlık | Tanım |
|---|---|---|---|---|
| 1 | `F_spa` | sürekli | **≡ 1** | `Σ −log p(t_i \| c_j)` — doğrudan (eşdeğerlik-dışı) SUB ve TR üzerinden |
| 2 | `F_spa_eq` | sürekli | `w_spa_eq` | aynı toplam, ama **eşdeğerlik sınıfı** arkından geçen SUB'lar üzerinden (beklenen: `< 1`) |
| 3 | `F_eq` | sayaç | `w_eq` | eşdeğerlik sınıfı ikamesi sayısı (`c→ç`, `g→ğ`, `i→ı`, `o→ö`, `s→ş`, `u→ü`) |
| 4 | `F_om_gem` | sayaç | `w_om_gem` | atlanan karakter **önceki emisyona eşit** (`elli`, `anne`) |
| 5 | `F_om_init` | sayaç | `w_om_init` | kelime başında atlama (`atWordStart`) |
| 6 | `F_om` | sayaç | `w_om` | diğer atlamalar |
| 7 | `F_ins_near` | sayaç | `w_ins_near` | önceki dokunmaya `Δt < τ_fast` **ve** mesafe `< d_near` (çift dokunma artefaktı) |
| 8 | `F_ins` | sayaç | `w_ins` | diğer fazla dokunmalar |
| 9 | `F_ins_bg` | sürekli | `w_ins_bg` | `Σ −log p_bg(t_i)` fazla dokunmalar üzerinden |
| 10 | `F_tr` | sayaç | `w_tr` | transposition sayısı |
| 11 | `F_len` | sayaç | `w_len` | **emisyon sayısı `m`** |
| 12 | `F_lex` | sürekli | `w_lex` | yüzey formunun leksikal maliyeti (§7) |
| 13 | `F_ctx` | sürekli | `w_ctx` | bağlam **delta**'sı: `−log P̂(w\|ctx,ℓ) + log P̂(w\|ℓ)` |
| 14 | `F_lang_prior` | sürekli | `w_lang` | `−log P̂(ℓ \| oturum)` |
| 15 | `F_lang_switch` | gösterge | `w_switch` | `[ℓ ≠ ℓ_önceki]` |
| 16 | `F_lang_off_ℓ` | gösterge | `offset_ℓ` | dil başına sabit; **`offset_tr ≡ 0`** (gauge) |

**16 öznitelik, 14 serbest ağırlık** (`w_spa` ve `offset_tr` sabitlenmiş).

### Tek sahiplik kuralı

| Kanıt | Tek sahibi | Girmediği yer |
|---|---|---|
| Harf sıklığı | `F_lex` | uzamsal terimlere **girmez** |
| Unigram kütlesi | `F_lex` | `F_ctx` onun üzerine **delta**'dır, mutlak değil |
| Ark üzerindeki ek maliyeti | `F_lex` bileşeni | ayrı ceza olarak **eklenmez** |
| Kelime uzunluğu | `F_len` + `F_lex` | ayrı "her adım survival öder" terimi **yoktur** |
| Morfem sayısı | `F_lex` bileşeni | ayrı ceza **yoktur** |

### Olay → öznitelik eşlemesi

| Olay | Tüketir | Emisyon | Katkı |
|---|---|---|---|
| `SUB` | `t_i` | `c_j` | `F_spa += −log p(t_i\|c_j)`; `F_len += 1` |
| `SUB_eq` | `t_i` | `c_j` | `F_spa_eq += −log p(t_i\|c_j)`; `F_eq += 1`; `F_len += 1` |
| `OM` | — | `c_j` | `F_om_{gem\|init\|·} += 1`; `F_len += 1` |
| `INS` | `t_i` | — | `F_ins_{near\|·} += 1`; `F_ins_bg += −log p_bg(t_i)` |
| `TR` | `t_i, t_{i+1}` | `c_j, c_{j+1}` | `F_tr += 1`; `F_spa += −log p(t_i\|c_{j+1}) − log p(t_{i+1}\|c_j)`; `F_len += 2` |
| `END` | — | — | **kendi katkısı yok**; yalnız otomat kabul durumundayken yasal |

`END`'in katkısı olmaması bilinçlidir: uzunluk etkisi tamamen `w_len·m` ve `F_lex` üzerinden gelir.
`END` çoğu karakter geçişinde yasal olmadığı için "her devam adımı survival öder" matematiği zaten
oluşmaz.

### Bütçe yok

Insertion/omission için **sabit sayaç bütçesi kullanılmaz.** Edit olayları ağırlıklarıyla
caydırılır, sayaçla yasaklanmaz. Gerekçe: bütçe ya modelin parçası olup state'i şişirir, ya da
yalnız arama kısıtı olup dedup'ta iki farklı bütçe kullanımının birleşmesiyle yanlış sonuç üretir.
İkisi de istenmiyor. Profil bir üst sınır gerektirirse, o zaman **arama sezgiseli** olarak eklenir
ve bu belgeye kaydedilir.

### Uzamsal öznitelikler — ortak referans ölçüsü

`p(t|c)` ve `p_bg(t)` ikisi de `[0,1]²` üzerinde yoğunluktur.

- `p(t|c)`: klavye alanında **truncate edilmiş** 2B Gaussian, `[0,1]²` üzerinde yeniden
  normalize. Normalizasyon sabiti dokunma başına hesaplanmaz — kalibrasyon tablosuyla birlikte
  önceden hesaplanır.
- `p_bg(t)`: arka plan dokunma yoğunluğu, aynı `[0,1]²` ölçüsünde.

Aksi halde cihaz/geometri ölçeği değiştikçe `INS`/`SUB` dengesi kayar. **Test:** her ikisinin de
sayısal integrali 1 olmalı.

---

## 3. Prefix-causality denetimi

Her öznitelik, alındığı anda `(touchIndex, geçmiş, o geçişin kendi tükettiği gözlemler)` bilgisiyle
hesaplanabilmelidir.

| Öznitelik | Neye bakar | Prefix-causal? |
|---|---|---|
| `F_spa`, `F_spa_eq` | `t_i` (tüketilen), `c_j` (ark) | ✅ |
| `F_eq` | ark tipi | ✅ |
| `F_om_gem` | **önceki emisyon** (`lastEmitted`) | ✅ geçmiş |
| `F_om_init` | `atWordStart` bayrağı | ✅ geçmiş |
| `F_ins_near` | `t_i` ile `t_{i−1}` arası `Δt` + mesafe | ✅ geçmiş |
| `F_ins_bg` | `t_i` | ✅ |
| `F_tr` | `t_i, t_{i+1}` — **kendi tükettikleri** | ✅ (aşağıdaki nota bak) |
| `F_len` | artımlı biriken sayaç | ✅ |
| `F_lex` | maliyet itmeli prefix maliyeti | ✅ |
| `F_ctx` | tamamlanmış `w` — **`END` olayında** uygulanır | ✅ terminal |
| `F_lang_*` | yol boyunca sabit / oturum durumu | ✅ |

**Yasaklı öznitelikler** (planda bir kez yanlışlıkla kabul edilmişti, kaldırıldı):
`kalan dokunma sayısı`, `toplam dokunma sayısı n`, `kelimenin nihai uzunluğu`.
Bunlar matematiksel olarak meşru olurdu ama **artımlı kod çözmeyi geçersiz kılar**: yeni dokunma
geldiğinde geçmiş geçişlerin maliyeti değişir, `modelVersion` sabit olsa bile saklanan beam bayatlar
ve geri alınamayan budama kararları yanlış olur.

### ⚠️ `TR`'nin uygulama sonucu: bir dokunmalık gecikme

`TR` iki dokunma tüketir. Prefix-causality ihlali **değildir** (yalnız kendi tükettiklerine bakar),
ama artımlı decoder için somut bir sonucu vardır:

> Dokunma `i+1` geldiğinde, `TR(t_i, t_{i+1})` ancak o an değerlendirilebilir — kaynağı
> `touchIndex = i−1` frontier'ıdır.
>
> **Bu yüzden beam, yalnız güncel frontier'ı değil, bir önceki adımın frontier'ını da tutar.**
> Ping-pong tampon yerine **üç yuvalı halka** gerekir: `i−1`, `i`, `i+1`.

Bu, §11'deki performans mimarisini doğrudan etkiler ve `-1A₁`'de böyle kurulacaktır.

### `F_ctx`'in budamaya katkısı yok

`F_ctx` yalnız `END`'de uygulandığı için erken budamaya yardım etmez. v1'de kabul edilen bir
özelliktir. (İleride admissible bir alt sınır itilebilir; ölçüm göstermedikçe yapılmaz.)

---

## 4. Decoder state şeması

Bir durum, **gelecekteki maliyetleri etkileyen her şeyi** taşımalı; fazlasını taşımamalı
(taşırsa beam gereksiz yere çeşitlenir, birleşme oranı düşer).

```
DecoderState:
  automaton     : UInt3    // AutomatonKind: formTrie | morphology | personal | domain
  language      : UInt2    // en fazla 2 aktif dil + rezerv
  node          : UInt32   // kaynağa özgü paketlenmiş düğüm kimliği
  touchIndex    : UInt6    // tüketilen dokunma sayısı (0..63)
  lastEmitted   : UInt8    // son emisyon sembol kimliği — F_om_gem sınıflandırması için
  atWordStart   : UInt1    // F_om_init sınıflandırması için
                 ────────
                 52 bit   → tek UInt64'e sığar
```

### Her alanın gerekçesi

| Alan | Neden gerekli | Çıkarılırsa ne olur |
|---|---|---|
| `automaton`, `language`, `node` | otomat pozisyonu | farklı kelimeler karışır |
| `touchIndex` | gözlem pozisyonu | farklı dokunma öneklerini tüketmiş yollar karışır |
| `lastEmitted` | `F_om_gem` sınıfı önceki emisyona bağlı | ikiz harf indirimi yanlış uygulanır |
| `atWordStart` | `F_om_init` sınıfı | kelime başı atlama maliyeti yanlış olur |

### `editContext` çözüldü

Plandaki tanımsız `editContext` alanı, işi yapınca **`lastEmitted` + `atWordStart`'a indi**:

- **Yarım transposition durumu yok** — `TR` atomiktir (2 tüketir, 2 emisyon yapar), araya
  girilemez.
- **Insertion bütçesi yok** (§2 "Bütçe yok").
- **Önceki tüketilen dokunmanın indeksi ayrı alan değil** — dokunmalar kesinlikle sırayla
  tüketildiği için her zaman `touchIndex − 1`'dir.

### Dedup anahtarı

Anahtar = `DecoderState`'in tamamı (52 bit). Aynı anahtara varan yollar birleşir, en düşük maliyet
kalır — `min_A` tanımı gereği doğrudur.

**Doğruluk tahmin edilmez, kanıtlanır:** küçük girişlerde dedup kapalı exhaustive aramayla birebir
eşdeğerlik testi (§5).

---

## 5. Exhaustive oracle — referans recurrence

Beam'in karşılaştırılacağı **tam** aramanın tanımı. Küçük leksikonda tüm kelimeler taranır; her
kelime için hizalamalar üzerinde tam DP yapılır.

Sabit bir `w = c₁..c_m` ve `T = t₁..t_n` için:

```
D[i][j] = ilk i dokunmayı ilk j karaktere hizalamanın minimum maliyeti

D[0][0] = 0
D[i][j] = min(
    D[i−1][j−1] + sub(i, j),                    // SUB veya SUB_eq
    D[i  ][j−1] + om(j),                        // OM   (dokunma tüketmez)
    D[i−1][j  ] + ins(i),                       // INS  (emisyon yapmaz)
    D[i−2][j−2] + tr(i, j)                      // TR   (i ≥ 2, j ≥ 2)
)

cost(w, ℓ) = D[n][m]
           + w_len·m
           + w_lex·F_lex(w, ℓ)
           + w_ctx·F_ctx(w, ctx, ℓ)
           + w_lang·F_lang_prior(ℓ) + w_switch·[ℓ≠ℓ_prev] + offset_ℓ
```

Birim maliyetler:

```
sub(i, j) = eşdeğerlik arkı ise:  w_spa_eq·(−log p(t_i|c_j)) + w_eq
            değilse:                    1·(−log p(t_i|c_j))

om(j)     = c_j == c_{j−1}  →  w_om_gem
            j == 1          →  w_om_init
            değilse         →  w_om

ins(i)    = (Δt(i,i−1) < τ_fast ∧ dist(i,i−1) < d_near) →  w_ins_near + w_ins_bg·(−log p_bg(t_i))
            değilse                                      →  w_ins     + w_ins_bg·(−log p_bg(t_i))

tr(i, j)  = w_tr + (−log p(t_i|c_{j+1})) + (−log p(t_{i+1}|c_j))
```

### DP'nin doğruluğu — state şemasının kanıtı

Yukarıdaki birim maliyetlerin hepsi **yola değil, yalnız `(i, j)` ve sabit `w`, `T`'ye** bağlıdır:

- `om(j)` sınıfı `c_j` ile `c_{j−1}`'e bakar — hangi yoldan gelindiğinden bağımsız, çünkü `j`
  pozisyonundaki önceki emisyon her zaman `c_{j−1}`'dir.
- `ins(i)` sınıfı `t_i` ile `t_{i−1}`'e bakar — `T` sabit.
- `sub`, `tr` yalnız `(i, j)`'ye bakar.

Dolayısıyla `(i, j)` **yeterli istatistiktir** ve DP tam çözümdür. Bu, §4'teki decoder state
şemasının doğrudan doğrulamasıdır: `(i, j)` ↔ `(touchIndex, node)`, artı sınıflandırma için
`lastEmitted`/`atWordStart` — DP'de bunlar `w`'den okunduğu için ayrı alan gerekmez, otomat
yürüyüşünde ise gerekir (aynı `node`'a farklı önceki emisyonla varılabilir).

### Test kapıları

1. **Eşdeğerlik**: küçük leksikon (≤ 2000 kelime) + kısa girdi (≤ 8 dokunma) üzerinde,
   yeterli beam genişliğinde beam çıktısı oracle ile **birebir aynı** olmalı.
2. **Dedup güvenliği**: dedup açık/kapalı sonuç aynı olmalı.
3. **Artımlı eşitliği**: artımlı decode ile sıfırdan tam decode **birebir aynı** sonucu vermeli
   (prefix-causality'nin makine denetimi).
4. **Literal kanalı**: hiçbir otomatta olmayan, n-gram uzunluk sınırını aşan ve alfabe dışı
   karakter içeren token'lar dahil **her sonlu Unicode token'ı** sonlu maliyet almalı.

---

## 6. Ağırlık eğitimi ve tanımlanabilirlik

Ağırlıklar **dev setinde**, yanlış-düzeltme oranı hedefiyle fit edilir; **test setinde asla**
yeniden ayarlanmaz.

**Tanımlanabilirlik riski:** güçlü kullanıcı sinyalleri hedef *kelimeyi* verir, gerçek *edit olay
dizisini* vermez. Hizalamaları kendi Viterbi decoder'ımızdan çıkarıp `F_om_*`/`F_ins_*`/`F_tr`
ağırlıklarını onunla eğitmek **döngüseldir**.

Bu yüzden:

1. **Elle doğrulanmış hizalama seti** (birkaç yüz kelime) referans olarak tutulur.
2. Geri kalanda latent-hizalama eğitimi kullanılır.
3. **Ablation** ile her ağırlığın ayrı ayrı belirlenebildiği gösterilir. Belirlenemeyen ağırlık
   **sabitlenir, uydurulmaz**; sınıfı komşusuyla birleştirilir.
4. Her ağırlığın kelime uzunluğu ve dokunma sayısı dilimlerinde kararlılığı ayrı doğrulanır —
   yalnız ortalamada çalışan global bir ağırlık kırmızı bayraktır.

**Yeterli veri yokken varsayılanlar:** `w_spa = 1`, `offset_tr = 0`, edit ağırlıkları elle
seçilmiş sabitler, `w_len` küçük negatif (uzun kelime hafif cezalı), sınıflar birleşik.

---

## 7. `F_lex` — leksikal maliyet

Her `(NFC-normalize UTF-8 yüzey formu, dil)` anahtarının **tek** bir `F_lex` değeri vardır.
Kaynaklar (form trie, morfoloji, kişisel, alan sözlüğü) aynı skorun *alternatif yürütme
mekanizmalarıdır*:

- Form listesinde varsa → değer oradan (gerçek korpus frekansı). Morfoloji aynı yüzeye ulaşsa bile
  **kendi maliyetini eklemez**.
- Yoksa → morfoloji üretim maliyetinden verir; ölçek uyumu paket üretiminde kalibre edilir.
- Hiçbirinde yoksa → **açık-vocabulary literal kanalı**:
  `F_lex = w_unk + F_char_ngram(w | OOV)`.
  Karakter n-gram: alfabe paketten, BOS/EOS sembolleri, uzunluk sınırı.
  **Taşma:** sınırı aşan her karakter `w_tail`, alfabe dışı her karakter `w_oov_char`; token
  ayrıca literal korumaya düşer (`θ = ∞`).
- Aynı yüzey **asla iki kanaldan birden** maliyet almaz.

**Maliyet itme (cost pushing):** leksikal maliyet paket üretiminde arklar boyunca öne itilir; her
düğüm oradan ulaşılabilir en iyi kelimenin maliyetini (admissible alt sınır) taşır. Böylece prefix
maliyetleri kaynaktan bağımsız karşılaştırılabilir olur ve beam adil budar. Çalışma anı maliyeti
yoktur.

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

---

## 9. Değişiklik kaydı

| Tarih | Değişiklik |
|---|---|
| 2026-07-28 | İlk sürüm. Log-linear normatif seçim; prefix-causality bağlayıcı kural; `editContext` → `lastEmitted` + `atWordStart` sadeleşmesi; `TR` bir-dokunmalık gecikme sonucu; oracle recurrence ve DP yeterlilik kanıtı. |
