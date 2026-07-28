# Lisanslar

Bu depoda **iki ayrı lisans rejimi** var. Ayrımı bilerek koruyoruz.

## 1. Kod — telifi bize ait

`Packages/`, `Apps/`, `Tools/` altındaki her şey: decoder, uzamsal model,
morfoloji motoru, klavye arayüzü, paket üreticisi, ölçüm araçları.

Bunlar veriden bağımsız eserlerdir; aşağıdaki veri lisansları **koda geçmez**.
(CC BY-SA'nın share-alike şartı türev *eserlere* uygular; bir veri dosyasını
okuyan program o verinin türevi değildir.)

## 2. Dil verisi — CC BY-SA 4.0

| Dosya | Lisans |
|---|---|
| `LanguagePacks/tr-TR/wordlist.tsv` | CC BY-SA 4.0 |
| `LanguagePacks/en-US/wordlist.tsv` | CC BY-SA 4.0 |
| `LanguagePacks/**/*.bkt` (üretilmiş paketler) | CC BY-SA 4.0 |

Bu dosyalar aşağıdaki kaynaklardan **türetilmiştir**; share-alike şartı
türetilmiş listelere ve onlardan üretilen binary paketlere geçer.

### Kaynaklar

**hermitdave / FrequencyWords** — © Hermit Dave
<https://github.com/hermitdave/FrequencyWords>
İçerik **CC BY-SA 4.0** (kod MIT). OpenSubtitles 2018 (OPUS) tabanlı.

**Türkçe Wikipedia** — © Wikipedia katkıcıları
<https://huggingface.co/datasets/wikimedia/wikipedia> (`20231101.tr`)
**CC BY-SA 3.0** + GFDL.

**adno / wikipedia-word-frequency-clean** (İngilizce)
<https://github.com/adno/wikipedia-word-frequency-clean>
Veri **CC BY-SA**, script BSD-3-Clause.

CC BY-SA 3.0 tek yönlü olarak 4.0 ile uyumlu olduğu için birleşik türev
**CC BY-SA 4.0** altında dağıtılıyor.

### Yapılan değişiklikler (BY-SA gereği belirtilir)

- Kaynaklar ayrı ayrı ppm'e normalize edildi, sonra `0.62 × altyazı +
  0.38 × Wikipedia` ağırlığıyla birleştirildi
- Türkçe listeden `q, w, x` içeren formlar çıkarıldı (neredeyse tamamı altyazı
  kaynaklı yabancı özel ad)
- Türkçeye özgü küçük harf dönüşümü uygulandı (`I→ı`, `İ→i`), Python'un
  `lower()`'ı `İ`'yi iki skalere ayırdığı için
- Sayımlar tamsayı ölçeğe çevrildi
- Çok kelimeli girdiler ve 40 karakterden uzun formlar elendi

## 3. Kök sözlüğü — Apache-2.0 (share-alike YOK)

| Dosya | Lisans |
|---|---|
| `LanguagePacks/tr-TR/roots.tsv` | Apache-2.0 (bkz. aşağıdaki istisna) |

**Zemberek-NLP** — © 2018 Ahmet A. Akın, Mehmet D. Akın
<https://github.com/ahmetaa/zemberek-nlp> — **Apache-2.0**.
`morphology/src/main/resources/tr/{master-dictionary,non-tdk,proper}.dict`
dosyalarından 30.041 kök çıkarıldı; POS ve fonolojik öznitelikler
(`Voicing`, `LastVowelDrop`) bu deponun şemasına eşlendi.

Apache-2.0'da **share-alike yoktur** — kök envanteri ve fonolojik bayraklar
copyleft taşımaz. Yükümlülük yalnız atıf + değişiklik beyanıdır; ikisi de
[`Data/licenses/zemberek-nlp.md`](Data/licenses/zemberek-nlp.md) ve dosyanın
kendi başlığında.

> **İstisna — `sayım` sütunu.** `roots.tsv`'nin frekans sütunu `wordlist.tsv`
> sayımlarından türetildi, yani CC BY-SA 4.0 kaynaklıdır ve share-alike taşır.
> Dosya bu yüzden depoda açık tutuluyor. Kök + POS + alternasyon +
> ünlü düşmesi sütunları bu şarttan bağımsızdır.

Kaynak başına tam envanter, ham URL'ler ve reddedilen kaynakların gerekçeleri:
[`Data/licenses/`](Data/licenses/)

## Ticari kullanım ve dağıtım

CC BY-SA 4.0 **ticari kullanımı kısıtlamaz**; uygulama ücretli satılabilir.
Yükümlülükler:

1. **Atıf** — uygulama içinde Lisanslar ekranı (`Apps/BestKeyboard/LicensesView.swift`)
2. **Değişiklik beyanı** — yukarıdaki liste
3. **Share-alike** — türetilmiş liste ve paketler CC BY-SA 4.0 altında
   erişilebilir tutulur

Üçüncü madde bu deponun kendisiyle karşılanıyor: veri dosyaları burada
herkese açık ve DRM'siz duruyor. Uygulama içindeki kopya yalnızca kolaylıktır.

> **Not:** bu bir hukuki görüş değildir. CC BY-SA 4.0'ın "etkili teknolojik
> önlem uygulanamaz" maddesi ile mağaza DRM'i arasındaki ilişki tam net
> değildir; veriyi ayrıca DRM'siz yayınlamak yaygın kabul gören çözümdür.
> Ticari dağıtım öncesinde bir avukata danışılması yerinde olur.
