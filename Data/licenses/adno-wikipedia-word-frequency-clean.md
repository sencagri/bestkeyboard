# adno / wikipedia-word-frequency-clean (İngilizce Wikipedia frekansı)

| Alan | Değer |
|---|---|
| Kaynağın adı | wikipedia-word-frequency-clean |
| Sahibi | Adam Nohejl (script) · English Wikipedia katkıcıları (veri) |
| URL | https://github.com/adno/wikipedia-word-frequency-clean |
| Kullanılan dosya | `results/enwiki-frequency-20221020-nfkc-lower.tsv.xz` |
| Ham URL | https://github.com/adno/wikipedia-word-frequency-clean/raw/main/results/enwiki-frequency-20221020-nfkc-lower.tsv.xz |
| Lisans (script/depo) | **BSD-3-Clause** — Copyright (c) 2022, Adam Nohejl |
| Lisans (veri) | **CC BY-SA** — English Wikipedia'dan türetilmiş (dump 2022-10-20) |
| Yeniden dağıtıma izin veriyor mu? | **Evet** (BSD-3 atıf; Wikipedia tarafı atıf + share-alike) |
| Ticari kullanım | Serbest |
| İndirme tarihi | 2026-07-28 |

## Neden seçildi

- Hazır, **temizlenmiş** İngilizce Wikipedia frekans listesi: HTML/wikitext
  etiketleri (`<br>`, `<ref>`), tablo biçimlendirmesi (`colspan`, `rowspan`),
  formül/kod yer tutucuları (`formula_…`, `codice_…`) upstream'de ayıklanmış.
  Bu, IlyaSemenov/wikipedia-word-frequency'ye göre açık bir kalite farkı.
- `-nfkc-lower` mutasyonu tam da bizim ihtiyacımız: NFKC normalize + küçük harf.
  packbuild NFC + tek-skaler grapheme istediği için ekstra bir normalizasyon
  adımı gerekmedi.
- 2.161.820 tip / 2.489.387.103 token — 60k'lık hedef için fazlasıyla derin.
- 3'ten az maddede geçen kelimeler upstream'de zaten atılmış (hapax gürültüsü yok).

## Dikkat

Dosyanın son satırı `[TOTAL]` etiketli bir toplam satırıdır. Bizim filtremiz
köşeli parantez içerdiği için onu zaten eliyor, ama başka bir işlemde
özel olarak ele alınmalıdır.

## Gerekli atıf metni

```
English word frequencies from adno/wikipedia-word-frequency-clean
(https://github.com/adno/wikipedia-word-frequency-clean), © 2022 Adam Nohejl,
BSD-3-Clause. Derived from English Wikipedia (dump 2022-10-20), text by
Wikipedia contributors, licensed CC BY-SA.
```

BSD-3-Clause telif uyarısının dağıtımla birlikte yer alması gerekir; bu dosya
bunu karşılar.
