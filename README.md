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

## Ortam

Xcode 26.5 · Swift 6.3.2 · iOS klavye uzantısı (App Extension)
