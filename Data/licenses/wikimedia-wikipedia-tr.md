# Türkçe Wikipedia (wikimedia/wikipedia, 20231101.tr)

| Alan | Değer |
|---|---|
| Kaynağın adı | Wikimedia Wikipedia dataset — Türkçe bölüm, `20231101.tr` |
| Sahibi | Wikimedia Foundation / Wikipedia katkıcıları |
| URL (dataset) | https://huggingface.co/datasets/wikimedia/wikipedia |
| Kullanılan dosyalar | `20231101.tr/train-00000-of-00002.parquet`, `…-00001-…` |
| Ham URL | https://huggingface.co/datasets/wikimedia/wikipedia/resolve/main/20231101.tr/train-00000-of-00002.parquet |
| Lisans | **CC BY-SA 3.0** ve **GFDL** (dataset kartı `license: [cc-by-sa-3.0, gfdl]`) |
| Yeniden dağıtıma izin veriyor mu? | **Evet**, atıf + share-alike şartıyla |
| Ticari kullanım | Serbest |
| İndirme tarihi | 2026-07-28 |

## Neden seçildi

- Ham `pages-articles.xml.bz2` dump'ı yerine bu dataset kullanıldı, çünkü
  **wikitext temizlenmiş düz metin** sunuyor. Ham dump'ta `colspan`, `thumb`,
  `px`, `ref` gibi markup artıkları saf Latin harflerinden oluştuğu için
  frekans listesine sızar ve elle stoplist bakımı gerektirir.
- Yazılı/biçimsel register: teknik ve kurumsal kelime dağarcığı
  (`yönetmelik`, `bileşen`, `uygulama`) altyazı korpusunda zayıf kalıyor.
  Altyazı listesiyle harmanlanınca iki register da temsil ediliyor.

## Bu depoda yapılan işlem

`20231101.tr` snapshot'ının `text` sütunu üzerinde:

- NFC normalizasyon,
- **Türkçe'ye özgü küçük harfe çevirme** — Python'un `str.lower()`'ı
  `I → i` (olması gereken `ı`) ve `İ (U+0130) → i + U+0307` (iki skaler!)
  üretir; ikincisi packbuild'in "her grapheme tek skaler" kuralını ihlal eder.
  Bu yüzden `I → ı`, `İ → i` eşlemesi `lower()`'dan **önce** uygulandı.
- `[abcçdefgğhıijklmnoöprsştuüvyzâîû]+` regex'iyle tokenizasyon,
- token ve belge sayımı; `count < 3` olan tipler atıldı.

Sonuç: **534.988 madde, 112.003.353 token, 1.888.414 tip**.

## Gerekli atıf metni

```
Contains word frequency statistics derived from Turkish Wikipedia
(https://tr.wikipedia.org), snapshot 2023-11-01, via the Wikimedia
`wikipedia` dataset. Text by Wikipedia contributors, licensed CC BY-SA 3.0
and GFDL.
```

## Yükümlülük

Share-alike. CC BY-SA 3.0 §4(b) "later version" hükmü, türev eserin
CC BY-SA 4.0 altında lisanslanmasına izin verir; bu depodaki birleşik
listeler CC BY-SA 4.0 olarak işaretlenmiştir (diğer kaynak zaten 4.0).
