import Foundation

/// Türkçe Q layout — `-1A₁` için koda gömülü.
/// Faz 0'da bu veri build sırasında binary blob'a derlenecek (§11.A: çalışma anında JSON yok).
///
/// ```
/// R0: 1 2 3 4 5 6 7 8 9 0          (opsiyonel sayı sırası, modelde YOK)
/// R1: q w e r t y u ı o p ğ ü      (12 tuş)
/// R2: a s d f g h j k l ş i        (11 tuş)
/// R3: ⇧ z x c v b n m ö ç . ⌫      (9 harf + nokta + 2 işlev)
/// R4: 123 [🌐] boşluk ⏎
/// ```
///
/// `.` **bu listede yok**: karakter üretiyor ama kod çözmeye girmiyor, o yüzden
/// `KeyLayout`'a değil işlev yuvalarına ait (`FunctionRole.period`). Yine de
/// 3. satırın ızgarasını paylaşıyor — satır 9 değil **10** yuvaya bölünüyor ve
/// harflerin merkezleri bu yüzden kaydı (`KeyboardMetrics.layoutGeneration`).
///
/// Dikkat: 1. satır 12 tuş — İngilizce QWERTY'den dar. Uzamsal model bu yüzden
/// global tuş genişliği değil **tuş başına genişlik** kullanır.
///
/// Türkçe Q, İngilizce QWERTY'nin harf kümesini kapsar (`q`, `w`, `x` mevcut) —
/// çoklu dilde tek layout / çoklu leksikon bunu mümkün kılar.
public enum TurkishQ {

    public static let row1: [Character] = ["q", "w", "e", "r", "t", "y", "u", "ı", "o", "p", "ğ", "ü"]
    public static let row2: [Character] = ["a", "s", "d", "f", "g", "h", "j", "k", "l", "ş", "i"]
    public static let row3: [Character] = ["z", "x", "c", "v", "b", "n", "m", "ö", "ç"]

    /// Varsayılan ölçülerdeki satır yüksekliği — 4 satır.
    /// Ölçüye bağlı hesap için `KeyboardGeometry.rowHeight(_:)`.
    public static let rowHeight = 0.25

    /// - Parameter metrics: kullanıcı ölçüleri. 3. satırın harf genişliği
    ///   `⇧`/`⌫`'den **artan**dır; sabit bir genişlik varsaymak işlev
    ///   tuşlarının harflerin üstüne binmesi demekti.
    public static func layout(metrics: KeyboardMetrics = .default) -> KeyLayout {
        var keys: [Key] = []
        let h = KeyboardGeometry.rowHeight(metrics)
        let r0 = KeyboardGeometry.firstLetterRow(metrics)

        func addRow(_ chars: [Character], rowIndex: Int, keyWidth: Double, xStart: Double) {
            let cy = (Double(r0 + rowIndex) + 0.5) * h
            for (i, ch) in chars.enumerated() {
                let cx = xStart + (Double(i) + 0.5) * keyWidth
                keys.append(Key(char: ch,
                                center: Point(x: cx, y: cy),
                                width: keyWidth,
                                height: h))
            }
        }

        // R1: tam genişlik, 12 tuş.
        addRow(row1, rowIndex: 0, keyWidth: 1.0 / 12.0, xStart: 0)

        // R2: tam genişlik, 11 tuş — R1'den geniş tuşlar.
        addRow(row2, rowIndex: 1, keyWidth: 1.0 / 11.0, xStart: 0)

        // R3: 9 harf + nokta, `⇧` ile `⌫` arasında kalan yeri **10 yuva**
        // olarak paylaşır. Satır böylece her ölçüde tam dolar ve hiçbir işlev
        // tuşu harfin üstüne binmez.
        //
        // Harfler ilk 9 yuvayı alıyor; 10. yuva `KeyboardGeometry`'de nokta
        // olarak kuruluyor. Buradan çizilmemesinin sebebi `.`'nun kod çözmeye
        // girmemesi: `KeyLayout.keys` decoder'ın aday kümesi ve oraya konan her
        // şey `nearestKey`'in de adayı olur.
        let u = 1.0 / KeyboardMetrics.rowUnits
        let w3 = metrics.letterWidthUnitsRow3 * u
        addRow(row3, rowIndex: 2, keyWidth: w3, xStart: metrics.shiftWidth * u)

        return KeyLayout(id: "tr-Q-" + metrics.idSuffix, keys: keys, asciiBase: asciiBase)
    }

    /// Skor sözleşmesi §2.3 — yalnız diyakritik → ASCII taban yönü.
    /// `guzel → güzel`'i çözen şey budur: dokunma `ü` tuşuna göre değil,
    /// tabanı olan `u` tuşuna göre skorlanır.
    public static let asciiBase: [Character: Character] = [
        "ç": "c",
        "ğ": "g",
        "ı": "i",
        "ö": "o",
        "ş": "s",
        "ü": "u",
    ]
}
