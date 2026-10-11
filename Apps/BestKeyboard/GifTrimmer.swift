import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Tasarım tuvali "14 · GIF yapıcı": yakınlaşan kare şeridi, iki kalın
/// tutamaç (uçtan çek = başlangıç/bitiş) ve ortadan sürükleme (pencereyi
/// kaydır). Şerit yalnız görünen aralığı gösteriyor; iki parmakla ya da
/// −/+ ile yakınlaşıyor. Uzun videoda 3 saniyelik seçim ince bir çizgi
/// olmasın diye açılışta seçimin çevresindeki 20 saniye görünüyor.
struct GifTrimmer: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let asset: AVURLAsset
    let duration: Double
    @Binding var start: Double
    @Binding var length: Double
    var onCommit: () -> Void

    @State private var view: Double = 0
    @State private var span: Double = 20
    @State private var frames: [UIImage] = []
    @State private var drag: (mode: Mode, start0: Double, len0: Double)?
    @State private var pinchSpan: Double?

    enum Mode { case start, end, body }
    private let handle: CGFloat = 22
    private let maxLen = 6.0
    private var minLen: Double { min(1, duration) }


    var body: some View {
        BKCard {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
            headerLayout {
                Text("Hangi kısım").font(.headline)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                HStack {
                    zoomButton("minus", "Uzaklaştır") { setSpan(span * 2) }
                    Text("\(Int(span.rounded())) sn görünüyor").font(.footnote).foregroundStyle(BK.sub)
                        .frame(minWidth: 96, maxWidth: .infinity).monospacedDigit()
                    zoomButton("plus", "Yakınlaştır") { setSpan(span / 2) }
                }
            }
            GeometryReader { g in
                let W = g.size.width - handle * 2
                let x = { (t: Double) in handle + CGFloat((t - view) / span) * W }
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 2) {
                        ForEach(Array(frames.enumerated()), id: \.offset) { i, im in
                            let t = view + (Double(i) + 0.5) / Double(max(frames.count, 1)) * span
                            Image(uiImage: im).resizable().scaledToFill()
                                .frame(maxWidth: .infinity).frame(height: 64).clipped()
                                .brightness(t >= start && t <= start + length ? 0 : -0.35)
                        }
                    }
                    .frame(width: W, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: BK.Radius.thumb))
                    .offset(x: handle, y: 4)

                    // Pencere gövdesi — ortadan sürükleyince kayar.
                    Rectangle().fill(Color.white.opacity(0.001))
                        .overlay(Rectangle().stroke(BK.purple.ink, lineWidth: 4).padding(.vertical, 2))
                        .frame(width: max(0, x(start + length) - x(start)), height: 72)
                        .offset(x: x(start))
                        .simultaneousGesture(dragGesture(.body, width: W))
                        .accessibilityHidden(true)

                    grip(left: true).offset(x: x(start) - handle).simultaneousGesture(dragGesture(.start, width: W))
                    grip(left: false).offset(x: x(start + length)).simultaneousGesture(dragGesture(.end, width: W))
                }
                .contentShape(Rectangle())
                .simultaneousGesture(MagnifyGesture().onChanged { v in
                    if pinchSpan == nil { pinchSpan = span }
                    setSpan((pinchSpan ?? span) / v.magnification)
                }.onEnded { _ in pinchSpan = nil })
            }
            .frame(height: 72)
            let rangeLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
            rangeLayout {
                Text(SettingsFormat.seconds(start, digits: 1)).bold().foregroundStyle(BK.purple.ink)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Text("uçlardan çek · ortadan kaydır").font(.caption).foregroundStyle(BK.sub)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Text(SettingsFormat.seconds(start + length, digits: 1)).bold().foregroundStyle(BK.purple.ink)
            }
            .font(.footnote).monospacedDigit()
        }
        .onAppear {
            span = min(duration, 20)
            view = clampView(start + length / 2 - span / 2)
        }
        .task(id: "\(Int(view * 10))-\(Int(span * 10))") { await loadFrames() }
    }

    private func grip(left: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: left ? 10 : 0, bottomLeadingRadius: left ? 10 : 0,
                               bottomTrailingRadius: left ? 0 : 10, topTrailingRadius: left ? 0 : 10)
            .fill(BK.purple.ink)
            .overlay(Capsule().fill(.white.opacity(0.85)).frame(width: 4, height: 26))
            .frame(width: handle, height: 72)
            // Dokunma alanı görünenden geniş: 44 pt.
            .contentShape(Rectangle().inset(by: -11))
            .accessibilityElement()
            .accessibilityLabel(left ? "Başlangıç" : "Bitiş")
            .accessibilityValue(SettingsFormat.seconds(left ? start : start + length, digits: 1))
            .accessibilityAdjustableAction { dir in
                let d = dir == .increment ? 0.1 : -0.1
                if left { moveStart(to: start + d) }
                else { length = min(duration - start, min(maxLen, max(minLen, length + d))) }
                onCommit()
            }
    }

    private func zoomButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundStyle(BK.purple.ink)
                .frame(width: 44, height: 44).background(BK.purple.chip, in: RoundedRectangle(cornerRadius: BK.Radius.thumb))
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private func dragGesture(_ mode: Mode, width W: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                // Dikey sürükleme sayfayı kaydırır; yalnız yatay hareket
                // videonun seçili bölümünü değiştirir.
                if drag == nil, abs(v.translation.width) <= abs(v.translation.height) { return }
                if drag == nil { drag = (mode, start, length) }
                guard let d = drag else { return }
                let dt = Double(v.translation.width / W) * span
                switch d.mode {
                case .body:
                    start = min(max(0, d.start0 + dt), duration - length)
                case .start:
                    let end = d.start0 + d.len0
                    let s = min(max(0, d.start0 + dt), end - minLen)
                    start = max(s, end - maxLen); length = end - start
                case .end:
                    length = min(max(minLen, d.len0 + dt), min(maxLen, duration - d.start0))
                }
                followSelection()
            }
            .onEnded { _ in
                guard drag != nil else { return }
                drag = nil; onCommit()
            }
    }

    private func moveStart(to s: Double) {
        let end = start + length
        start = max(0, min(s, end - minLen)); length = end - start
    }

    /// Seçim görünen aralığın dışına çıkarsa şerit onunla kayıyor.
    private func followSelection() {
        if start < view { view = clampView(start) }
        if start + length > view + span { view = clampView(start + length - span) }
    }

    private func setSpan(_ s: Double) {
        let newSpan = min(duration, max(4, s))
        let mid = start + length / 2
        span = newSpan
        view = clampView(mid - newSpan / 2)
    }

    private func clampView(_ v: Double) -> Double { max(0, min(v, duration - span)) }

    private func loadFrames() async {
        let gen = VideoFrames.generator(asset, maxSide: 120, tolerance: VideoFrames.time(max(0.05, span / 30)))
        let n = 10
        let times = (0..<n).map { CMTime(seconds: view + (Double($0) + 0.5) / Double(n) * span, preferredTimescale: 600) }
        var out: [UIImage] = []
        for await r in gen.images(for: times) {
            if Task.isCancelled { return }
            if let cg = try? r.image { out.append(UIImage(cgImage: cg)) }
        }
        frames = out
    }
}
