import Foundation
import KBDecoder
import KBRuntime

/// Motorun ürettiği olgulardan **kayıt parçalarını** kuran saf dönüşümler.
///
/// Kaydedicinin (`RecordingEngine`) içinde `private` yöntemlerdi. Ayrı olmaları
/// iki sebepten: dönüşüm durum taşımıyor (girdisi rapor, çıktısı şema tipi) ve
/// kaydedici sınıfı faz kapısı, günlük yazımı ve katlamayla zaten dolu.
enum ActionBuilder {

    /// Decoder'ın ham adayı → kayıt.
    static func candidate(_ c: DecodeResult) -> CandidateSnapshot {
        // `emitCount` **biliniyor**: decoder onu üretiyor. `.unknown` yazmak
        // bilinen bir olguyu atmaktı — omission/insertion teşhisi buna bakıyor.
        .init(id: .known(InputCoordinator.candidateID(word: c.word, source: c.source)),
              word: c.word, cost: c.cost,
              emitCount: .known(c.emitCount),
              source: Int(c.source), language: Int(c.language))
    }

    /// Gösterilen öneriler → kayıt.
    ///
    /// Sınıflandırma **koordinatörde**: burada ikinci bir kopya tutmak, UI'ın
    /// uydurduğu kimlikle kaydın yazdığının ayrışmasına açık kapı bırakıyordu.
    static func shown(_ suggestions: [InputCoordinator.Suggestion]) -> ShownSnapshot {
        .init(items: suggestions.map {
                  .init(id: .known($0.id), surface: $0.surface,
                        origin: .known($0.origin))
              },
              // Yerel kayıt **eksiksiz**: gösterilen yüzeylerin tamamı UI ile
              // aynı çağrıdan geliyor.
              completeness: .complete)
    }

    /// Sınır olayının commit kaydı.
    ///
    /// Boş token da **açıkça** yazılıyor (`kind: .empty`): `nil` bırakmak
    /// "sınır olayı commit taşımıyor" ile "boş token kapandı"yı karıştırıyordu
    /// ve validator ikisini ayırt edemiyordu.
    ///
    /// - Parameter label: §12.5 etiketi — kural `Commit.Label.make`'te.
    /// - Parameter cursor: commit **öncesi** cursor.
    static func commit(from r: InputCoordinator.TokenCommitReport,
                       label: CanonicalSession.Action.Commit.Label,
                       cursor: Int) -> CanonicalSession.Action.Commit {
        .init(
            kind: .init(r.kind),
            // Boş token kimlik tüketmiyor; `.notApplicable` "böyle bir token
            // yok" demek, `.unknown` "vardı ama bilmiyoruz" demek olurdu.
            tokenID: r.tokenID.map { Epistemic.known($0) }
                ?? (r.kind == .empty ? .notApplicable : .unknown),
            literal: r.literal, displayBefore: r.displayBefore,
            committed: r.committed,
            // JSON sonsuz taşıyamıyor; koruma durumu ayrı bayrakta.
            delta: r.delta?.isFinite == true ? r.delta : nil,
            theta: r.theta?.isFinite == true ? r.theta : nil,
            bestCost: r.bestCost, bestWord: r.bestWord,
            language: r.language.map(Int.init),
            touchCount: r.touchCount, casingApplied: r.casingApplied,
            literalProtected: r.theta?.isFinite == false,
            label: label,
            cursorBefore: .known(cursor))
    }
}

extension CanonicalSession.Action.Commit.Kind {
    /// Motorun commit türü → kaydın commit türü — **açık** eşleme.
    ///
    /// `.init(rawValue: r.kind.rawValue) ?? .literal` ile köprüleniyordu:
    /// motora yeni bir tür eklenip şemaya eklenmeseydi kayıt onu sessizce
    /// `literal` diye yazardı. Total `switch` bunu derleme hatasına çeviriyor.
    init(_ kind: InputCoordinator.TokenCommitReport.Kind) {
        switch kind {
        case .literal:     self = .literal
        case .autocorrect: self = .autocorrect
        case .suggestion:  self = .suggestion
        case .expansion:   self = .expansion
        case .empty:       self = .empty
        }
    }
}
