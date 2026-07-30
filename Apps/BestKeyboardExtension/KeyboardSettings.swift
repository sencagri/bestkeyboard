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
        let theme = ThemeChoice(rawValue: d.string(forKey: Key.theme) ?? "") ?? .system
        // `KeyRepeatCadence.init` de kırpıyor.
        let cd = KeyRepeatCadence.default
        let cadence = KeyRepeatCadence(
            initialDelay: width(Key.initialDelay, cd.initialDelay),
            characterInterval: width(Key.charInterval, cd.characterInterval),
            wordInterval: width(Key.wordInterval, cd.wordInterval),
            charactersBeforeWordStage: count(Key.charsBeforeWord,
                                             cd.charactersBeforeWordStage))
        return KeyboardSettings(metrics: metrics, theme: theme, cadence: cadence)
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
                  Key.wordInterval, Key.charsBeforeWord] {
            defaults.removeObject(forKey: k)
        }
        return load()
    }
}
