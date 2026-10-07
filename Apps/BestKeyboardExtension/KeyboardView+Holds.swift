import UIKit
import KBGeometry
import KBRuntime
import KBSessions

/// Basılı tutma: ⌫ tekrarı, nokta → virgül ve boşlukta imleç kipi.
extension KeyboardView {
    // MARK: - Tekrar zamanlayıcısı

    /// Şimdilik yalnız geri silme tekrar ediyor. Boşlukta imleç sürükleme ve
    /// harf tekrarı ayrı davranışlar; buraya girerlerse kendi kademeleriyle girer.
    static func repeats(_ h: KeyHit) -> Bool { h == .function(.backspace) }

    func startRepeat(_ h: KeyHit, id: ObjectIdentifier) {
        // Sahiplik devredilmez: ikinci bir parmak zaten tekrar eden bir tuşa
        // basarsa hızı ikiye katlamamalı, birincinin durumunu da ezmemeli.
        guard repeatHold.owner == nil else { return }
        repeatKey = h
        repeatTicks = 0
        repeatHold.start(id, after: cadence.initialDelay) { [weak self] in self?.fireRepeat() }
    }

    /// Her tekrar kendi zamanlayıcısını kurar. Tek bir tekrarlayan `Timer`
    /// kullanmak kademe değişiminde aralığı güncelleyemiyordu; tik başına bir
    /// zamanlayıcı saniyede ~11 tane demek, ölçülebilir bir maliyet değil.
    private func fireRepeat() {
        guard let h = repeatKey else { return }
        if let id = repeatHold.owner { repeatedTouches.insert(id) }
        repeatTicks += 1
        onKeyRepeat?(h, cadence.stage(forTick: repeatTicks))
        repeatHold.schedule(after: cadence.interval(afterTick: repeatTicks)) { [weak self] in
            self?.fireRepeat()
        }
    }

    /// Sahip parmak kalktığında hâlâ basılı duran bir tekrar adayı varsa
    /// sahipliği ona verir.
    ///
    /// Olmasa tekrar sessizce dururdu: iki parmakla geri silerken birini
    /// kaldırmak silmeyi kesiyor, kullanıcıya tuş takılmış gibi geliyordu.
    /// Gecikme baştan işliyor — devralma yeni bir basış sayılıyor.
    func adoptPendingRepeat() {
        guard repeatHold.owner == nil else { return }
        for (id, h) in activeTouches where Self.repeats(h) {
            startRepeat(h, id: id)
            return
        }
    }

    func cancelRepeat() {
        repeatHold.cancel()
        repeatKey = nil
        repeatTicks = 0
    }

    // MARK: - Nokta uzun basma → virgül

    func startPeriodLongPress(_ id: ObjectIdentifier) {
        cancelPeriodLongPress()
        periodHold.start(id, after: cadence.initialDelay) { [weak self] in self?.firePeriodLongPress() }
    }

    /// Eşik geçildi: virgül **şimdi** yazılıyor ve etiket de şimdi değişiyor.
    ///
    /// Emisyonu parmağın kalkmasına bırakmak (globe uzun basmasının yaptığı)
    /// burada yanlış olurdu: globe bir menü açıyor ve menünün kendisi geri
    /// bildirim; virgülde ise kullanıcı ne alacağını ancak iş işten geçtikten
    /// sonra görürdü.
    private func firePeriodLongPress() {
        guard let id = periodHold.owner else { return }
        alternateTouches.insert(id)
        periodShowsAlternate = true
        refreshFunctionTitles()
        onPeriodLongPress?()
    }

    func cancelPeriodLongPress() {
        periodHold.cancel()
        guard periodShowsAlternate else { return }
        periodShowsAlternate = false
        refreshFunctionTitles()
    }

    // MARK: - Boşlukta imleç sürükleme

    func startSpaceDrag(_ id: ObjectIdentifier, at p: CGPoint) {
        // Bağlanmamışsa kip **hiç açılmıyor**.
        //
        // Tezgah ve kayıt ekranı bu jesti bağlamıyor: tezgahın belgesi yok,
        // kayıt ekranında ise imleç hareketi kayda giremiyor (`ReplayCommand`
        // karşılığı yok). Kipi orada da açmak, boşluğun yazısını "◂ ▸" yapıp
        // hiçbir şey yapmamak olurdu — kullanıcıya bozuk bir tuş göstermek.
        guard onSpaceDragChanged != nil else { return }
        // **Sahiplik devredilmez** — `startRepeat` ile aynı kural.
        //
        // Koşulsuz `cancelSpaceDrag()` çağırmak ikinci parmağın jesti
        // çalmasına yol açıyordu: birinci parmak imleç kipindeyken sahipliği
        // kaybediyor, `touchesMoved`'ın özel dalına artık girmiyor ve normal
        // hit-test'e dönüp üstünde durduğu tuşu commit edebiliyordu. Yani
        // boşluğa ikinci kez dokunmak, sürüklemekte olan parmağa harf
        // yazdırıyordu.
        guard spaceDragHold.owner == nil else { return }
        spaceDragOrigin = p
        // Eşik **sabit**: ⌫ gecikmesine bağlıydı ve kullanıcı onu 0,05 sn'ye
        // indirince her boşluk basışı imleç kipine düşüyordu.
        spaceDragHold.start(id, after: Self.spaceHoldToArm) { [weak self] in self?.armSpaceDrag() }
    }

    /// Kip açıldı. Jest bu andan itibaren **klavyenin tek sahibi**; boşluğun
    /// yazısı değişiyor: kullanıcı parmağını kaldırmadan **kipte olduğunu**
    /// görmeli, yoksa boşluk yazacağını sanıp sürükler.
    ///
    /// ## Neden diğer parmaklar düşürülüyor
    ///
    /// Jest, belgeyi jest başında okunmuş sabit bir bağlama göre hesaplıyor
    /// (`CursorTrackpad`). O sırada ikinci bir parmağın harf ya da boşluk
    /// commit etmesi bağlamı geçersiz kılar ve sonraki ofsetler yanlış yerden
    /// hesaplanır — sahiplik guard'ı yalnız *ikinci bir jestin açılmasını*
    /// engelliyordu, commit'i değil.
    ///
    /// İkinci parmağı düşürmek yerine "sonraki commit'te jesti bitir" de
    /// olabilirdi; seçilmedi, çünkü kullanıcı imleci konumlandırırken yazmayı
    /// beklemiyor ve kazara değen bir parmağın metne karakter sokması,
    /// jestin engellemek için var olduğu şeyin ta kendisi.
    func armSpaceDrag() {
        guard let owner = spaceDragHold.owner else { return }
        spaceDragArmed = true

        // Sahip dışındaki her parmak **iptal**: vurgusu kalkıyor ve bıraktığında
        // hiçbir şey yazmıyor. Kayda `.cancelled` olarak giriyorlar, klavye
        // dışına kaymış gibi değil.
        suppress(activeTouches.keys.filter { $0 != owner })
        abandonHolds()

        functionLabels[.space]?.string = Self.spaceDragTitle
        setTrackpadDimmed(true)
        if hapticsEnabled { cursorTick.prepare() }
        onSpaceDragBegan?()
    }

    /// İmleç kipinde harfler soluyor: klavye artık bir izleme yüzeyi.
    private func setTrackpadDimmed(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        for l in keyLabels + digitLabels { l.opacity = on ? 0.2 : 1 }
        CATransaction.commit()
    }

    func cancelSpaceDrag() {
        spaceDragHold.cancel()
        guard spaceDragArmed else { return }
        spaceDragArmed = false
        setTrackpadDimmed(false)
        onSpaceDragEnded?()
        refreshFunctionTitles()
    }
}
