import Testing
@testable import KBRuntime

/// Boşluk sürüklemesi — kelime sınırı aritmetiği (erişilebilirlik adımı).
///
/// Jestin cihazda denenmesi şart ama **yeterli değil**: burada sınanan şeylerin
/// hiçbiri gözle görülmüyor. Bir kelime geri gitmenin kaç karakter olduğu,
/// parmağı geri getirince imlecin başladığı yere dönüp dönmediği ve dikey
/// eksenin kelimeden taşmadığı — üçü de ancak sayarak doğrulanabiliyor.
@Suite("Boşlukta imleç sürükleme")
struct CursorDragTests {

    // MARK: - Kelime sınırları

    @Test("Kelimenin ortasından geri gitmek kelimenin başına götürüyor")
    func backwardFromMidWordGoesToItsStart() {
        // "kalem kut|u" → imleç `kut` ile `u` arasında.
        #expect(WordBoundaries.toPreviousWordStart(before: "kalem kut") == -3)
    }

    @Test("Kelimenin başındayken bir önceki kelimenin başına gidiyor")
    func backwardFromWordStartSkipsToThePreviousWord() {
        #expect(WordBoundaries.toPreviousWordStart(before: "kalem ") == -6)
        #expect(WordBoundaries.toPreviousWordStart(before: "kalem kutu ") == -5)
    }

    /// Boşluk **önce** atlanıyor, sonra kelime. Ayrı bir "ortada mıyım"
    /// kontrolü olmadan iki davranışın da çıkması bu sıradan geliyor.
    @Test("Çoklu boşluk tek adımda atlanıyor")
    func runsOfWhitespaceAreCrossedInOneStep() {
        #expect(WordBoundaries.toPreviousWordStart(before: "kalem   ") == -8)
    }

    @Test("Metnin başında geri gitmek duruyor")
    func backwardAtTheStartOfTextStops() {
        #expect(WordBoundaries.toPreviousWordStart(before: "") == 0)
        #expect(WordBoundaries.toPreviousWordStart(before: "   ") == -3)
    }

    /// İki yön de **kelime başını** hedefliyor. Simetrik olmamaları gerekiyordu:
    /// ileri giderken önce kelimenin kalanı, sonra boşluk atlanıyor.
    @Test("İleri gitmek sonraki kelimenin başında duruyor")
    func forwardLandsOnTheNextWordStart() {
        #expect(WordBoundaries.toNextWordStart(after: "lem kutu") == 4)
        #expect(WordBoundaries.toNextWordStart(after: " kutu") == 1)
    }

    @Test("Metnin sonunda ileri gitmek duruyor")
    func forwardAtTheEndOfTextStops() {
        #expect(WordBoundaries.toNextWordStart(after: "") == 0)
        #expect(WordBoundaries.toNextWordStart(after: "kalem") == 5)
    }

    /// Noktalama kelimeye **dahil**: `kalem.` tek kelime. Ayırmak "daha doğru"
    /// görünüyor ama kullanıcı için noktadan önce duran fazladan bir engel
    /// demek.
    @Test("Noktalama kelimeden ayrılmıyor")
    func punctuationStaysWithTheWord() {
        #expect(WordBoundaries.toPreviousWordStart(before: "bitti kalem.") == -6)
        #expect(WordBoundaries.currentWord(before: "kalem", after: ".") == (-5, 1))
    }

    // MARK: - Çok kelimelik tek atlama

    /// Hızlı sürüklemede birden çok kelime **tek** ofsette hesaplanıyor.
    ///
    /// Adımları tek tek uygulamak `adjustTextPosition`'ın proxy'yi anında
    /// güncellememesi yüzünden yanlıştı: ikinci adım eski konumdan hesaplanmış
    /// bir bağlamı okuyabiliyordu. Tek okuma + tek mutasyon o yarışı yok ediyor.
    @Test("Çok kelimelik geri atlama tek ofsette")
    func multipleWordsBackwardInOneOffset() {
        #expect(WordBoundaries.toPreviousWordStart(before: "bir iki üç ", count: 2) == -7)
        #expect(WordBoundaries.toPreviousWordStart(before: "bir iki üç ", count: 3) == -11)
    }

    /// Metnin başına dayanınca **duruyor**, taşmıyor: fazladan istenen adımlar
    /// sessizce yutuluyor ve ofset bağlamın dışına çıkmıyor.
    @Test("Bağlamın başına dayanan atlama taşmıyor")
    func multiWordJumpsClampAtTheStart() {
        let before = "bir iki"
        let n = WordBoundaries.toPreviousWordStart(before: before, count: 99)
        #expect(n == -before.count)
    }

    @Test("Çok kelimelik ileri atlama tek ofsette")
    func multipleWordsForwardInOneOffset() {
        #expect(WordBoundaries.toNextWordStart(after: "ir iki üç", count: 2) == 7)
        let after = "ir iki"
        #expect(WordBoundaries.toNextWordStart(after: after, count: 99) == after.count)
    }

    @Test("Sıfır ve negatif sayı hiçbir şey yapmıyor")
    func nonPositiveCountsAreNoOps() {
        #expect(WordBoundaries.toPreviousWordStart(before: "bir iki", count: 0) == 0)
        #expect(WordBoundaries.toNextWordStart(after: "bir iki", count: -3) == 0)
    }

    @Test("İçinde bulunulan kelimenin sınırları")
    func currentWordBounds() {
        #expect(WordBoundaries.currentWord(before: "bir kal", after: "em ve") == (-3, 2))
    }

    /// İmleç boşluktaysa dikey eksenin dolaşacağı bir kelime yok.
    ///
    /// En yakın kelimeye atlamak da mümkündü; yapılmadı çünkü kullanıcı
    /// parmağını kaldırmadan hangi kelimeye girdiğini göremez ve yanlış
    /// kelimede karakter karakter dolaşmak jestin engellemek için var olduğu
    /// şeyin ta kendisi.
    @Test("İmleç boşluktaysa kelime aralığı boş")
    func cursorOnWhitespaceHasNoWord() {
        #expect(WordBoundaries.currentWord(before: "kalem ", after: " kutu") == (0, 0))
    }

}

// MARK: - İzleme yüzeyi

@Suite("CursorTrackpad")
struct CursorTrackpadTests {
    /// Yavaş, sabit hızlı sürükleme: 60 Hz'de kare başına `step` nokta.
    private func drag(_ t: inout CursorTrackpad, dx: Double = 0, dy: Double = 0, frames: Int) -> Int {
        var total = 0, x = 0.0, y = 0.0, time = 0.0
        total += t.update(dx: 0, dy: 0, time: 0)
        for _ in 0..<frames {
            x += dx; y += dy; time += 1.0 / 60
            total += t.update(dx: x, dy: y, time: time)
        }
        return total
    }

    @Test("Yavaş yatay sürükleme harf harf gidiyor")
    func slowHorizontalMovesByCharacter() {
        var t = CursorTrackpad(before: "merhaba", after: " dünya")
        // 18 nokta, saniyede 60 nokta → ivme yok, 9 nokta/karakter = 2 karakter.
        #expect(drag(&t, dx: -1, frames: 18) == -2)
    }

    @Test("Hızlı sürükleme ivmeleniyor")
    func fastDragsAccelerate() {
        var slow = CursorTrackpad(before: String(repeating: "a", count: 200), after: "")
        var fast = CursorTrackpad(before: String(repeating: "a", count: 200), after: "")
        let s = drag(&slow, dx: -1, frames: 90)     // 90 nokta yavaş
        let f = drag(&fast, dx: -18, frames: 5)     // 90 nokta hızlı
        #expect(abs(f) > abs(s))
    }

    @Test("Metnin sınırında duruyor")
    func clampsAtTheEnds() {
        var t = CursorTrackpad(before: "ab", after: "c")
        #expect(drag(&t, dx: -1, frames: 200) == -2)
        var u = CursorTrackpad(before: "ab", after: "c")
        #expect(drag(&u, dx: 1, frames: 200) == 1)
    }

    @Test("Yukarı tek satırlık metinde başa gidiyor")
    func upOnASingleLineGoesToStart() {
        var t = CursorTrackpad(before: "selam nasılsın", after: " iyi")
        #expect(drag(&t, dy: -2, frames: 20) == -14)
    }

    @Test("Aşağı sütunu koruyarak sonraki satıra geçiyor")
    func downKeepsTheColumn() {
        var t = CursorTrackpad(before: "ab", after: "cd\nefgh")
        // imleç 0. satır 2. sütunda → 1. satır 2. sütun: "ab|cd\nef|gh" = +5
        #expect(drag(&t, dy: 2, frames: 16) == 5)
    }

    @Test("Emoji tek adım, UTF-16 ofseti doğru")
    func emojiIsOneStepWithUTF16Offset() {
        var t = CursorTrackpad(before: "a👨‍👩‍👧", after: "")
        #expect(drag(&t, dx: -1, frames: 9) == -8)
    }

    @Test("Yatay sürüklerken hafif eğim satır atlatmıyor")
    func diagonalDriftDoesNotChangeLines() {
        var t = CursorTrackpad(before: "ab\ncd", after: "")
        // Her karede 1 yatay, 0,5 dikey: dikey hiç baskın değil.
        #expect(drag(&t, dx: -1, dy: -0.5, frames: 9) == -1)
    }
}
