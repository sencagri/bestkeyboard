import Foundation
import KBLearning

/// Yazma geçmişinin deposu — uzantı sandbox'ı, JSON.
///
/// Uygulamadaki içe aktarma (WhatsApp, Telegram) ortak klasöre bir **bekleyen**
/// dosya bırakıyor; klavye açılışta onu kendi geçmişine katıp siliyor. Tek
/// yazar yine klavye: kişisel sözlük ve kalibrasyonla aynı ilke.
enum PersonalHistoryStore {
    static var url: URL? { LocalStore.url(LocalStore.Name.history) }

    static func load() -> PersonalHistory {
        var h = JSONFile.read(PersonalHistory.self, at: url) ?? PersonalHistory()
        if let imported = claimImport() {
            h.merge(imported)
            save(h)
        }
        return h
    }

    static func save(_ h: PersonalHistory) {
        JSONFile.write(h, to: url, protected: true)
    }

    /// Uygulamanın bıraktığı içe aktarmayı sahiplenir — uygulamanın yazmasıyla
    /// aynı kilit altında (yarıda okunup iki kez katılmasın).
    private static func claimImport() -> PersonalHistory? {
        guard KeyboardSettingsStore.sharingAllowed else { return nil }
        let data = AppGroup.withLock(AppGroup.File.historyImport) { AppGroup.claim(AppGroup.File.historyImport) }
        return data.flatMap { $0 }.flatMap { try? JSONDecoder().decode(PersonalHistory.self, from: $0) }
    }
}

/// Yazma geçmişi (sonraki kelime, hatırlama) — gözlem, tahmin ve kayıt.
///
/// Kelime bitince son iki token öğreniliyor. Kaynak belge: düzeltme
/// uygulanmışsa son hâli öğreniliyor, kullanıcının yazdığı ham dokunmalar değil.
final class TypingHistory {
    /// Bu kadar gözlemde bir diske yazılıyor (her kelimede yazmak pahalı).
    private static let saveEvery = 20

    private lazy var history = PersonalHistoryStore.load()
    private var lastObserved: (token: String, previous: String?, length: Int)?
    private var unsaved = 0

    /// `before`: imleçten önceki metin; boşlukla bitmiyorsa kelime bitmemiş.
    func observe(before: String) {
        guard let lastChar = before.last, lastChar.isWhitespace else { return }
        let toks = PersonalHistory.tokenize(before)
        guard let token = toks.last else { return }
        let prev = toks.count >= 2 ? toks[toks.count - 2] : nil
        // Aynı sınır birden çok kez bildirilebiliyor; bir kez say.
        if let l = lastObserved, l.token == token, l.previous == prev, l.length == before.count { return }
        lastObserved = (token, prev, before.count)
        history.observe(token: token, previous: prev)
        unsaved += 1
        if unsaved >= Self.saveEvery { flush() }
    }

    /// Bir metnin tamamından öğrenir (alandan içe aktarma).
    func ingest(text: String) {
        history.observe(text: text)
        unsaved += 1
        flush()
    }

    func flush() {
        guard unsaved > 0 else { return }
        PersonalHistoryStore.save(history)
        unsaved = 0
    }

    /// Boşlukla biten metinden sonra gelebilecek kelimeler.
    func nextWords(before: String) -> [String] {
        guard before.last == " ", let prev = PersonalHistory.tokenize(before).last,
              PersonalHistory.isWord(prev) else { return [] }
        return history.nextWords(after: prev)
    }

    /// Yazılan önekle başlayan, daha önce yazılmış tam token (IP, e-posta…).
    /// Önek geçmişin sakladığı biçimde: uç noktalama atılmış ("(192.16" → "192.16").
    func recall(lastToken raw: String) -> (prefix: String, full: String)? {
        guard let last = PersonalHistory.tokenize(raw).last, raw.hasSuffix(last),
              let full = history.recall(prefix: last).first else { return nil }
        return (last, full)
    }
}
