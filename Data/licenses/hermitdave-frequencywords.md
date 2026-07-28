# hermitdave / FrequencyWords

| Alan | Değer |
|---|---|
| Kaynağın adı | FrequencyWords — Frequency Word List Generator and processed files |
| Sahibi | Hermit Dave |
| URL | https://github.com/hermitdave/FrequencyWords |
| Kullanılan dosyalar | `content/2018/tr/tr_full.txt`, `content/2018/en/en_full.txt` |
| Ham URL (tr) | https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/tr/tr_full.txt |
| Ham URL (en) | https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_full.txt |
| Lisans (kod) | MIT — depodaki `LICENSE`, "Copyright (c) 2016 Hermit Dave" |
| **Lisans (içerik/veri)** | **CC BY-SA 4.0** — depo `README.md`: "MIT License for code. CC-by-sa-4.0 for content." |
| Yeniden dağıtıma izin veriyor mu? | **Evet**, atıf + share-alike şartıyla |
| Ticari kullanım | Serbest (CC BY-SA 4.0 ticari kullanımı kısıtlamaz) |
| İndirme tarihi | 2026-07-28 |

## Neden seçildi

OpenSubtitles tabanlı olduğu için **konuşma dili** register'ında. Bir klavye
için Wikipedia'dan daha temsili: kullanıcı mesaj yazar, ansiklopedi maddesi
yazmaz. Türkçe listesi 2.035.629 satır, İngilizce 1.656.996 satır — sondan
eklemeli Türkçe'nin yüzey formu kuyruğunu taşıyacak derinlikte.

## Upstream zinciri ve bilinen belirsizlik

Sayımlar OPUS **OpenSubtitles2018** korpusundan üretilmiştir
(http://opus.nlpl.eu/OpenSubtitles2018.php). OPUS'un altında yatan altyazı
metinlerinin telif durumu upstream'de **açıkça lisanslanmamıştır**; OPUS
korpusları "halka açık kaynaklardan derlendi" notuyla dağıtılır.

Bu depoda dağıtılan şey altyazı metni değil, **kelime → sayım** biçiminde
türetilmiş istatistiktir; Hermit Dave bu türevi açıkça CC BY-SA 4.0 ile
lisanslamıştır. Riski daha da düşürmek için:

- listeye yalnız **frekans sayımları** girdi, hiçbir cümle/bağlam girmedi;
- sayımlar ikinci bir kaynakla (Wikipedia) harmanlanıp yeniden ölçeklendi,
  yani orijinal sayım vektörü birebir yeniden dağıtılmıyor.

## Gerekli atıf metni

```
Word frequency data derived from hermitdave/FrequencyWords
(https://github.com/hermitdave/FrequencyWords), © Hermit Dave,
content licensed CC BY-SA 4.0. Built from the OpenSubtitles2018 corpus (OPUS).
```

## Yükümlülük

CC BY-SA 4.0 **share-alike**: bu veriden türetilen `wordlist-corpus.tsv` ve
`en-US/wordlist.tsv` de CC BY-SA 4.0 altında dağıtılmalıdır. Uygulamanın
**kodu** etkilenmez (veri ile kod ayrı eserlerdir), ancak paketle birlikte
dağıtılan liste dosyaları ve onlardan üretilen `.bkt` binary'si etkilenir.
