# BestKeyboard

iPhone için uzamsal kod çözücülü (spatial decoder) Türkçe klavye.

Tuşa basılan harf değil **dokunma koordinatı** kaydedilir; her dokunma için tuşlar üzerinde bir
skor dağılımı çıkarılır ve kelime, dokunma dizisi üzerinde **sıraya sadık** bir beam search ile
bulunur. Sistem ayrıca kullanıcının düzeltmelerinden **kendi kendini kalibre eder**.

Kanonik test vakası: `l s l e m` dokunma dizisi → **kalem** (❌ *işlem* değil).
Sıra korunduğu için `l→k` ve `s→a` komşuluğu ucuz, `l→i` ve `s→ş` uzaklığı pahalıdır.

## Durum

**Faz -1A₀ — skor sözleşmesi.** Kod öncesi, bloklayan kapı.

| Faz | Kapsam | Durum |
|---|---|---|
| -1A₀ | Skor sözleşmesi, state şeması, oracle recurrence | 🔨 devam |
| -1A₁ | Form-trie dikey dilimi, cihazda çalışan ilk çıktı | ⏳ |
| -1A₂ | Morfoloji / state-equivalence spike'ı | ⏳ |
| -1B | Fizibilite hattı (lisans, veri, paket formatı) | ⏳ |

## Lisans

Kod bize ait. **Dil verisi CC BY-SA 4.0** kaynaklardan türetilmiştir ve
share-alike yükümlülüğü taşır — ama yalnız veri dosyalarına, koda değil.
Ticari kullanım serbesttir. Ayrıntı: [`LICENSES.md`](LICENSES.md)

## Dokümanlar

- [`docs/00-score-contract.md`](docs/00-score-contract.md) — **normatif** skor modeli, öznitelik
  vektörü, prefix-causality denetimi, decoder state şeması, exhaustive oracle recurrence.

Tam plan: `~/.claude/plans/imdi-bir-tane-klavye-melodic-stallman.md`

## Cihaza yükleme

```bash
./Tools/fix-signing.sh     # BİR KEZ: codesign'a anahtar erişimi ver
./Tools/deploy.sh          # paket üret → derle → yükle → aç
./Tools/deploy.sh --help   # seçenekler ve ön koşullar
```

Xcode açmaya gerek yok. `fix-signing.sh` bir kez çalıştırılır: Xcode'un ürettiği
sertifikanın özel anahtarına `/usr/bin/codesign`'ın erişmesini sağlar (macOS'un
her imzalamada açtığı onay diyaloğunu kalıcı olarak kaldırır).

Tek seferlik ön koşullar (script kontrol eder, kendisi yapamaz):

1. iPhone'da **"Bu bilgisayara güven"**
2. iPhone: Ayarlar → Gizlilik ve Güvenlik → **Geliştirici Modu** → aç → yeniden başlat
3. Xcode → Settings → Accounts → **Apple ID ekle** — sertifikayı Apple'ın
   sunucusundan yalnız Xcode alabildiği için bu adım kaçınılmaz. Bir kereliktir.
4. `./Tools/fix-signing.sh`

Kablosuz için ayrıca bir şey yapmaya gerek yok: Xcode 15+ eşleşmiş ve Geliştirici
Modu açık cihazlarda ağ bağlantısını kendiliğinden kurar (Devices listesinde
cihazın yanındaki 🌐 simgesi). Kabloyu çıkarıp aynı komutu çalıştırabilirsin.

Ücretsiz (Personal Team) hesapla imzalanan uygulama **7 gün** sonra açılmaz.
Şirket/ücretli takımda 1 yıl.

## Ortam

Xcode 26.5 · Swift 6.3.2 · iOS klavye uzantısı (App Extension)
