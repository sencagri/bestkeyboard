import Testing
import Foundation
import KBGeometry

/// Ayarlanabilir klavye geometrisi.
///
/// Bu paketin varlık sebebi bir hata: işlev tuşlarının çerçeveleri UIKit
/// tarafında, harf merkezleri çekirdekte hesaplanıyordu. İkisi tutarsızlaştı ve
/// `⇧`/`⌫` 3. satırın ilk ve son harfinin yarısını örttü — dokunma testi işlev
/// tuşlarına öncelik verdiği için `z` ve `ç` kısmen **basılamaz** hâle geldi.
/// Hesap çekirdeğe taşındı; buradaki testler çakışmama invariantını tutuyor.
@Suite("Klavye geometrisi")
struct LayoutGeometryTests {

    /// Test edilen ölçü kümesi: uçlar ve varsayılan.
    static let cases: [KeyboardMetrics] = [
        .default,
        KeyboardMetrics(showsNumberRow: true),
        KeyboardMetrics(shiftWidth: 1.0, backspaceWidth: 1.0, spaceWidth: 3.0),
        KeyboardMetrics(shiftWidth: 2.5, backspaceWidth: 2.5, spaceWidth: 7.5),
        KeyboardMetrics(showsNumberRow: true, shiftWidth: 2.5,
                        backspaceWidth: 1.0, spaceWidth: 7.5),
        // Boşluk satırı yüksekliğinin uçları — satırlar artık tekdüze değil.
        KeyboardMetrics(bottomRowScale: 0.75),
        KeyboardMetrics(bottomRowScale: 1.75),
        KeyboardMetrics(showsNumberRow: true, bottomRowScale: 1.75),
        // Aralık dışı — init kırpmalı.
        KeyboardMetrics(shiftWidth: 9, backspaceWidth: -3, spaceWidth: 99,
                        bottomRowScale: 42),
    ]

    // MARK: - Regresyon: örtüşen işlev tuşları

    @Test("Hiçbir işlev tuşu hiçbir harf tuşunun üstüne binmiyor",
          arguments: LayoutGeometryTests.cases, [true, false])
    func functionKeysNeverOverlapLetters(_ m: KeyboardMetrics, _ globe: Bool) {
        let layout = TurkishQ.layout(metrics: m)
        let slots = KeyboardGeometry.functionSlots(m, showsGlobe: globe)
        for k in layout.keys {
            let r = Rect(x: k.center.x - k.width / 2, y: k.center.y - k.height / 2,
                         width: k.width, height: k.height)
            for s in slots {
                #expect(!s.rect.overlaps(r.insetBy(1e-9)),
                        "\(s.role) ile '\(k.char)' çakışıyor (ölçü \(m.idSuffix))")
            }
        }
    }

    @Test("Sembol düzlemlerinin tuşları da işlev tuşlarıyla çakışmıyor",
          arguments: LayoutGeometryTests.cases)
    func functionKeysNeverOverlapSymbols(_ m: KeyboardMetrics) {
        let slots = KeyboardGeometry.functionSlots(m, showsGlobe: true)
        for plane in [SymbolPlanes.numbersPlane(metrics: m),
                      SymbolPlanes.symbolsPlane(metrics: m)] {
            for k in plane.keys {
                let r = Rect(x: k.center.x - k.width / 2, y: k.center.y - k.height / 2,
                             width: k.width, height: k.height)
                for s in slots {
                    #expect(!s.rect.overlaps(r.insetBy(1e-9)),
                            "\(s.role) ile '\(k.char)' çakışıyor")
                }
            }
        }
    }

    @Test("İşlev tuşları birbirinin üstüne binmiyor", arguments: LayoutGeometryTests.cases, [true, false])
    func functionKeysDoNotOverlapEachOther(_ m: KeyboardMetrics, _ globe: Bool) {
        let slots = KeyboardGeometry.functionSlots(m, showsGlobe: globe)
        for (i, a) in slots.enumerated() {
            for b in slots[(i + 1)...] {
                #expect(!a.rect.insetBy(1e-9).overlaps(b.rect.insetBy(1e-9)),
                        "\(a.role) ile \(b.role) çakışıyor")
            }
        }
    }

    // MARK: - Satırlar tam doluyor

    @Test("3. satır tam dolu: ⇧ + 9 harf + ⌫ = 1", arguments: LayoutGeometryTests.cases)
    func thirdRowFills(_ m: KeyboardMetrics) {
        let u = 1.0 / KeyboardMetrics.rowUnits
        let total = (m.shiftWidth + m.backspaceWidth) * u
                  + 9 * m.letterWidthUnitsRow3 * u
        #expect(abs(total - 1) < 1e-9)

        // Harfler `⇧` biter bitmez başlıyor, `⌫` başlamadan bitiyor.
        let layout = TurkishQ.layout(metrics: m)
        let row3 = TurkishQ.row3.compactMap { layout.keyIndex(for: $0) }.map { layout.keys[$0] }
        #expect(row3.count == 9)
        #expect(abs((row3[0].center.x - row3[0].width / 2) - m.shiftWidth * u) < 1e-9)
        let last = row3[8]
        #expect(abs((last.center.x + last.width / 2) - (1 - m.backspaceWidth * u)) < 1e-9)
    }

    /// Satırlar tekdüze değil: harf satırları 1 birim, boşluk satırı
    /// `bottomRowScale` birim. Toplam yine tam olarak [0,1] olmalı — aksi hâlde
    /// ya altta boşluk kalır ya da son satır klavyeden taşar.
    @Test("Satırlar [0,1]'i tam kaplıyor, boşluk satırı doğru oranda",
          arguments: LayoutGeometryTests.cases)
    func rowsTileTheUnitSquare(_ m: KeyboardMetrics) {
        let h = KeyboardGeometry.rowHeight(m)
        let bh = KeyboardGeometry.bottomRowHeight(m)
        #expect(abs(bh - h * m.bottomRowScale) < 1e-9)
        // İçerik satırları + boşluk satırı = 1
        #expect(abs(Double(m.contentRowCount) * h + bh - 1) < 1e-9)
        #expect(abs(h * m.heightUnits - 1) < 1e-9)

        // İçerik bandı bitince boşluk satırı başlıyor, o da 1'de bitiyor.
        let band = KeyboardGeometry.contentBand(m)
        let row4 = KeyboardGeometry.functionSlots(m, showsGlobe: true)
                    .filter { $0.role != .leftModifier && $0.role != .backspace }
        for s in row4 {
            #expect(abs(s.rect.minY - band.upperBound) < 1e-9)
            #expect(abs(s.rect.maxY - 1) < 1e-9)
        }
        // 3. satır işlev tuşları harf satırı yüksekliğinde kalıyor.
        for s in KeyboardGeometry.functionSlots(m, showsGlobe: true)
            where s.role == .leftModifier || s.role == .backspace {
            #expect(abs(s.rect.height - h) < 1e-9)
        }
    }

    @Test("Boşluk satırı yüksekliği harf geometrisini değiştiriyor")
    func bottomRowScaleAffectsLetterGeometry() {
        let a = KeyboardMetrics.default
        let b = a.with(bottomRowScale: 1.5)
        // Normalize uzay [0,1]'e sabit: alt satır uzayınca harfler yer değiştiriyor.
        #expect(!a.sharesLetterGeometry(with: b))
        #expect(TurkishQ.layout(metrics: a).id != TurkishQ.layout(metrics: b).id)
        let ka = TurkishQ.layout(metrics: a).keys[0]
        let kb = TurkishQ.layout(metrics: b).keys[0]
        #expect(ka.height > kb.height)
        // Fiziksel yükseklik korunuyor: klavye büyüyor, harf satırı kısalmıyor.
        #expect(abs(ka.height * a.heightUnits - kb.height * b.heightUnits) < 1e-9)
    }

    @Test("4. satır tam dolu ve ⏎ sınırların içinde", arguments: LayoutGeometryTests.cases, [true, false])
    func fourthRowFills(_ m: KeyboardMetrics, _ globe: Bool) {
        let slots = KeyboardGeometry.functionSlots(m, showsGlobe: globe)
        let row4 = slots.filter { $0.role != .leftModifier && $0.role != .backspace }
                        .sorted { $0.rect.x < $1.rect.x }
        #expect(abs(row4.first!.rect.minX) < 1e-9)
        #expect(abs(row4.last!.rect.maxX - 1) < 1e-9)
        for (a, b) in zip(row4, row4.dropFirst()) {
            #expect(abs(a.rect.maxX - b.rect.minX) < 1e-9, "4. satırda boşluk var")
        }
        let ret = m.returnWidth(showsGlobe: globe)
        #expect(ret >= KeyboardMetrics.returnRange.lowerBound - 1e-9)
        #expect(ret <= KeyboardMetrics.returnRange.upperBound + 1e-9)
    }

    // MARK: - Sayı sırası

    @Test("Sayı sırası kapalıyken 3, açıkken 4 içerik satırı")
    func rowCount() {
        #expect(KeyboardMetrics().contentRowCount == 3)
        #expect(KeyboardMetrics(showsNumberRow: true).contentRowCount == 4)
        #expect(KeyboardGeometry.numberRow(KeyboardMetrics()).isEmpty)
        #expect(KeyboardGeometry.numberRow(KeyboardMetrics(showsNumberRow: true)).count == 10)
    }

    @Test("Sayı sırası açılınca harfler tam bir satır aşağı iner, üst bant boşalır")
    func numberRowPushesLettersDown() {
        let on = KeyboardMetrics(showsNumberRow: true)
        let layout = TurkishQ.layout(metrics: on)
        let h = KeyboardGeometry.rowHeight(on)
        #expect(abs(h - 0.2) < 1e-9)

        // Hiçbir harf ilk satırın bandına girmiyor.
        for k in layout.keys {
            #expect(k.center.y - k.height / 2 >= h - 1e-9, "'\(k.char)' sayı sırasına girmiş")
        }
        // Sayı sırası tam ilk bandı dolduruyor.
        let digits = KeyboardGeometry.numberRow(on)
        #expect(abs(digits.first!.center.x - digits.first!.width / 2) < 1e-9)
        #expect(abs(digits.last!.center.x + digits.last!.width / 2 - 1) < 1e-9)
        for d in digits { #expect(abs(d.center.y - h / 2) < 1e-9) }
    }

    @Test("Sayı sırası ile işlev tuşları çakışmıyor", arguments: [true, false])
    func numberRowDoesNotOverlapFunctions(_ globe: Bool) {
        let m = KeyboardMetrics(showsNumberRow: true)
        let slots = KeyboardGeometry.functionSlots(m, showsGlobe: globe)
        for d in KeyboardGeometry.numberRow(m) {
            let r = Rect(x: d.center.x - d.width / 2, y: d.center.y - d.height / 2,
                         width: d.width, height: d.height)
            for s in slots { #expect(!s.rect.overlaps(r.insetBy(1e-9))) }
        }
    }

    @Test("İçerik bandı 3 satır ve harfleri kapsıyor", arguments: LayoutGeometryTests.cases)
    func contentBandCoversLetters(_ m: KeyboardMetrics) {
        let band = KeyboardGeometry.contentBand(m)
        #expect(abs((band.upperBound - band.lowerBound) - 3 * KeyboardGeometry.rowHeight(m)) < 1e-9)
        for k in TurkishQ.layout(metrics: m).keys {
            #expect(k.center.y >= band.lowerBound && k.center.y < band.upperBound)
        }
    }

    // MARK: - Düzlemler hizalı

    @Test("Sembol düzlemleri harf düzlemiyle aynı satır bandını kullanıyor",
          arguments: LayoutGeometryTests.cases)
    func planesShareRowBands(_ m: KeyboardMetrics) {
        let letters = TurkishQ.layout(metrics: m)
        let numbers = SymbolPlanes.numbersPlane(metrics: m)
        // 1. satırın merkez y'si her iki düzlemde de aynı olmalı.
        let ly = letters.keys[0].center.y
        #expect(abs(numbers.keys[0].center.y - ly) < 1e-9)
        for k in numbers.keys { #expect(abs(k.height - KeyboardGeometry.rowHeight(m)) < 1e-9) }
    }

    // MARK: - Ölçü kırpma ve kimlik

    @Test("Aralık dışı ölçüler kırpılıyor — geçersiz bir metrics üretilemez")
    func metricsAreClamped() {
        let m = KeyboardMetrics(shiftWidth: 99, backspaceWidth: -5, spaceWidth: 0,
                                bottomRowScale: 99)
        #expect(m.shiftWidth == KeyboardMetrics.shiftRange.upperBound)
        #expect(m.backspaceWidth == KeyboardMetrics.backspaceRange.lowerBound)
        #expect(m.spaceWidth == KeyboardMetrics.spaceRange.lowerBound)
        #expect(m.bottomRowScale == KeyboardMetrics.bottomRowRange.upperBound)
    }

    @Test("Boşluk, globe durumuna göre kırpılıyor ve ⏎ hep sınırlar içinde",
          arguments: [true, false])
    func spaceIsBoundedByTheRow(_ globe: Bool) {
        let bounds = KeyboardMetrics.spaceBounds(showsGlobe: globe)
        for w in stride(from: 3.0, through: 7.5, by: 0.25) {
            let m = KeyboardMetrics(spaceWidth: w)
            let eff = m.effectiveSpaceWidth(showsGlobe: globe)
            #expect(eff >= bounds.lowerBound - 1e-9 && eff <= bounds.upperBound + 1e-9)
        }
    }

    /// `idSuffix` değerleri yüzde bire yuvarlıyor. Ölçüler kademeye
    /// oturtulmazsa `1.3271` ile `1.3349` **aynı** profil kimliğini üretip
    /// farklı geometrileri aynı kalibrasyon kovasına koyuyordu.
    @Test("Ölçüler kademeye oturuyor, kimlik kayıpsız")
    func metricsAreSnappedSoTheIDIsLossless() {
        let step = KeyboardMetrics.step
        func onGrid(_ v: Double) -> Bool { abs((v / step).rounded() * step - v) < 1e-9 }

        let a = KeyboardMetrics(shiftWidth: 1.3271, backspaceWidth: 2.0149,
                                spaceWidth: 5.5051)
        #expect(onGrid(a.shiftWidth))
        #expect(onGrid(a.backspaceWidth))
        #expect(onGrid(a.spaceWidth))

        // Aynı kademeye düşen iki ham değer → aynı kimlik **ve** aynı geometri.
        let b = KeyboardMetrics(shiftWidth: 1.3349, backspaceWidth: 2.0149,
                                spaceWidth: 5.5051)
        #expect(TurkishQ.layout(metrics: a).id == TurkishQ.layout(metrics: b).id)
        #expect(a == b, "aynı kimlik farklı geometri taşıyor")

        // Farklı kademeler → farklı kimlik.
        let c = a.with(shiftWidth: a.shiftWidth + step)
        #expect(TurkishQ.layout(metrics: a).id != TurkishQ.layout(metrics: c).id)
    }

    /// Bozuk bir `UserDefaults` girdisi `NaN` verebiliyor; kırpma ve yuvarlama
    /// ikisi de `NaN`'ı geçiriyordu ve `idSuffix`'teki `Int(...)` trap ediyordu.
    @Test("Sonlu olmayan değerler varsayılana düşüyor")
    func nonFiniteValuesFallBackToDefaults() {
        let d = KeyboardMetrics.default
        let m = KeyboardMetrics(shiftWidth: .nan, backspaceWidth: .infinity,
                                spaceWidth: -.infinity, bottomRowScale: .nan)
        // `NaN` ve ±sonsuz aynı muameleyi görüyor: hepsi varsayılana düşüyor.
        // Sonsuzu sınıra kırpmak "niyeti koru" gibi görünse de gerçek kaynak
        // bozuk bir depo girdisi; orada niyet diye bir şey yok.
        #expect(m.shiftWidth == d.shiftWidth)
        #expect(m.bottomRowScale == d.bottomRowScale)
        #expect(m.backspaceWidth == d.backspaceWidth)
        #expect(m.spaceWidth == d.spaceWidth)
        // Kimlik üretilebiliyor (trap yok).
        #expect(!TurkishQ.layout(metrics: m).id.isEmpty)
    }

    @Test("Alanlar init dışında değiştirilemiyor — invariant tip tarafından korunuyor")
    func metricsAreImmutableAfterInit() {
        // `with(...)` de `init`'ten geçiyor: aralık dışı bir değer kırpılıyor,
        // doğrudan atama ise derlenmiyor (`private(set)`).
        let m = KeyboardMetrics.default.with(shiftWidth: 100, spaceWidth: -1)
        #expect(m.shiftWidth == KeyboardMetrics.shiftRange.upperBound)
        #expect(m.spaceWidth == KeyboardMetrics.spaceRange.lowerBound)
        #expect(m.backspaceWidth == KeyboardMetrics.default.backspaceWidth)
    }

    /// Varsayılanlar ve aralık uçları kademeye oturmalı: oturmazsa panel 6.60
    /// gösterip ilk sürgü hareketinde 6.50'ye sıçrar ve "her ayar kanonik
    /// kademededir" varsayımı düşer.
    @Test("Varsayılanlar ve boşluk aralığı ayar kademesine oturuyor")
    func defaultsAreOnTheStepGrid() {
        let step = KeyboardMetrics.step
        func onGrid(_ v: Double) -> Bool { abs((v / step).rounded() * step - v) < 1e-9 }
        let d = KeyboardMetrics.default
        #expect(onGrid(d.shiftWidth))
        #expect(onGrid(d.backspaceWidth))
        #expect(onGrid(d.spaceWidth))
        // Yükseklik kendi (daha ince) ızgarasında.
        let hStep = KeyboardMetrics.bottomRowStep
        func onHeightGrid(_ v: Double) -> Bool {
            abs((v / hStep).rounded() * hStep - v) < 1e-9
        }
        #expect(onHeightGrid(d.bottomRowScale))
        #expect(onHeightGrid(KeyboardMetrics.bottomRowRange.lowerBound))
        #expect(onHeightGrid(KeyboardMetrics.bottomRowRange.upperBound))
        // Izgara dışı bir değer kanonikleştiriliyor.
        #expect(onHeightGrid(KeyboardMetrics.default.with(bottomRowScale: 1.3271)
                                .bottomRowScale))
        for globe in [true, false] {
            let b = KeyboardMetrics.spaceBounds(showsGlobe: globe)
            #expect(onGrid(b.lowerBound))
            #expect(onGrid(b.upperBound))
            #expect(b.contains(d.spaceWidth), "varsayılan boşluk aralık dışında")
            // Kademeye yuvarlanan her değer hâlâ geçerli bir `⏎` bırakmalı.
            var w = b.lowerBound
            while w <= b.upperBound + 1e-9 {
                let ret = KeyboardMetrics.default.with(spaceWidth: w)
                    .returnWidth(showsGlobe: globe)
                #expect(ret >= KeyboardMetrics.returnRange.lowerBound - 1e-9)
                #expect(ret <= KeyboardMetrics.returnRange.upperBound + 1e-9)
                w += step
            }
        }
    }

    /// Geometri değişince kalibrasyon profili de değişmeli: bir geometride
    /// öğrenilen parmak sapması diğerinde yanlış.
    @Test("Harf geometrisini değiştiren ölçüler farklı layout kimliği üretiyor")
    func metricsChangeTheLayoutID() {
        let d = KeyboardMetrics.default
        #expect(TurkishQ.layout(metrics: d).id
                != TurkishQ.layout(metrics: d.with(showsNumberRow: true)).id)
        #expect(TurkishQ.layout(metrics: d).id
                != TurkishQ.layout(metrics: d.with(shiftWidth: 2.0)).id)
        #expect(TurkishQ.layout(metrics: d).id
                != TurkishQ.layout(metrics: d.with(backspaceWidth: 2.0)).id)
    }

    /// Boşluk 4. satırda; harf merkezlerine dokunmuyor. Kimliğe girseydi
    /// boşluğu bir kademe genişleten kullanıcı öğrenilmiş sapmasını kaybederdi.
    @Test("Boşluk genişliği kalibrasyon profilini değiştirmiyor")
    func spaceWidthDoesNotSplitTheCalibrationProfile() {
        let a = KeyboardMetrics.default
        let b = a.with(spaceWidth: KeyboardMetrics.spaceBounds(showsGlobe: true).lowerBound)
        #expect(a.spaceWidth != b.spaceWidth)
        #expect(a.sharesLetterGeometry(with: b))
        #expect(TurkishQ.layout(metrics: a).id == TurkishQ.layout(metrics: b).id)
        // Harf merkezleri de birebir aynı olmalı.
        for (ka, kb) in zip(TurkishQ.layout(metrics: a).keys, TurkishQ.layout(metrics: b).keys) {
            #expect(ka.center == kb.center)
            #expect(ka.width == kb.width)
        }
    }

    @Test("sharesLetterGeometry yalnız 4. satır değişimlerinde doğru")
    func sharesLetterGeometryIsExact() {
        let d = KeyboardMetrics.default
        #expect(!d.sharesLetterGeometry(with: d.with(showsNumberRow: true)))
        #expect(!d.sharesLetterGeometry(with: d.with(shiftWidth: 2.0)))
        #expect(!d.sharesLetterGeometry(with: d.with(backspaceWidth: 2.0)))
        #expect(!d.sharesLetterGeometry(with: d.with(bottomRowScale: 1.5)))
        #expect(d.sharesLetterGeometry(with: d.with(spaceWidth: 4.0)))
    }

    // MARK: - Dokunma çözümlemesi

    @Test("Dokunma sırası: sayı sırası → işlev → içerik", arguments: [true, false])
    func surfaceResolutionOrder(_ numberRow: Bool) {
        let m = KeyboardMetrics(showsNumberRow: numberRow)
        let h = KeyboardGeometry.rowHeight(m)
        let u = 1.0 / KeyboardMetrics.rowUnits
        let r0 = Double(KeyboardGeometry.firstLetterRow(m))

        func at(_ x: Double, _ y: Double) -> KeyboardGeometry.Surface {
            KeyboardGeometry.surface(at: Point(x: x, y: y), metrics: m, showsGlobe: true)
        }

        // Üst bant: sayı sırası açıksa rakam, kapalıysa 1. harf satırı.
        if numberRow {
            #expect(at(0.05, h * 0.5) == .digit(index: 0))
            #expect(at(0.95, h * 0.5) == .digit(index: 9))
        } else {
            #expect(at(0.05, h * 0.5) == .content)
        }

        // 3. satır: solda ⇧, ortada harf, sağda ⌫.
        let row3 = (r0 + 2.5) * h
        #expect(at(m.shiftWidth * u * 0.5, row3) == .function(.leftModifier))
        #expect(at(0.5, row3) == .content)
        #expect(at(1 - m.backspaceWidth * u * 0.5, row3) == .function(.backspace))

        // Regresyon: `⇧`'in hemen sağı `z`'nin alanı, işlev tuşunun değil.
        #expect(at(m.shiftWidth * u + 1e-6, row3) == .content)
        #expect(at(1 - m.backspaceWidth * u - 1e-6, row3) == .content)

        // 4. satır tamamen işlev.
        let row4 = (r0 + 3.5) * h
        #expect(at(0.02, row4) == .function(.planeSwitch))
        #expect(at(0.5, row4) == .function(.space))
        #expect(at(0.99, row4) == .function(.ret))

        // Klavye dışı.
        #expect(at(-0.01, 0.5) == .none)
        #expect(at(0.5, 1.01) == .none)
    }

    @Test("İçerik bandının dışına düşen dokunma harfe snap edilmiyor")
    func touchesOutsideTheContentBandProduceNothing() {
        let m = KeyboardMetrics(showsNumberRow: true)
        let h = KeyboardGeometry.rowHeight(m)
        // Sayı sırası ile harfler arasında boşluk yok; ama sayı sırası
        // kapalıyken üst bandın üstü de yok. Asıl risk 4. satırın boşlukları:
        // globe gizliyken bile satır tam dolu olmalı.
        let bandTop = KeyboardGeometry.contentBand(m).upperBound
        let midY = bandTop + KeyboardGeometry.bottomRowHeight(m) / 2
        for globe in [true, false] {
            let slots = KeyboardGeometry.functionSlots(m, showsGlobe: globe)
            let row4 = slots.filter { $0.rect.y >= bandTop - 1e-9 }
            for x in stride(from: 0.0, through: 0.999, by: 0.01) {
                let p = Point(x: x, y: midY)
                #expect(row4.contains { $0.rect.contains(p) },
                        "4. satırda x=\(x) boşta (globe=\(globe))")
            }
        }
    }

    /// `Rect.contains` sağ ve alt kenarı dışlıyor (komşu hücreler çakışmasın
    /// diye). Tam `x = 1` bu yüzden hiçbir yuvaya girmiyor, içerik bandına
    /// düşüp `nearestKey` ile son harfe snap ediliyordu — sağ kenara basan
    /// `⌫` yerine `ç` yazıyordu.
    @Test("Dış kenarlar son tuşa ait, boşa değil", arguments: LayoutGeometryTests.cases)
    func outerEdgesBelongToTheLastKey(_ m: KeyboardMetrics) {
        let h = KeyboardGeometry.rowHeight(m)
        let r0 = Double(KeyboardGeometry.firstLetterRow(m))
        func at(_ x: Double, _ y: Double) -> KeyboardGeometry.Surface {
            KeyboardGeometry.surface(at: Point(x: x, y: y), metrics: m, showsGlobe: true)
        }
        // Sağ kenar, 3. satır → ⌫
        #expect(at(1.0, (r0 + 2.5) * h) == .function(.backspace))
        // Sağ-alt köşe → ⏎
        #expect(at(1.0, 1.0) == .function(.ret))
        // Sol kenar, 3. satır → ⇧
        #expect(at(0.0, (r0 + 2.5) * h) == .function(.leftModifier))
        // Üst kenar — `x` bir tuşun merkezinde (0.5 tam olarak `5` ile `6`
        // arasındaki boşluk; orası kasten ölü, bkz. `numberRowIndex`).
        #expect(at(0.55, 0.0) == (m.showsNumberRow ? .digit(index: 5) : .content))
        if m.showsNumberRow {
            // Sol/sağ ekran kenarı ilk ve son rakamı kaçırmamalı.
            #expect(at(0.0, 0.0) == .digit(index: 0))
            #expect(at(1.0, 0.0) == .digit(index: 9))
            // İki rakam arasındaki boşluk hâlâ hiçbir şey üretmiyor.
            #expect(at(0.5, KeyboardGeometry.rowHeight(m) / 2) == .none)
        }
        // Sınırın dışı hâlâ hiçbir şey
        #expect(at(1.0 + 1e-9, 0.5) == .none)
        #expect(at(0.5, 1.0 + 1e-9) == .none)
    }

    @Test("Globe gizliyken globe yuvası hiç üretilmiyor")
    func globeSlotDisappears() {
        let m = KeyboardMetrics.default
        #expect(KeyboardGeometry.functionSlots(m, showsGlobe: true)
                    .contains { $0.role == .globe })
        #expect(!KeyboardGeometry.functionSlots(m, showsGlobe: false)
                    .contains { $0.role == .globe })
    }

    @Test("Tuş sayısı ölçüden bağımsız", arguments: LayoutGeometryTests.cases)
    func keyCountIsStable(_ m: KeyboardMetrics) {
        #expect(TurkishQ.layout(metrics: m).keys.count == 32)
    }

    @Test("Tuşlar her ölçüde [0,1]² içinde", arguments: LayoutGeometryTests.cases)
    func keysStayInUnitSquare(_ m: KeyboardMetrics) {
        for k in TurkishQ.layout(metrics: m).keys {
            #expect(k.center.x - k.width / 2 >= -1e-9)
            #expect(k.center.x + k.width / 2 <= 1 + 1e-9)
            #expect(k.center.y - k.height / 2 >= -1e-9)
            #expect(k.center.y + k.height / 2 <= 1 + 1e-9)
        }
    }
}

private extension Rect {
    /// Kenar teması çakışma sayılmasın diye içeri çekilmiş kopya.
    func insetBy(_ d: Double) -> Rect {
        Rect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d)
    }
}
