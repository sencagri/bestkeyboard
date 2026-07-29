import Foundation
import KBRuntime

/// Sürüm-önce okuma ve v2 → kanonik migrasyon — plan v8 §2.2.
///
/// ## Neden `decodeIfPresent` yetmez
///
/// Eksik alanı property default'una düşürmek, **bozuk bir v3** kaydını da "eski
/// kayıt" sayar; hata sessizce geçer. Doğrusu:
///
/// 1. Önce yalnız `schema` okunur.
/// 2. `v2` → ayrı DTO → kanonik **migrasyon**; taşınmayan olgular `.unknown`.
/// 3. `v3` → **sıkı** decode; eksik alan hatadır.
/// 4. `v4+` → **reddedilir**. İleri sürümü tahmin etmek, bilmediğini bilmemektir.
/// Kaydın **tek** codec'i.
///
/// Okuyucu kendi `JSONDecoder`'ını kurup yazan taraf başka bir strateji
/// seçtiğinde kayıt sessizce okunamaz olur — tarih stratejisi böyle bir tuzak:
/// `.deferredToDate` sayı yazar, `.iso8601` string bekler. Simetri tesadüfe
/// bırakılmaz.
public enum SessionCodec {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        // Anahtar sırası sabit: aynı kayıt iki kez yazıldığında bayt bayt aynı
        // olmalı ki golden karşılaştırması ve içerik özeti anlamlı olsun.
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = SessionCodec.decoder
        return d
    }

    public static func encode(_ session: CanonicalSession) throws -> Data {
        try encoder.encode(session)
    }
}

public enum SessionReader {

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case missingSchema
        case unsupportedSchema(Int)
        case malformed(schema: Int, detail: String)

        public var description: String {
            switch self {
            case let .unreadable(d):      return "okunamadı: \(d)"
            case .missingSchema:          return "şema alanı yok"
            case let .unsupportedSchema(v): return "desteklenmeyen şema: \(v)"
            case let .malformed(v, d):    return "şema \(v) bozuk: \(d)"
            }
        }
    }

    private struct SchemaProbe: Decodable { let schema: Int? }

    public static func read(_ data: Data) -> Result<CanonicalSession, ReadError> {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601

        // 1) Şemayı önce oku. Alan yoksa tahmin ETMEYİZ — v1 diye varsaymak
        //    bilmediğimiz bir biçimi bildiğimiz gibi işlemek olurdu.
        guard let probe = try? d.decode(SchemaProbe.self, from: data) else {
            return .failure(.unreadable("JSON çözülemedi"))
        }
        guard let schema = probe.schema else { return .failure(.missingSchema) }

        switch schema {
        case 2:
            do { return .success(try migrateV2(data, decoder: d)) }
            catch { return .failure(.malformed(schema: 2, detail: "\(error)")) }
        case CanonicalSession.currentSchema:
            do { return .success(try d.decode(CanonicalSession.self, from: data)) }
            catch { return .failure(.malformed(schema: schema, detail: "\(error)")) }
        default:
            return .failure(.unsupportedSchema(schema))
        }
    }

    // MARK: - v2 → kanonik

    /// v2'nin **taşımadığı** olgular `.unknown` olur; asla uydurulmaz.
    ///
    /// Somut kayıplar:
    /// - Geri açma olgusu hiç kaydedilmemişti → yıkıcı etki `.unknown`.
    /// - Tap ile character-repeat aynı `"backspace"` ile yazılmıştı →
    ///   `kind = .backspaceUnspecified`, `event = .unknown`.
    /// - `ReplayCommand` yoktu → `event` yalnız harf/sembol/sınır gibi
    ///   **belirsizlik taşımayan** olaylarda `.known` olabilir.
    /// - `DocumentMutation` yoktu; v2 her action'da tam metin taşıyordu →
    ///   belge deltası `.unknown`. Ardışık `textAfter` farkından mutasyon
    ///   **türetmek** mümkün görünse de bunu yapmıyoruz: aynı metin farkını
    ///   üreten birden çok mutasyon dizisi var (bir sil+bir yaz ile iki sil+iki
    ///   yaz aynı sonucu verir) ve seçim, olguyu uydurmak olurdu.
    private static func migrateV2(_ data: Data, decoder d: JSONDecoder) throws
        -> CanonicalSession {
        let old = try d.decode(TypingSession.self, from: data)

        var actions: [CanonicalSession.Action] = []
        actions.reserveCapacity(old.actions.count)
        for a in old.actions {
            let (kind, event) = Self.migrateKind(a.kind)
            actions.append(.init(
                actionID: a.actionID, t: a.t, kind: kind, touchID: a.touchID,
                event: event,
                // v2 yıkıcı olguyu hiç taşımıyordu.
                effect: kind.invalidatesBeam || kind.closesToken ? .unknown : .notApplicable,
                document: .unknown,
                targetTokenIndex: a.targetWordIndex, targetToken: a.targetWord,
                candidates: nil, shown: nil,
                commit: try a.commit.map {
                    try Self.migrateCommit($0, actionID: a.actionID)
                }))
        }

        return CanonicalSession(
            sourceSchema: 2, schema: CanonicalSession.currentSchema,
            attemptID: old.attemptID, participantID: old.participantID,
            protocolVersion: old.protocolVersion,
            sessionOrdinal: old.sessionOrdinal,
            condition: old.condition == .calibrationReplay ? .calibrationReplay : .behavior,
            status: Self.migrateStatus(old.status),
            promptID: old.promptID, promptText: old.promptText,
            promptSource: old.promptSource == .builtin ? .builtin : .manual,
            split: old.split,
            // v2 gösterilen diziyi kaydetmiyordu; bugünkü kuralla türetmek
            // eski replay'i bugünkü tokenizer'a bağlardı.
            promptTokens: .unknown,
            alignmentSource: Self.migrateAlignment(old.alignmentSource),
            startedAt: old.startedAt, endedAt: old.endedAt,
            posture: .init(hands: Self.migrateHands(old.posture.hands),
                           mobility: Self.migrateMobility(old.posture.mobility)),
            engine: Self.migrateEngine(old.engine),
            geometry: Self.migrateGeometry(old.geometry),
            touches: old.touches.map(Self.migrateTouch),
            actions: actions,
            finalText: old.finalText)
    }

    /// v2 kind → (kanonik kind, komut).
    ///
    /// `"backspace"` **belirsiz**: v2 hem tap'i hem character-repeat'i böyle
    /// yazıyordu. Kesin bir kipe uydurmak olguyu uydurmak olurdu.
    static func migrateKind(_ raw: String)
        -> (CanonicalSession.Action.Kind, Epistemic<ReplayCommand>) {
        switch raw {
        case "letter":         return (.letter, .unknown)   // baseKey/display yok
        case "symbol":         return (.symbol, .unknown)
        case "space":          return (.space, .known(.space))
        case "newline":        return (.newline, .known(.newline))
        case "suggestionPick": return (.suggestionPick, .unknown)  // kimlik/köken yok
        case "backspace":      return (.backspaceUnspecified, .unknown)
        case "backspaceWord":  return (.deleteWord, .known(.deleteWord))
        case "backspaceRepeat": return (.backspaceRepeat, .known(.backspaceRepeat))
        case "shift":          return (.shift, .notApplicable)
        case "plane.numbers", "plane.symbols", "plane.letters":
            return (.planeChange, .notApplicable)
        default:               return (.backspaceUnspecified, .unknown)
        }
    }

    private static func migrateStatus(_ s: TypingSession.Status)
        -> CanonicalSession.Status {
        switch s {
        case .inProgress:  return .interrupted   // yarım kalmış = kesilmiş
        case .completed:   return .completed
        case .aborted:     return .aborted
        case .interrupted: return .interrupted
        case .invalid:     return .invalid
        }
    }

    private static func migrateAlignment(_ a: TypingSession.AlignmentSource)
        -> CanonicalSession.AlignmentSource {
        switch a {
        case .constructed: return .constructed
        case .sequential:  return .sequential
        case .none:        return .none
        }
    }

    private static func migrateHands(_ h: TypingSession.Posture.Hands)
        -> CanonicalSession.Posture.Hands {
        switch h {
        case .oneThumb: return .oneThumb
        case .twoThumbs: return .twoThumbs
        case .indexFinger: return .indexFinger
        case .unknown: return .unknown
        }
    }

    private static func migrateMobility(_ m: TypingSession.Posture.Mobility)
        -> CanonicalSession.Posture.Mobility {
        switch m {
        case .seated: return .seated
        case .standing: return .standing
        case .walking: return .walking
        case .unknown: return .unknown
        }
    }

    private static func migrateTouch(_ t: TypingSession.Touch)
        -> CanonicalSession.Touch {
        .init(touchID: t.touchID,
              phase: CanonicalSession.Touch.Phase(rawValue: t.phase) ?? .ended,
              outcome: CanonicalSession.Touch.Outcome(rawValue: t.outcome) ?? .pending,
              rawX: t.rawX, rawY: t.rawY, normX: t.normX, normY: t.normY,
              decoderX: t.decoderX, decoderY: t.decoderY,
              timestamp: t.timestamp, majorRadius: t.majorRadius,
              majorRadiusTolerance: t.majorRadiusTolerance,
              plane: t.plane, shift: t.shift,
              hitKind: t.hitKind, key: t.key, keyIndex: t.keyIndex)
    }

    /// v2 commit'inde `tokenID` ve `cursorBefore` **yoktu**.
    ///
    /// `tokenID` **action kimliğinden** türetiliyor: deterministik, tekil ve
    /// izlenebilir. Sayaç tutmak global durum olurdu ve migrasyonu çağrı
    /// sırasına bağlardı — aynı dosya iki kez okunduğunda farklı kimlikler
    /// üretirdi. `cursorBefore` ise gerçekten
    /// bilinmiyor: `targetWordIndex`'ten türetmek §6.2'nin yasakladığı çıkarım
    /// olurdu → `.unknown`, tüketici için "bu token geri açılamaz".
    private static func migrateCommit(_ c: TypingSession.Action.Commit,
                                      actionID: Int) throws
        -> CanonicalSession.Action.Commit {
        // §12.5 etiketi v2'de serbest string'di ama değer kümesi kapalıydı.
        // Tanınmayan bir değer eksik olgu **değil**, bozuk kayıttır: `.unknown`
        // yazmak bozukluğu "eski sürüm" diye gizlerdi.
        guard let source = CanonicalSession.Action.Commit.Label.Source(
                  rawValue: c.labelSource),
              let confidence = CanonicalSession.Action.Commit.Label.Confidence(
                  rawValue: c.confidence) else {
            throw ReadError.malformed(
                schema: 2,
                detail: "tanınmayan etiket: \(c.labelSource)/\(c.confidence)")
        }
        return .init(
            kind: CanonicalSession.Action.Commit.Kind(rawValue: c.kind) ?? .literal,
            tokenID: TokenID(raw: actionID),
            literal: c.literal, displayBefore: c.displayBefore,
            committed: c.committed, delta: c.delta, theta: c.theta,
            bestCost: c.bestCost, bestWord: c.bestWord, language: c.language,
            touchCount: c.touchCount, casingApplied: c.casingApplied,
            literalProtected: c.literalProtected,
            label: .init(source: source, confidence: confidence,
                         targetWord: c.targetWord,
                         matchesTarget: c.matchesTarget),
            cursorBefore: .unknown)
    }

    private static func migrateGeometry(_ g: TypingSession.Geometry)
        -> CanonicalSession.Geometry {
        .init(layoutID: g.layoutID,
              // v2 parmak izi taşımıyordu; golden bunu `unverifiable` sayacak.
              layoutFingerprint: .unknown,
              boundsX: g.boundsX, boundsY: g.boundsY,
              boundsWidth: g.boundsWidth, boundsHeight: g.boundsHeight,
              frameInScreenX: g.frameInScreenX, frameInScreenY: g.frameInScreenY,
              frameInScreenWidth: g.frameInScreenWidth,
              frameInScreenHeight: g.frameInScreenHeight,
              safeAreaBottom: g.safeAreaBottom, screenScale: g.screenScale,
              interfaceOrientation: g.interfaceOrientation,
              deviceModel: g.deviceModel, systemVersion: g.systemVersion)
    }

    private static func migrateEngine(_ e: TypingSession.EngineSnapshot)
        -> CanonicalSession.EngineSnapshot {
        .init(buildConfiguration: e.buildConfiguration,
              appVersion: e.appVersion,
              build: .init(codeRevision: e.codeRevision, provenance: .unknown),
              packs: e.packs.map {
                  // v2 rol/dil/sıra/offset taşımıyordu — topoloji bilinmiyor.
                  .init(name: $0.name, sha256: $0.sha256, bytes: $0.bytes,
                        topology: .unknown)
              },
              // Politika v2'de yoktu ve koşuldan türetilmez: `condition` yalnız
              // **niyeti** gösteriyor, motorun fiilen nasıl kurulduğunu değil.
              // Kalibrasyon filtresi politikayı istediği için bu kayıtlar
              // zaten dışlanacak — ki doğrusu da bu.
              policy: .unknown,
              beamWidth: e.beamWidth, oovTheta: e.oovTheta,
              suggestionWindow: e.suggestionWindow,
              autoCorrectsOutOfVocabulary: e.autoCorrectsOutOfVocabulary,
              scoring: .unknown,
              calibration: .init(applied: e.calibration.applied,
                                 strongSamples: e.calibration.strongSamples,
                                 biasX: e.calibration.biasX,
                                 biasY: e.calibration.biasY,
                                 sigma: .unknown),
              initialLanguage: e.initialLanguage)
    }
}
