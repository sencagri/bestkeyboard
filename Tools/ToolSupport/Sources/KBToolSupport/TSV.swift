import Foundation

/// TSV satırı: fiziksel satır numarası (1 tabanlı, hata mesajları için),
/// kenarlarındaki boşluk atılmış metin ve sekmeyle ayrılmış alanlar.
public struct TSVRecord: Sendable {
    public let line: Int
    public let text: String
    public let fields: [Substring]
}

/// Dil verisi TSV'leri — `kelime<TAB>sayım`, kök sözlüğü, genişletme haritası.
///
/// Okuma döngüsü üç araçta on bir kez ayrı yazılıyordu ve satırları farklı
/// kurallarla atlıyordu (biri kırpıyor, biri kırpmıyor; biri boş alanı
/// koruyor, biri atıyor). Yorum ve boş satır kuralı burada; satırın
/// **geçerliliği** (atla, listele, dur) çağıranın politikası olarak kalıyor.
public enum TSV {

    /// Dosyanın metni; okunamazsa `nil`.
    public static func text(at path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Boş ve `#` ile başlayan satırlar atılmış kayıtlar.
    ///
    /// - Parameter keepingEmptyFields: boş alanları koru. İsteğe bağlı
    ///   sütunları olan biçimler (kök sözlüğü) bunu istiyor: varsayılan
    ///   bölme boş alanı atınca sonraki sütun kayıyor ve okunuş `aorist`
    ///   sanılıyordu.
    public static func records(_ text: String, keepingEmptyFields: Bool = false) -> [TSVRecord] {
        var out: [TSVRecord] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            out.append(TSVRecord(line: i + 1, text: t,
                                 fields: t.split(separator: "\t",
                                                 omittingEmptySubsequences: !keepingEmptyFields)))
        }
        return out
    }

    /// `kelime<TAB>sayım` — tam iki alan ve sayısal sayım; değilse `nil`.
    public static func wordCount(_ r: TSVRecord) -> (word: String, count: Double)? {
        guard r.fields.count == 2, let c = Double(r.fields[1]) else { return nil }
        return (String(r.fields[0]), c)
    }

    /// Dosyadaki geçerli `kelime<TAB>sayım` çiftleri, **dosya sırasıyla**.
    /// Dosya okunamazsa boş; geçersiz satırlar atlanır.
    public static func wordCounts(at path: String) -> [(word: String, count: Double)] {
        guard let t = text(at: path) else { return [] }
        return records(t).compactMap(wordCount)
    }

    /// Sayıma göre azalan — en sık kelimeler en çok yazılan kelimelerdir,
    /// rastgele örneklem gerçek kullanımı temsil etmez.
    public static func wordsByFrequency(at path: String,
                                        limit: Int = .max) -> [(word: String, count: Double)] {
        Array(wordCounts(at: path).sorted { $0.count > $1.count }.prefix(limit))
    }
}
