# Plan v7 — kayıt zinciri: kayıpsız olgular, gerçek konteyner, bağımsız replay

`1df2d19` temiz, 371 test. Kod yazılmadı. v1 ve v2 iki incelemeden de REVISE aldı.
Bu sürüm v2'nin kapanmayan maddelerini kapatıyor. İşaretler: **[F]** Fable,
**[C]** Codex, **[F+C]** ikisi. Kod üzerinde doğrulanmış olgular *(dosya:satır)*.

---

## 0. Kapanmayan bulgular ve karşılıkları

| # | Bulgu | v3'teki yer |
|---|---|---|
| B1 **[C blocker]** | `detachedEvidence: Bool` kayıpsız değil — canlı taraf `isDetached`'i temizliyor *(ComposingSession 314, 342, 453, 592)*, reducer temizlemiyor | §2.1 post-state |
| B2 **[C blocker]** | `invalidateLastToken` hedefsiz — tekrarlı silme yanlış token'ı işaretler | §2.1 `tokenID` |
| R1 **[F]** | Reopen meşruiyet kuralı yok *(`hasSuffix(" ")` + tam eşitlik, ComposingSession 326-335)* | §2.1 tablo + §2.5 |
| R2 **[F]** | `deleteWordBackward`'ın iki alt durumu *(242-293: `removeLast` vs `removeAll`)*; ayırıcı silme; tekrarda daha eski token | §2.1 |
| R3 **[F]** | Seçim kipi ne şemada ne reducer'da | §2.5 + §3.11 |
| C1 **[C]** | Tek huni `log()` yetmez — mutasyon önce, log sonra | §2.6 komut kapısı |
| C2 **[C]** | Journal `textAfter` ile O(n²)'yi çözmüyor | §2.7 `DocumentMutation` |
| C3 **[C]** | Journal crash-consistency sözleşmesi yok; `pull-sessions` `*.json` arıyor | §2.7 |
| C4 **[C]** | "unknown" olgular canonical modelde temsilsiz | §2.2 epistemik tip |
| C5 **[C]** | `EngineSnapshot` eksik; `PackLoader` `Apps/` altında | §2.8 |
| C6 **[C]** | Replay girdi/karşılaştırma sözleşmesi eksik | §2.9 `ReplayCommand` |
| C7 **[C]** | Fail-closed, zorunlu abort kayıtlarıyla çelişiyor | §2.10 tüketici bazlı |
| C8 **[C]** | §7 üretim codec'ini sınamadan RecordingEngine kuruyor; **modül döngüsü** | §7 |
| m1 **[C]** | Tokenizer Unicode/boş hedef sınırı | §2.3 |
| R6 **[F]** | Adım 0'ın bazı testleri bugün koşulamaz | §2.0 |

---

## 2. Kapsam

### 2.0 Adım 0 — baseline + karakterizasyon *(sınırları işaretli)* [F+C]

Baseline **hiçbir kod değişmeden** `1df2d19` üzerinde üretilip commit'lenir.

**Bugün test edilebilenler:** importer tarafı (`TypingSession` programatik kurulur,
`SessionReplayTests` bunu zaten yapıyor) ve `InputCoordinator`/`ComposingSession`
davranışları — A4 detach yolu dahil.

**Bugün test edilemeyenler [F]:** A1'in "newline commit yazmıyor"u ve A3'ün
`wordIndex−1` çifte hizalaması `RecorderViewController`'da; `Apps/` test hedefi
taşımıyor. Karakterizasyonları elle kurgulanmış fixture'a dayanır, **VC'nin
kendisini test etmez**; gerçek kapanışları adım 5'te (`RecordingEngine` SwiftPM'e
taşınınca). Bu sınır plana ve teste yorum olarak yazılır.

**Kırmızı test mekanizması [F]:** repoda XFAIL yok. swift-testing `withKnownIssue`
kullanılır; düzeltme gelince `withKnownIssue` kaldırılır — kaldırma işlemi
davranış değişikliğinin kanıtı olur.

### 2.1 Kayıpsız yıkıcı olgular — **`KBRuntime`'da** [C8]

`KBSessions`'a koymak `KBSessions ↔ KBRuntime` döngüsü açar.

```swift
// KBRuntime
public struct TokenID: Hashable, Codable { public let raw: Int }

public struct DestructiveEffect: Sendable, Codable, Equatable {
    public enum PendingMutation: String, Codable {
        case none, dropLast, dropAll, restoreToken
    }
    /// Silinen belge aralığının token'lara atfı — **sıralı liste** [C].
    ///
    /// Tek bir case yetmiyor: `deleteWordBackward` önce boşlukları, sonra **tüm**
    /// non-whitespace diziyi siliyor *(271)*. Tokenizer'ın **iki** token saydığı
    /// `wi-fi ` tek çağrıda ikisini ve ayırıcıyı birden yiyebilir.
    public enum DeletedSpan: Codable, Equatable, Sendable {
        /// Token'ın **bir kısmı**; kalanı belgede duruyor. Cursor geri alınmaz.
        case editedToken(TokenID)
        /// Token **tamamen** gitti.
        case removedToken(TokenID)
        /// Ayırıcı — hiçbir token'a ait değil.
        case separator
        /// Defterde karşılığı yok.
        case unattributed
    }
    /// Belgeden silinen aralıklar, **belgedeki sıraya göre** (eskiden yeniye).
    ///
    /// **Kanonik biçim** [C] — golden karşılaştırması ancak tekilse anlamlı:
    /// bitişik ayırıcılar **tek** `.separator`'a, bitişik `.unattributed`'lar tek
    /// öğeye indirgenir; her token en fazla **bir** span katkısı yapar; sıra
    /// daima eskiden yeniye; `[]` "hiçbir şey silinmedi".
    public var deleted: [DeletedSpan]
    /// Olay değil **post-state** [B1]: canlı `isDetached` üç yerde temizleniyor.
    public enum EvidenceState: String, Codable { case attached, detached, cleared }

    public var pending: PendingMutation
    public var evidenceStateAfter: EvidenceState
    /// `restoreToken`'da hangi token geri açıldı.
    public var restoredToken: TokenID?
}
```

**`tokenID` commit anında üretilir** ve `history` girdisine, `TokenCommitReport`'a
ve reducer token'ına birlikte taşınır [B2].

**Operasyon × geçerli etki tablosu** (validator zorlar; kodla satır satır eşlendi)

> **Son sütun `setsDivergence`** — post-state değil **neden** [C]. Etkin değer
> `prior || setsDivergence`; §3.6 monotonluğu böyle korunur ve sınır satırlarının
> "hayır"ı onunla çelişmez.
>
> **Divergence yalnız hedef eşlemesi gerçekten kaybolduğunda** başlar:
> `unattributed` span, ya da `removedToken` sonrası cursor geri alınamıyorsa.
> `foo␠␠ → backspace` (fazladan ayırıcı) ve boş belgede `space → backspace`
> **tam hizalı duruma döner**; koşulsuz `diverged` yazmak denemeyi sonsuza dek
> kaybederdi [C].

`backspaceTap` / `backspaceRepeat`, composing varken — **tek satır değil beş** [B1/Y1]:

| Durum | pending | deleted | evidenceAfter | setsDivergence |
|---|---|---|---|---|
| hizalı silme, yüzey kalıyor | `dropLast` | `[]` | `attached` | hayır |
| hizalı silme, yüzey **boşaldı** *(satır 314)* | `dropLast` | `[]` | `cleared` | hayır |
| **hiza bozuldu** → `detachEvidence()` *(303-316, 320-324)* | `dropAll` | `[]` | `detached` | **evet** |
| zaten `detached`, yüzey kalıyor | `none` | `[]` | `detached` | hayır (önceki korunur) |
| zaten `detached`, **yüzey boşaldı** *(314 detached dalda da koşuyor)* | `none` | `[]` | **`cleared`** | hayır (önceki korunur) |

`backspaceTap`, composing yokken:

| Durum | pending | deleted | evidenceAfter | setsDivergence |
|---|---|---|---|---|
| reopen başarılı | `restoreToken` | `[]` | `attached` | **hayır** |
| reopen başarısız, silinen **ayırıcı** | `none` | `[.separator]` | `cleared` | hayır (hiza korunur) |
| reopen başarısız, silinen karakter bir token'a ait | `none` | `[.editedToken(id)]` | `cleared` | **evet** |
| atfedilemedi | `none` | `[.unattributed]` | `cleared` | **evet** |
| belge boş, **no-op** *(250)* | `none` | `[]` | `cleared` | hayır |

`backspaceRepeat`, composing yokken *(233)* — aynı dört satır; **`.separator` dahil**
[Y3]: toplu silmede ilk tekrar tam olarak ayırıcı boşluğu siler, en yaygın yol.

`deleteWord` *(242-293)*:

| Durum | pending | deleted | evidenceAfter | setsDivergence |
|---|---|---|---|---|
| composing var → `clearComposing()` *(247)* | `dropAll` | `[]` | `cleared` | hayır (cursor değişmiyor) |
| belge boş, no-op *(250)* | `none` | `[]` | `cleared` | hayır |
| **satır sonu sınırı** *(265-269)* | `none` | `[.separator]` | `cleared` | hayır |
| defterden atfedildi (bir ya da **çok** token) | `none` | `[.removedToken(id), …]` | `cleared` | cursor geri alınamıyorsa **evet** |
| defterde yok | `none` | `[.unattributed]` | `cleared` | **evet** |

**Sınır operasyonları da tabloda** [Y2] — `finishToken → clearComposing` `isDetached`'i
sıfırlıyor *(589-596)*; tabloda olmazlarsa reducer'ın evidence'ı sonsuza dek `detached`
kalır ve sonraki **tüm** harfler yanlışlıkla düşer:

| Operasyon | pending | deleted | evidenceAfter | setsDivergence |
|---|---|---|---|---|
| `space` / `symbol` / `suggestionPick` / `newline` | `none` | `[]` | **`cleared`** | hayır |
| `suggestionPick`, **`detached` iken no-op** *(guard 374)* | `none` | `[]` | `detached` | hayır (önceki korunur) |

Son satırın gerekçesi: `suggestionSurfaces` *(476-494)* detached iken de genişletme
yüzeyi gösterebiliyor ve dokunuş `pickSuggestion`'a gidiyor; guard `.empty()`
döndürüp ne oturuma ne belgeye dokunuyor. Sınır satırının `cleared`'ı dayatılırsa
meşru kayıt violation sayılırdı.

**`editedToken` ≠ `removedToken`** [C]: ikisi de `invalidate` altında birleşemez.
Tek karakter silmede cursor **geri alınmaz** (belgede token'ın kalanı duruyor);
yalnız **tam token silindiği kanıtlandığında** `cursorBefore`'a dönülür.

**Reopen meşruiyeti [R1/C]** — validator: `restoreToken` ancak (a) `pending` boş,
(b) hedef token history **tepesinde**, (c) sınırı `space` **ya da** `suggestionPick`,
(d) belgede tam `display + " "` soneki, (e) araya history silen olay girmemiş
— `removeAll` çağıran yollar açıkça: *221, 234, 267, 290, 299, 570* (ve erişilemez `beginEditingSelection` 448) ve `newline`'ın
`invalidate()`'i *(203)* —, (f) derinlik ≤ 8 *(118)* iken meşrudur; aksi **violation**.

**Belge-aralığı defteri (`TokenLedger`) [C]** — reopen history'sinden **ayrı**.

`history` sınırlı (`maxHistoryDepth = 8`) ve birçok yolda tamamen temizleniyor;
üstelik `backspaceRepeat` ilk ayırıcıdan sonra `removeAll()` yapıyor *(234)*, yani
sonraki karakterin hangi token'a ait olduğu **history'den bulunamaz**. Defter her
commit'te `(tokenID, belge aralığı)` kaydeder; yalnız compaction'da budanır ve
silinen aralığın atfı buradan yapılır.

`removedToken` birden çok olduğunda cursor **tek kez** geri alınır: **tam silinen
en eski** token'ın `cursorBefore` değerine. Öğe başına geri alım, "cursor en eski
token'da kalır" invariantıyla çelişirdi [C].

Bir token reopen edilip yeniden commit edildiğinde **yeni `TokenID` alır** ve
defterdeki eski aralık girdisi yenisiyle **süperseed edilir**: çakışan aralığın
**aktif sahibi daima yeni ID**'dir, eski girdi defterden düşer. Eski ID "geri
alınmış" durumdadır ve hedefli etkilere konu olamaz (§3.16).

**`TokenID` sözleşmesi** [Y5/C]: attempt içinde **monoton, benzersiz, asla yeniden
kullanılmaz**; reopen edilip yeniden commit edilen token **yeni ID** alır (eski ID
"geri alınmış" olarak kalır). `restoreToken`/`editedToken`/`removedToken` yalnız
**var olan ve yasal durumdaki** ID'ye uygulanabilir; aynı ID'ye tekrarlı
`editedToken` idempotenttir (repeat her karakterde ateşler).

### 2.2 Şema v3 — epistemik durum [C4]

`effect?`'in `nil`'i üç ayrı şeyi karıştırıyordu. Canonical tipe:

```swift
public enum Epistemic<T: Codable & Equatable>: Codable, Equatable {
    case known(T)
    /// Eski şemada bu olgu **yoktu** — bilinmiyor, yanlış kesinliğe çevrilmez.
    case unknown
    /// Bu bağlamda anlamsız (ör. `letter` action'ında destructive effect).
    case notApplicable
}
```

- `sourceSchema: Int` her kayıtta.
- **v3 hiçbir `.unknown` üretmez** [C]: uygulanabilirse `.known`, değilse
  `.notApplicable`. `.unknown` **yalnız** V2DTO migrasyonundan çıkar.
- Tüm canonical ve frame tipleri koşullu **`Sendable`** [C].
- Legacy `unknown` **asla** v3 kesinliği olarak yeniden encode edilmez.
- Okuma: önce `schema`; `v2 → V2DTO → canonical` migrasyon; `v3` **sıkı**
  (eksik alan hata); `v4+` reddedilir. Eski kind'lar (`plane.numbers`) açık
  migration tablosuyla.
- `hadBackspace == true` olan v2 kayıtları kalibrasyondan dışlanır, sayılır [F].

Şemaya girenler: typed `Action.Kind` (üç backspace kipi **ayrı** [C]) **artı**
`.backspaceUnspecified` — yalnız v2 migrasyonunun ürettiği, v3'ün **asla
yazmadığı** kip: v2 tap ile character-repeat'i aynı `"backspace"` ile yazıyor ve
`Action.event` `.unknown` olsa bile `kind` **ayrı bir alan** ve kesin değer
istiyordu [C]. Bu kipi taşıyan kayıtlar kalibrasyondan dışlanır, golden'da
`unverifiable`. Ayrıca:
`Action.effect: Epistemic<DestructiveEffect>`, `Action.event: Epistemic<Event>` — `Event = .command(ReplayCommand) | .uiEvent(UIEvent)`.
**Epistemik olmak zorunda [C]:** v2 hem tap'i hem character-repeat'i aynı
`"backspace"` kind'ıyla yazıyor *(RecordingView 499, 536)*; non-optional bir v3
komutuna çevirmek **belirsiz olguyu uydurmak** olurdu. v2 belirsiz backspace →
`.unknown`; kalibrasyondan dışlanır, golden'da `unverifiable`
(§2.9) — `shift`/`plane.*` komut değil UI olayı; non-optional `command` onları
temsil edemiyordu [C], `Action.mutations: [DocumentMutation]` (§2.7), `promptTokens: [String]`,
`CandidateSnapshot { id, word, cost, emitCount, source, language }` (sabit `topK`)
ve `ShownSuggestion { id, surface, origin }` — golden "tüm adaylar"ı ancak kanonik
aday tipi varsa karşılaştırabilir [C],
commit kind'ında `.suggestion` / `.expansion` ayrı.

### 2.3 Ortak tokenizer [C, m1]

Maksimal **layout-harf** dizisi: `Wi-Fi → ["wi","fi"]`, `Caddesi'ne →
["caddesi","ne"]`. `KBSessions`'a taşınır, `PromptCorpus` çağırır.

- **NFC politikası sabit**: Türkçe casing'den **önce** NFC normalize; test edilir.
- **Boş `promptTokens` attempt başlatmaz** (yalnız sembol/rakam içeren manuel hedef).
- Validator: gösterilen dizi == kayda yazılan dizi.

### 2.4 `SessionEventReducer` — `KBSessions`

```swift
public struct TouchAtom { let touchID: Int; let sample: TouchSample; let keyIndex: Int }

public struct State {
    var cursor: Int                 // clamp EDİLMEZ
    var pending: [TouchAtom]
    var tokens: [Token]             // her biri tokenID + cursorBefore taşır
    var dropped: [(TouchAtom, DropReason, actionID: Int)]
    var evidence: DestructiveEffect.EvidenceState
    var diverged: Bool
    var violations: [Violation]
}
```

Kurallar (§2.1 tablosunu uygular):
- `letter` **evidence FSM'i** [C]: `.cleared → .attached` + topla ·
  `.attached →` topla · `.detached →` `dropped`. Yeni token'ın ilk harfi
  `.cleared`'dan gelir; "yalnız `.attached` topla" kuralı onu düşürürdü.
- Yıkıcı/sınır action'larda `evidence := effect.evidenceStateAfter`.
- **Detach anında** `pending`'in tamamı gerekçeli `dropped`'a taşınır [Y4];
  aksi hâlde `commit.touchCount == token.atoms.count` meşru yolda patlar.
- sınır + commit non-empty → token kapat (`tokenID`, `cursorBefore` sakla), cursor+1
- sınır + commit `.empty` → pending dolu olması **violation** [F+C]
- `restoreToken` → o `tokenID`'li token'ı geri al, atom'ları pending'e,
  `cursor = token.cursorBefore` [C]. **Divergence set ETMEZ** [C]: geri açma
  hizalamayı tam olarak eski hâline döndürüyor (aynı dokunmalar, aynı cursor).
  Divergence sonrasında olandan gelir — hizasız bir silme detach üretirse oradan.
- `editedToken(id)` → token "metni geçersiz" işaretlenir, cursor **geri
  alınmaz** (belgede kalanı duruyor) [C]
- `removedToken(id)` → token geçersiz. Cursor **öğe başına değil, eylem başına
  bir kez** geri alınır: bir `deleted` listesinde birden çok `removedToken` varsa
  `cursor = min(cursorBefore)` — yani **tam silinen en eski** token'ınki [C].
  Öğe başına geri alım, `wi-fi ` gibi tek çağrıda iki token silen durumlarda
  cursor'ı iki kez geriye taşırdı.
- **Divergence §2.1'in `setsDivergence` sütunundan gelir**, olay adından değil:
  `diverged := prior || setsDivergence`. `.unattributed` span ve cursor'ı geri
  alınamayan `removedToken` **evet**; `.separator`, boş-belge no-op ve composing
  `dropAll` **hayır** — bunlar hizayı bozmuyor (ayırıcı silmede cursor ilerlemiyor,
  belge yüzeyi zaten `DocumentMutation`'dan yeniden kuruluyor). Eski koşulsuz
  kural `setsDivergence` düzeltmesinin tamamını geri alır ve invariant 6
  ("kayıtlı == türetilen") her ayırıcı silmede mismatch üretirdi.
- `.unattributed` sonrası **sonraki tüm token'lar** hizalama dışı sayılır

- `suggestionPick` → dokunmalar **kullanılmış** [F]

### 2.5 `SessionValidator` [C]

`reduce` `Void` döndürüyordu → bozuk sıra sessizce geçerdi.

Zorunlu: `actionID` **sıfırdan başlayan kesintisiz** dizi [C]; zaman monoton;
her `letter` **tek terminal committed** dokunmaya çözülür (çözülmezse violation
[F]); payload–kind uyumu; §2.1 tablosuna uygunluk; reopen meşruiyeti [R1];
token'da `touchCount` eşitliği (diverged **meşrulaştırmaz** [C]); kayıtlı
`alignmentDiverged` == türetilen; sayısal alanlar finite ve aralıkta;
**seçim türevi olgu reddedilir** [R3] (kayıtta `selectedText: nil`, görünemez).

### 2.6 `RecordingEngine` — coordinator'ı **sahiplenir** [C1]

Tek huni `log()` yetmiyor: mevcut akış önce `InputCoordinator`'ı ve belgeyi
değiştirip **sonra** logluyor; geç callback kaydı değiştirmese de belgeyi
değiştirebilir.

**Tek serileştirilmiş ingress** — komut kapısı yetmiyordu [C]: geç `touch`,
`engineConfigured` ya da finalize callback'i terminalden **sonra** frame yazabilir.

```swift
engine.ingest(_ event: IngressEvent)   // attempt | configure | touch | command | terminal
```

- Harf komutu, **tüketilmemiş terminal `touchID`** taşıyan bir zarfla gelir —
  "son dokunmaya" örtük bağlanmak kimlik korunumunu zayıflatıyordu [C].
- Faz **mutasyondan önce** kontrol edilir; runtime çağrısı → rapor/snapshot →
  reduce → journal enqueue **tek sıralı işlem**.
- Writer terminalden **sonra** eklemeyi **reddeder**.
- VC'de `wordIndex` yok.

**Attempt state machine:** `initializing → recording → finishing →
completed|aborted|invalid`; kurtarma yalnız `recording → interrupted`. Terminal
**değişmez**. `completed` şartı: `cursor == promptTokens.count` (**tam**, `>` başarı değil [C]),
açık/pending token yok, açık dokunma yok, `violations.isEmpty`, terminal frame
**durable** yazılmış.

**`attemptStarted` durability kapısı [C]:** yalnız terminali fsync'lemek yetmez —
güç kaybı ilk frame'i yok eder ve deneme abort/interrupted **paydasından tamamen
düşer**, §12.6'nın *"başlar başlamaz diske düşer"* şartı bozulur. Bu yüzden
klavye **açılmadan önce**: dosya + `attemptStarted` + eligibility kaydı fsync,
yeni dizin girdisi için **parent-directory fsync**.

**Durability operasyonel tanımı [C]:** normal write tamamlanması durability
değildir. Terminal geçişinden **önce** dosyada `fsync`; compaction'da
`temp fsync → rename → parent-directory fsync`. Torn son frame checksum'la
tespit edilir ve **yalnız o** kurtarılabilir; hata/retry yolu test edilir.

### 2.7 Journal — gerçek konteyner [C2, C3]

**`textAfter` O(n²)'nin kaynağı** [C2]: her action tam belgeyi taşıyor, i'nci
harfte O(i) → toplam O(n²). Çözüm: action başına `DocumentMutation` +
`documentHash`; `textAfter` importer'da mutasyonlardan **türetilir**; `finalText`
yalnız terminalde yazılır.

**Mutasyon codec'i normatif [C]** — doğrulanabilir olması için kesin:

```
DocumentMutation = .insert(String) | .deleteBackward(count: Int)
```

- Başlangıç metni **boş dize** (recorder'ın tamponu sıfırdan başlıyor).
- Silme birimi **`Character`** (grapheme), UTF-16 birimi değil — `deleteBackward`
  `ComposingSession`'da öyle sayıyor.
- `documentHash` = FNV-1a 64, **UTF-8 baytları** üzerinde, action **sonrası** tam
  belge; seed `0xcbf29ce484222325` (depoda `CalibrationStore`'un kullandığı sabit).
- Invariantlar: mutasyon **underflow** yapamaz (silme > uzunluk → violation);
  her action sonrası türetilen metnin hash'i kayıtlıya eşit; terminalde
  türetilen metin `finalText`'e **ve** hash'ine eşit.

**Konteyner sözleşmesi** (şemadan bağımsız `containerVersion`, magic):
frame türü/sırası/uzunluğu/checksum'u; frame'ler `attemptStarted |
engineConfigured | touch | action | terminal`. **Yalnız eksik son frame
kurtarılabilir**; bozuk orta frame **load error**. Atomik compaction, file
protection, tek writer (actor) — `markStale`, silme ve terminal finalize
yarışlarını da kapatır.

**Birlikte taşınacaklar [C3]:** `SessionStore`, kayıt listesi UI'ı ve
`Tools/pull-sessions.sh` (bugün `*.json` arayıp Python'la parse ediyor).

**Karışık dizin okuyucusu [C]:** yeni konteyner uzantısına geçmek mevcut
`*.json` kayıtlarını **görünmez** bırakırdı. Tek ortak okuyucu hem legacy JSON
hem v3 konteyneri listeler, çeker ve doğrular; çekme aracı ikisini de paketler.

### 2.8 Ortak motor kurulumu + `ReplayEngineFactory` [C5]

`PackLoader` `Apps/` altında; paket içindeki factory onu paylaşamaz → paket
çözme ve engine assembly **ortak SwiftPM katmanına** taşınır; hem uygulama hem
factory onu kullanır.

`EngineSnapshot` tamamlanır: tüm `ScoreWeights`; `maxKeyCandidates`,
`candidateCostWindow`, `maxConsecutiveOmissions`; `LiteralChannel.cUnk` ve
**kendi** `weights`'i; `LanguageModel.prior` ve durumu (decoder ile kanalın ayrı
kopyaları var — ayrı saklanır ya da eşitlik runtime invariantı olur);
**tam spatial konfigürasyon** (`sigmaMin` + tüm bias/sigma); paketlerin
**rolü/dili/kaynak sırası/offset'i** (ad+hash topolojiyi kanıtlamaz).

`codeRevision` = commit + **dirty** durumu; build fazıyla enjekte edilir; Release
kaydı `unknown` ile başlamaz.

**Önemli ayrım [C]:** kayıt revision'ı ile güncel revision'ın **farklı olması
regression replay'in amacıdır** — tek başına environment mismatch **değildir**.
Mismatch: paket hash'i, **layout parmak izi**, ya da çözülemeyen paket.

**Layout parmak izi [C]:** `layoutID` tekil değil — aynı kimlikle tuş sırası,
geometri ve `asciiBase` değişebilir ve bu, kod regresyonu diye yanlış
sınıflanırdı. Kaydedilen: tüm tuşların `(char, center, width, height)` dizisi ve
`asciiBase` üzerinden hesaplanan kanonik hash.

**Build manifesti [C]:** temiz commit **tekil binary tanımlamıyor** — aynı kaynak
farklı Swift/Xcode sürümü, target triple, mimari ya da optimizasyon ayarında
farklı sonuç verebilir ve bu **kod regresyonu sanılırdı**. Kaydedilen:
`swiftVersion`, `xcodeVersion`, `targetTriple`, `arch`, `optimizationLevel`,
`configuration`. Replay uyumluluk politikası bunu okur.

**Build provenance [C]:** `commit + dirty` iki farklı kirli ağacı ayırt etmiyor.
Golden için **temiz build zorunlu**; kirliyse kaynak ağacının içerik hash'i
kaydedilir ve golden sonucu `unverifiable` olur.

### 2.9 `ReplayCommand` ve karşılaştırma sözleşmesi [C6]

```swift
public enum ReplayCommand: Codable, Equatable {
    /// `insertLetter` mi `insertUppercaseLetter` mi — belirsiz bırakılamaz [C].
    case letter(baseKey: Character, display: String, shifted: Bool)
    case symbol(Character)
    case space
    case newline
    case suggestionPick(id: String, surface: String, origin: SuggestionOrigin)
    case backspaceTap, backspaceRepeat, deleteWord
}
```

Golden **bağımsız**: kayıtlı sonuç motora geri beslenmez; gerçek
`InputCoordinator` + sahte `DocumentEditor` ile komutlar yeniden çalıştırılır.

Karşılaştırılan: tüm aday listesi (**sıra ve uzunluk**), `ShownSuggestion`
sırası ve `origin`'i, `DestructiveEffect`, türetilen divergence ve reducer
post-state, ve commit'in `literal`, `displayBefore`, `committed`, `kind`,
`delta`, `theta`, `bestCost`, `bestWord`, `language`, `touchCount`,
`casingApplied`, `literalProtected`, `targetWord`, `labelSource`, `confidence`,
`matchesTarget` alanları; her action'ın türetilmiş metni ve sondaki `finalText`.

**Float toleransı** ve optional/NaN kuralları açık: maliyetler `1e-9` mutlak;
`nil ≠ 0`; NaN daima mismatch.

`newline` de `TokenCommitReport` döndürür [F R4].

### 2.9b Kayıt politikası — `engineConfigured` frame'inde [C]

Kalibrasyon filtresinin *"öneriler gizli"* ve *"literal korumalı"* koşulları
canonical kayıttan **güvenilir seçilemiyor**: `condition` yalnız **niyeti**
gösteriyor, `literalProtected` ise yalnız **bir kararın** sonucunu — alternatif
aday yokken `false` olabilir.

`engineConfigured` frame'i normatif bir politika taşır:

```swift
public struct RecordingPolicy: Codable, Sendable {
    public var feedbackVisible: Bool        // yazılan metin görünüyor mu
    public var suggestionsVisible: Bool     // öneri çubuğu dokunulabilir mi
    public var correctionPolicy: CorrectionPolicy   // .applied | .suppressed
    public var learningMode: LearningMode           // .frozen | .live
}
```

`RecordingEngine` politikayı **uygular**; validator komut/commit/UI
snapshot'larıyla **çapraz doğrular** (ör. `suppressed` iken hiçbir commit
`.autocorrect` olamaz). Kalibrasyon filtresi `condition` yerine bunu okur.

### 2.10 Tüketici bazlı uygunluk [C7]

"Her skip geçişi engeller" kuralı, **normal ve gerekli** olan sıfır-action
abort'u tüm koşuyu sonsuza dek `unverifiable` yapardı.

| Tüketici | Seçim | Fail-closed |
|---|---|---|
| Özet | **tüm** kayıtlar | — (yalnız sayar) |
| Kalibrasyon | `completed` + `constructed` + **`RecordingPolicy`** (`feedbackVisible == false`, `suggestionsVisible == false`, `correctionPolicy == .suppressed`, `learningMode == .frozen`) + `applied == false` + `Action.event` **`.known`** + sürüm politikası [C] | seçilen küme içinde (aşama 2: yükleme + `validated`) |
| Golden | açıkça seçilmiş + `completed` + Release + v3 + **tekil build provenance** [C] | seçilen küme içinde (aşama 2: yükleme + `validated`) |

**Index ↔ journal sahiplik sözleşmesi [C]:** terminal durum `attemptStarted`'dan
**türetilemez**, sonradan güncellenmelidir. Yazma sırası: (1) journal + ilk frame
fsync → (2) index girdisi fsync → … → (3) terminalde index güncellenir.
**Journal terminal durumun tek doğruluk kaynağıdır; index bir önbellektir** [C]:
terminal journal fsync'inden **sonra**, index güncellemesinden **önce** çöküş
"var ama index'i eski" bir kayıt bırakır — index girdisi journal'dan **yeniden
inşa edilir**, kayıt kaybolmuş sayılmaz.

Uzlaştırma: index'te olup journal'ı olmayan → **orphan**, raporlanır; journal'ı
olup index'te olmayan **ya da terminal durumu eski** → journal'dan yeniden inşa;
index checksum hatası → tüm evren `unverifiable`. Legacy JSON'lar ilk okumada index'e alınır;
tanınan ama okunamayan legacy dosya `unverifiable`.

**Eligibility manifesti [C]:** "yalnız seçilen kümedeki load error fail" tek
başına **uygulanamaz** — okunamayan dosyanın `completed`/şema/koşul bilgisi
bilinmediği için kümeye girip girmediği belirlenemez. Çözüm: attempt başına
checksum'lı bir **eligibility index**
taşır. **Tüketici seçiminin tamamı index'ten yapılabilmeli** [C] — aksi hâlde
"yalnız seçilen küme" ile "evrendeki her load error" kuralları uyuşmuyor:

| alan | kaynak frame | ne zaman yazılır |
|---|---|---|
| dosya adı, `attemptID`, `schema`, `condition`, `alignmentSource`, `promptID` | `attemptStarted` | deneme başlarken (fsync) |
| `RecordingPolicy` özeti, `calibration.applied`, `buildConfiguration`, build provenance özeti, paket hash özeti | `engineConfigured` | motor kurulunca (fsync) |
| `eventUnknown` bayrağı | action akışı | **monoton VEYA**; deneme boyunca birikir, terminalde yazılır |
| terminal durum | `terminal` | terminalde (fsync) |

**`validated` index'te YOKTUR ve olamaz [C]:** validator'ı koşmak journal'ın
tamamını gerektiriyor, yani yazma anında bilinemez. Bu yüzden seçim **iki
aşamalı**:

1. **Evren**, index'ten seçilir (ucuz, checksum'lı): koşul, şema, hizalama,
   politika, `applied`, build, terminal durum, `eventUnknown`.
2. Evrendeki **her** kayıt yüklenir ve validate edilir. Bu aşamadaki her load
   hatası, `unknown` ya da validator ihlali **fail-closed**'dır.

`validated`'ı index'e yazmak, onu ancak yazarken bilinebilir sanmak olurdu;
kaydın geçerliliği okuyucunun bugünkü kurallarına göre değişir, yazarınkine göre
değil.

**Alan sahipliği ve güncelleme sözleşmesi [C]:** index `attemptStarted`'dan
*türetilmiş* değil, **üç noktada güncellenen** bir önbellektir. Her güncelleme
fsync'lidir; journal her alan için tek doğruluk kaynağıdır ve index herhangi bir
noktada journal'dan **yeniden inşa edilebilir**. Eksik ya da eski bir alan
kaydı geçersiz yapmaz — yeniden inşa tetikler.. Bu evrendeki **her** load
error `unverifiable`.

Sonuç: `passed | mismatched | unverifiable`.

---

## 3. Invariantlar

1. **Korunum, daraltılmış evrende [C]:** "her `touchID`" yanlış evren
   (began/moved/cancelled/function/repeated var). Doğrusu: **kanıt taşıyan her
   `TouchAtom`** (yani `ended`+`committed`+`letter`) tam olarak birinde: bir
   token, `pending`, ya da gerekçeli `dropped`.
2. *(§3.18'e taşındı — durum-farkında FSM)*
3. **Sayım:** `commit.touchCount == token.atoms.count`; diverged meşrulaştırmaz.
4. **Cursor tersinirliği:** `restoreToken` ve `removedToken` cursor'ı
   `cursorBefore`'a **tam** geri alır; `editedToken` **geri almaz** (token'ın
   kalanı belgede duruyor). İç sayacı clamp edilmez.
5. **Evidence post-state:** reducer'ın `evidence`'ı **evidence taşıyan** (yıkıcı
   ve sınır) her action'da kayıttakine eşit. Harf action'ının effect'i
   `.notApplicable`'dır ve geçişi reducer kendi yapar (`.cleared → .attached`);
   "her action" demek ilk harfte patlardı.
6. **Diverged monotonluğu**; kayıtlı == türetilen.
7. **Determinizm + prefix kapalılığı** (`interrupted` geçerli prefix).
8. **Boş commit** token üretmez, cursor ilerletmez, pending **boş olmalı**.
9. **Her sınır commit taşır**; taşımayan kayıt hatadır.
10. **Yedeklilik türetilir [C]:** `targetWordIndex`/`targetWord`/`confidence`/
    `matchesTarget` reducer'dan türetilir **ya da** birebir doğrulanır; seçilen
    öneri **önceki** `shownSuggestions` snapshot'ının üyesidir.
11. **Seçim yok [R3]:** seçim türevi hiçbir olgu kayıtta bulunamaz.
12. **Terminal kapanış:** terminal frame'den sonra frame/action yok;
    `completed` tam cursor + validator kapısından geçmiş.
13. **app == importer, totolojik değil [C]:** her adımda reducer `pending`'i
    **gerçek** `InputCoordinator.session.touches` ile, türetilen belge canlı
    sahte belgeyle karşılaştırılır; araya **gerçek journal codec'i** girer
    (yalnız JSON round-trip yetmez [C]).
14. **Fixture diff:** v2 baseline ↔ v3; kasıtlı farklar listelenir.
15. **v2 migrasyonu:** v2 açılır, bilinmeyenler `unknown`, `hadBackspace`
    olanlar kalibrasyondan dışlanır ve sayılır.
16. **`TokenID` bütünlüğü [Y6/C]:** attempt içinde tekil ve yeniden
    kullanılmamış; her `restoreToken`/`editedToken`/`removedToken` **var olan ve
    yasal durumdaki** bir ID'ye işaret eder.
17. **Belge codec'i [C]:** mutasyon underflow yok; her action sonrası türetilen
    metnin hash'i kayıtlıya eşit; terminalde metin **ve** hash `finalText`'e eşit.
18. **Durum-farkında touch FSM'i [C]:** `began → moved* → ended|cancelled`,
    ID yeniden kullanılamaz, terminalden önce `began` şart, terminalden sonra
    olay yok. `completed`'da **açık dokunma yasak**; `interrupted`/`aborted`
    prefix'lerinde açık dokunma **izinli ve raporlu** — §3.7 prefix
    kapalılığıyla çelişmesin diye.

---

## 4. Kasıtlı davranış değişiklikleri

Geri açılan/detach/invalidate olan token kalibrasyona girmiyor · newline bir sınır ·
iç ayırıcılı hedefler doğru bölünüyor · `verifyGolden` sonuçları değişiyor ·
boş commit'in sessiz `removeAll`'u kalkıyor · `deleteWord` sonrası cursor geri
alınıyor. Hepsi adım 0'da **kırmızı** kayda geçer.

## 5. §12 normatif güncelleme [F]

§12.6 yeniden yazılır (cihazda katlama artık meşru: reopen **olgu** oldu,
kanonik türetme tek reducer) · §12.7 commit kind listesi kodla uzlaştırılır ·
§12.2'ye tokenizer kaynaklı hizalama sınırı · §12.11: konteyner sözleşmesi.

## 6. Kapsam dışı

Çok katılımcılı protokol ve resmî kabul kapısı (§12.2/§12.8 zaten kaydediyor).
Attempt doğruluğu, durable persistence ve fail-closed golden **kapsamda** —
verinin geçerliliğinin ön şartı.

## 7. Sıra [C8]

0. Baseline dondur + `withKnownIssue`'lu karakterizasyon testleri *(sınırlar
   işaretli)*
1. **KBRuntime**: `DestructiveEffect`, `TokenID`, `ReplayCommand` (modül döngüsü
   yok) + şema/snapshot/**ortak engine assembly** (PackLoader SwiftPM'e)
2. Coordinator raporları: tap/repeat/deleteWord/newline + tek çağrılık suggestion
   snapshot
3. Reducer + validator + kimlik tabanlı korunum/undo invariantları
4. **Journal codec/reader/writer** (RecordingEngine'den ÖNCE — v2'de sıra yanlıştı)
5. `RecordingEngine` + attempt state machine + **gerçek codec üzerinden**
   full-state property ve crash-prefix testleri
6. VC tek huniye · `SessionStore` · `pull-sessions` konteynere geçer
7. `ReplayEngineFactory` + bağımsız golden + importer entegrasyonu
8. v3 fixture'ı **gerçek `RecordingEngine` yolundan** üret; v2/v3 diff; §12

## 7b. Uygulama sırasında kararlaştırılacaklar [IMPL]

Plana bağlayıcı değil; uygulama/test aşamasında kesinleşir ve orada yakalanır.

- **Torn tail politikası:** yalnız **fiziksel olarak eksik** EOF tail kurtarılır;
  tam uzunluktaki bir frame'de checksum hatası — son frame olsa bile — **load
  error**. Test matrisinde ikisi ayrı vaka.
- `CandidateSnapshot.id` deterministik üretim fonksiyonu; ham `topK` ve gösterim
  limiti ortak runtime sabitleri; golden'da sıra/kimlik kararlılığı doğrulanır.
- `history.removeAll` yol listesi seçim açma yolundaki **448**'i de içerir; kayıt
  evreninde erişilemez ama liste "seçimsiz evren" diye daraltılmadıysa tamamlanır.
- §3.18'de terminal `.invalid` durumunun açık-dokunma politikası: `aborted`/
  `interrupted` gibi izinli ve raporlu mu, yoksa kapalı mı — testle sabitlenir.
- `deleteWord`'ün sıra dışı boşluk yolu *(280: `deleted == 0 → 1`)*: writer ve
  validator **aynı** sınıflandırmayı seçer (`.separator` ya da `.unattributed`).

## 8. Risk

Harf/olağan yol O(1); yıkıcı yol token uzunluğu kadar; `tokens`/`dropped`
oturumla büyür. Kayıt kapalıyken uzantı etkilenmez (`KBSessions` linklenmiyor;
`KBRuntime` eklentileri additive).
