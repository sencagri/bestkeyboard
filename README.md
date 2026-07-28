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

## Dokümanlar

- [`docs/00-score-contract.md`](docs/00-score-contract.md) — **normatif** skor modeli, öznitelik
  vektörü, prefix-causality denetimi, decoder state şeması, exhaustive oracle recurrence.

Tam plan: `~/.claude/plans/imdi-bir-tane-klavye-melodic-stallman.md`

## Cihaza yükleme

```bash
./Tools/deploy.sh          # paket üret → derle → yükle → aç
./Tools/deploy.sh --help   # seçenekler ve ön koşullar
```

Tek seferlik ön koşullar (script kontrol eder, kendisi yapamaz):

1. iPhone'da **"Bu bilgisayara güven"**
2. iPhone: Ayarlar → Gizlilik ve Güvenlik → **Geliştirici Modu** → aç → yeniden başlat
3. Xcode → Settings → Accounts → **Apple ID ekle** (ücretsiz hesap yeterli)
4. Kablosuz için: Xcode → Window → Devices and Simulators → cihaz →
   **"Connect via network"**. Sonra kablo gerekmez.

Ücretsiz hesapla imzalanan uygulama **7 gün** sonra açılmaz; yeniden yüklemek gerekir.

## Ortam

Xcode 26.5 · Swift 6.3.2 · iOS klavye uzantısı (App Extension)
