import Foundation

/// Shift ve otomatik büyük harf politikası — plan §8.
///
/// Görünümden ayrı: çift dokunuşla caps-lock, tek harften sonra düşme ve
/// cümle başı otomatiği zamanlamaya bağlı ve `UIInputViewController` içinde
/// hiç test edilemezdi.
public struct ShiftPolicy: Sendable {

    public enum Mode: Equatable, Sendable {
        /// Küçük harf.
        case off
        /// Bir harf sonra düşer — normal shift.
        case oneShot
        /// Kilitli (çift dokunuş) — kullanıcı kapatana kadar sürer.
        case locked
    }

    public private(set) var mode: Mode = .off

    /// İki dokunuş bu süre içindeyse caps-lock.
    public var doubleTapWindow: Double = 0.35
    private var lastTapTime: Double?

    public init() {}

    public var isUppercase: Bool { mode != .off }

    // MARK: - Kullanıcı eylemleri

    /// Shift tuşuna dokunuldu.
    ///
    /// Kilitliyken tek dokunuş **kapatır** — kullanıcının kilidi bırakmasının
    /// tek yolu bu, çift dokunuş beklemek tuzak olurdu.
    public mutating func tapShift(at time: Double) {
        // Kilidi açan dokunuş zaman damgası **bırakmaz**: bıraksaydı hemen
        // sonraki tek dokunuş yeniden kilitlerdi ve kullanıcı kilitten
        // çıkamazdı (üç hızlı dokunuş kaza eseri olur).
        if mode == .locked { mode = .off; lastTapTime = nil; return }

        defer { lastTapTime = time }
        if let last = lastTapTime, time - last <= doubleTapWindow {
            mode = .locked
            return
        }
        mode = (mode == .oneShot) ? .off : .oneShot
    }

    /// Bir harf üretildi. `oneShot` burada düşer.
    public mutating func didEmitLetter() {
        if mode == .oneShot { mode = .off }
        // Kilitliyken hiçbir şey olmaz — kilidin anlamı bu.
        //
        // Çift dokunuş zinciri **kesilir**: araya harf girmişse iki shift
        // dokunuşu ardışık değildir. Kesilmeseydi `shift → harf → shift`
        // dizisi 0.35 sn içinde yanlışlıkla caps-lock açardı.
        lastTapTime = nil
    }

    /// Harf dışı girdi (sembol, boşluk, silme) de çift dokunuş zincirini keser.
    public mutating func didInterruptChain() {
        lastTapTime = nil
    }

    /// Otomatik büyük harf kararı — token sınırında çağrılır.
    ///
    /// Kilitliyi **bozmaz**: kullanıcı açıkça kilitlediyse otomatik mantık
    /// onu ezmemeli.
    public mutating func autoCapitalize(_ decision: Bool) {
        guard mode != .locked else { return }
        mode = decision ? .oneShot : .off
        lastTapTime = nil          // otomatik geçiş de zinciri keser
    }

    /// Kullanıcının açık kararını korumak için: shift'e elle dokunulduysa
    /// otomatik mantık o token boyunca devreye girmez.
    public mutating func reset() {
        mode = .off
        lastTapTime = nil
    }

    // MARK: - Otomatik büyük harf

    /// Ne zaman büyük harfle başlanmalı.
    public enum Autocapitalization: Sendable {
        case none
        case words
        case sentences
        case allCharacters
    }

    /// Verilen bağlamda sonraki harf büyük mü olmalı.
    ///
    /// Kural metinden okunur, sayaçtan değil: host metni bizim bilmediğimiz
    /// bir şekilde değiştirmiş olabilir (§8, tampon spekülatiftir).
    ///
    /// - Parameter context: imlecin **öncesindeki** metin.
    public static func shouldCapitalize(context: String?,
                                        type: Autocapitalization) -> Bool {
        switch type {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard let c = context, let last = c.last else { return true }
            return last.isWhitespace
        case .sentences:
            guard let c = context else { return true }
            // Sondaki boşlukları atlarken **satır sonu görüldü mü** ayrıca
            // izleniyor: satır sonu kendisi bir cümle sınırıdır, onu boşluk
            // gibi atıp öncesindeki harfe bakmak yanlıştı.
            var s = Substring(c)
            var sawSpace = false, sawNewline = false
            while let last = s.last, last.isWhitespace {
                if last.isNewline { sawNewline = true }
                s = s.dropLast()
                sawSpace = true
            }
            if sawNewline { return true }
            guard let last = s.last else { return true }        // metnin başı
            // Boşluk görülmediyse kelime ortasındayız.
            guard sawSpace else { return false }
            return Punctuation.sentenceTerminators.contains(last)
        }
    }
}
