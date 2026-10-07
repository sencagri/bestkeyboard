/// Belgeye yazma yeteneği — `UITextDocumentProxy`'nin bu oturumun ihtiyaç
/// duyduğu kadarı.
///
/// Protokol olmasının sebebi test edilebilirlik değil sadece; **metnin sahibi
/// host'tur** (plan §8) ve oturum ona yalnız bu üç kanaldan dokunabilir.
/// Genişlerse §8 uzlaştırmasının kapsamı da genişler — dar tutuluyor.
public protocol DocumentEditor: AnyObject {
    func insertText(_ text: String)
    func deleteBackward()
    var contextBeforeInput: String? { get }
    /// Kullanıcının seçtiği metin, seçim yoksa `nil`.
    ///
    /// iOS bunu `UITextDocumentProxy.selectedText` ile veriyor. **Metni**
    /// veriyor, dokunma koordinatını değil — o yüzden seçilen kelimenin
    /// uzamsal kanıtı ancak *biz yazdıysak* ve geçmişte duruyorsa bulunur.
    var selectedText: String? { get }
    /// Seçimin (ya da imlecin) **sonrasındaki** metin.
    ///
    /// Seçimin belgedeki konumunu doğrulamak için gerekli: yüzey tek başına
    /// hangi geçtiği yeri seçtiğimizi söylemez.
    var contextAfterInput: String? { get }
}
