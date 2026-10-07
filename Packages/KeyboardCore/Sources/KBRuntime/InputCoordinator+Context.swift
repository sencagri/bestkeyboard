import KBGeometry
import KBDecoder

// MARK: - Dil ve bağlam durumu

extension InputCoordinator.Engine {

    /// Bir sonraki token'ın puanlandığı **önceki token** durumu.
    ///
    /// Decoder ile literal kanalı bu durumun **ayrı kopyalarını** taşıyor ve
    /// `Δ = cost(literal) − cost(best)` ancak ikisi aynıyken anlamlı: dil
    /// geçiş cezası (`w_switch`) ya da bağlam terimi (`F_ctx`) yalnız bir tarafa
    /// uygulanırsa `Δ` sessizce kayar. Eşli yazım koordinatörün üç yöntemine ve
    /// `kbbench`'in dil önceli koluna dağılmıştı; tek setter onları birlikte
    /// değiştirmeyi **tek yol** yapıyor.
    public struct ContextState: Equatable, Sendable {
        /// Önceki token'ın dili — dil geçiş cezası buna bakıyor (§5b).
        public var previousLanguage: UInt8?
        /// Önceki token'ın kanonik yüzeyi; `nil` = bağlam bilinmiyor (§2
        /// öznitelik 13).
        public var word: String?

        public init(previousLanguage: UInt8? = nil, word: String? = nil) {
            self.previousLanguage = previousLanguage
            self.word = word
        }
    }

    /// Okuma decoder'dan; yazma **iki tarafa birden**.
    public var context: ContextState {
        get {
            ContextState(previousLanguage: decoder.languageModel.previous,
                         word: decoder.contextWord)
        }
        set {
            decoder.languageModel.previous = newValue.previousLanguage
            literalChannel.languageModel.previous = newValue.previousLanguage
            decoder.contextWord = newValue.word
            literalChannel.contextWord = newValue.word
        }
    }
}

extension InputCoordinator {

    mutating func remember(language: UInt8?) {
        guard let language else { return }
        engine?.context.previousLanguage = language
        rebuildIncremental()
    }

    /// Kapanan token bir sonrakinin **bağlamı** olur (§2 öznitelik 13).
    ///
    /// Yüzey kanonikleştiriliyor: paket küçük harfli yüzeyler taşıyor ve
    /// `Ali` ile `ali` aynı bağlam. `nil` = bağlam bilinmiyor; bağlamı
    /// "bilinmiyor" saymak, yanlış bir bağlamla puanlamaktan iyidir.
    ///
    /// **Token sınırında** uygulanıyor ve `IncrementalDecoder` kurulurken
    /// snapshot'lanıyor — token ortasında bağlam değişmez (§3 prefix-causality).
    mutating func remember(context word: String?) {
        guard engine?.decoder.bigrams != nil else { return }
        let ctx = word.flatMap { w -> String? in
            let c = TurkishText.key(w)
            return c.isEmpty ? nil : c
        }
        engine?.context.word = ctx
        rebuildIncremental()
    }

    /// Bağlamı **bilinmiyor** yapar: imleç oynadı, seçim değişti ya da belge
    /// bizim bilmediğimiz bir şekilde değişti. Eski bağlamı taşımak, artık
    /// orada olmayan bir kelimeyle puanlamak olurdu.
    mutating func forgetContext() {
        guard engine?.decoder.contextWord != nil else { return }
        engine?.context.word = nil
        rebuildIncremental()
    }

    /// Cümleyi bitiren noktalama.
    ///
    /// Liste dar tutuldu: virgül, tire, kesme işareti cümleyi bitirmiyor ve
    /// oralarda bağlam gerçekten devam ediyor. Şüphede kalınan her karakteri
    /// "bitirir" saymak, bağlamı çoğu yerde kapatıp özelliği işlevsiz kılardı.
    static func endsSentence(_ ch: Character) -> Bool {
        Punctuation.contextBreakers.contains(ch)
    }
}
