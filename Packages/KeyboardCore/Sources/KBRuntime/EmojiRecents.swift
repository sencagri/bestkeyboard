import Foundation

/// Son kullanılan emoji — **en son kullanılan başta**.
///
/// Kişisel sözlükten (§8.7) ayrı bir şey ve öyle kalmalı: orada saklanan
/// kullanıcının **kelimeleri** ve karar modeline giriyor; burada saklanan bir
/// UI kolaylığı ve hiçbir maliyete dokunmuyor. İkisini aynı depoya koymak, bir
/// gizlilik sınıfını diğerine karıştırmak olurdu.
public struct EmojiRecents: Equatable, Sendable {

    /// Bir ızgara satırı 8 emoji; üç satır hem yeterli hem de sekmeyi
    /// kaydırmadan görünüyor.
    public static let capacity = 24

    public private(set) var items: [String]

    public init(items: [String] = []) {
        // Depodan gelen liste bozuk olabilir: tekrarlar düşürülüyor ve sınır
        // uygulanıyor. Bozuk bir listeyi olduğu gibi kabul etmek, `use`'un
        // koruduğu değişmezleri yükleme yolunda delerdi.
        var seen = Set<String>()
        var out: [String] = []
        for e in items where seen.insert(e).inserted {
            out.append(e)
            if out.count == Self.capacity { break }
        }
        self.items = out
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Kullanılan emoji'yi başa alır.
    /// - Returns: liste değiştiyse `true` (çağıran diske yazsın).
    @discardableResult
    public mutating func use(_ emoji: String) -> Bool {
        // Tek grapheme değilse listeye girmiyor: ızgara tek hücrede tek şey
        // gösteriyor ve iki grapheme'lik bir girdi hücreyi taşırırdı.
        guard emoji.count == 1 else { return false }
        let before = items
        items.removeAll { $0 == emoji }
        items.insert(emoji, at: 0)
        if items.count > Self.capacity { items.removeLast(items.count - Self.capacity) }
        return items != before
    }

    public mutating func removeAll() { items.removeAll() }
}
