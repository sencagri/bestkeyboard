import Foundation

/// Rakam ve sembol düzlemleri — plan §8 *"Sayı/sembol düzlemleri"*.
///
/// ## Neden ayrı bir tip
///
/// Bu tuşlar **kod çözmeye girmez**. Uzamsal decoder bir *leksikon* üzerinde
/// çalışır; rakam ve noktalamanın leksikonu yoktur, komşuluk düzeltmesi de
/// istenmez — `3` yazmak isteyene `4` vermek düpedüz hatadır.
///
/// Üstelik §5c zaten rakam içeren token'ları korumaya alıyor. Yani bu düzlemler
/// **doğrudan yazım**: dokunma → karakter, arada model yok.
///
/// `KeyLayout` kullanmamalarının sebebi de bu: `KeyLayout` uzamsal modelin
/// girdisi ve her tuşu bir leksikal sembole bağlı. Buradaki tuşlar öyle değil.
public enum SymbolPlanes {

    public struct PlaneKey: Sendable {
        public let char: Character
        public let center: Point
        public let width: Double
        public let height: Double

        public init(char: Character, center: Point, width: Double, height: Double) {
            self.char = char
            self.center = center
            self.width = width
            self.height = height
        }
    }

    public struct Plane: Sendable {
        public let id: String
        public let keys: [PlaneKey]

        /// Çerçeve testiyle vuruş — **en yakın merkez değil**.
        ///
        /// Harf düzleminde en yakın merkez doğru: belirsizliği uzamsal model
        /// çözüyor. Burada model yok, dolayısıyla tuşun dışına basmak karakter
        /// üretmemeli — yoksa `,` ile `.` arasındaki boşluğa dokunmak rastgele
        /// birini yazardı.
        /// - Parameter gap: tuşlar arası **görsel** boşluk oranı. Çizim tuşları
        ///   içeri çektiği için vuruş alanı da o kadar daralmalı; yoksa görünen
        ///   boşluğa dokunmak karakter üretir.
        public func hit(at p: Point, gap: Double = SymbolPlanes.hitGap) -> Int? {
            for (i, k) in keys.enumerated() {
                let hw = k.width * (1 - gap) / 2
                let hh = k.height * (1 - gap) / 2
                // Sınırlarda `<` kullanılıyor: `<=` ile komşu hücreler
                // çakışıyor ve ilk tuş kazanıyordu.
                if abs(p.x - k.center.x) < hw, abs(p.y - k.center.y) < hh { return i }
            }
            return nil
        }
    }

    /// Harf düzlemiyle **aynı** satır yüksekliği: düzlem değişince tuşlar
    /// yerinden oynamamalı, yoksa kas hafızası her geçişte bozulur.
    /// (Varsayılan ölçüler için; ölçüye bağlı hesap `KeyboardGeometry`'de.)
    public static let rowHeight = TurkishQ.rowHeight

    /// Tuşlar arası **görsel** boşluk oranı — vuruş alanı da o kadar daralır.
    public static let hitGap: Double = 0.06

    public static let numbersRow1: [Character] = ["1","2","3","4","5","6","7","8","9","0"]
    public static let numbersRow2: [Character] = ["-","/",":",";","(",")","₺","&","@","\""]
    public static let numbersRow3: [Character] = [".",",","?","!","'"]

    public static let symbolsRow1: [Character] = ["[","]","{","}","#","%","^","*","+","="]
    public static let symbolsRow2: [Character] = ["_","\\","|","~","<",">","€","$","¥","•"]
    public static let symbolsRow3: [Character] = [".",",","?","!","'"]

    /// Varsayılan ölçülerdeki düzlemler.
    public static let numbers = numbersPlane()
    public static let symbols = symbolsPlane()

    /// Ölçüye bağlı düzlemler. Harf düzlemiyle aynı satır bandını kullanırlar:
    /// sayı sırası açıkken sembol düzlemi de bir satır aşağı iner, yoksa
    /// `123`'e basınca bütün tuşlar yerinden oynardı.
    public static func numbersPlane(metrics: KeyboardMetrics = .default) -> Plane {
        build(id: "numbers", metrics, numbersRow1, numbersRow2, numbersRow3)
    }

    public static func symbolsPlane(metrics: KeyboardMetrics = .default) -> Plane {
        build(id: "symbols", metrics, symbolsRow1, symbolsRow2, symbolsRow3)
    }

    private static func build(id: String, _ metrics: KeyboardMetrics,
                              _ r1: [Character], _ r2: [Character],
                              _ r3: [Character]) -> Plane {
        var keys: [PlaneKey] = []
        let h = KeyboardGeometry.rowHeight(metrics)
        let r0 = KeyboardGeometry.firstLetterRow(metrics)

        func addRow(_ chars: [Character], rowIndex: Int, keyWidth: Double, xStart: Double) {
            let cy = (Double(r0 + rowIndex) + 0.5) * h
            for (i, ch) in chars.enumerated() {
                keys.append(PlaneKey(char: ch,
                                     center: Point(x: xStart + (Double(i) + 0.5) * keyWidth,
                                                   y: cy),
                                     width: keyWidth, height: h))
            }
        }

        addRow(r1, rowIndex: 0, keyWidth: 1.0 / 10.0, xStart: 0)
        addRow(r2, rowIndex: 1, keyWidth: 1.0 / 10.0, xStart: 0)
        // 3. satırın kenarlarında düzlem değiştirme ve silme var; 5 tuş ortada.
        let w3 = 1.0 / 10.0
        addRow(r3, rowIndex: 2, keyWidth: w3, xStart: (1.0 - 5.0 * w3) / 2.0)

        return Plane(id: id, keys: keys)
    }
}
