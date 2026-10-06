import Testing
@testable import KBRuntime

/// Boşluk sürüklemesi — kelime sınırı aritmetiği ve eksen kilidi.
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

    // MARK: - Eksen kilidi

    private func gesture(word: (Int, Int) = (-3, 3)) -> CursorDragGesture {
        CursorDragGesture(word: word,
                          metrics: .init(axisLock: 10, wordStride: 20, charStride: 10))
    }

    @Test("Eşik aşılmadan hiçbir eksen kilitlenmiyor")
    func noAxisBeforeTheThreshold() {
        var g = gesture()
        #expect(g.update(dx: 5, dy: 5) == nil)
        #expect(g.axis == nil)
    }

    @Test("Baskın eksen kilitleniyor ve diğeri artık çalışmıyor")
    func theDominantAxisLocksAndTheOtherIsIgnored() {
        var g = gesture()
        _ = g.update(dx: 40, dy: 0)
        #expect(g.axis == .horizontal)
        // Dikeye geçmek serbest **değil**: kullanıcı istese de aynı jestte iki
        // eksen çalışmıyor. Yatay bileşen aynı kaldığı için hedef de aynı.
        #expect(g.update(dx: 40, dy: 200) == nil,
                "kilitli eksende dikey hareket hedefi değiştirdi")
        #expect(g.axis == .horizontal)
    }

    @Test("Dikey baskınsa dikey kilitleniyor")
    func verticalLocksWhenItDominates() {
        var g = gesture()
        _ = g.update(dx: 2, dy: 30)
        #expect(g.axis == .vertical)
    }

    // MARK: - Yatay: mutlak kelime hedefi

    /// Hedef **mutlak**: jest başındaki imleçten kaç kelime uzakta olunması
    /// gerektiği. Kaç adım atılacağı değil.
    @Test("Her stride hedefi bir kelime uzaklaştırıyor")
    func eachStrideMovesTheTargetByOneWord() {
        var g = gesture()
        #expect(g.update(dx: -20, dy: 0) == .words(-1))
        #expect(g.update(dx: -40, dy: 0) == .words(-2))
        #expect(g.update(dx: -60, dy: 0) == .words(-3))
    }

    /// Tek karede birden çok stride atlanırsa hedef **doğrudan** oraya gidiyor.
    @Test("Hızlı sürükleme hedefi atlamıyor")
    func fastDragsDoNotLoseGround() {
        var g = gesture()
        #expect(g.update(dx: -60, dy: 0) == .words(-3))
    }

    /// Aynı hedef iki kez bildirilmiyor: stride içinde kalan titreme host'a
    /// gereksiz mutasyon göndermemeli.
    @Test("Değişmeyen hedef tekrar bildirilmiyor")
    func anUnchangedTargetIsNotReported() {
        var g = gesture()
        #expect(g.update(dx: -20, dy: 0) == .words(-1))
        #expect(g.update(dx: -25, dy: 0) == nil)
    }

    /// **Jestin en çok güven isteyen kısmı.** Parmağı geri getirmek imleci
    /// başladığı yere döndürmeli.
    ///
    /// Mutlak hedef bunu yapısal olarak garantiliyor: başlangıç ötelemesi sıfır
    /// ötelemeye dönünce hedef de `0`. Artımlı toplamda yuvarlama artıkları
    /// birikiyordu ve dönüş noktası kayıyordu.
    @Test("Parmağı geri getirmek hedefi başa döndürüyor")
    func draggingBackReturnsTheTargetToTheOrigin() {
        var g = gesture()
        _ = g.update(dx: -60, dy: 0)
        #expect(g.update(dx: 0, dy: 0) == .words(0))
    }

    /// Hedef geri dönüşte **kaymıyor**.
    ///
    /// Eski adım listesinde `applied` istenen adım sayısını sayıyordu ve
    /// parmak yarıya döndüğünde ters adımlar birikimden hesaplanıyordu. Mutlak
    /// hedefte böyle bir birikim yok — makine her karede "nerede olmalıyım"
    /// sorusunu yeniden cevaplıyor.
    ///
    /// **Bu testin kapsamadığı şey:** host'un geçerli bir ofseti kısmen
    /// uygulaması. `adjustTextPosition` sonuç döndürmüyor, dolayısıyla ne bu
    /// makine ne de çağıran bunu görebiliyor. Güvence yalnız *yakalanmış
    /// bağlam içinde* geçerli (`clampedContextDoesNotOvershootOnTheWayBack`).
    @Test("Geri dönüşte hedef kaymıyor")
    func theTargetDoesNotDriftOnTheWayBack() {
        var g = gesture()
        #expect(g.update(dx: -60, dy: 0) == .words(-3))
        // Host yalnız bir kelime ilerletmiş olsun; makine bunu bilmiyor ve
        // bilmesi de gerekmiyor. Parmak yarıya dönünce hedef yine mutlak.
        #expect(g.update(dx: -30, dy: 0) == .words(-1))
        #expect(g.update(dx: 0, dy: 0) == .words(0))
    }

    // MARK: - Dikey: kelimenin içinde

    @Test("Dikey hedef karakter cinsinden ve mutlak")
    func verticalTargetsAreAbsoluteCharacters() {
        var g = gesture(word: (-3, 3))
        #expect(g.update(dx: 0, dy: 10) == .characters(1))
        #expect(g.update(dx: 0, dy: 30) == .characters(3))
    }

    /// **Asıl koruma**: kelime değişmiyor. Parmak ne kadar giderse gitsin hedef
    /// kelimenin sınırında duruyor.
    @Test("Dikey eksen kelimenin dışına taşmıyor")
    func verticalNeverLeavesTheWord() {
        var g = gesture(word: (-3, 3))
        #expect(g.update(dx: 0, dy: 500) == .characters(3))
        #expect(g.update(dx: 0, dy: 900) == nil, "sınırda ikinci kez ilerledi")

        var h = gesture(word: (-3, 3))
        #expect(h.update(dx: 0, dy: -500) == .characters(-3))
    }

    /// Kırpma hedefte, adımda değil: sınırın ötesinde harcanan mesafe
    /// birikmiyor ve parmak geri gelince imleç **gecikmesiz** tepki veriyor.
    @Test("Sınırın ötesinden geri dönmek gecikmesiz")
    func returningFromBeyondTheBoundIsImmediate() {
        var g = gesture(word: (-3, 3))
        _ = g.update(dx: 0, dy: 500)          // sınıra oturdu (+3)
        #expect(g.update(dx: 0, dy: 20) == .characters(2))
    }

    /// İmleç boşluktaysa aralık `(0, 0)`: eksen kilitleniyor ama hedef hep
    /// sıfır, dolayısıyla çağıran hiçbir mutasyon uygulamıyor.
    @Test("Kelime yoksa dikey eksen hedef üretmiyor")
    func verticalProducesNoTargetWithoutAWord() {
        var g = gesture(word: (0, 0))
        #expect(g.update(dx: 0, dy: 30) == .characters(0))
        #expect(g.axis == .vertical)
        #expect(g.update(dx: 0, dy: 300) == nil)
    }

    /// Hedef üretmek **hareket demek değil**.
    ///
    /// Belgenin başında bir kelime geri istemek geçerli bir hedef ama sıfır
    /// karakter hareket eder; o jest bırakışta boşluk yazmalı. Durum makinesi
    /// gerçekleşeni bilmediği için bu kararı veremez ve vermeye çalışmıyor —
    /// `didMove` diye bir alan bilerek yok.
    @Test("Sıfır ofsete karşılık gelen hedef de üretilebiliyor")
    func aTargetCanCorrespondToZeroMovement() {
        var g = gesture()
        #expect(g.update(dx: -20, dy: 0) == .words(-1))
        // Belgenin başındaysak bunun karakter karşılığı 0 olur — kararı
        // çağıran veriyor, makine değil.
        #expect(WordBoundaries.toPreviousWordStart(before: "", count: 1) == 0)
    }

    // MARK: - UTF-16 birimi

    /// Ofsetler **UTF-16 kod birimi**, grapheme değil.
    ///
    /// `adjustTextPosition` `UITextInput` konumlarına dayanıyor ve o katman
    /// `NSString` semantiği taşıyor. Grapheme saymak emoji içeren metinde
    /// imleci kelimenin ortasına düşürürdü.
    @Test("Ofsetler UTF-16 kod birimi sayıyor")
    func offsetsAreCountedInUTF16Units() {
        // "👍" tek Character, 2 UTF-16 birimi.
        #expect("👍".count == 1 && "👍".utf16.count == 2)
        #expect(WordBoundaries.toPreviousWordStart(before: "bir 👍") == -2)
        // ZWJ dizisi: tek Character, 8 UTF-16 birimi.
        let family = "👨‍👩‍👧"
        #expect(family.count == 1)
        #expect(WordBoundaries.toPreviousWordStart(before: "bir \(family)")
                == -family.utf16.count)
        #expect(WordBoundaries.currentWord(before: "a\(family)", after: "b")
                == (-(1 + family.utf16.count), 1))
    }

    /// Türkçe düz metinde iki birim **aynı** — emoji olmadan fark yok.
    @Test("Türkçe metinde UTF-16 ile grapheme aynı")
    func turkishTextIsUnaffectedByTheUnitChoice() {
        let s = "güzel şeyler"
        #expect(s.count == s.utf16.count)
        #expect(WordBoundaries.toPreviousWordStart(before: s) == -"şeyler".count)
    }

    // MARK: - Belgeye bağlı oturum

    private func session(before: String, after: String) -> CursorDragSession {
        CursorDragSession(before: before, after: after,
                          metrics: .init(axisLock: 10, wordStride: 20, charStride: 10))
    }

    @Test("Oturum mutlak hedefi uygulanacak farka çeviriyor")
    func theSessionTurnsTargetsIntoDeltas() {
        var s = session(before: "bir iki üç ", after: "")
        // Bir kelime geri: "üç " (3 birim) geriye.
        #expect(s.update(dx: -20, dy: 0) == -3)
        // İki kelime geri: mutlak -7, zaten -3 uygulandı → -4 fark.
        #expect(s.update(dx: -40, dy: 0) == -4)
        // Başa dönüş: mutlak 0, uygulanan -7 → +7.
        #expect(s.update(dx: 0, dy: 0) == 7)
    }

    /// **Kısmi karşılanma kendiliğinden düzeliyor.**
    ///
    /// Bağlam kırpılmışsa (host yalnız paragrafı veriyor) üç kelimelik istek
    /// pencerenin başında duruyor. Parmağı geri getirmek yine mutlak hedefe
    /// göre hesaplanıyor, yani imleç başlangıcı **aşmıyor**.
    @Test("Bağlam sınırına dayanan sürükleme başlangıcı aşmıyor")
    func clampedContextDoesNotOvershootOnTheWayBack() {
        var s = session(before: "tek", after: "")
        #expect(s.update(dx: -60, dy: 0) == -3, "üç kelime istendi, bir kelime var")
        #expect(s.update(dx: 0, dy: 0) == 3, "geri dönüş tam başlangıca")
    }

    /// Hedef üretmek hareket demek değil: belgenin başında sıfır ofset çıkıyor
    /// ve o jest bırakışta boşluk **yazmalı**.
    @Test("Sıfır ofset hareket sayılmıyor")
    func aZeroOffsetIsNotAMove() {
        var s = session(before: "", after: "")
        #expect(s.update(dx: -60, dy: 0) == 0)
        #expect(!s.didRequestMove, "hiç oynamayan jest boşluğu bastırdı")
    }

    @Test("Sıfır olmayan ofset hareket sayılıyor")
    func aNonZeroOffsetIsAMove() {
        var s = session(before: "bir iki", after: "")
        #expect(s.update(dx: -20, dy: 0) != 0)
        #expect(s.didRequestMove)
    }

    /// Dikey eksen oturumda da kelimeyi değiştirmiyor: sınırlar `before`/`after`
    /// okumasından geliyor.
    @Test("Oturumda dikey eksen kelimeyle sınırlı")
    func theSessionClampsVerticalToTheWord() {
        var s = session(before: "bir ka", after: "lem ve")
        // Kelime `kalem`: imlecin solunda 2, sağında 3 birim.
        #expect(s.update(dx: 0, dy: 500) == 3, "kelimenin sonuna kadar")
        #expect(s.update(dx: 0, dy: 900) == 0, "sınırda ikinci kez ilerledi")
        #expect(s.update(dx: 0, dy: -500) == -5, "sondan kelimenin başına")
    }

    @Test("Oturum eksen kilidini koruyor")
    func theSessionKeepsTheAxisLock() {
        var s = session(before: "bir iki üç ", after: "")
        _ = s.update(dx: -40, dy: 0)
        #expect(s.axis == .horizontal)
        #expect(s.update(dx: -40, dy: 300) == 0, "kilitli eksende dikey iş gördü")
    }
}
