import KBLexicon
import KBDecoder

/// Öneri çubuğunun **içeriği** — decoder adaylarından ve genişletmelerden
/// kullanıcının gördüğü listeyi kuran saf kural.
///
/// Koordinatörün durumuna bakmıyor: adayları, yazılan yüzeyi ve genişletme
/// haritasını alıp listeyi döndürüyor. Kural tek yerde, çünkü listeyi iki
/// tüketici okuyor — UI (dokunulacak yüzeyler) ve kayıt (gösterilenlerin
/// anlık görüntüsü) — ve ikisi farklı listeye bakarsa kayıt kullanıcının
/// görmediği bir şeyi "gösterildi" diye yazar.
struct SuggestionPresenter {

    /// Kazanandan bu kadar geride kalan aday gösterilmez — **UI politikası**,
    /// skor sözleşmesinin parçası değil.
    var window: Double

    /// Gösterilecek adaylar — kazanandan çok geride kalanlar elenir.
    func shown(_ candidates: [DecodeResult]) -> [DecodeResult] {
        guard let best = candidates.first else { return [] }
        return candidates.filter { $0.cost - best.cost <= window }
    }

    /// Öneri çubuğunda gösterilecek **yüzeyler** — adaylar + genişletmeler.
    ///
    /// Genişletmeler (§4.D) listenin **sonuna** eklenir ve maliyet
    /// karşılaştırmasına girmez: onlar bir sıralama adayı değil, ayrı bir
    /// teklif. `slm` yazan kullanıcıya `selam` gösterilir ama `slm` kazanan
    /// olarak kalır.
    ///
    /// Otomatik uygulanmaları **imkânsız**: düzeltme kararı yalnız decoder
    /// adaylarına bakıyor ve `slm` gayrıresmî sözlükte olduğu için zaten
    /// `θ = ∞` alıyor (§8 bilinen kelime koruması). Yani kural iki bağımsız
    /// yerde tutuluyor.
    ///
    /// - Parameter typed: kullanıcının **yazdığı** yüzey. Genişletme oradan
    ///   aranır — düzeltilmiş adaydan değil. `slm` yazıp `selam` görmek
    ///   isteniyor; decoder'ın ürettiği bir şeyin açılımı değil.
    func surfaces(shown: [DecodeResult], typed: String,
                  expansions: ExpansionMap?, limit: Int) -> [String] {
        let decoded = shown.map(\.word)
        guard !typed.isEmpty, let expansions else {
            return Array(decoded.prefix(limit))
        }
        let extras = expansions.expansions(of: typed)
            .filter { !decoded.contains($0) }
        guard !extras.isEmpty else { return Array(decoded.prefix(limit)) }

        // Genişletmeye **ayrılmış slot**. Sona ekleyip `prefix(limit)`
        // uygulamak, üç decoder adayı pencere içinde kaldığında açılımı
        // tamamen kesiyordu: `.bkx` girdisi var ama kullanıcı hiç görmüyordu.
        let reserved = min(extras.count, max(0, limit - 1))
        return Array(decoded.prefix(limit - reserved)) + Array(extras.prefix(reserved))
    }

    /// Yüzeyleri **kimlik ve kaynaklarıyla** sınıflandırır.
    ///
    /// Aday listesinde olan yüzey adaydır; olmayan, yazılan yüzeyin
    /// genişletmesidir (§4.D) — ayrı bir teklif, sıralama adayı değil.
    func suggestions(surfaces: [String], shown: [DecodeResult],
                     typed: String) -> [InputCoordinator.Suggestion] {
        let byWord = Dictionary(shown.map { ($0.word, $0) },
                                uniquingKeysWith: { a, _ in a })
        return surfaces.map { surface in
            if let c = byWord[surface] {
                let id = InputCoordinator.candidateID(word: c.word, source: c.source)
                return .init(surface: surface, origin: .candidate(id: id), id: id)
            }
            return .init(surface: surface, origin: .expansion(trigger: typed),
                         id: InputCoordinator.expansionID(surface: surface))
        }
    }
}

// MARK: - Koordinatörün öneri yüzeyi

extension InputCoordinator {

    /// Gösterilen bir öneri — **kimliği ve kaynağıyla**.
    ///
    /// `suggestionSurfaces` yalnız `[String]` veriyordu ve UI dokunulan yüzey
    /// için `id = surface`, `origin = .candidate` **uyduruyordu**. Oysa ayrım
    /// motorun içinde zaten yapılıyor: `slm` yazıp `selam`'a dokunulduğunda
    /// gerçek olgu `id = "expansion:selam"`, origin genişletme ve tetikleyici
    /// `slm`. Kayıt bunun yerine aday kimliği yazıyordu ve metin doğru olduğu
    /// için hiçbir test görmüyordu.
    ///
    /// İki yerde sınıflandırmak zaten aynı hatanın ikinci kopyasıydı; tek
    /// kaynak `SuggestionPresenter`.
    public struct Suggestion: Equatable, Sendable {
        public let surface: String
        public let origin: SuggestionOrigin
        /// Kayda giren kimlik. Aday için `word#source`, genişletme için
        /// `expansion:<yüzey>` — `CandidateSnapshot.id` ile aynı üretim.
        public let id: String

        public init(surface: String, origin: SuggestionOrigin, id: String) {
            self.surface = surface; self.origin = origin; self.id = id
        }
    }

    /// Aday kimliğinin **tek** üretimi.
    public static func candidateID(word: String, source: UInt8) -> String {
        "\(word)#\(source)"
    }

    /// Genişletme kimliğinin **tek** üretimi.
    public static func expansionID(surface: String) -> String {
        "expansion:\(surface)"
    }

    var presenter: SuggestionPresenter { SuggestionPresenter(window: suggestionWindow) }

    public func candidates(topK: Int = 3) -> [DecodeResult] {
        guard let inc = incremental, !session.touches.isEmpty else { return [] }
        return inc.results(topK: topK)
    }

    /// Gösterilecek adaylar — kazanandan çok geride kalanlar elenir.
    public func shownCandidates() -> [DecodeResult] {
        presenter.shown(candidates())
    }

    /// Öneri çubuğunda gösterilecek yüzeyler — `SuggestionPresenter.surfaces`.
    public func suggestionSurfaces(limit: Int = 3) -> [String] {
        presenter.surfaces(shown: shownCandidates(), typed: session.display,
                           expansions: engine?.expansions, limit: limit)
    }

    /// Gösterilen öneriler, kimlik ve kaynaklarıyla.
    public func suggestions(limit: Int = 3) -> [Suggestion] {
        let shown = shownCandidates()
        let surfaces = presenter.surfaces(shown: shown, typed: session.display,
                                          expansions: engine?.expansions,
                                          limit: limit)
        return presenter.suggestions(surfaces: surfaces, shown: shown,
                                     typed: session.display)
    }
}
