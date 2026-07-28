import Foundation

/// Türkçe Q layout — `-1A₁` için koda gömülü.
/// Faz 0'da bu veri build sırasında binary blob'a derlenecek (§11.A: çalışma anında JSON yok).
///
/// ```
/// R1: q w e r t y u ı o p ğ ü      (12 tuş)
/// R2: a s d f g h j k l ş i        (11 tuş)
/// R3: ⇧ z x c v b n m ö ç ⌫        (9 harf + 2 işlev)
/// R4: 123 [🌐] space . ⏎
/// ```
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

    /// 4 satırlı klavye; harfler 0..2, son satır boşluk/işlev (modelde yok).
    public static let rowHeight = 0.25

    public static func layout() -> KeyLayout {
        var keys: [Key] = []

        func addRow(_ chars: [Character], rowIndex: Int, keyWidth: Double, xStart: Double) {
            let cy = (Double(rowIndex) + 0.5) * rowHeight
            for (i, ch) in chars.enumerated() {
                let cx = xStart + (Double(i) + 0.5) * keyWidth
                keys.append(Key(char: ch,
                                center: Point(x: cx, y: cy),
                                width: keyWidth,
                                height: rowHeight))
            }
        }

        // R1: tam genişlik, 12 tuş.
        addRow(row1, rowIndex: 0, keyWidth: 1.0 / 12.0, xStart: 0)

        // R2: tam genişlik, 11 tuş — R1'den geniş tuşlar.
        addRow(row2, rowIndex: 1, keyWidth: 1.0 / 11.0, xStart: 0)

        // R3: 9 harf, R2 ile aynı tuş genişliğinde, ortalanmış.
        // Kenarlarda ⇧ ve ⌫ var; harf olmadıkları için modele girmezler.
        let w3 = 1.0 / 11.0
        addRow(row3, rowIndex: 2, keyWidth: w3, xStart: (1.0 - 9.0 * w3) / 2.0)

        return KeyLayout(id: "tr-Q", keys: keys, asciiBase: asciiBase)
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
