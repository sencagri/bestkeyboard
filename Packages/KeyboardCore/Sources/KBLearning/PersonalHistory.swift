import Foundation
import KBFoundation
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

    /// Transient undo evidence for a bounded live observation window. Never
    /// serialized: observation IDs themselves live only in the current process.
    private struct ObservationReceipt: Sendable {
        let key: String
        let previousKey: String?
        var tokenBefore: Stat?
        var tokenAfter: Stat?
        var pairBefore: Stat?
        var pairAfter: Stat?
        let sequence: UInt32
    }
    private var observationReceipts: [UUID: ObservationReceipt] = [:]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Transient receipt caches are not learned history or persistence state.
        lhs.tokens == rhs.tokens && lhs.pairs == rhs.pairs && lhs.seq == rhs.seq && lhs.pairTotal == rhs.pairTotal
    }


    public init() {}

    /// Natural words, including a typographic apostrophe between letters.
    /// A leading/trailing curly quote is prose punctuation, not part of a word.
    public static func isWord(_ s: String) -> Bool {
        guard !s.isEmpty, s.contains(where: \.isLetter) else { return false }
        for index in s.indices {
            let character = s[index]
            if character.isLetter || character == "'" || character == "-" { continue }
            let next = s.index(after: index)
            if character == "’", index != s.startIndex, next != s.endIndex,
               s[s.index(before: index)].isLetter, s[next].isLetter { continue }
            return false
        }
        return true
    }

    /// Recall technical tokens, including valid short compressed IPv6 addresses.
    public static func isRecallable(_ s: String) -> Bool {
        if s.count < 4 { return s.contains(":") && TechnicalTokenKind.classify(s) == .ipv6 }
        return !isWord(s) && s.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// Technical surfaces are case-sensitive identities (URL paths and email
    /// local parts in particular). Turkish folding is only for natural words.
    static func tokenKey(_ surface: String) -> String {
        let surface = emailWithoutProseSuffix(surface)
        if TechnicalTokenKind.classify(surface) == .phone,
           let normalized = TechnicalTokenKind.normalizedPhone(surface) { return normalized }
        return isRecallable(surface) ? technicalSearchKey(surface) : TurkishText.key(surface)
    }

    /// Fold only case-insensitive address components. Mailbox and URL path
    /// spelling stays exact; this also works on incomplete completion prefixes.
    static func technicalSearchKey(_ surface: String) -> String {
        let text = surface.precomposedStringWithCanonicalMapping
        if let scheme = text.range(of: "://") {
            let tail = text[scheme.upperBound...]
            let end = tail.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
            let authority = text[scheme.upperBound..<end]
            let hostStart = authority.lastIndex(of: "@").map { text.index(after: $0) } ?? scheme.upperBound
            return text[..<scheme.lowerBound].lowercased() + "://"
                + text[scheme.upperBound..<hostStart] + text[hostStart..<end].lowercased() + text[end...]
        }
        if let at = TechnicalTextSpan.emailSeparator(in: text) {
            return String(text[...at]) + text[text.index(after: at)...].lowercased()
        }
        if let colon = text.firstIndex(of: ":"),
           ["http", "https", "ftp", "ssh"].contains(text[..<colon].lowercased()),
           text[text.index(after: colon)...].allSatisfy({ $0 == "/" }) { return text.lowercased() }
        return text
    }

    private static func emailWithoutProseSuffix(_ raw: String) -> String {
        guard !raw.contains("://"), let at = TechnicalTextSpan.emailSeparator(in: raw) else { return raw }
        let domain = raw[raw.index(after: at)...]
        let trimmed = String(domain.reversed().drop(while: { ",.;:!?…。\"»”".contains($0) }).reversed())
        guard trimmed != domain else { return raw }
        let email = String(raw[...at]) + trimmed
        return TechnicalTokenKind.classify(email) == .email ? email : raw
    }

    static func admissible(_ s: String) -> Bool {
        // The Turkish pronoun is a complete word, not a stray one-key fragment.
        let singleLetterWord = TurkishText.key(s) == "o"
        guard (s.count >= PersonalLexicon.minLength || singleLetterWord), s.count <= maxTokenLength else { return false }
        if s.filter(\.isNumber).count <= maxDigits { return true }
        switch TechnicalTokenKind.classify(s) {
        case .ipv4, .ipv6, .phone: return true
        default: return false
        }
    }

    /// Bir metni token'lara böler — boşluk ve satır sonu; uç noktalama
    /// (`akşam,` → `akşam`) kelimelerden atılıyor ama `192.168.1.10`'un içi
    /// korunuyor (`Punctuation.tokenEdges`).
    public static func tokenize(_ text: String) -> [String] {
        guard let matcher = groupedTechnicalPattern else { return tokenizePlain(text) }
        let ns = text as NSString
        let matches = matcher.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var output: [String] = []
        var start = 0
        for match in matches {
            let surface = ns.substring(with: match.range)
            guard let kind = TechnicalTokenKind.classify(surface), kind == .phone || kind == .email else { continue }
            if kind == .email, match.range.location > 0,
               let previous = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: match.range.location - 1)).first,
               !previous.isWhitespace && !"([{`«“\"'".contains(previous) {
                // An opening mailbox quote is not a boundary when it is
                // attached to a path, identifier or another technical token.
                continue
            }
            if kind == .email, NSMaxRange(match.range) < ns.length,
               let next = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: NSMaxRange(match.range))).first,
               !next.isWhitespace && !",.;:!?…\"'”’»)]}`".contains(next) {
                // A regex match can end inside a longer technical expression.
                // Never learn that prefix as an independently observed address.
                continue
            }
            output += tokenizePlain(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            output.append(surface)
            start = NSMaxRange(match.range)
        }
        output += tokenizePlain(ns.substring(from: start))
        return output
    }

    private static let groupedTechnicalPattern = try? NSRegularExpression(pattern: #""(?:[^"\\\r\n]|\\[^\r\n])*"@(?:[\p{L}\p{N}](?:[\p{L}\p{M}\p{N}.\-]*[\p{L}\p{M}\p{N}])?|\[(?:[0-9.]+|[Ii][Pp][Vv]6:[0-9A-Fa-f:.]+)\])|(?<![\w+])\(?0[2-5](?:[ ().\-\u00a0]*[0-9]){9}(?![ ().\-\u00a0]*[0-9])|(?<![\w+])\+[1-9](?:[ ().\-\u00a0]*[0-9]){6,14}(?![ ().\-\u00a0]*[0-9])"#)

    /// Remove only explicit enclosing delimiters and punctuation outside them.
    /// Unwrapped URL tails remain untouched because their punctuation is valid
    /// address data. Limit nesting to keep malformed inputs bounded.
    private static func unwrappedAddress(_ surface: String) -> String? {
        func interior(_ input: Substring) -> Substring? {
            guard let opening = input.first else { return nil }
            let closing: Character
            switch opening {
            case "(": closing = ")"
            case "[": closing = "]"
            case "{": closing = "}"
            case "`": closing = "`"
            case "«": closing = "»"
            case "“": closing = "”"
            case "\"": closing = "\""
            case "'": closing = "'"
            default: return nil
            }
            var token = input
            while let last = token.last, ",.;:!?…".contains(last) { token = token.dropLast() }
            guard token.count >= 2, token.last == closing else { return nil }
            return token.dropFirst().dropLast()
        }
        var candidate = Substring(surface)
        var unwrapped = false
        for _ in 0..<8 {
            guard let inner = interior(candidate) else { break }
            candidate = inner
            unwrapped = true
        }
        // Peel all explicit layers before classifying. Some email parsers
        // accept Unicode quote characters in local/domain components.
        guard unwrapped, interior(candidate) == nil else { return nil }
        let address = String(candidate)
        guard let kind = TechnicalTokenKind.classify(address), kind == .url || kind == .email else { return nil }
        return address
    }

    private static func tokenizePlain(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { piece in
                var raw = String(piece)
                // Only paired prose wrappers are unambiguous. Preserve path
                // prefixes, URL query punctuation and quoted email local parts.
                if let address = Self.unwrappedAddress(raw) {
                    raw = address
                } else if let first = raw.first, let last = raw.last,
                   [("(", ")"), ("«", "»"), ("“", "”")].contains(where: { String(first) == $0.0 && String(last) == $0.1 }) {
                    raw = String(raw.dropFirst().dropLast())
                }
                raw = Self.emailWithoutProseSuffix(raw)
                // Colons at either end belong to a compressed IPv6 address.
                // Strip only unambiguous trailing prose punctuation before
                // classification, never the address's colon delimiters.
                var ipv6 = raw
                while let last = ipv6.last, ",.!?;…".contains(last) { ipv6.removeLast() }
                if TechnicalTokenKind.classify(ipv6) == .ipv6 { return ipv6 }
                let technical = raw.contains("/") || raw.contains("@")
                    || (raw.hasPrefix(".") && raw.contains(where: \.isLetter))
                guard !technical else { return raw }
                // Quotes can span several whitespace-delimited words. Strip
                // prose edges only when the interior is a natural word; never
                // apply this normalization to an address, path or code token.
                let proseEdges = Punctuation.tokenEdges.union(["'", "‘", "’", "“", "”"])
                func isProseEdge(_ character: Character) -> Bool {
                    proseEdges.contains(character) || character.unicodeScalars.allSatisfy {
                        switch $0.properties.generalCategory {
                        case .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation: return true
                        default: return false
                        }
                    }
                }
                let unquoted = String(raw.drop(while: isProseEdge)
                    .reversed().drop(while: isProseEdge).reversed())
                if raw.allSatisfy({ $0 == "`" || isProseEdge($0) }) { return "" }
                // Grouped addresses can leave their outer closing quote as a
                // separate fragment. It must not hide the last real token.
                if unquoted.isEmpty { return "" }
                if Self.isWord(unquoted) { return unquoted }
                return String(Punctuation.trimmingTokenEdges(raw))
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Gözlem

    /// Tek bir commit: `token` yazıldı, önünde `previous` vardı.
    public mutating func observe(token: String, previous: String?) {
        let token = Self.emailWithoutProseSuffix(token)
        guard Self.admissible(token) else { return }
        seq &+= 1
        let k = Self.tokenKey(token)
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
        for (k, st) in other.tokens.sorted(by: { ($0.value.seq, $0.key) < ($1.value.seq, $1.key) }) {
            seq &+= 1
            var cur = tokens[k] ?? Stat(count: 0, seq: seq, surface: st.surface)
            cur.count += st.count; cur.seq = seq; cur.surface = st.surface
            tokens[k] = cur
        }
        for (pk, row) in other.pairs.sorted(by: { $0.key < $1.key }) {
            var mine = pairs[pk] ?? [:]
            for (k, st) in row.sorted(by: { ($0.value.seq, $0.key) < ($1.value.seq, $1.key) }) {
                seq &+= 1
                if mine[k] == nil { pairTotal += 1 }
                var cur = mine[k] ?? Stat(count: 0, seq: seq, surface: st.surface)
                cur.count += st.count; cur.seq = seq; cur.surface = st.surface
                mine[k] = cur
            }
            pairs[pk] = mine
        }
        evict()
    }

    // Archive contributions share one logical clock. Aggregate rebuilding must
    // neither invent recency nor prune a partial sum between sources.
    var sequence: UInt32 { seq }
    mutating func advanceSequence(to value: UInt32) { seq = max(seq, value) }

    static func aggregate(_ histories: [PersonalHistory]) -> PersonalHistory {
        var result = PersonalHistory()
        func summed(_ old: Stat?, _ incoming: Stat) -> Stat {
            guard let old else { return incoming }
            let latest = (incoming.seq, incoming.surface) > (old.seq, old.surface) ? incoming : old
            return Stat(count: old.count + incoming.count, seq: max(old.seq, incoming.seq), surface: latest.surface)
        }
        for history in histories {
            result.seq = max(result.seq, history.seq)
            for (key, stat) in history.tokens { result.tokens[key] = summed(result.tokens[key], stat) }
            for (previous, row) in history.pairs {
                for (key, stat) in row {
                    result.pairs[previous, default: [:]][key] = summed(result.pairs[previous]?[key], stat)
                }
            }
        }
        result.pairTotal = result.pairs.values.reduce(0) { $0 + $1.count }
        result.evict()
        return result
    }

    /// Restore metadata as well as counts. Reverse order matters when several
    /// provisional occurrences touched the same word inside one quoted mailbox.
    public mutating func observe(_ event: HistoryObservation.Event) {
        for occurrence in event.retracting.reversed() { retract(occurrence.id) }
        let token = Self.emailWithoutProseSuffix(event.token)
        let key = Self.tokenKey(token)
        let previousKey = event.previous.flatMap {
            Self.isWord($0) && Self.isWord(token) ? Self.tokenKey($0) : nil
        }
        let tokenBefore = tokens[key]
        let pairBefore = previousKey.flatMap { pairs[$0]?[key] }
        observe(token: token, previous: event.previous)
        let tokenAfter = tokens[key]
        let pairAfter = previousKey.flatMap { pairs[$0]?[key] }
        guard tokenAfter != tokenBefore || pairAfter != pairBefore else { return }
        observationReceipts[event.id] = ObservationReceipt(key: key, previousKey: previousKey,
            tokenBefore: tokenBefore, tokenAfter: tokenAfter,
            pairBefore: pairBefore, pairAfter: pairAfter, sequence: seq)
        // More receipts than can fit in the 64-character observation span;
        // bounding by count also survives large intervening import sequences.
        if observationReceipts.count > Self.maxTokenLength * 2,
           let oldest = observationReceipts.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            observationReceipts.removeValue(forKey: oldest)
        }
    }

    /// Retract only live receipts; independent/imported evidence remains intact.
    @discardableResult
    public mutating func retract(_ occurrences: [HistoryObservation.Occurrence]) -> Bool {
        var changed = false
        for occurrence in occurrences.reversed() {
            if retract(occurrence.id) { changed = true }
        }
        return changed
    }

    @discardableResult
    private mutating func retract(_ id: UUID) -> Bool {
        guard let receipt = observationReceipts.removeValue(forKey: id) else { return false }
        func restored(_ current: Stat?, before: Stat?, applied: Stat?) -> Stat? {
            guard let applied, var current else { return current }
            if current == applied { return before }
            // A later legitimate update owns the newer display/sequence. Only
            // subtract our occurrence; forget/eviction invalidate its receipt.
            current.count -= 1
            return current.count > 0 ? current : nil
        }
        tokens[receipt.key] = restored(tokens[receipt.key], before: receipt.tokenBefore, applied: receipt.tokenAfter)
        if let previous = receipt.previousKey {
            let old = pairs[previous]?[receipt.key]
            let value = restored(old, before: receipt.pairBefore, applied: receipt.pairAfter)
            if old != nil && value == nil { pairTotal -= 1 }
            if old == nil && value != nil { pairTotal += 1 }
            if let value { pairs[previous, default: [:]][receipt.key] = value }
            else { pairs[previous]?.removeValue(forKey: receipt.key) }
            if pairs[previous]?.isEmpty == true { pairs.removeValue(forKey: previous) }
        }
        return true
    }

    private mutating func invalidateTokenReceipts(_ key: String, includingPairs: Bool) {
        for id in Array(observationReceipts.keys) {
            guard var receipt = observationReceipts[id] else { continue }
            if receipt.key == key { receipt.tokenBefore = nil; receipt.tokenAfter = nil }
            if includingPairs && (receipt.key == key || receipt.previousKey == key) {
                receipt.pairBefore = nil; receipt.pairAfter = nil
            }
            observationReceipts[id] = receipt.tokenAfter == nil && receipt.pairAfter == nil ? nil : receipt
        }
    }

    private mutating func invalidatePairReceipts(previous: String, key: String) {
        for id in Array(observationReceipts.keys) {
            guard var receipt = observationReceipts[id], receipt.key == key, receipt.previousKey == previous else { continue }
            receipt.pairBefore = nil; receipt.pairAfter = nil
            observationReceipts[id] = receipt.tokenAfter == nil ? nil : receipt
        }
    }

    public mutating func forget(_ surface: String) {
        let key = Self.tokenKey(surface)
        invalidateTokenReceipts(key, includingPairs: true)
        tokens.removeValue(forKey: key)
        pairs.removeValue(forKey: key)
        for previous in Array(pairs.keys) {
            pairs[previous]?.removeValue(forKey: key)
            if pairs[previous]?.isEmpty == true { pairs.removeValue(forKey: previous) }
        }
        pairTotal = pairs.values.reduce(0) { $0 + $1.count }
    }

    public mutating func clear() { self = PersonalHistory() }

    // MARK: - Teklifler

    public func nextWords(after previous: String, limit: Int = 3) -> [String] {
        guard let row = pairs[TurkishText.key(previous)] else { return [] }
        return row.values
            .sorted { ($0.count, $0.seq, $0.surface) > ($1.count, $1.seq, $1.surface) }
            .prefix(limit).map(\.surface)
    }

    /// Önekle başlayan hatırlanacak token'lar — önek en az 2 karakter.
    public func recall(prefix: String, limit: Int = 1) -> [String] {
        let p = Self.technicalSearchKey(prefix)
        guard p.count >= 2 else { return [] }
        let prefixIsRecallable = Self.isRecallable(p)
        return tokens.lazy
            .filter { $0.key.hasPrefix(p) && $0.key != p
                && (prefixIsRecallable || Self.isRecallable($0.value.surface)) }
            .map(\.value)
            .sorted { ($0.count, $0.seq, $0.surface) > ($1.count, $1.seq, $1.surface) }
            .prefix(limit).map(\.surface)
    }

    // MARK: - Kapasite

    private mutating func evict() {
        if tokens.count > Self.tokenCapacity {
            let drop = tokens.sorted { ($0.value.count, $0.value.seq, $0.key) < ($1.value.count, $1.value.seq, $1.key) }
                .prefix(tokens.count - Self.tokenCapacity).map(\.key)
            for k in drop { tokens[k] = nil; invalidateTokenReceipts(k, includingPairs: false) }
        }
        guard pairTotal > Self.pairCapacity else { return }
        var all: [(String, String, Stat)] = []
        for (pk, row) in pairs { for (k, st) in row { all.append((pk, k, st)) } }
        all.sort { ($0.2.count, $0.2.seq, $0.0, $0.1) < ($1.2.count, $1.2.seq, $1.0, $1.1) }
        for (pk, k, _) in all.prefix(pairTotal - Self.pairCapacity) {
            pairs[pk]?[k] = nil
            invalidatePairReceipts(previous: pk, key: k)
            if pairs[pk]?.isEmpty == true { pairs[pk] = nil }
            pairTotal -= 1
        }
    }

    enum CodingKeys: String, CodingKey { case tokens, pairs, seq }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try c.decode([String: Stat].self, forKey: .tokens)
        tokens = [:]
        // Migrate legacy folded keys from the retained surface. Previously
        // collapsed variants cannot be reconstructed, but future ones stay distinct.
        for (_, storedStat) in stored.sorted(by: { $0.key < $1.key }) {
            var stat = storedStat
            stat.surface = Self.emailWithoutProseSuffix(stat.surface)
            let key = Self.tokenKey(stat.surface)
            if let prior = tokens[key] {
                var merged = stat.seq >= prior.seq ? stat : prior
                merged.count = stat.count + prior.count
                tokens[key] = merged
            } else { tokens[key] = stat }
        }
        pairs = try c.decode([String: [String: Stat]].self, forKey: .pairs)
        seq = try c.decode(UInt32.self, forKey: .seq)
        pairTotal = pairs.values.reduce(0) { $0 + $1.count }
        evict()
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
        /// Export-provided chat/message identity; absent when the format cannot
        /// distinguish repeated identical messages safely.
        public let identity: String?
        public init(sender: String, text: String, identity: String? = nil) {
            self.sender = sender; self.text = text; self.identity = identity
        }
    }

    /// WhatsApp `.txt`: `[06.10.2026 17:34:12] Ad: mesaj` (iOS) ya da
    /// `06.10.2026 17:34 - Ad: mesaj` (Android). Devam satırları bir önceki
    /// mesaja ekleniyor; sistem satırları (`Ad: ‎<medya dahil edilmedi>`)
    /// atılıyor.
    public static func whatsApp(_ text: String) -> [Message] {
        let pattern = #"^\[?\d{1,2}[./]\d{1,2}[./]\d{2,4},? \d{1,2}:\d{2}(?::\d{2})?(?: ?[AP]M)?\]? ?(?:- )?([^:]{1,60}): (.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let header = try? NSRegularExpression(pattern: #"^\[?\d{1,2}[./]\d{1,2}[./]\d{2,4},? \d{1,2}:\d{2}"#)
        var out: [Message] = []
        var acceptsContinuation = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\u{200E}", with: "")
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let sender = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let body = ns.substring(with: m.range(at: 2))
                out.append(Message(sender: sender, text: body))
                acceptsContinuation = true
            } else if header?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                // A system event is a new record, never part of the previous sender's text.
                acceptsContinuation = false
            } else if acceptsContinuation, let last = out.last, !line.isEmpty {
                out[out.count - 1] = Message(sender: last.sender, text: last.text + "\n" + line)
            }
        }
        let mediaMarkers: Set<String> = ["<media omitted>", "image omitted", "video omitted",
            "audio omitted", "sticker omitted", "<medya dahil edilmedi>", "medya dahil edilmedi"]
        return out.filter { !mediaMarkers.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }

    /// Telegram Desktop `result.json`: `messages[].from` + `text` (dizgi ya
    /// da parça dizisi).
    public static func telegram(_ data: Data) -> [Message] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let chats = (root["chats"] as? [String: Any])?["list"] as? [[String: Any]]
        let chatRecords = chats ?? [root]
        let lists = chatRecords.map { $0["messages"] as? [[String: Any]] ?? [] }
        var identities: [String: Set<String>] = [:]
        for list in lists {
            for message in list {
                if let name = message["from"] as? String, let id = message["from_id"] as? String {
                    identities[name, default: []].insert(id)
                }
            }
        }
        var out: [Message] = []
        for (chatIndex, list) in lists.enumerated() {
            for m in list {
                guard m["type"] as? String != "service",
                      let from = m["from"] as? String else { continue }
                let text: String
                if let s = m["text"] as? String { text = s }
                else if let parts = m["text"] as? [Any] {
                    text = parts.map { ($0 as? String) ?? (($0 as? [String: Any])?["text"] as? String ?? "") }.joined()
                } else { continue }
                let sender: String
                if (identities[from]?.count ?? 0) > 1, let id = m["from_id"] as? String {
                    sender = from + " (" + id + ")"
                } else { sender = from }
                let identity: String?
                if let chatID = chatRecords[chatIndex]["id"], let messageID = m["id"] {
                    identity = "telegram:\(chatID):\(messageID)"
                } else { identity = nil }
                if !text.isEmpty { out.append(Message(sender: sender, text: text, identity: identity)) }
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
