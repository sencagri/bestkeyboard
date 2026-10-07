import Foundation
import KBGeometry
import KBRuntime

/// Kullanıcı ayarları: geometri + tema + basılı tutma zamanlaması.
struct KeyboardSettings: Equatable {
    var metrics: KeyboardMetrics
    var theme: ThemeChoice
    /// `⌫` basılı tutma kademeleri. Geometri değil, dolayısıyla kalibrasyon
    /// profiline ve decoder'a dokunmuyor.
    var cadence: KeyRepeatCadence
    /// Öneri çubuğunun altındaki tanı satırı (paket, yükleme süresi,
    /// kalibrasyon). Geliştirme aracı; varsayılan kapalı — açıkken kullanıcıya
    /// anlamsız bir yazı ve öneriler için daha az yer demekti.
    var showsDiagnostics: Bool = false
    /// Basışta hafif titreşim. Klavyede yalnız Tam Erişim açıkken çalışıyor.
    var haptics: Bool = true
    /// 0 hafif · 1 orta · 2 güçlü.
    var hapticLevel: Int = 0
    /// Boşluktan sonra, geçmişe göre sonraki kelime önerisi.
    var predictNext: Bool = true
    /// Sık yazılan token'ları (IP, e-posta…) hatırlayıp önerme.
    var recallTokens: Bool = true
    /// Basış sesleri — ana anahtar ve iki kanal (harf, kelime sonu).
    /// Yalnız Tam Erişimle duyuluyor.
    var soundEnabled: Bool = true
    var letterSound: KeySoundChannel = .letterDefault
    var wordSound: KeySoundChannel = .wordDefault
    /// Kullanıcının kısayol listesi — hazır listeyle başlıyor, eklenip
    /// çıkarılıyor.
    var shortcuts: [TextShortcut] = ShortcutLibrary.defaultList
    /// Öneri çubuğunun solundaki uygulama kısayolları, sırasıyla.
    var aiApps: [String] = AIApp.defaultIDs
    /// Yapay zeka tuşları — tek düzenlenebilir liste (kısayollar gibi).
    var aiActions: [AIAction] = AIAction.defaults

    /// Sayı satırı varsayılan **açık** — kullanıcı tercihi ("sayı satırı
    /// olsun"). Çekirdeğin `KeyboardMetrics.default`'u kapalı kalıyor: o,
    /// geometri testlerinin ve benchmark'ın sabit noktası.
    static let `default` = KeyboardSettings(metrics: KeyboardMetrics.default.with(showsNumberRow: true),
                                            theme: .system, cadence: .default)
}

/// Ayarların kalıcı deposu — uygulama ile klavyenin **tek** ayar kaynağı.
///
/// Ortak klasör (App Group) kullanılabiliyorsa ayarlar orada; uygulama da
/// klavye de aynı değerleri okuyup yazıyor. Kullanılamıyorsa (klavyede Tam
/// Erişim kapalı) her taraf kendi `UserDefaults`'ında kalıyor. Bütün okuma
/// yazma `defaults` üstünden geçiyor.
enum KeyboardSettingsStore {


    /// Ortak depo kullanılabilir mi — uygulamada her zaman, uzantıda yalnız
    /// Tam Erişim açıkken (iOS ortak klasörü ancak o zaman veriyor).
    /// Uzantı bunu `hasFullAccess`'e göre ayarlıyor.
    static var sharingAllowed = false

    /// Ayarlar ortak klasörde mi duruyor.
    ///
    /// İzin (App Group) imza profiline bağlanmadan `containerURL` `nil`
    /// dönüyor ve her iki taraf kendi deposunda kalıyor — bugünkü davranış.
    /// İzin geldiği an iki taraf aynı depoyu görmeye başlıyor; ilk geçişte
    /// yerel değerler ortak depoya **bir kez** taşınıyor ki klavyede yapılmış
    /// ayarlar kaybolmasın.
    static var isShared: Bool { shared != nil }

    private static var shared: UserDefaults? {
        guard sharingAllowed,
              FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroup.id) != nil,
              let g = AppGroup.defaults else { return nil }
        if !g.bool(forKey: "kb.migrated") {
            for (k, v) in UserDefaults.standard.dictionaryRepresentation()
            where k.hasPrefix("kb.") && !LocalKey.all.contains(k) && g.object(forKey: k) == nil {
                g.set(v, forKey: k)
            }
            g.set(true, forKey: "kb.migrated")
        }
        return g
    }

    private static var defaults: UserDefaults { shared ?? .standard }

    /// Bu cihazdaki klavyeye özel kayıtlar: ortak depoya **taşınmıyor**.
    /// Cihaza özel küçük kayıtların deposu (`LocalKey`) — ortak depoya taşınmıyor.
    static var local: UserDefaults { .standard }

    enum LocalKey {
        static let emojiRecents = "kb.emoji.recents"
        static let fancyLast = "kb.fancy.last"
        static let clipChangeCount = "kb.clip.changeCount"
        static let all: Set<String> = [emojiRecents, fancyLast, clipChangeCount]
    }

    private enum Key {
        static let numberRow = "kb.metrics.numberRow"
        static let shift = "kb.metrics.shiftWidth"
        static let backspace = "kb.metrics.backspaceWidth"
        static let space = "kb.metrics.spaceWidth"
        static let bottomRow = "kb.metrics.bottomRowScale"
        static let theme = "kb.theme"
        static let initialDelay = "kb.repeat.initialDelay"
        static let charInterval = "kb.repeat.characterInterval"
        static let wordInterval = "kb.repeat.wordInterval"
        static let charsBeforeWord = "kb.repeat.charactersBeforeWordStage"
        static let diagnostics = "kb.diagnostics"
        static let haptics = "kb.haptics"
        static let hapticLevel = "kb.haptics.level"
        static let predictNext = "kb.predict.next"
        static let recallTokens = "kb.predict.recall"
        static let sound = "kb.sound"
        static let letterKind = "kb.sound.letter.kind"
        static let letterVolume = "kb.sound.letter.volume"
        static let wordKind = "kb.sound.word.kind"
        static let wordVolume = "kb.sound.word.volume"
        static let shortcuts = "kb.shortcuts.list"
        // Eski biçim (gruplar + özel) — yalnız taşımak için okunuyor.
        static let shortcutGroups = "kb.shortcuts.groups"
        static let customShortcuts = "kb.shortcuts.custom"
        static let aiApps = "kb.apps"
        static let aiActions = AIActionStore.key
        static let aiOffered = AIActionStore.offeredKey
    }

    static func load() -> KeyboardSettings {
        let d = defaults
        // Kayıt yoksa `double(forKey:)` 0 döner; 0 geçerli bir genişlik değil,
        // o yüzden `object(forKey:)` ile varlık kontrolü yapılıyor. Aksi hâlde
        // ilk açılışta bütün genişlikler alt sınıra kırpılırdı.
        func width(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
        }
        func count(_ key: String, _ fallback: Int) -> Int {
            d.object(forKey: key) == nil ? fallback : d.integer(forKey: key)
        }
        func channel(_ kindKey: String, _ volKey: String,
                     _ fallback: KeySoundChannel) -> KeySoundChannel {
            let kind = d.string(forKey: kindKey).flatMap(KeySoundKind.init(rawValue:))
                ?? fallback.kind
            let vol = d.object(forKey: volKey) == nil ? fallback.volume : d.double(forKey: volKey)
            return KeySoundChannel(kind: kind, volume: min(max(vol.isFinite ? vol : 0, 0), 1))
        }
        let def = KeyboardSettings.default.metrics
        // `KeyboardMetrics.init` kırpıyor: bozuk ya da eski sürümden kalma bir
        // değer geçersiz geometri üretemez.
        let metrics = KeyboardMetrics(
            showsNumberRow: d.object(forKey: Key.numberRow) == nil
                ? def.showsNumberRow : d.bool(forKey: Key.numberRow),
            shiftWidth: width(Key.shift, def.shiftWidth),
            backspaceWidth: width(Key.backspace, def.backspaceWidth),
            spaceWidth: width(Key.space, def.spaceWidth),
            bottomRowScale: width(Key.bottomRow, def.bottomRowScale))
        // Tanınmayan kimlik (silinmiş tema, başka sürüm) Sistem'e düşüyor.
        let stored = ThemeChoice(rawValue: d.string(forKey: Key.theme) ?? "")
        let theme = stored.isKnown ? stored : .system
        // `KeyRepeatCadence.init` de kırpıyor.
        let cd = KeyRepeatCadence.default
        let cadence = KeyRepeatCadence(
            initialDelay: width(Key.initialDelay, cd.initialDelay),
            characterInterval: width(Key.charInterval, cd.characterInterval),
            wordInterval: width(Key.wordInterval, cd.wordInterval),
            charactersBeforeWordStage: count(Key.charsBeforeWord,
                                             cd.charactersBeforeWordStage))
        return KeyboardSettings(metrics: metrics, theme: theme, cadence: cadence,
                                showsDiagnostics: d.bool(forKey: Key.diagnostics),
                                haptics: d.object(forKey: Key.haptics) == nil
                                    ? true : d.bool(forKey: Key.haptics),
                                hapticLevel: min(max(count(Key.hapticLevel, 0), 0), 2),
                                predictNext: d.object(forKey: Key.predictNext) == nil
                                    ? true : d.bool(forKey: Key.predictNext),
                                recallTokens: d.object(forKey: Key.recallTokens) == nil
                                    ? true : d.bool(forKey: Key.recallTokens),
                                soundEnabled: d.object(forKey: Key.sound) == nil
                                    ? true : d.bool(forKey: Key.sound),
                                letterSound: channel(Key.letterKind, Key.letterVolume,
                                                     .letterDefault),
                                wordSound: channel(Key.wordKind, Key.wordVolume,
                                                   .wordDefault),
                                shortcuts: shortcutList(d),
                                aiApps: (d.array(forKey: Key.aiApps) as? [String])?
                                    .filter { AIApp.byID[$0] != nil } ?? AIApp.defaultIDs,
                                aiActions: aiActionList(d))
    }

    private static func aiActionList(_ d: UserDefaults) -> [AIAction] { AIActionStore.load(from: d) }

    /// Depo **sapmayı** kaydediyor, durumu değil: varsayılana eşit bir değer
    /// yazılmıyor, anahtar siliniyor.
    ///
    /// İki şeyi birden çözüyor. Birincisi, varsayılan ileride değişirse bugün
    /// varsayılanda kalan kullanıcı da yenisini alıyor. İkincisi, "Varsayılana
    /// dön" artık geri alınamıyor: panel depoyu temizleyip `onChange` çağırıyor
    /// ve controller o ayarı hemen kaydediyordu — varsayılanları yazan bu ikinci
    /// adım temizliği iptal ediyordu.
    static func save(_ s: KeyboardSettings) {
        let d = KeyboardSettings.default
        set(s.metrics.showsNumberRow, d.metrics.showsNumberRow, Key.numberRow)
        set(s.metrics.shiftWidth, d.metrics.shiftWidth, Key.shift)
        set(s.metrics.backspaceWidth, d.metrics.backspaceWidth, Key.backspace)
        set(s.metrics.spaceWidth, d.metrics.spaceWidth, Key.space)
        set(s.metrics.bottomRowScale, d.metrics.bottomRowScale, Key.bottomRow)
        set(s.theme.rawValue, d.theme.rawValue, Key.theme)
        set(s.cadence.initialDelay, d.cadence.initialDelay, Key.initialDelay)
        set(s.cadence.characterInterval, d.cadence.characterInterval, Key.charInterval)
        set(s.cadence.wordInterval, d.cadence.wordInterval, Key.wordInterval)
        set(s.cadence.charactersBeforeWordStage,
            d.cadence.charactersBeforeWordStage, Key.charsBeforeWord)
        set(s.showsDiagnostics, d.showsDiagnostics, Key.diagnostics)
        set(s.haptics, d.haptics, Key.haptics)
        set(s.hapticLevel, d.hapticLevel, Key.hapticLevel)
        set(s.predictNext, d.predictNext, Key.predictNext)
        set(s.recallTokens, d.recallTokens, Key.recallTokens)
        set(s.soundEnabled, d.soundEnabled, Key.sound)
        set(s.letterSound.kind.rawValue, d.letterSound.kind.rawValue, Key.letterKind)
        set(s.letterSound.volume, d.letterSound.volume, Key.letterVolume)
        set(s.wordSound.kind.rawValue, d.wordSound.kind.rawValue, Key.wordKind)
        set(s.wordSound.volume, d.wordSound.volume, Key.wordVolume)
        set(try? JSONEncoder().encode(s.shortcuts),
            try? JSONEncoder().encode(d.shortcuts), Key.shortcuts)
        // Eski biçim artık yazılmıyor: liste kaydedildiyse taşıma bitti.
        defaults.removeObject(forKey: Key.shortcutGroups)
        defaults.removeObject(forKey: Key.customShortcuts)
        set(s.aiApps, d.aiApps, Key.aiApps)
        set(try? JSONEncoder().encode(s.aiActions),
            try? JSONEncoder().encode(d.aiActions), Key.aiActions)
        // Kaydedilen liste bugünkü varsayılanların hepsini görmüş demek: silinen
        // varsayılan tuş (ör. ilk iş Takvim'i silen yeni kullanıcı) geri gelmesin.
        AIActionStore.markAllOffered(in: defaults)
    }

    /// Liste kayıtlıysa o; yoksa eski grup/özel ayarından taşınıyor; o da
    /// yoksa hazır liste.
    private static func shortcutList(_ d: UserDefaults) -> [TextShortcut] {
        if let data = d.data(forKey: Key.shortcuts),
           let list = try? JSONDecoder().decode([TextShortcut].self, from: data) { return list }
        let groups = (d.array(forKey: Key.shortcutGroups) as? [String]).map(Set.init)
        let custom = d.data(forKey: Key.customShortcuts)
            .flatMap { try? JSONDecoder().decode([TextShortcut].self, from: $0) } ?? []
        guard groups != nil || !custom.isEmpty else { return ShortcutLibrary.defaultList }
        let enabled = groups ?? ShortcutLibrary.defaultEnabled
        return custom + ShortcutLibrary.groups.filter { enabled.contains($0.id) }.flatMap(\.items)
    }

    private static func set<T: Equatable>(_ value: T, _ fallback: T, _ key: String) {
        if value == fallback { defaults.removeObject(forKey: key) }
        else { defaults.set(value, forKey: key) }
    }

    /// Anahtarları **siler** — varsayılanları yazmaz.
    ///
    /// Fark ileride ortaya çıkıyor: bugün varsayılanları yazan bir kullanıcı,
    /// varsayılan değiştiğinde eski değerlerde kalırdı; hiç ayar kaydetmemiş
    /// kullanıcı ise yenisini alırdı. "Varsayılana dön" ikinci davranışı
    /// vermeli.
    @discardableResult
    static func reset() -> KeyboardSettings {
        for k in [Key.numberRow, Key.shift, Key.backspace, Key.space,
                  Key.bottomRow, Key.theme, Key.initialDelay, Key.charInterval,
                  Key.wordInterval, Key.charsBeforeWord, Key.diagnostics, Key.haptics, Key.hapticLevel, Key.predictNext,
                  Key.recallTokens, Key.sound,
                  Key.letterKind, Key.letterVolume, Key.wordKind, Key.wordVolume,
                  Key.shortcuts, Key.shortcutGroups, Key.customShortcuts, Key.aiApps, Key.aiActions, Key.aiOffered] {
            defaults.removeObject(forKey: k)
        }
        return load()
    }
}

/// Sayıların ekrandaki yazımı (Türkçe, virgüllü) — uygulama, stüdyo ve klavye paneli aynı biçim.
enum SettingsFormat {
    /// 0…1 → "%55".
    static func percent(_ v: Double) -> String { "%\(Int((v * 100).rounded()))" }
    /// Saniye → "450 ms".
    static func milliseconds(_ v: Double) -> String { String(format: "%.0f ms", v * 1000) }
    /// Tuş genişliği → "1,50 birim".
    static func units(_ v: Double) -> String { decimal("%.2f birim", v) }
    /// Saniye → "0,45 sn" (`digits`: virgülden sonraki hane).
    static func seconds(_ v: Double, digits: Int = 2) -> String { decimal("%.\(digits)f sn", v) }
    /// Kelime kademesine kalan süre → "~1,2 sn sonra".
    static func wordStageAfter(_ v: Double) -> String { "~" + seconds(v, digits: 1) + " sonra" }
    /// Dosya boyu (KB) → "850 KB" / "1,4 MB".
    static func fileSize(kb v: Double) -> String { v >= 1024 ? decimal("%.1f MB", v / 1024) : "\(Int(v)) KB" }
    /// Ondalıklı sayıyı Türkçe yazar (virgülle): `decimal("saniyede %.1f kelime", 2.5)`.
    static func decimal(_ format: String, _ v: Double) -> String { String(format: format, locale: .turkish, v) }
    static func characters(_ v: Double) -> String { String(format: "%.0f karakter", v) }
}

/// Bir ayar kaydırıcısının tanımı: başlık, aralık, adım, biçim. Uygulamadaki
/// tezgah ekranı ve klavyedeki panel **aynı** tanımı çiziyor.
struct SliderSpec {
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
}

enum SettingsSliders {
    static let shift = SliderSpec(title: "⇧ genişliği", range: KeyboardMetrics.shiftRange,
                                  step: KeyboardMetrics.step, format: SettingsFormat.units)
    static let backspace = SliderSpec(title: "⌫ genişliği", range: KeyboardMetrics.backspaceRange,
                                      step: KeyboardMetrics.step, format: SettingsFormat.units)
    static func space(showsGlobe: Bool) -> SliderSpec {
        SliderSpec(title: "boşluk genişliği", range: KeyboardMetrics.spaceBounds(showsGlobe: showsGlobe),
                   step: KeyboardMetrics.step, format: SettingsFormat.units)
    }
    /// `rowHeight`: bir satırın nokta karşılığı (`KeyboardView.rowHeightPoints`).
    static func bottomRow(rowHeight: Double) -> SliderSpec {
        SliderSpec(title: "boşluk satırı yüksekliği", range: KeyboardMetrics.bottomRowRange,
                   step: KeyboardMetrics.bottomRowStep,
                   format: { String(format: "%.2f × satır (%.0f pt)", locale: .turkish, $0, $0 * rowHeight) })
    }
    static let repeatDelay = SliderSpec(title: "⌫ tekrar gecikmesi", range: KeyRepeatCadence.initialDelayRange,
                                        step: KeyRepeatCadence.initialDelayStep, format: SettingsFormat.milliseconds)
    static let characterInterval = SliderSpec(title: "⌫ karakter aralığı", range: KeyRepeatCadence.characterIntervalRange,
                                              step: KeyRepeatCadence.characterIntervalStep, format: SettingsFormat.milliseconds)
    static let wordInterval = SliderSpec(title: "⌫ kelime aralığı", range: KeyRepeatCadence.wordIntervalRange,
                                         step: KeyRepeatCadence.wordIntervalStep, format: SettingsFormat.milliseconds)
    static let wordStage = SliderSpec(title: "⌫ kelimeye geçiş",
                                      range: Double(KeyRepeatCadence.charactersBeforeWordStageRange.lowerBound)
                                          ... Double(KeyRepeatCadence.charactersBeforeWordStageRange.upperBound),
                                      step: Double(KeyRepeatCadence.charactersBeforeWordStageStep),
                                      format: SettingsFormat.characters)
    static func volume(_ title: String) -> SliderSpec {
        SliderSpec(title: title, range: 0...1, step: 0.05, format: SettingsFormat.percent)
    }
}
