import Foundation
import KBRuntime

/// Belge taklidi.
///
/// `insertText`/`deleteBackward` üzerinden bir metin tutar; `contextBeforeInput`
/// gerçek `UITextDocumentProxy` gibi imlecin **öncesini** döndürür. Testler
/// belgeyi doğrudan yazmaz — yalnız oturumun ürettiği düzenlemelerle değişir,
/// yoksa test kendi kendini doğrulardı.
final class FakeDocument: DocumentEditor {
    private(set) var text: String = ""
    /// Host'un yaptığı, bizim bilmediğimiz değişiklik.
    /// Seçim de düşüyor: eski aralık yeni metinde geçersiz bir indeks olurdu.
    func hostRewrites(to s: String) { text = s; selection = nil }

    func insertText(_ t: String) {
        // Seçim varken `insertText` seçimi DEĞİŞTİRİR — gerçek proxy böyle.
        if let r = selection {
            text.replaceSubrange(r, with: t)
            selection = nil
        } else {
            text.insert(contentsOf: t, at: cursor)
        }
    }
    func deleteBackward() {
        if let r = selection {
            // Seçim varken silme **seçimin tamamını** siler.
            text.removeSubrange(r)
            selection = nil
        } else if cursor > text.startIndex {
            text.remove(at: text.index(before: cursor))
        }
    }

    /// Seçim bir **aralık**, metin değil: metinle modellemek "aynı kelime iki
    /// kez geçiyor" sorununu gizlerdi — testin yakalaması gereken şey tam da o.
    private var selection: Range<String.Index>?
    private var cursor: String.Index { selection?.lowerBound ?? text.endIndex }

    var contextBeforeInput: String? {
        let full = String(text[text.startIndex..<cursor])
        guard contextWindow > 0, full.count > contextWindow else { return full }
        return String(full.suffix(contextWindow))
    }
    var contextAfterInput: String? {
        String(text[(selection?.upperBound ?? text.endIndex)...])
    }
    var selectedText: String? { selection.map { String(text[$0]) } }

    /// `occurrence`: kaçıncı geçtiği yer seçilsin (0 tabanlı).
    func hostSelects(_ s: String, occurrence: Int = 0) {
        var searchStart = text.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            guard let r = text.range(of: s, range: searchStart..<text.endIndex) else {
                found = nil; break
            }
            found = r
            searchStart = r.upperBound
        }
        selection = found
    }
    func hostClearsSelection() { selection = nil }

    /// `documentContextBeforeInput`'ın **sınırlı** olduğu durum.
    ///
    /// Gerçek `UITextDocumentProxy` belgenin tamamını vermek zorunda değil; uzun
    /// bir denemede pencere kısalıyor. Sıfır = sınırsız.
    var contextWindow = 0
}
