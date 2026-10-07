import Foundation
import KBLearning
import KBRuntime

// MARK: - Üretim yolunun ihtiyaçları
//
// Uzantı koordinatörü **doğrudan tutmuyor**: tuttuğu anda kaydın görmediği
// bir mutasyon mümkün olurdu ve motorun bütün garantisi o sahiplikte.
// Belgeye dokunmayan işlemler (kalibrasyon, okuma) buradan geçiyor; belgeye
// dokunanlar (`perform`, `selectionChanged`) faz kapısından.

extension RecordingEngine {

    // MARK: Kalibrasyon

    /// Öğrenilen kalibrasyon — okuma.
    public var calibration: CalibrationLearner { coordinator.calibration }
    /// Diske yazılması isteniyor mu.
    public var wantsCalibrationSave: Bool { coordinator.wantsCalibrationSave }
    public func calibrationSaved() { coordinator.calibrationSaved() }

    /// Biriken örnekleri uzamsal modele uygular.
    ///
    /// **Kayıt dışı bir motor değişikliği**: `engineConfigured` çoktan
    /// yazılmış durumda ve o snapshot artık motoru anlatmıyor. Deneme bu
    /// yüzden işaretleniyor ve çağıran yenisine geçmek zorunda — yeni denemenin
    /// snapshot'ı güncel kalibrasyonu taşıyor.
    public func applyCalibration() {
        coordinator.applyCalibration()
        stateChangedOutsideTheLog = true
    }

    /// Profil değişti: öğrenici baştan yükleniyor.
    public func replaceCalibration(_ l: CalibrationLearner) {
        coordinator.replaceCalibration(l)
        stateChangedOutsideTheLog = true
    }

    // MARK: Kişisel sözlük (§8.7)

    public var personal: PersonalLexicon { coordinator.personal }
    public var wantsPersonalSave: Bool { coordinator.wantsPersonalSave }
    public func personalSaved() { coordinator.personalSaved() }
    /// Parola alanı bilgisi — koordinatör orada kanıt toplamıyor.
    public var fieldIsSecure: Bool {
        get { coordinator.fieldIsSecure }
        set { coordinator.fieldIsSecure = newValue }
    }
    /// Depodan yüklenen sözlük yürürlüğe konuyor.
    ///
    /// `replaceCalibration` ile aynı işaret: leksikon değişiyor, dolayısıyla
    /// yazılmış snapshot artık motoru anlatmıyor.
    public func replacePersonalLexicon(_ p: PersonalLexicon) {
        coordinator.replacePersonalLexicon(p)
        stateChangedOutsideTheLog = true
    }
    /// Kullanıcı yanlışlıkla öğretilmiş bir yüzeyi siliyor.
    public func forgetPersonal(_ surface: String) {
        coordinator.forgetPersonal(surface)
        stateChangedOutsideTheLog = true
    }
    /// Kullanıcının kendi metninden kelime öğreniyor.
    @discardableResult
    public func ingestPersonal(tokens: [String]) -> PersonalLexicon.IngestReport {
        let report = coordinator.ingestPersonal(tokens: tokens)
        if report.changed { stateChangedOutsideTheLog = true }
        return report
    }

    // MARK: Okuma yüzeyleri
    //
    // Koordinatör motorun **içinde**: dışarıdan erişilebilseydi kaydın
    // görmediği bir mutasyon mümkün olurdu. UI'ın ihtiyacı olan okumalar
    // buradan veriliyor.

    /// Öneri çubuğunda gösterilecek yüzeyler — politikadan **bağımsız** okuma.
    ///
    /// `visibleSuggestions` politikayı uyguluyor (kayıt koşulunda gizlenebilir);
    /// üretimde politika `behavior` ve çubuk her zaman açık.
    public func suggestionSurfaces(limit: Int = 3) -> [String] {
        coordinator.suggestionSurfaces(limit: limit)
    }

    /// Öneri çubuğunda gösterilecek yüzeyler.
    ///
    /// Politika gizliyorsa **boş**: kaydın "gösterilmedi" dediği bir yüzeyi
    /// ekranda göstermek, kaydı yalancı çıkarırdı.
    public func visibleSuggestions(limit: Int = 3)
        -> [InputCoordinator.Suggestion] {
        guard policy.suggestionsVisible else { return [] }
        // **Kimlik ve kaynakla birlikte**: UI dokunulan öneri için komutu
        // buradan kuruyor. Yalnız yüzey vermek, UI'ın `id` ve `origin`
        // uydurmasına yol açıyordu ve kayıt genişletmeyi aday seçimi diye
        // anlatıyordu.
        return coordinator.suggestions(limit: limit)
    }

    /// Composing yüzeyi açık mı.
    public var isComposing: Bool { coordinator.session.isComposing }

    /// Yazılmakta olan token'ın **belgedeki** yüzeyi.
    ///
    /// Motor bırakıldığında yarım kalan token'ı yedek koordinatöre devretmek
    /// için okunuyor (§8.9). Belgeden ayrıştırmak yerine buradan alınıyor:
    /// oturumun kendi yüzeyi bir olgu, belgenin son token'ı ise bir tahmin —
    /// host'un yazdığı metinle bizimki orada ayırt edilemez.
    public var composingSurface: String { coordinator.session.display }

    /// Yazılmakta olan yüzeyin uzunluğu — kalibrasyon kipinde nokta sayısı.
    public var composingLength: Int { coordinator.session.display.count }

    /// Seçim düzenlemesinde gerçek dokunma kanıtı var mı.
    public var selectionHasRealEvidence: Bool {
        coordinator.session.selectionHasRealEvidence
    }

    /// Motorun türettiği belge metni.
    ///
    /// `finish`'e verilecek `finalText` bu: çağıranın kendi tamponunu geçmesi,
    /// host'un gördüğüyle kaydın ayrıştığı durumu görünmez yapıyordu.
    public var documentText: String { document }

    // MARK: Kayda girmeyen durum değişiklikleri

    /// Host seçimi değişti.
    ///
    /// **Faz kapısından geçiyor**: composing durumunu değiştiriyor ve terminalden
    /// sonra gelen geç bir callback kaydı büyütürdü. Seçim gerçekten bir şey
    /// değiştirdiyse `stateChangedOutsideTheLog` işaretleniyor.
    @discardableResult
    public func selectionChanged(_ selected: String?,
                                 into editor: DocumentEditor) throws -> String? {
        try require(.recording)
        let result = coordinator.handleSelection(selected, into: editor)
        // Seçim gerçekten bir şey değiştirdiyse kayıt artık eksik.
        if coordinator.session.isEditingSelection || result != nil {
            stateChangedOutsideTheLog = true
        }
        return result
    }

    /// Kayda **giremeyen** bir mutasyon oldu — deneme kapanmalı.
    ///
    /// Somut sebebi boşlukta imleç sürükleme: `ReplayCommand` kümesinde imleç
    /// hareketinin karşılığı yok. Komut eklemek de doğru değil — imlecin
    /// nereye gittiği host'un metnine bağlı ve replay o metni yeniden kurmuyor,
    /// yani kaydedilen ofset başka bir belgede başka bir yeri gösterirdi.
    ///
    /// `selectionChanged` bunu **karşılamıyor**: orada bayrak yalnız seçim
    /// varsa ya da bir şey değiştiyse kalkıyor, düz bir imleç hareketi sessiz
    /// geçiyordu. Ayrı bir kapı olmasının sebebi bu.
    ///
    /// Sonucu `rollOverIfNeeded` görüyor ve denemeyi kapatıyor: sonrasını aynı
    /// dosyada anlatmak yanlış bir geçmiş yazmak olurdu.
    public func noteStateChangedOutsideTheLog() {
        stateChangedOutsideTheLog = true
    }

    /// Composing durumu host tarafından geçersiz kılındı.
    public func invalidateComposing() throws {
        try require(.recording)
        // Açık bir token iptal ediliyorsa kayıt onu anlatamaz (bkz.
        // `stateChangedOutsideTheLog`). Kapalıyken no-op ve işaretlemeye gerek
        // yok.
        if coordinator.session.isComposing { stateChangedOutsideTheLog = true }
        coordinator.invalidateComposing()
    }
}
