# Devam notları — 25 Ekim 2026

Kullanıcının isteğiyle sürekli test hedefi **duraklatıldı**. Kullanıcı devam etmeden otomatik test döngüsünü yeniden başlatma. Çalışma tamamlandı sayılmıyor.

## Tamamlanan son durum

- Türkçe kök/ek kapsamı, şapkasız yazım, çift basma ve yanlış boşluk önerileri genişletildi. Kişisel öğrenmede aynı kullanımı yeniden seçme/silme/Enter ile çoğaltan yollar düzeltildi.
- İncelenen 36 ertelenmiş kaynak kaydının tümü sonuçlandı. Bu, bütün Türkçe köklerin eksiksiz olduğu anlamına gelmez. Güncel kaynak taramasında 167 ham yüzey tanınmıyor; bunlar doğrudan 167 eksik geçerli kök sayılmamalı. Şapkalı varyantlar, ayrı yazılması gereken ifadeler ve kaynak hataları ayrıştırılmalı.
- Son düzeltme: `gele cek` / `bilgisa yar` için sözlük kanıtıyla açık birleştirme önerisi. Normal iki kelimeli ifadeler ve soru ekleri korunur; otomatik birleştirme yapılmaz. Baş harf, Enter sonrası geri açma ve seçim sonrası yeniden düzenleme simülatörde geçti.
- Son geniş test: 795 XCTest, 97 isteğe bağlı atlama, sıfır hata (319.086 s); ayrıca 406 Swift Testing testi, 54 takım, sıfır hata (4.610 s). `audits/everyday-20261025-stray-space-full.log`.
- Kullanıcının açık isteğiyle son Release sürümü fiziksel iPhone'a mevcut uygulamanın üzerine kuruldu ve açıldı. Uygulama kaldırılmadı, öğrenme verileri sıfırlanmadı. `audits/everyday-20261025-phone-deploy.log`.

## Kalan işler

1. Gerçek Türkçe yazışma denemelerine devam et: romantik, teknik, şiveli arkadaş sohbeti, resmî yazı ve günlük senaryolar. Çift/fazladan harf, eksik harf, harf sırası, eksik/fazla boşluk, Enter, silme, seçim sonrası yeniden düzenleme kombinasyonlarını kullan. Bulunan hataları yeniden üret, düzelt ve hem motor hem gerçek klavyede doğrula.
2. Kesilen sıradaki deneme: `raporu gönderdmi` → `raporu gönderdim`. Henüz yazılmadı/test edilmedi. Başlangıçta `raporu`, `gönderdim`, `gönderdmi` geçmiş sayıları ve `raporu -> gönderdim` çifti sıfırdı. Yeniden başlarken tekrar ölç.
3. Fiziksel telefondaki eski yanlış öğrenilmiş kelimelerin güncel davranışını ayrıca incele. Simülatör başarıları bütün telefon geçmişinin temiz olduğu kanıtı değildir. Önceki salt okunur kayıt `Data/raw/phone-20261024-unlocked` altında; kişisel ham veriler Git'e alınmaz. Kullanıcı silme istemedi; mevcut öğrenmeyi topluca sıfırlama.
4. Türkçe kapsamını kaynaklara dayanarak genişletmeye devam et. Günlük şapkasız yazımı zorla şapkalıya çevirme; açıkça yazılan şapkalı biçimi koru. Kaynak dosyanın metadata hatalarını körlemesine aktarma.
5. Sonradan yeni değişiklik yapılırsa telefondaki sürümün otomatik olarak güncel olduğunu varsayma. Bu kurulum anındaki sürüm gönderildi; sonraki telefon kurulumunu kullanıcı isteğiyle ilişkilendir.

## Devam için kaynaklar ve ortam

- Ana ilerleme kaydı: `audits/everyday-20261024-progress.json`.
- Ayrıntılı değişiklik ve test gerekçeleri: `docs/keyboard-architecture-review.md`.
- Kaynak kararları: `audits/turkish-manual-source-decisions-20261025.json`.
- Güncel kaynak tanıma taraması: `audits/turkish-root-runtime-rabbena-after-20261025.json`.
- Kendi test simülatörümüz: `2219EC8E-73BE-4E32-8A92-ECF2C045A789`, iPhone 17 Pro, iOS 26.4.1. Son uygulama PID 23590; PID'yi yeniden doğrula.
- Diğer simülatörlere dokunma. Özellikle `4367ED19-CB05-4589-ADE2-5F1822F54390` başka iş içindir.
- Son arayüz: yeni boş fixture açıldı; Device menüsü açık, Toggle Software Keyboard görünüyordu. Yeni oturumda güncel görüntüyü okuyarak ilerle; eski erişilebilirlik indekslerini kullanma.
- Çalışan derleme/test kalmadı: son geniş test 58172 ve telefon kurulumu 42580 başarıyla tamamlandı. Bunları tekrar çalışan iş sanma.
- Motor testleri: `swift test --package-path Packages/KeyboardCore -c release`. Tam test yaklaşık 5 dakika; tamponlanan günlük uzun süre değişmeyebilir. Canlı oturumu sırf çıktı gelmedi diye yeniden başlatma.
- Dil paketi üretimi: `bash Tools/build-packs.sh`. Telefon kurulumu: `bash Tools/deploy.sh --no-pack --device 00008120-0002382C2EC0201E` (paketler güncelse). Varsayılan Release korunmalı.
- `/tmp/bk-inspect-simulator-{history,personal,pairs}.py` yerel sayaç denetim yardımcılarıdır; geçici oldukları için ileride varlıklarını doğrula. Testte önce/sonra sayaçlarını al; yanlış parçaların sıfır ve doğru kullanım artışının bir olduğunu kontrol et.
