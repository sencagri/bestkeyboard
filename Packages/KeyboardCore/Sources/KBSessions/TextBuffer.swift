import KBRuntime

/// Host'suz yeniden oynatmanın belge tamponu — yalnız **sona** yazan bir
/// `DocumentEditor`.
///
/// Host yok; kayıt zaten host'un ne yaptığını değil **bizim** ne yazdığımızı
/// ölçüyor. Seçim desteklenmiyor: §12 kaydında seçim türevi olgu bulunamıyor
/// (`selectedText` daima `nil`), dolayısıyla replay'in de seçime girmesi
/// gerekmiyor.
///
/// Golden replay ve dil önceli sondası aynı tamponu ayrı ayrı tanımlıyordu;
/// birinde bir davranış (örneğin boş belgede silme) değişseydi iki replay
/// aynı komut dizisinden farklı belgeler üretirdi.
final class TextBuffer: DocumentEditor {
    private(set) var text = ""

    init() {}

    func insertText(_ t: String) { text += t }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    var contextBeforeInput: String? { text }
    var contextAfterInput: String? { "" }
    var selectedText: String? { nil }
}
