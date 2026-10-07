import UIKit
import KBGeometry
import KBRuntime
import KBSessions

/// Erişilebilirlik: tuş öğeleri, etkinleştirme ve duyurular.
extension KeyboardView {
    // MARK: - Erişilebilirlik
    //
    // Öğeler hem **okunuyor** hem **etkinleştiriliyor**: `accessibilityActivate()`
    // tuşu tam da parmağın ürettiği yola sokuyor (`onKeyCommit`), yalnız
    // etkinleştirme türü `.accessibility`.
    //
    // Uzun süre bağlanmamış olmasının sebebi bağlamanın zorluğu değildi,
    // **kanıtın sahte olmasıydı**: harf aktivasyonu tuş merkezinden bir `Point`
    // üretmek zorunda ve o dokunma kalibrasyon öğrenimine girseydi sapma
    // öğrenimini sistematik olarak sıfıra çekerdi — tam merkeze konan
    // dokunmalar §8.1.1'de ölçümü bozan şeyin ta kendisi. Çözüm noktayı
    // üretmemek değil, **türetilmiş olduğunu taşımak**: `KeyActivation` motora
    // kadar gidiyor ve orada hem otomatik düzeltmeyi hem öğrenmeyi kapatıyor
    // (§8.9).

    /// Tuşun VoiceOver'da okunacak adı.
    ///
    /// Enum adını (`shift`, `backspace`) okutmak, Türkçe konuşan bir ekran
    /// okuyucuya İngilizce kimlik adları söyletmek olurdu. Kimlik (`key.shift`)
    /// XCUITest'in; etiket kullanıcının.
    private func functionLabel(_ fk: FunctionKey) -> String {
        switch fk {
        case .shift:     return isShiftLocked ? "büyük harf kilidi" : "büyük harf"
        case .backspace: return "sil"
        case .numbers:   return "rakamlar"
        case .symbols:   return "semboller"
        case .letters:   return "harfler"
        case .globe:     return "sonraki klavye"
        case .space:     return "boşluk"
        case .ret:       return "satır sonu"
        case .period:    return "nokta"
        }
    }

    override func buildAccessibilityElements() -> [Any] {
        var elements: [UIAccessibilityElement] = []

        func add(_ id: String, _ label: String, _ frame: CGRect,
                 _ hit: KeyHit) {
            let e = ActivatableAccessibilityElement(accessibilityContainer: self)
            e.accessibilityIdentifier = id
            e.accessibilityLabel = label
            e.accessibilityTraits = .keyboardKey
            e.accessibilityFrameInContainerSpace = frame
            e.onActivate = { [weak self] in
                guard let self, self.allowsAccessibilityActivation else { return false }
                self.onKeyCommit?(hit, .accessibility)
                return true
            }
            elements.append(e)
        }

        // Sayı sırası ayrı bir önek alıyor: rakam düzleminin 1. satırı aynı
        // karakterleri taşıyor ve sayı sırası açıkken `key.1` iki öğeye birden
        // ait oluyordu — hem XCUITest seçimi hem teşhis belirsizleşiyordu.
        for (i, k) in numberRow.enumerated() where i < digitFrames.count {
            add("key.numRow.\(k.char)", String(k.char), digitFrames[i],
                .digit(k.char))
        }
        switch plane {
        case .letters:
            for (i, k) in layout.keys.enumerated() where i < keyFrames.count {
                // Etiket **görünen** hâli: shift açıkken tuş `A` yazıyor ve
                // VoiceOver'ın `a` demesi kullanıcıyı hangi harfin çıkacağı
                // konusunda yanıltırdı. Kimlik küçük harfte kalıyor — o
                // XCUITest'in sabiti ve shift'e göre değişmemeli.
                //
                // Nokta tuşun **layout merkezi**: decoder'ın o tuş için
                // beklediği değerin ta kendisi. Çerçeveden hesaplamak ikinci bir
                // geometri kaynağı açardı ve §Geometri sözleşmesi tam da bunu
                // yasaklıyor.
                add("key.\(k.char)", letterTitle(k.char), keyFrames[i],
                    .letter(index: i, point: k.center))
            }
        case .numbers, .symbols:
            for (i, k) in planeKeys.enumerated() where i < keyFrames.count {
                add("key.\(k.char)", String(k.char), keyFrames[i], .symbol(k.char))
            }
        }
        for (fk, f) in functionFrames {
            add("key.\(fk)", functionLabel(fk), f, .function(fk))
        }

        // `⌫` basılı tutmanın erişilebilirlik karşılığı.
        //
        // Kademeli tekrar bir **zamanlayıcı** davranışı ve VoiceOver'da parmak
        // tuşun üstünde durmuyor; kelime silme başka türlü hiç erişilemezdi.
        // Özel eylem tekrarı taklit etmiyor, doğrudan `.word` kademesini
        // çağırıyor — aynı huniden geçen aynı komut.
        if let backspace = elements.first(where: {
            $0.accessibilityIdentifier == "key.\(FunctionKey.backspace)"
        }) {
            backspace.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "kelimeyi sil") { [weak self] _ in
                    guard let self, self.allowsAccessibilityActivation else { return false }
                    self.onKeyRepeat?(.function(.backspace), .word)
                    return true
                }
            ]
        }

        // İmleç sürüklemesinin erişilebilirlik karşılığı.
        //
        // Jest **sürükleme**, VoiceOver'da ise parmak ekranda gezinip çift
        // dokunuyor: bir öteleme yok, dolayısıyla jestin kendisi o kullanıcıya
        // hiç ulaşmıyor. Özel eylemler aynı yeteneği ayrık adımlar hâlinde
        // veriyor — `⌫`'deki `kelimeyi sil` ile aynı gerekçe.
        //
        // Dikey eksenin karşılığı **yok** ve olmamalı: VoiceOver zaten metni
        // karakter karakter gezdirebiliyor (rotor) ve ikinci bir yol koymak
        // sistemin kendi mekanizmasıyla yarışırdı.
        if let space = elements.first(where: {
            $0.accessibilityIdentifier == "key.\(FunctionKey.space)"
        }), onSpaceDragChanged != nil {
            space.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "bir kelime geri") { [weak self] _ in
                    guard let self, self.allowsAccessibilityActivation else { return false }
                    return self.onSpaceDragStep?(-1) ?? false
                },
                UIAccessibilityCustomAction(name: "bir kelime ileri") { [weak self] _ in
                    guard let self, self.allowsAccessibilityActivation else { return false }
                    return self.onSpaceDragStep?(1) ?? false
                },
            ]
        }

        // Virgülün erişilebilirlik karşılığı — `⌫`'deki kelime silmeyle aynı
        // gerekçe. VoiceOver çift dokunuşu bir *süre* taşımıyor, dolayısıyla
        // basılı tutmaya bağlanan her şey özel eylem olarak da durmak zorunda;
        // yoksa virgül o kullanıcı için harf düzleminde **hiç** erişilemez ve
        // `123`'e geçmek tek yol olurdu.
        if let period = elements.first(where: {
            $0.accessibilityIdentifier == "key.\(FunctionKey.period)"
        }) {
            period.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "virgül") { [weak self] _ in
                    guard let self, self.allowsAccessibilityActivation else { return false }
                    self.onPeriodLongPress?()
                    return true
                }
            ]
        }

        return elements
    }

    /// Yüzey değişti — VoiceOver odağı ve öğe listesi yenilenmeli.
    ///
    /// `123`'e basınca bütün tuşlar değişiyor; bildirim olmadan ekran okuyucu
    /// eski listeyi okumaya devam ediyor ve kullanıcı harf sandığı yerde sembol
    /// yazıyor. Yalnız VoiceOver çalışırken gönderiliyor: bildirim ucuz değil ve
    /// her `layoutSubviews`'ta atılırsa yazma yolunda gereksiz iş olur.
    func announceSurfaceChange() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}
