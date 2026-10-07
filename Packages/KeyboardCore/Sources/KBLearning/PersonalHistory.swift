import Foundation
import KBGeometry

/// Kullanıcının yazma geçmişinden **öneri** — kod çözmeye girmiyor.
///
/// ## Neden skor modelinin dışında
///
/// Sözleşmenin bağlam terimi (`F_ctx`, §2 öznitelik 13) bir **paket** bigramı
/// bekliyor ve verisi yok. Kişisel sayımları oraya koymak, kendi toplamına
/// normalize edilmiş bir sayımı paket ölçeğiyle karşılaştırmak olurdu —
/// `PersonalLexicon.lexCost`'un gerekçesinde çürütülen hatanın aynısı. Bu
/// yüzden geçmiş yalnız **öneri çubuğuna teklif** üretiyor (genişletmeler
/// gibi, §4.D): otomatik düzeltme yapmıyor, hiçbir adayın maliyetini
/// değiştirmiyor.
///
/// İki teklif:
/// - **Sonraki kelime** — boşluktan sonra, önceki kelimeden sonra en sık
///   yazılanlar ("dün" → "akşam").
/// - **Hatırlama** — harf dışı karakter taşıyan token'lar (IP, e-posta,
///   adres, kullanıcı adı): yazılan öneke göre. Düz kelimeleri decoder zaten
///   tamamlıyor; boşluk bunlar.
///
/// ## Ne saklanmıyor
///
/// Metnin kendisi değil, token ve çift sayımları. 12'den fazla rakam taşıyan
/// token (kart, IBAN, kimlik numarası) hiç girmiyor. Saat yok; yaş bir sıra
/// numarası (`PersonalLexicon` ile aynı gerekçe).
public struct PersonalHistory: Codable, Equatable, Sendable {

    public struct Stat: Codable, Equatable, Sendable {
        public var count: Int
        public var seq: UInt32
        /// Son görülen yazılış — anahtar küçük harf, gösterilen bu.
        public var surface: String
    }

    public static let tokenCapacity = 3000
    public static let pairCapacity = 8000
    public static let maxTokenLength = 64
    public static let maxDigits = 12

    public private(set) var tokens: [String: Stat] = [:]
    /// önceki kelime anahtarı → sonraki kelime anahtarı → sayım
    public private(set) var pairs: [String: [String: Stat]] = [:]
    private var seq: UInt32 = 0
    private var pairTotal = 0

    public init() {}

    /// Kelime mi — yalnız harf (ve `'`, `-`: `sql'leri`, `e-posta`).
    public static func isWord(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
            && s.contains(where: \.isLetter)
    }

    /// Hatırlanacak token mu — harf dışı karakter taşıyan, en az 4 karakter.
    public static func isRecallable(_ s: String) -> Bool {
        s.count >= 4 && !isWord(s) && s.contains(where: { $0.isLetter || $0.isNumber })
    }

    static func admissible(_ s: String) -> Bool {
        // Alt sınır kişisel sözlükle **aynı**: tek harfli yüzey öğrenilmiyor.
        guard s.count >= PersonalLexicon.minLength, s.count <= maxTokenLength else { return false }
        return s.filter(\.isNumber).count <= maxDigits
    }

    /// Bir metni token'lara böler — boşluk ve satır sonu; uç noktalama
    /// (`akşam,` → `akşam`) kelimelerden atılıyor ama `192.168.1.10`'un içi
    /// korunuyor (`Punctuation.tokenEdges`).
    public static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { String(Punctuation.trimmingTokenEdges($0)) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Gözlem

    /// Tek bir commit: `token` yazıldı, önünde `previous` vardı.
    public mutating func observe(token: String, previous: String?) {
        guard Self.admissible(token) else { return }
        seq &+= 1
        let k = TurkishText.key(token)
        if Self.isRecallable(token) || Self.isWord(token) {
            var st = tokens[k] ?? Stat(count: 0, seq: seq, surface: token)
            st.count += 1; st.seq = seq; st.surface = token
            tokens[k] = st
        }
        if let p = previous, Self.isWord(p), Self.isWord(token) {
            let pk = TurkishText.key(p)
            var row = pairs[pk] ?? [:]
            if row[k] == nil { pairTotal += 1 }
            var st = row[k] ?? Stat(count: 0, seq: seq, surface: token)
            st.count += 1; st.seq = seq; st.surface = token
            row[k] = st
            pairs[pk] = row
        }
        evict()
    }

    /// Toplu metin (içe aktarma, "bu alandan öğren").
    public mutating func observe(text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            var prev: String?
            for t in Self.tokenize(String(line)) {
                observe(token: t, previous: prev)
                prev = t
            }
        }
    }

    public mutating func merge(_ other: PersonalHistory) {
        for (k, st) in other.tokens {
            seq &+= 1
            var cur = tokens[k] ?? Stat(count: 0, seq: seq, surface: st.surface)
            cur.count += st.count; cur.seq = seq
            tokens[k] = cur
        }
        for (pk, row) in other.pairs {
            var mine = pairs[pk] ?? [:]
            for (k, st) in row {
                seq &+= 1
                if mine[k] == nil { pairTotal += 1 }
                var cur = mine[k] ?? Stat(count: 0, seq: seq, surface: st.surface)
                cur.count += st.count; cur.seq = seq
                mine[k] = cur
            }
            pairs[pk] = mine
        }
        evict()
    }

    public mutating func clear() { self = PersonalHistory() }

    // MARK: - Teklifler

    public func nextWords(after previous: String, limit: Int = 3) -> [String] {
        guard let row = pairs[TurkishText.key(previous)] else { return [] }
        return row.values
            .sorted { ($0.count, $0.seq) > ($1.count, $1.seq) }
            .prefix(limit).map(\.surface)
    }

    /// Önekle başlayan hatırlanacak token'lar — önek en az 2 karakter.
    public func recall(prefix: String, limit: Int = 1) -> [String] {
        let p = TurkishText.key(prefix)
        guard p.count >= 2 else { return [] }
        return tokens.lazy
            .filter { $0.key.hasPrefix(p) && $0.key != p && Self.isRecallable($0.value.surface) }
            .map(\.value)
            .sorted { ($0.count, $0.seq) > ($1.count, $1.seq) }
            .prefix(limit).map(\.surface)
    }

    // MARK: - Kapasite

    private mutating func evict() {
        if tokens.count > Self.tokenCapacity {
            let drop = tokens.sorted { ($0.value.count, $0.value.seq) < ($1.value.count, $1.value.seq) }
                .prefix(tokens.count - Self.tokenCapacity).map(\.key)
            for k in drop { tokens[k] = nil }
        }
        guard pairTotal > Self.pairCapacity else { return }
        var all: [(String, String, Stat)] = []
        for (pk, row) in pairs { for (k, st) in row { all.append((pk, k, st)) } }
        all.sort { ($0.2.count, $0.2.seq) < ($1.2.count, $1.2.seq) }
        for (pk, k, _) in all.prefix(pairTotal - Self.pairCapacity) {
            pairs[pk]?[k] = nil
            if pairs[pk]?.isEmpty == true { pairs[pk] = nil }
            pairTotal -= 1
        }
    }

    enum CodingKeys: String, CodingKey { case tokens, pairs, seq }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decode([String: Stat].self, forKey: .tokens)
        pairs = try c.decode([String: [String: Stat]].self, forKey: .pairs)
        seq = try c.decode(UInt32.self, forKey: .seq)
        pairTotal = pairs.values.reduce(0) { $0 + $1.count }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(pairs, forKey: .pairs)
        try c.encode(seq, forKey: .seq)
    }
}

/// Sohbet dışa aktarımlarından **yalnız kullanıcının** satırları.
public enum ChatExportParser {
    public struct Message: Equatable, Sendable {
        public let sender: String
        public let text: String
        public init(sender: String, text: String) { self.sender = sender; self.text = text }
    }

    /// WhatsApp `.txt`: `[06.10.2026 17:34:12] Ad: mesaj` (iOS) ya da
    /// `06.10.2026 17:34 - Ad: mesaj` (Android). Devam satırları bir önceki
    /// mesaja ekleniyor; sistem satırları (`Ad: ‎<medya dahil edilmedi>`)
    /// atılıyor.
    public static func whatsApp(_ text: String) -> [Message] {
        let pattern = #"^\[?\d{1,2}[./]\d{1,2}[./]\d{2,4},? \d{1,2}:\d{2}(?::\d{2})?(?: ?[AP]M)?\]? ?(?:- )?([^:]{1,60}): (.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [Message] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\u{200E}", with: "")
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let sender = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let body = ns.substring(with: m.range(at: 2))
                out.append(Message(sender: sender, text: body))
            } else if let last = out.last, !line.isEmpty {
                out[out.count - 1] = Message(sender: last.sender, text: last.text + "\n" + line)
            }
        }
        return out.filter { !$0.text.hasPrefix("<") && !$0.text.contains("omitted") && !$0.text.contains("dahil edilmedi") }
    }

    /// Telegram Desktop `result.json`: `messages[].from` + `text` (dizgi ya
    /// da parça dizisi).
    public static func telegram(_ data: Data) -> [Message] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let chats = (root["chats"] as? [String: Any])?["list"] as? [[String: Any]]
        let lists = chats?.compactMap { $0["messages"] as? [[String: Any]] } ?? [root["messages"] as? [[String: Any]] ?? []]
        var out: [Message] = []
        for list in lists {
            for m in list {
                guard let from = m["from"] as? String else { continue }
                let text: String
                if let s = m["text"] as? String { text = s }
                else if let parts = m["text"] as? [Any] {
                    text = parts.map { ($0 as? String) ?? (($0 as? [String: Any])?["text"] as? String ?? "") }.joined()
                } else { continue }
                if !text.isEmpty { out.append(Message(sender: from, text: text)) }
            }
        }
        return out
    }

    /// Gönderenler, en çok yazandan aza — kullanıcı kendini seçsin.
    public static func senders(_ messages: [Message]) -> [String] {
        var c: [String: Int] = [:]
        for m in messages { c[m.sender, default: 0] += 1 }
        return c.sorted { $0.value > $1.value }.map(\.key)
    }
}
