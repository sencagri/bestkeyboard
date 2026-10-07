/// Noktalama kümeleri — adlandırılmış, çünkü farklı işler **bilerek** farklı
/// kümeler kullanıyor; aynı karakter dizisi üç yerde ayrı ayrı yazılınca hangi
/// farkın kasıtlı olduğu okunmuyordu.
public enum Punctuation {
    /// Büyük harfi tetikleyen cümle sonu (`ShiftPolicy`). Dar: `:`/`;`/`…`
    /// sonrası küçük harfle devam etmek Türkçede olağan.
    public static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// Önceki kelimenin bağlamını (bigram) kesen karakterler (`InputCoordinator`).
    /// Cümle sonundan geniş: `…`, `:` ve `;` sonrasında bağlam da kopuyor.
    public static let contextBreakers: Set<Character> = [".", "!", "?", "…", ":", ";"]
}
