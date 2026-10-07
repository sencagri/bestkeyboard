import KBFoundation
import KBGeometry

extension InputCoordinator {

    /// Token sınırında **fiilen ne olduğu** — teşhis ve tekrarlanabilir test için.
    ///
    /// ## Neden döndürülüyor
    ///
    /// Bu alanların hepsi `space()` içinde **zaten hesaplanıyordu ve atılıyordu**.
    /// Sözleşme §12.1 iki şey istiyor: klavyenin hangi kararı neden verdiğini
    /// görebilmek, ve kaydedilen gerçek yazımı sonraki değişikliklere karşı
    /// yeniden oynatabilmek. İkisi de bu bilgi olmadan kurulamıyor.
    ///
    /// ## Neden dışarıda yeniden hesaplanmıyor
    ///
    /// Karar `CorrectionPolicy`'de ve koordinatör onu **tek** yerden çağırıyor.
    /// Kararı çağıranın yeniden hesaplaması **tek karar noktası** disiplinini
    /// bozar: iki yerde hesaplanan bir eşik sessizce ayrışır ve §8.1'de bu
    /// hatanın bedeli zaten kayıtlı.
    ///
    /// ## Neden `committed != literal` yetmez
    ///
    /// Büyük harf de farkı üretir: `Ali` yazılırken literal `ali`, display `Ali`
    /// olur ama **hiçbir düzeltme yoktur**. `kind` bu ikisini ayırır.
    public struct TokenCommitReport: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// Kullanıcının bastığı harfler aynen commit edildi.
            case literal
            /// `Δ > θ` — otomatik düzeltme uygulandı.
            case autocorrect
            /// Kullanıcı öneri çubuğundan bir **aday** seçti.
            case suggestion
            /// Kullanıcı bir **genişletme** seçti (§4.D): `slm → selam`.
            ///
            /// Adaydan ayrı: sıralama kararı değil, kısaltma açılımı. Şemada
            /// zaten ayrı bir tür vardı ama runtime onu hiç üretmiyordu, yani
            /// kayıt genişletmeyi aday seçimi diye anlatıyordu.
            case expansion
            /// Boş token (art arda boşluk gibi).
            case empty
        }

        public var kind: Kind
        /// Kullanıcının **fiilen bastığı** harfler.
        public var literal: String
        /// Token sınırından hemen önce belgede duran metin.
        public var displayBefore: String
        /// Belgeye yazılan nihai metin.
        public var committed: String
        /// `cost(literal) − cost(best)`; karar verilemediyse `nil`.
        public var delta: Double?
        /// O anki eşik; karar verilemediyse `nil`.
        public var theta: Double?
        /// En iyi adayın maliyeti — `delta`'nın hangi adaydan geldiğini sabitler.
        public var bestCost: Double?
        public var bestWord: String?
        public var language: UInt8?
        /// Bu token'a ait dokunma sayısı (kayıtta dokunmalarla eşlemek için).
        public var touchCount: Int
        /// Büyük harf biçimi uygulandı mı — `kind` ile karıştırılmasın diye ayrı.
        public var casingApplied: Bool
        /// Kapanan token'ın kimliği; boş token'da `nil`.
        ///
        /// Yıkıcı etkiler bu kimliğe atıf yapıyor. "Son token" ifadesi art arda
        /// silmede belirsiz: iki `deleteWord` üst üste geldiğinde ikisi de
        /// sonuncuyu işaretliyordu.
        public var tokenID: TokenID?

        /// Sınır işleminin kanıta **fiilen** ne yaptığı.
        ///
        /// Çağıranın `.boundary` varsayması yanlıştı: kanıtı kopmuş bir
        /// oturumda `pickSuggestion` gerçek bir no-op ve kanıt `detached`
        /// kalıyor. Çağıran `.boundary` yazarsa kayda `evidenceStateAfter:
        /// .cleared` girer ve reducer kopukluktan çıkıldığını sanıp sonraki
        /// harfleri toplamaya başlar; durumu oturumdan **okumaya** çalışırsa da
        /// §6.2'nin yasakladığı çıkarımı yapmış olur.
        public var effect: DestructiveEffect

        public static func empty(literal: String = "") -> TokenCommitReport {
            .init(kind: .empty, literal: literal, displayBefore: "", committed: "",
                  delta: nil, theta: nil, bestCost: nil, bestWord: nil, language: nil,
                  touchCount: 0, casingApplied: false, tokenID: nil,
                  effect: .boundary)
        }

        /// Hiçbir şey olmadı — kanıt durumu **olduğu gibi** kalıyor.
        public static func noOp(evidence: DestructiveEffect.EvidenceState)
            -> TokenCommitReport {
            .init(kind: .empty, literal: "", displayBefore: "", committed: "",
                  delta: nil, theta: nil, bestCost: nil, bestWord: nil, language: nil,
                  touchCount: 0, casingApplied: false, tokenID: nil,
                  effect: .init(pending: .none, deleted: [],
                                evidenceStateAfter: evidence))
        }
    }

    /// Commit'te **yalnız büyük harf** mi farklı — `Ali` yazarken literal
    /// `ali`, display `Ali`: fark var ama düzeltme yok.
    ///
    /// Commit yolları bunu ayrı ayrı ve locale'siz hesaplıyordu; `İstanbul` ↔
    /// `istanbul` locale'siz karşılaştırmada farklı çıkıyor (`İ` iki skalere
    /// açılıyor) ve olgu tam Türkçe harfte yanlış kaydediliyordu.
    static func casingApplied(committed: String, literal: String) -> Bool {
        committed != literal && TurkishText.equalIgnoringCase(committed, literal)
    }
}
