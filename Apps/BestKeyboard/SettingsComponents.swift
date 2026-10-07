import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

/// Değer satırı: etiket solda, renkli değer sağda, altında kaydırıcı ve ipucu.
extension BKSliderRow {
    /// Ortak tanımdan (`SettingsSliders`): başlık, aralık, adım ve biçim tek yerde.
    init(_ spec: SliderSpec, tint: Color, x: Binding<Double>, hint: String? = nil, ends: (String, String)? = nil) {
        self.init(title: spec.title, value: spec.format(x.wrappedValue), tint: tint, x: x,
                  range: spec.range, step: spec.step, hint: hint, ends: ends)
    }
}

struct BKSliderRow: View {
    let title: String
    let value: String
    let tint: Color
    @Binding var x: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var hint: String? = nil
    var ends: (String, String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.body.weight(.semibold))
                Spacer()
                Text(value).font(.subheadline.weight(.bold)).foregroundStyle(tint).monospacedDigit()
            }
            Slider(value: $x, in: range, step: step).tint(tint)
                .accessibilityLabel(title).accessibilityValue(value)
            if let ends {
                HStack { Text(ends.0); Spacer(); Text(ends.1) }.font(.caption).foregroundStyle(BK.sub)
            }
            if let hint { Text(hint).font(.footnote).foregroundStyle(BK.sub) }
        }
        .padding(.vertical, 6)
    }
}

/// Uygulama ayarları henüz klavyeye ulaşamıyorsa söyleyen şerit.
struct SharedStoreNotice: View {
    var body: some View {
        if !KeyboardSettingsStore.isShared {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(BK.orange.ink)
                Text("Buradaki değişiklikler şimdilik yalnız önizlemeyi etkiliyor; klavyede ⚙︎'den aynı ayarlar var. Uygulama ile klavye bağlanınca buradan yönetilecek.")
                    .font(.footnote).foregroundStyle(BK.ink)
            }
            .padding(12)
            .background(BK.orange.chip, in: RoundedRectangle(cornerRadius: BK.Radius.button, style: .continuous))
        }
    }
}
