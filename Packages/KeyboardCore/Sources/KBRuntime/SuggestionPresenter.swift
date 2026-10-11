import KBLexicon
import KBDecoder
import KBLearning

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
        guard limit > 0 else { return [] }
        let decoded = shown.map(\.word)
        guard !typed.isEmpty else { return Array(decoded.prefix(limit)) }
        // İlk yuva daima yazılan yüzeyindir; sözlük/beam üyeliği gerekmez.
        let alternatives = decoded.filter { $0 != typed }
        let extras = (expansions?.expansions(of: typed) ?? [])
            .filter { $0 != typed && !alternatives.contains($0) }
        let remaining = limit - 1
        let reserved = min(extras.count, max(0, remaining - (alternatives.isEmpty ? 0 : 1)))
        return [typed] + Array(alternatives.prefix(remaining - reserved))
            + Array(extras.prefix(reserved))
    }

    /// Yüzeyleri **kimlik ve kaynaklarıyla** sınıflandırır.
    ///
    /// Yazılan yüzey açık onay; kalan yüzeyler decoder adayı veya genişletmedir.
    func suggestions(surfaces: [String], shown: [DecodeResult],
                     typed: String) -> [InputCoordinator.Suggestion] {
        let byWord = Dictionary(shown.map { ($0.word, $0) },
                                uniquingKeysWith: { a, _ in a })
        return surfaces.map { surface in
            if surface == typed {
                return .init(surface: surface, origin: .literal, id: "literal:" + surface)
            }
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

    func boundaryRepairs() -> [String] {
        guard !session.isDetached, let engine else { return [] }
        return WordBoundaryRepair.suggestions(for: session.literalSuggestionSurface,
                                               channel: engine.literalChannel,
                                               personalCost: { isKnownPersonalInflection($0) ? PersonalLexicon.lexCost : nil })
    }

    private func presentedSurfaces(shown: [DecodeResult], limit: Int) -> [String] {
        var surfaces = presenter.surfaces(shown: shown, typed: session.literalSuggestionSurface,
                                          expansions: engine?.expansions, limit: limit)
        if limit >= 2 {
            let repairs = boundaryRepairs().filter { $0 != session.literalSuggestionSurface }.prefix(limit - 1)
            if !repairs.isEmpty {
                // Keep both plausible boundaries when a stray letter is also a
                // valid suffix (seni+n vs senin). The original remains first.
                surfaces = Array(surfaces.filter { !repairs.contains($0) }.prefix(limit - repairs.count))
                surfaces.append(contentsOf: repairs)
            }
        }
        return surfaces
    }

    /// Gösterilecek adaylar — kazanandan çok geride kalanlar elenir.
    public func shownCandidates() -> [DecodeResult] {
        presenter.shown(candidates())
    }

    /// Öneri çubuğunda gösterilecek yüzeyler — `SuggestionPresenter.surfaces`.
    public func suggestionSurfaces(limit: Int = 3) -> [String] {
        presentedSurfaces(shown: shownCandidates(), limit: limit)
    }

    /// Gösterilen öneriler, kimlik ve kaynaklarıyla.
    public func suggestions(limit: Int = 3) -> [Suggestion] {
        let shown = shownCandidates()
        let surfaces = presentedSurfaces(shown: shown, limit: limit)
        return presenter.suggestions(surfaces: surfaces, shown: shown,
                                     typed: session.literalSuggestionSurface)
    }
}
