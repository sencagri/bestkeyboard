# ahmetaa / zemberek-nlp — Türkçe kök sözlüğü

| Alan | Değer |
|---|---|
| Kaynağın adı | Zemberek-NLP — Turkish NLP Tools, `morphology` modülü sözlük kaynakları |
| Sahibi | Ahmet A. Akın, Mehmet D. Akın |
| URL | https://github.com/ahmetaa/zemberek-nlp |
| Kullanılan dosyalar | `morphology/src/main/resources/tr/master-dictionary.dict`, `…/non-tdk.dict`, `…/proper.dict` |
| Ham URL (master) | https://raw.githubusercontent.com/ahmetaa/zemberek-nlp/master/morphology/src/main/resources/tr/master-dictionary.dict |
| Referans alınan kod | `morphology/src/main/java/zemberek/morphology/lexicon/tr/TurkishDictionaryLoader.java` |
| Lisans | **Apache-2.0** — depo kökündeki `LICENSE`: "Copyright 2018 Ahmet A. Akın, Mehmet D. Akın / Licensed under the Apache License, Version 2.0" |
| Yeniden dağıtıma izin veriyor mu? | **Evet**, atıf + NOTICE/değişiklik beyanı şartıyla |
| Share-alike yükümlülüğü | **YOK** |
| Ticari kullanım | Serbest |
| Depo HEAD (indirme anında) | `ae2fbe31438dda4dddc674a2a8991d518984d392` (2026-04-28) |
| `master-dictionary.dict` son commit | `6b90eac24bfbb9eaefc1ca625c403a0fc8bbc1e5` (2019-04-04) |
| SHA-256 (master-dictionary.dict) | `c539e12904d1ccac4792073f05deeae2babe692249dc4a359da254f1bd338f6f` |
| SHA-256 (non-tdk.dict) | `106c459e9ab8d430e3c64cc60e529eca7c369de3993315a71db10ace17cca6b8` |
| SHA-256 (proper.dict) | `5704f4017854c474442cce246443b9fec5967799a968ab9d7eb0cce930e32178` |
| İndirme tarihi | 2026-07-28 |

## Neden seçildi

Bu depodaki 70k'lık `wordlist.tsv` bir **yüzey formu** listesidir ve Türkçe
sondan eklemeli olduğu için o kuyruğu prensip olarak kapatamaz:
`kalemlerimizden` hiçbir korpusta yeterli sıklıkta geçmez. `KBMorphology`
otomatı kökten türetir, ama kök sözlüğü olmadan çalışmaz.

Zemberek tam olarak eksik olan şeyi taşır: **kök + POS + fonolojik öznitelik**
(`Voicing`, `NoVoicing`, `LastVowelDrop`, `InverseHarmony`, …). Bu bilgi
sözlükseldir, yüzeyden türetilemez — `kitap→kitabı` yumuşar, `at→atı`
yumuşamaz; ikisi de aynı sınıf ünsüzle biter.

**Lisans açısından da bir kazanç.** `wordlist.tsv` CC BY-SA 4.0 (share-alike
yükümlülüğü var, `LICENSES.md`). Apache-2.0'da share-alike yoktur: `roots.tsv`
copyleft taşımaz, yalnız atıf ve değişiklik beyanı ister.

## Lisans kapsamı hakkında dürüst not

Depo `README.md`'si "**Code** is licensed under Apache License, Version 2.0"
diyor; kök dizindeki `LICENSE` dosyası ise böyle bir daraltma yapmıyor ve
Apache-2.0 metnindeki "Work" tanımı depo içeriğinin tamamını (kaynak dosyalar
dahil) kapsar. hermitdave'deki gibi açık bir "kod X / içerik Y" ayrımı **yok**;
dolayısıyla sözlük dosyalarının da Apache-2.0 altında olduğu okumasıyla
ilerlendi.

`master-dictionary.dict`'in madde başları TDK Güncel Türkçe Sözlük'ün madde
başlarıyla büyük ölçüde örtüşür. Bu depoya giren şey **yalnız madde başı +
dilbilgisel öznitelik**tir; TDK'nın tanım metinlerinden, örnek cümlelerinden
veya kökenbilgisinden hiçbir şey alınmadı. Bir dilin kelime envanteri
telif konusu bir *ifade* değil olgudur; alınan öznitelikler de (yumuşama,
ünlü düşmesi) Türkçe fonolojisinin olgularıdır.

## Bu depoda yapılan işlem

Dönüşüm tek seferlik yapıldı; çıktısı `LanguagePacks/tr-TR/roots.tsv`.
Zemberek çalışma anında bir bağımlılık **değildir**, uygulamaya Java kodu
girmez — yalnız sözlük içeriği okunup bu deponun şemasına çevrildi. Yapılanlar:

1. **Kök çıkarma** — `TurkishDictionaryLoader.generateRoot()` birebir
   uygulandı: fiillerde `-mek/-mak` atıldı (`gitmek → git`), Türkçeye özgü
   küçük harf (`I→ı`, `İ→i`), şapka normalizasyonu (`â→a`, `î→i`, `û→u`),
   tire ve kesme işareti temizliği.
2. **POS çıkarımı** — `getPosData()` / `inferPrimaryPos()`: `P:` alanı yoksa
   `-mek/-mak` ile bitenler `Verb`, kalanı `Noun`; büyük harfle başlayanlar
   `ProperNoun`. `P:` alanında PrimaryPos kısa biçimi olmayan token
   (`P:Prop` gibi) SecondaryPos'a düşürüldü.
3. **Öznitelik çıkarımı** — `inferMorphemicAttributes()` birebir uygulandı.
   Kritik nokta: `Voicing` **çoğu girdide yazılı değildir, çıkarılır**.
   İsim/sıfatlarda ≥2 heceli ve `p/ç/t/k` ile biten kökler varsayılan olarak
   yumuşar; `NoVoicing` veya `InverseHarmony` işareti bunu bastırır; tek
   heceliler varsayılan `NoVoicing`'dir (bu yüzden `cep [A:Voicing]` açıkça
   işaretlidir). `-nk` / `-og` ile bitenler heceden bağımsız yumuşar.
   Fiil dalı **Voicing üretmez**; fiilde yumuşama yalnız açık `[A:Voicing]`
   ile gelir (`gitmek [A:Voicing]`).
4. **Alternasyon sınıfına eşleme** — `Voicing` + son harf:
   `p→pToB`, `ç→cToC`, `t→tToD`, `k→` **`-nk` ise `kToG`** (`renk→rengi`),
   değilse `kToGSoft` (`çocuk→çocuğu`).
5. **Kapsam dışı bırakılanlar** — `Punc`, `Interj`, `Conj`, `Det`, `Postp`,
   `Pron`, `Ques`, `Dup` POS'ları (çekimlenmez ya da düzensiz çekimlenir);
   `CompoundP3sg` bileşikleri; çok kelimeli girdiler; Türk alfabesi dışı
   harf içerenler (`washington`, `holywood`); `proper-from-corpus.dict`
   (kendi başlığında "may contain wrong proper nouns" diyor).
6. **Frekans** — `sayım` sütunu Zemberek'ten **gelmez**; `wordlist.tsv`
   sayımlarından en-uzun-kök-öneki ataması ile hesaplandı. Bu sütun
   dolayısıyla CC BY-SA kaynaklıdır (aşağıya bak).

Sonuç: **30.041 kök** (20.463 isim, 3.784 sıfat, 3.447 fiil, 1.484 özel ad,
863 zarf).

## Gerekli atıf metni

```
Turkish root lexicon derived from Zemberek-NLP
(https://github.com/ahmetaa/zemberek-nlp), © 2018 Ahmet A. Akın,
Mehmet D. Akın, licensed under the Apache License, Version 2.0.
Modified: roots extracted from dictionary lemmas, part-of-speech and
phonological attributes remapped to this project's schema, entries filtered
and frequency-weighted.
```

## Yükümlülük

Apache-2.0 §4: türev dağıtımında lisans kopyası, telif bildirimi ve
**"değişiklik yapıldığı" beyanı** bulunmalı. Üçü de karşılanıyor:
lisans metni bu kayıtta, telif bildirimi yukarıda, değişiklik listesi
"Bu depoda yapılan işlem" bölümünde ve `roots.tsv` başlığında.

**Share-alike yoktur.** `roots.tsv`'nin ilk, ikinci, dördüncü ve beşinci
sütunları (kök, pos, alternasyon, ünlüDüşmesi) yalnız Apache-2.0'a tabidir.

**Tek istisna — `sayım` sütunu.** O sütun `wordlist.tsv`'den, yani CC BY-SA 4.0
kaynaklardan türetilmiştir; frekans bilgisi bu yüzden share-alike taşır.
İki rejim tek dosyada. Pratik sonuç: dosyanın tamamı bu depoda CC BY-SA 4.0
uyumlu şekilde açık tutuluyor, ama **kök envanteri ve fonolojik bayraklar**
copyleft'ten bağımsız olarak yeniden kullanılabilir. Frekanslardan arındırılmış
bir kopya (`sayım` sütunu sabitlenmiş) saf Apache-2.0'dır.
