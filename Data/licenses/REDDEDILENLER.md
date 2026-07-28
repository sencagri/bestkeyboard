# Reddedilen kaynaklar

Değerlendirilip **kullanılmayan** veri kaynakları ve gerekçeleri.
Bir kaynağı ileride yeniden değerlendirirken bu listeye bak — aynı araştırmayı
iki kez yapmaya gerek yok.

İnceleme tarihi: 2026-07-28

## Lisans gerekçesiyle reddedilenler

### Leipzig Corpora Collection (Wortschatz Leipzig) — Türkçe
- URL: https://wortschatz.uni-leipzig.de/en/download
- Durum: **lisans doğrulanamadı.** İndirme sayfası bot korumasının
  (Anubis challenge) arkasında; lisans beyanı otomatik olarak okunamadı.
  Kaynaklarda hem CC BY hem CC BY-NC atıfları geçiyor — CC BY-NC ticari
  kullanımı yasaklar.
- Karar: **red.** "Lisansı belirsiz olan kaynak kullanılmaz" kuralı.
  Doğrulanabilir bir CC BY beyanı bulunursa yeniden değerlendirilebilir;
  Türkçe için 1M cümlelik temiz haber/web korpusu iyi bir tamamlayıcı olurdu.

### TS Corpus — Türkçe
- URL: https://tscorpus.com/
- Durum: kaynaklar erişimi "**akademik çalışma ve araştırma için**" serbest
  olarak tanımlıyor; açık bir yeniden dağıtım / ticari kullanım izni yok.
- Karar: **red.** "Yalnız araştırma amaçlı" kaynak ürüne giremez.

### OSCAR (Open Super-large Crawled Aggregated coRpus) — tr
- URL: https://oscar-project.org/
- Durum: metadata için CC0 beyanı var, ancak **metnin kendisi** Common Crawl
  kaynaklı ve OSCAR bu metne bir lisans vermiyor ("we do not own any of the
  text"). Ayrıca son sürümler için erişim kabul formu isteniyor.
- Karar: **red.** Belirsiz lisans + koşullu erişim.

### CC-100 (tr)
- URL: https://data.statmt.org/cc-100/
- Durum: Common Crawl'dan türetilmiş; dağıtım sayfası açık bir yeniden dağıtım
  lisansı beyan etmiyor, Common Crawl kullanım şartlarına gönderme yapıyor.
- Karar: **red.** Belirsiz lisans.

### Norvig `count_1w.txt`
- URL: https://norvig.com/ngrams/
- Durum: sayfadaki MIT beyanı **kodu** kapsıyor; veri Google Web Trillion Word
  Corpus'tan türetilmiş ve o korpusun dağıtım lisansı sayfada belirtilmiyor.
- Karar: **red.** Veri tarafının lisansı belirsiz. Zaten yalnız 333k tip ve
  sıklık kesimi kaba; hermitdave + enwiki kombinasyonu her açıdan üstün.

## Uygunluk (kalite/register) gerekçesiyle reddedilenler

### Google Books Ngrams
- URL: http://storage.googleapis.com/books/ngrams/books/datasetsv3.html
- Lisans: **CC BY 3.0** — lisans açısından sorun yok.
- Karar: **red.**
  1. **Türkçe yok.** Veri seti yalnız İngilizce, Çince, Fransızca, Almanca,
     İbranice, İtalyanca, Rusça, İspanyolca içeriyor.
  2. İngilizce için de register yanlış: 1500–2019 arası **kitap** metni.
     Arkaik biçimler ve OCR hataları ağır basıyor, klavye için gereken
     günlük dil zayıf. Ayrıca terabayt ölçeğinde — 60k'lık bir liste için
     orantısız.

### dwyl/english-words
- URL: https://github.com/dwyl/english-words
- Lisans: Unlicense — sorun yok.
- Karar: **red.** **Frekans yok.** Bu proje `−log(freq/total)` ile leksikal
  maliyet üretiyor; frekanssız liste tüm kelimeleri eşit maliyete koyar ve
  beam search'ün ayrım gücünü yok eder. Ayrıca liste çok gürültülü
  (~466k giriş, büyük kısmı kısaltma/tarama artığı).

### SCOWL / Hunspell en_US
- URL: http://wordlist.aspell.net/
- Lisans: permissive (SCOWL kendi izin veren lisansı) — sorun yok.
- Karar: **red.** Frekans yok; yazım denetimi için tasarlanmış, sıklık
  bilgisi taşımıyor. Gelecekte "bu form geçerli mi" kontrolü için
  ikincil bir filtre olarak yararlı olabilir.

### Zemberek (`zemberek-nlp`) — ARTIK KULLANILIYOR, bu maddeye bakma
- URL: https://github.com/ahmetaa/zemberek-nlp
- Lisans: **Apache-2.0** — sorun yok, ürüne girebilir.
- Karar (ilk değerlendirme): **yüzey frekans listesi için** red, ama atılmadı.
  Zemberek kök sözlüğü + morfotaktik kuralları taşır, **yüzey formu frekansı
  taşımaz**. Frekans listesinin yerine değil, **yanına** konumlanır.
- **Güncelleme (2026-07-28): kabul edildi ve kullanıldı.** Tam da öngörülen
  yerde: `LanguagePacks/tr-TR/roots.tsv` (30.041 kök) bu kaynaktan üretildi ve
  `KBMorphology` otomatını besliyor. Kabul kaydı, atıf metni ve dönüşüm
  ayrıntıları: [`zemberek-nlp.md`](zemberek-nlp.md).

### IlyaSemenov/wikipedia-word-frequency
- URL: https://github.com/IlyaSemenov/wikipedia-word-frequency
- Lisans: MIT (script) + CC BY-SA (veri) — sorun yok.
- Karar: **red.** `adno/wikipedia-word-frequency-clean` aynı işi daha temiz
  yapıyor: markup artıkları (`br`, `colspan`) ayıklanmış, tokenizasyon tutarlı,
  NFKC/lowercase mutasyonları hazır. Ayrıca Türkçe **ikisinde de yok**.
