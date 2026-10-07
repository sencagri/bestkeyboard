import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

struct LayoutSettingsView: View {
    let model: KeyboardSettingsModel
    @Environment(\.colorScheme) private var scheme

    private func pt(_ units: Double) -> String { "\(Int((units * 393 / 11).rounded())) pt" }

    var body: some View {
        let m = model.metrics
        VStack(spacing: 0) {
            PreviewHeader(settings: model.settings)
                .animation(.easeOut(duration: 0.16), value: m)
            ScrollView {
                VStack(spacing: 14) {
                    SharedStoreNotice()
                    BKCard {
                        BKToggleRow("Sayı satırı", "Rakamlar harflerin üstünde dursun", tint: BK.teal.ink, isOn: Binding(get: { model.showsNumberRow }, set: { model.showsNumberRow = $0 }))
                        BKDivider()
                        BKSliderRow(title: "Shift tuşu", value: pt(m.shiftWidth), tint: BK.teal.ink,
                                    x: model.metricBinding(.shift), range: KeyboardMetrics.shiftRange,
                                    step: KeyboardMetrics.step)
                        BKSliderRow(title: "Silme tuşu", value: pt(m.backspaceWidth), tint: BK.teal.ink,
                                    x: model.metricBinding(.backspace), range: KeyboardMetrics.backspaceRange,
                                    step: KeyboardMetrics.step,
                                    hint: "Bu ikisi genişledikçe alt sıradaki harfler daralır: şu an her harf \(pt(m.letterWidthUnitsRow3)).")
                        BKSliderRow(title: "Boşluk tuşu", value: pt(m.effectiveSpaceWidth(showsGlobe: KeyboardSettingsModel.showsGlobe)),
                                    tint: BK.teal.ink, x: model.metricBinding(.space),
                                    range: KeyboardMetrics.spaceBounds(showsGlobe: KeyboardSettingsModel.showsGlobe),
                                    step: KeyboardMetrics.step,
                                    hint: "Enter kalan yeri alır: \(pt(model.returnWidth)).")
                        BKSliderRow(title: "Alt satır yüksekliği", value: "\(Int((KeyboardView.rowHeightPoints * m.bottomRowScale).rounded())) pt",
                                    tint: BK.teal.ink, x: model.metricBinding(.bottomRow),
                                    range: KeyboardMetrics.bottomRowRange, step: KeyboardMetrics.bottomRowStep,
                                    hint: "Boşluk satırı uzar, harfler aynı kalır.")
                    }
                    Button("Varsayılana dön") { model.reset() }
                        .buttonStyle(.bkCard())
                }
                .padding(16)
            }
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Klavye düzeni")
    }
}
