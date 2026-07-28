import SwiftUI

/// Lisans atıf ekranı.
///
/// CC BY-SA 4.0 üç şey istiyor: **atıf**, **lisansın belirtilmesi** ve
/// **yapılan değişikliklerin beyanı**. Üçü de burada. Share-alike yükümlülüğü
/// ayrıca veri dosyalarının herkese açık depoda DRM'siz durmasıyla karşılanıyor
/// — uygulamadaki kopya yalnızca kolaylık.
///
/// Bu ekran uygulamanın **kodunu** kapsamaz; kod veriden bağımsız bir eserdir.
struct LicensesView: View {

    private struct Source: Identifiable {
        let id = UUID()
        let name: String
        let holder: String
        let license: String
        let licenseURL: URL
        let sourceURL: URL
        let note: String
    }

    private let sources: [Source] = [
        Source(name: "FrequencyWords",
               holder: "Hermit Dave",
               license: "CC BY-SA 4.0",
               licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!,
               sourceURL: URL(string: "https://github.com/hermitdave/FrequencyWords")!,
               note: "OpenSubtitles 2018 (OPUS) tabanlı kelime frekansları. "
                   + "Depo kodu MIT, içerik CC BY-SA 4.0."),
        Source(name: "Türkçe Wikipedia",
               holder: "Wikipedia katkıcıları",
               license: "CC BY-SA 3.0 + GFDL",
               licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/3.0/")!,
               sourceURL: URL(string: "https://huggingface.co/datasets/wikimedia/wikipedia")!,
               note: "20231101.tr anlık görüntüsü; yazılı dil frekansları buradan sayıldı."),
        Source(name: "wikipedia-word-frequency-clean",
               holder: "adno",
               license: "CC BY-SA (veri) · BSD-3-Clause (script)",
               licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!,
               sourceURL: URL(string: "https://github.com/adno/wikipedia-word-frequency-clean")!,
               note: "İngilizce yazılı dil frekansları."),
    ]

    private let modifications = [
        "Kaynaklar ayrı ayrı normalize edilip ağırlıklı olarak birleştirildi",
        "Türkçe listeden q, w, x içeren formlar çıkarıldı",
        "Türkçeye özgü küçük harf dönüşümü uygulandı (I→ı, İ→i)",
        "Sayımlar tamsayı ölçeğe çevrildi",
        "Çok kelimeli ve 40 karakterden uzun girdiler elendi",
    ]

    var body: some View {
        List {
            Section {
                Text("Bu klavyenin sözlük verisi aşağıdaki açık kaynaklardan "
                     + "türetilmiştir. Uygulamanın kendi kodu bu lisanslar "
                     + "kapsamında değildir.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            ForEach(sources) { s in
                Section(s.name) {
                    LabeledContent("Hak sahibi", value: s.holder)
                    LabeledContent("Lisans", value: s.license)
                    Link("Lisans metni", destination: s.licenseURL)
                    Link("Kaynak", destination: s.sourceURL)
                    Text(s.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Yapılan değişiklikler") {
                Text("CC BY-SA, türev üzerinde yapılan değişikliklerin "
                     + "belirtilmesini ister:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(modifications, id: \.self) { m in
                    Label(m, systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .imageScale(.small)
                }
            }

            Section("Share-alike") {
                Text("Türetilmiş kelime listeleri ve onlardan üretilen sözlük "
                     + "paketleri CC BY-SA 4.0 altındadır ve depoda herkese açık "
                     + "olarak, teknolojik koruma olmadan yayımlanır. Uygulama "
                     + "içindeki kopya yalnızca kolaylık amaçlıdır.")
                .font(.footnote)
            }
        }
        .navigationTitle("Lisanslar")
        .navigationBarTitleDisplayMode(.inline)
    }
}
