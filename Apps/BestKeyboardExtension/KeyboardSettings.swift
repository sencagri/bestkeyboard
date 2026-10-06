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
    /// Basış sesleri — ana anahtar ve iki kanal (harf, kelime sonu).
    /// Yalnız Tam Erişimle duyuluyor.
    var soundEnabled: Bool = true
    var letterSound: KeySoundChannel = .letterDefault
    var wordSound: KeySoundChannel = .wordDefault

    static let `default` = KeyboardSettings(metrics: .default, theme: .system,
                                            cadence: .default)
}

/// Ayarların kalıcı deposu.
///
/// ## Neden uzantının kendi sandbox'ında
///
/// Kalibrasyonla **aynı** gerekçe (plan §7): tek yazar. App Group paylaşımlı
/// bir depo verirdi ama entitlement gerektiriyor ve `-1B`'ye bırakıldı; o
/// gelene kadar iki depo tutmak split-brain demek olurdu. Bu yüzden ayarlar
/// **klavyenin içinden** düzenleniyor ve klavyenin kendi `UserDefaults`'ında
/// duruyor. Uygulama içi tezgahın kendi kopyası var — orası zaten deneme
/// yüzeyi, uzantının ayarını taşımasına gerek yok.
///
/// App Group açıldığında değişecek tek şey `defaults`: bütün okuma/yazma
/// buradan geçiyor.
enum KeyboardSettingsStore {

    private static let defaults = UserDefaults.standard

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
        static let sound = "kb.sound"
        static let letterKind = "kb.sound.letter.kind"
        static let letterVolume = "kb.sound.letter.volume"
        static let wordKind = "kb.sound.word.kind"
        static let wordVolume = "kb.sound.word.volume"
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
        let def = KeyboardMetrics.default
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
                                soundEnabled: d.object(forKey: Key.sound) == nil
                                    ? true : d.bool(forKey: Key.sound),
                                letterSound: channel(Key.letterKind, Key.letterVolume,
                                                     .letterDefault),
                                wordSound: channel(Key.wordKind, Key.wordVolume,
                                                   .wordDefault))
    }

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
        set(s.soundEnabled, d.soundEnabled, Key.sound)
        set(s.letterSound.kind.rawValue, d.letterSound.kind.rawValue, Key.letterKind)
        set(s.letterSound.volume, d.letterSound.volume, Key.letterVolume)
        set(s.wordSound.kind.rawValue, d.wordSound.kind.rawValue, Key.wordKind)
        set(s.wordSound.volume, d.wordSound.volume, Key.wordVolume)
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
                  Key.wordInterval, Key.charsBeforeWord, Key.diagnostics, Key.haptics, Key.sound,
                  Key.letterKind, Key.letterVolume, Key.wordKind, Key.wordVolume] {
            defaults.removeObject(forKey: k)
        }
        return load()
    }
}
