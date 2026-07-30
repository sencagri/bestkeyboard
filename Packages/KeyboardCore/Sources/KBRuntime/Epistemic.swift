import Foundation

/// Bir olgunun **bilinme durumu** — sözleşme §12, plan v8 §2.2.
///
/// ## Neden gerekli
///
/// İlk şemada olgular `Optional`'dı ve `nil` üç ayrı şeyi karıştırıyordu:
///
/// 1. **Uygulanmaz** — harf action'ının yıkıcı etkisi yoktur.
/// 2. **Eski şemada yoktu** — v2 kayıtlarında geri açma olgusu hiç
///    kaydedilmemişti; bilinmiyor.
/// 3. **Bozuk v3'te eksik** — olması gerekirken yok; bu bir hatadır.
///
/// Üçünü tek `nil`'e indirmek, bilinmeyeni yanlış bir kesinliğe çevirir: v2'nin
/// belirsiz backspace'ine "geri açma olmadı" demek, olmamış bir olguyu olmuş
/// gibi kaydetmektir.
///
/// ## Kural
///
/// **v3 hiçbir `.unknown` üretmez.** Uygulanabilirse `.known`, değilse
/// `.notApplicable`. `.unknown` **yalnız** v2 migrasyonundan çıkar ve asla
/// yeniden v3 kesinliği olarak encode edilmez.
///
/// `.unknown` taşıyan kayıt kalibrasyondan dışlanır ve golden'da
/// `unverifiable` sayılır — bilinmeyenden sonuç çıkarmak yerine bilinmediğini
/// raporlamak.
public enum Epistemic<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case known(T)
    /// Kaynak şema bu olguyu hiç taşımıyordu.
    case unknown
    /// Bu bağlamda anlamsız (ör. harf action'ında yıkıcı etki).
    case notApplicable

    public var value: T? {
        if case let .known(v) = self { return v }
        return nil
    }

    /// Bilinmeyen bir olgu taşıyor mu — uygunluk kapıları bunu sorar.
    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    // MARK: - Codec
    //
    // Etiketli temsil: `{"state":"known","value":…}`. Düz `Optional` ile
    // temsil edilemez, çünkü `unknown` ile `notApplicable` ayrı kalmalı.

    private enum CodingKeys: String, CodingKey { case state, value }
    private enum State: String, Codable { case known, unknown, notApplicable }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let state = try c.decode(State.self, forKey: .state)
        if state != .known, c.contains(.value) {
            // `{"state":"unknown","value":7}` **çelişkili**: bilinmediği
            // söylenen bir olgunun değeri var. Sessizce atmak, yazan tarafın
            // hatasını okuyan tarafta görünmez yapardı — üstelik hangisinin
            // doğru olduğunu bilmiyoruz.
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "\(state) durumunda `value` bulunamaz"))
        }
        switch state {
        case .known: self = .known(try c.decode(T.self, forKey: .value))
        case .unknown: self = .unknown
        case .notApplicable: self = .notApplicable
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .known(v):
            try c.encode(State.known, forKey: .state)
            try c.encode(v, forKey: .value)
        case .unknown:
            try c.encode(State.unknown, forKey: .state)
        case .notApplicable:
            try c.encode(State.notApplicable, forKey: .state)
        }
    }
}
