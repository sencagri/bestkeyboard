import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

/// ⌫ basılı tutma — animasyonla. Parametre değişince animasyon baştan
/// başlıyor ve zaman çizgisindeki her çentik bir silme anı; kullanıcı
/// ayarın etkisini sayıdan değil gözden okuyor.
struct DeleteSettingsView: View {
    let model: KeyboardSettingsModel
    @State private var start = Date()

    private static let sample = "Yarın akşam yedide buluşalım mı, yoksa hafta sonuna mı bırakalım"

    var body: some View {
        let c = model.cadence
        BKScreen("Silme tuşu") {
            (Text("⌫'ye basılı tutunca önce biraz bekler, sonra ")
             + Text("harf harf").bold().foregroundColor(BK.orange.ink)
             + Text(", en sonunda ")
             + Text("kelime kelime").bold().foregroundColor(BK.pink.ink)
             + Text(" siler. Ayarları değiştir, aşağıda hemen gör."))
                .font(.subheadline).foregroundStyle(BK.sub)
                .padding(.horizontal, 4)
            SharedStoreNotice()
            BKCard { TimelineView(.animation) { ctx in demo(c, at: ctx.date) } }
            BKCard {
                BKSliderRow(title: "Silmeye başlamadan bekle",
                            value: SettingsFormat.seconds(c.initialDelay),
                            tint: BK.blue.ink, x: restart(model.cadenceBinding(.initialDelay)),
                            range: KeyRepeatCadence.initialDelayRange, step: KeyRepeatCadence.initialDelayStep,
                            hint: "Kısa olursa hızlı yazarken istemeden fazla silebilirsin.")
                BKDivider()
                BKSliderRow(title: "Harf silme hızı", value: "saniyede \(Int((1 / c.characterInterval).rounded())) harf",
                            tint: BK.orange.ink, x: restart(reversed(model.cadenceBinding(.characterInterval),
                                                                     KeyRepeatCadence.characterIntervalRange)),
                            range: KeyRepeatCadence.characterIntervalRange, step: KeyRepeatCadence.characterIntervalStep,
                            ends: ("yavaş", "hızlı"))
                BKDivider()
                BKSliderRow(title: "Kaç harften sonra kelimeye geçsin", value: "\(c.charactersBeforeWordStage) harf",
                            tint: BK.orange.ink, x: restart(model.cadenceBinding(.wordStage)),
                            range: SettingsSliders.wordStage.range, step: SettingsSliders.wordStage.step)
                BKDivider()
                BKSliderRow(title: "Kelime silme hızı",
                            value: SettingsFormat.decimal("saniyede %.1f kelime", 1 / c.wordInterval),
                            tint: BK.pink.ink, x: restart(reversed(model.cadenceBinding(.wordInterval),
                                                                   KeyRepeatCadence.wordIntervalRange)),
                            range: KeyRepeatCadence.wordIntervalRange, step: KeyRepeatCadence.wordIntervalStep,
                            ends: ("yavaş", "hızlı"))
            }
            Button("Varsayılana dön") { model.reset(); start = Date() }
                .buttonStyle(.bkCard())
        }
    }

    /// Kaydırıcı sağa = hızlı: aralık küçülüyor, o yüzden ters çevriliyor.
    private func reversed(_ b: Binding<Double>, _ r: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { r.lowerBound + r.upperBound - b.wrappedValue },
                set: { b.wrappedValue = r.lowerBound + r.upperBound - $0 })
    }

    private func restart(_ b: Binding<Double>) -> Binding<Double> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = $0; start = Date() })
    }

    @ViewBuilder
    private func demo(_ c: KeyRepeatCadence, at now: Date) -> some View {
        let n = c.charactersBeforeWordStage
        let wordStart = c.initialDelay + Double(n - 1) * c.characterInterval
        let hold = wordStart + c.wordInterval * 4 + 0.25
        let loop = hold + 1.1
        let t = now.timeIntervalSince(start).truncatingRemainder(dividingBy: loop)
        let holding = t < hold
        let tt = min(t, hold)
        let events: [(Double, Bool)] = (1...n).map { (c.initialDelay + Double($0 - 1) * c.characterInterval, false) }
            + (1...max(1, Int((hold - wordStart) / c.wordInterval))).map { (wordStart + Double($0) * c.wordInterval, true) }
        let done = events.filter { $0.0 <= tt }
        let text = done.reduce(Self.sample) { s, e in
            if !e.1 { return String(s.dropLast()) }
            let trimmed = s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            guard let i = trimmed.lastIndex(of: " ") else { return "" }
            return String(trimmed[...i])
        }
        let lastWord = done.last?.1 == true
        let (phase, sub, color): (String, String, Color) =
            !holding ? ("Parmak kalktı", "Birazdan yeniden başlıyor", BK.sub)
            : tt < c.initialDelay ? ("Bekliyor…", "Kısa dokunuş tek harf siler", BK.blue.ink)
            : lastWord ? ("Kelime kelime siliyor", "Parmağını kaldırana kadar", BK.pink.ink)
            : ("Harf harf siliyor", "\(min(done.count, n)) / \(n) harf", BK.orange.ink)

        VStack(alignment: .leading, spacing: 14) {
            (Text(text) + Text("|").foregroundColor(BK.accent))
                .font(.body).frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                .bkField()
            HStack(spacing: 14) {
                Image(systemName: "delete.left").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(holding ? .white : BK.ink)
                    .frame(width: 64, height: 48)
                    .background(holding ? BK.orange.ink : BK.line, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase).font(.headline).foregroundStyle(color)
                    Text(sub).font(.footnote).foregroundStyle(BK.sub)
                }
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        BK.blue.chip.frame(width: w * c.initialDelay / hold)
                        BK.orange.chip.frame(width: w * (wordStart - c.initialDelay) / hold)
                        BK.pink.chip
                    }
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(e.1 ? BK.pink.ink : BK.orange.ink)
                            .opacity(e.0 <= tt ? 1 : 0.35)
                            .frame(width: 2, height: 16)
                            .offset(x: w * min(e.0, hold) / hold)
                    }
                    Rectangle().fill(BK.ink).frame(width: 2).offset(x: w * tt / hold)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 26)
            HStack(spacing: 0) {
                GeometryReader { g in
                    let w = g.size.width
                    HStack(spacing: 0) {
                        Text("bekle").foregroundStyle(BK.blue.ink).frame(width: w * c.initialDelay / hold, alignment: .leading)
                        Text("harf harf").foregroundStyle(BK.orange.ink).frame(width: w * (wordStart - c.initialDelay) / hold, alignment: .leading)
                        Text("kelime kelime").foregroundStyle(BK.pink.ink)
                    }
                    .lineLimit(1).font(.caption.weight(.semibold))
                }
            }
            .frame(height: 16)
        }
    }
}
