/// Noktalama kümeleri — adlandırılmış, çünkü farklı işler **bilerek** farklı
/// kümeler kullanıyor; aynı karakter dizisi üç yerde ayrı ayrı yazılınca hangi
/// farkın kasıtlı olduğu okunmuyordu.
///
/// `KBGeometry`'de: öğrenme katmanı (`PersonalHistory`) da token sınırını aynı
/// kümelerden okuyor ve `KBLearning` çalışma anı katmanına bağımlı değil.
public enum Punctuation {
    /// Büyük harfi tetikleyen cümle sonu (`ShiftPolicy`). Dar: `:`/`;`/`…`
    /// sonrası küçük harfle devam etmek Türkçede olağan.
    public static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// Önceki kelimenin bağlamını (bigram) kesen karakterler (`InputCoordinator`).
    /// Cümle sonundan geniş: `…`, `:` ve `;` sonrasında bağlam da kopuyor.
    public static let contextBreakers: Set<Character> = [".", "!", "?", "…", ":", ";"]

    /// Token **ucundan** atılan noktalama (`akşam,` → `akşam`). Yalnız uçlar:
    /// `192.168.1.10`'un içindeki noktalar token'ın parçası.
    public static let tokenEdges: Set<Character> =
        [",", ".", "!", "?", ";", ":", "\"", "(", ")", "«", "»", "…"]

    /// `token`'ın iki ucundaki `tokenEdges` karakterleri atılmış hâli.
    public static func trimmingTokenEdges<S: StringProtocol>(_ token: S) -> Substring {
        var t = Substring(token)
        while let f = t.first, tokenEdges.contains(f) { t = t.dropFirst() }
        while let l = t.last, tokenEdges.contains(l) { t = t.dropLast() }
        return t
    }
}
