import SwiftUI
import UIKit
import KBGeometry
import KBRuntime

/// Ayar ekranının durumu.
///
/// ## Neden ham alan yok
///
/// İlk sürüm her ayarı ayrı bir `Double` olarak tutuyor, `settings`'i onlardan
/// üretiyordu. Kanonikleştirme (kırpma, kademeye oturtma, `wordInterval ≥
/// characterInterval`) `init`'lerde olduğu için **sonuç** ile **ham alan**
/// ayrışıyordu: kelime aralığını karakter aralığının altına çekince sürgü
/// 100 ms göstermeye devam ediyor, çalışan klavye 200 ms kullanıyor, sonra
/// karakter aralığını düşürmek o gizli 100 ms'yi sessizce geri getiriyordu.
///
/// Şimdi tek doğruluk kaynağı kanonik `settings`; sürgüler ona `with(...)`
/// üzerinden yazıyor ve okurken kanonik değeri görüyor — kırpılan bir hareket
/// sürgüde de geri sıçrıyor.
@Observable
final class KeyboardSettingsModel {
    private(set) var settings: KeyboardSettings = KeyboardSettingsStore.load()

    var metrics: KeyboardMetrics { settings.metrics }
    var cadence: KeyRepeatCadence { settings.cadence }

    var theme: ThemeChoice {
        get { settings.theme }
        set { settings.theme = newValue; save() }
    }

    var showsNumberRow: Bool {
        get { metrics.showsNumberRow }
        set { apply(metrics.with(showsNumberRow: newValue)) }
    }

    /// `⏎` boşluktan artanı alıyor; kullanıcı ne kadar yer bıraktığını görmeli.
    var returnWidth: Double { metrics.returnWidth(showsGlobe: true) }

    /// Ölçü sürgüleri. `get` kanonik değeri döndürüyor: kırpılan bir hareket
    /// sürgünün kendisinde de görünüyor.
    func metricBinding(_ key: MetricKey) -> Binding<Double> {
        Binding(get: { [weak self] in
            guard let m = self?.metrics else { return 0 }
            switch key {
            case .shift:      return m.shiftWidth
            case .backspace:  return m.backspaceWidth
            case .space:      return m.effectiveSpaceWidth(showsGlobe: true)
            case .bottomRow:  return m.bottomRowScale
            }
        }, set: { [weak self] v in
            guard let self else { return }
            switch key {
            case .shift:      self.apply(self.metrics.with(shiftWidth: v))
            case .backspace:  self.apply(self.metrics.with(backspaceWidth: v))
            case .space:      self.apply(self.metrics.with(spaceWidth: v))
            case .bottomRow:  self.apply(self.metrics.with(bottomRowScale: v))
            }
        })
    }

    enum MetricKey { case shift, backspace, space, bottomRow }
    enum CadenceKey { case initialDelay, characterInterval, wordInterval, wordStage }

    func cadenceBinding(_ key: CadenceKey) -> Binding<Double> {
        Binding(get: { [weak self] in
            guard let c = self?.cadence else { return 0 }
            switch key {
            case .initialDelay:      return c.initialDelay
            case .characterInterval: return c.characterInterval
            case .wordInterval:      return c.wordInterval
            case .wordStage:         return Double(c.charactersBeforeWordStage)
            }
        }, set: { [weak self] v in
            guard let self else { return }
            let c = self.cadence
            switch key {
            case .initialDelay:      self.apply(c.with(initialDelay: v))
            case .characterInterval: self.apply(c.with(characterInterval: v))
            case .wordInterval:      self.apply(c.with(wordInterval: v))
            case .wordStage:
                self.apply(c.with(charactersBeforeWordStage: Int(v.rounded())))
            }
        })
    }

    /// Depoyu **temizleyip** kanonik varsayılanı geri okuyor. Mevcut
    /// varsayılanları yazmak, varsayılan ileride değişirse bugün resetleyeni
    /// eski değerlerde bırakırdı.
    func reset() { settings = KeyboardSettingsStore.reset() }

    /// Serbest güncelleme — kırpma yine ilgili `init`'lerde.
    func update(_ body: (inout KeyboardSettings) -> Void) { body(&settings); save() }

    func binding<T>(_ path: WritableKeyPath<KeyboardSettings, T>) -> Binding<T> {
        Binding(get: { [weak self] in self!.settings[keyPath: path] },
                set: { [weak self] v in self?.update { $0[keyPath: path] = v } })
    }

    private func apply(_ m: KeyboardMetrics) { settings.metrics = m; save() }
    private func apply(_ c: KeyRepeatCadence) { settings.cadence = c; save() }
    private func save() { KeyboardSettingsStore.save(settings) }

    /// Klavyenin ⚙︎ panelinde yapılanlar ortak depoya yazılıyor; uygulama
    /// öne her geldiğinde yeniden okunuyor. Okunmasa eski kopya bir sonraki
    /// kaydette panelde yapılanların üstüne yazardı.
    func reload() {
        let s = KeyboardSettingsStore.load()
        if s != settings { settings = s }
    }
}

struct SettingsView: View {
    @State private var model = KeyboardSettingsModel()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                KeyboardPreview(settings: model.settings, colorScheme: colorScheme)
                    .frame(height: KeyboardPreview.height(for: model.metrics))
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("Önizleme")
            } footer: {
                Text("Uzantıyla aynı görünüm ve aynı geometri.")
            }

            Section("Tema") {
                Picker("Tema", selection: $model.theme) {
                    ForEach(ThemeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                Toggle("Üst sayı sırası", isOn: $model.showsNumberRow)
            } footer: {
                Text("Açıkken klavye bir satır uzuyor; harfler sıkışmıyor. "
                     + "Rakamlar kod çözmeye girmez, doğrudan yazılır.")
            }

            Section {
                slider(SettingsSliders.shift, value: model.metricBinding(.shift))
                slider(SettingsSliders.backspace, value: model.metricBinding(.backspace))
                slider(SettingsSliders.space(showsGlobe: true), value: model.metricBinding(.space))
                LabeledContent("⏎ (kalan)", value: SettingsFormat.units(model.returnWidth))
                    .foregroundStyle(.secondary)
                slider(SettingsSliders.bottomRow(rowHeight: KeyboardView.rowHeightPoints),
                       value: model.metricBinding(.bottomRow))
            } header: {
                Text("Tuş ölçüleri")
            } footer: {
                Text("Genişlikler birim tuş cinsinden; 1 birim = satırın 1/11'i. "
                     + "3. satırın harfleri ⇧ ile ⌫'den artanı paylaşıyor, "
                     + "boşluktan artanı da ⏎ alıyor — satırlar hep tam doluyor. "
                     + "Yükseklik bütün alt satıra ait: yalnız boşluk tuşunu "
                     + "uzatmak onu harf satırının üstüne bindirirdi.")
            }

            Section {
                slider(SettingsSliders.repeatDelay, value: model.cadenceBinding(.initialDelay))
                slider(SettingsSliders.characterInterval, value: model.cadenceBinding(.characterInterval))
                slider(SettingsSliders.wordInterval, value: model.cadenceBinding(.wordInterval))
                slider(SettingsSliders.wordStage, value: model.cadenceBinding(.wordStage))
                LabeledContent("Kelime kademesi",
                               value: String(format: "~%.1f sn sonra",
                                             model.cadence.timeToWordStage))
                    .foregroundStyle(.secondary)
            } header: {
                Text("⌫ basılı tutma")
            } footer: {
                Text("Gecikme: tekrar başlamadan önce beklenen süre — kısa "
                     + "tutmak hızlı yazarken istemsiz silme demek. Sonra "
                     + "karakter karakter, ardından kelime kelime siliniyor. "
                     + "Kelime aralığı karakter aralığının altına inemez: daha "
                     + "hızlı akan bir kelime silme nerede durduğunu göstermez.")
            }

            Section {
                Button("Varsayılana dön", role: .destructive) { model.reset() }
            } footer: {
                SharedStoreNotice()
            }
        }
        .navigationTitle("Klavye ayarları")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Kademe **parametre başına**: 1 birim genişlik ≈ 36 pt, 1 birim yükseklik
    /// ≈ 54 pt, süreler ise saniye. Tek bir adım hepsine uymuyor.
    private func slider(_ spec: SliderSpec, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(spec.title, value: spec.format(value.wrappedValue))
            Slider(value: value, in: spec.range, step: spec.step)
        }
    }
}

/// Canlı önizleme — uzantının çizdiği `KeyboardView`'ın ta kendisi.
///
/// Ayrı bir "önizleme çizici" yazmak, önizlemenin gerçekten çizilenden
/// ayrışmasına açık kapı bırakırdı; bu ekranın bütün değeri o ikisinin aynı
/// olmasında.
struct KeyboardPreview: UIViewRepresentable {
    let settings: KeyboardSettings
    let colorScheme: ColorScheme
    /// Arka plan dışarıda (öneri çubuğuyla ortak) çiziliyorsa `false`.
    var drawsBackdrop = true
    /// Kaydedilmemiş bir tema (düzenleyicideki taslak).
    var themeOverride: KeyboardTheme? = nil

    /// Uzantıyla aynı satır yüksekliği (216 pt / 4 satır).
    static func height(for metrics: KeyboardMetrics) -> CGFloat {
        KeyboardView.height(for: metrics)
    }

    func makeUIView(context: Context) -> KeyboardView {
        let v = KeyboardView(layout: TurkishQ.layout(metrics: settings.metrics),
                             metrics: settings.metrics)
        // Önizleme yazmıyor: dokunma decoder'a gitmediği için tuşları basılabilir
        // göstermek yanıltıcı olurdu.
        v.isUserInteractionEnabled = false
        // Face ID'li telefonlarda 🌐 tuşu yok; önizleme gerçek alt satırı
        // göstermeli.
        v.showsGlobeKey = false
        v.drawsBackdrop = drawsBackdrop
        return v
    }

    func updateUIView(_ v: KeyboardView, context: Context) {
        // Ölçü gerçekten değiştiyse yeniden kur: sürgü sürüklenirken her karede
        // 32 katmanı yıkıp kurmanın gereği yok.
        if v.metrics != settings.metrics {
            v.apply(layout: TurkishQ.layout(metrics: settings.metrics),
                    metrics: settings.metrics)
        }
        v.theme = themeOverride ?? settings.theme.resolved(
            for: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
    }
}
