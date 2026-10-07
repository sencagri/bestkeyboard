import Foundation
import KBRuntime

/// Kaydın **tek** codec'i.
///
/// Okuyucu kendi `JSONDecoder`'ını kurup yazan taraf başka bir strateji
/// seçtiğinde kayıt sessizce okunamaz olur — tarih stratejisi böyle bir tuzak:
/// `.deferredToDate` sayı yazar, `.iso8601` string bekler. Simetri tesadüfe
/// bırakılmaz; testler de bu iki fabrikayı kullanmak zorunda, yoksa gerçekte
/// koşan codec hiç sınanmamış olur.
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
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode(_ session: CanonicalSession) throws -> Data {
        try encoder.encode(session)
    }
}

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
public enum SessionReader {

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        /// JSON hiç ayrıştırılamadı.
        case unreadable(String)
        /// Üst düzey bir nesne değil (dizi, sayı, dize…).
        case notAnObject
        /// `schema` anahtarı yok.
        case missingSchema
        /// `schema` var ama `null`.
        case nullSchema
        /// `schema` var ama tamsayı değil.
        case schemaNotAnInteger(String)
        case unsupportedSchema(Int)
        case malformed(schema: Int, detail: String)

        public var description: String {
            switch self {
            case let .unreadable(d):        return "okunamadı: \(d)"
            case .notAnObject:              return "üst düzey nesne değil"
            case .missingSchema:            return "şema alanı yok"
            case .nullSchema:               return "şema alanı null"
            case let .schemaNotAnInteger(v): return "şema tamsayı değil: \(v)"
            case let .unsupportedSchema(v): return "desteklenmeyen şema: \(v)"
            case let .malformed(v, d):      return "şema \(v) bozuk: \(d)"
            }
        }
    }

    public static func read(_ data: Data) -> Result<CanonicalSession, ReadError> {
        // 1) Şemayı önce oku. Alan yoksa tahmin ETMEYİZ — v1 diye varsaymak
        //    bilmediğimiz bir biçimi bildiğimiz gibi işlemek olurdu.
        //
        //    `JSONSerialization` ile okunuyor çünkü `Decodable` bir probe
        //    "yok", "null" ve "yanlış tipte" durumlarını tek `nil`'e indiriyor.
        //    Bozuk bir kaydı "eski kayıt" diye sınıflamak tam olarak kaçınmak
        //    istediğimiz hata.
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { return .failure(.unreadable("\(error)")) }

        guard let dict = object as? [String: Any] else {
            return .failure(.notAnObject)
        }
        guard let raw = dict["schema"] else { return .failure(.missingSchema) }
        if raw is NSNull { return .failure(.nullSchema) }
        // `NSNumber` hem `3` hem `3.5` hem `true` olabiliyor; tamsayı olmayanı
        // sessizce yuvarlamak, sürüm numarasını uydurmak olurdu.
        guard let number = raw as? NSNumber,
              CFNumberIsFloatType(number) == false,
              !(raw is Bool),
              let schema = Int(exactly: number)
        else { return .failure(.schemaNotAnInteger("\(raw)")) }

        let d = SessionCodec.decoder
        switch schema {
        case TypingSession.schemaVersion:
            do { return .success(try migrateV2(data, decoder: d)) }
            catch let e as ReadError { return .failure(e) }
            catch { return .failure(.malformed(schema: TypingSession.schemaVersion, detail: "\(error)")) }
        case CanonicalSession.currentSchema:
            do { return .success(try d.decode(CanonicalSession.self, from: data)) }
            catch { return .failure(.malformed(schema: schema, detail: "\(error)")) }
        default:
            return .failure(.unsupportedSchema(schema))
        }
    }

    // MARK: - v2 → kanonik

    /// v2'nin **taşımadığı** olgular `.unknown` olur; asla uydurulmaz. v2'nin
    /// **taşıdığı** olgular ise asla düşürülmez.
    ///
    /// Somut kayıplar (hepsi `.unknown`):
    /// - Geri açma olgusu hiç kaydedilmemişti → yıkıcı etki.
    /// - Tap ile character-repeat aynı `"backspace"` ile yazılmıştı →
    ///   `kind = .backspaceUnspecified`, `event = .unknown`.
    /// - `DocumentMutation` yoktu; v2 her action'da tam metin taşıyordu →
    ///   belge deltası `.unknown`. Ardışık `textAfter` farkından mutasyon
    ///   **türetmek** mümkün görünse de yapmıyoruz: aynı metin farkını üreten
    ///   birden çok mutasyon dizisi var (bir sil + bir yaz ile iki sil + iki
    ///   yaz aynı sonucu verir) ve seçim, olguyu uydurmak olurdu. Ham metin
    ///   `legacy.textAfter`'da duruyor.
    /// - Token kimliği, cursor, layout parmak izi, skor modeli, paket
    ///   topolojisi, σ, derleme kökeni.
    ///
    /// Korunanlar: `suggestions` (→ `candidates` + `shown`), `textAfter` ve
    /// `alignmentDiverged` (→ `legacy`), `hadBackspace` (→ oturum `legacy`),
    /// `learningFrozen` (→ `policy.learning`), hiyerarşik kalibrasyon.
    private static func migrateV2(_ data: Data, decoder d: JSONDecoder) throws
        -> CanonicalSession {
        let old = try d.decode(TypingSession.self, from: data)

        var actions: [CanonicalSession.Action] = []
        actions.reserveCapacity(old.actions.count)
        for a in old.actions {
            let (kind, event) = try Self.migrateKind(a.kind)
            actions.append(.init(
                actionID: a.actionID, t: a.t, kind: kind, touchID: a.touchID,
                event: event,
                // v2 yıkıcı olguyu hiç taşımıyordu.
                effect: kind.invalidatesBeam || kind.closesToken
                    ? .unknown : .notApplicable,
                document: .unknown,
                targetTokenIndex: a.targetWordIndex, targetToken: a.targetWord,
                candidates: Self.migrateCandidates(a.suggestions),
                shown: Self.migrateShown(a.suggestions),
                commit: try a.commit.map(Self.migrateCommit),
                legacy: .known(.init(alignmentDiverged: a.alignmentDiverged,
                                     textAfter: a.textAfter))))
        }

        return CanonicalSession(
            sourceSchema: TypingSession.schemaVersion,
            attemptID: old.attemptID, participantID: old.participantID,
            protocolVersion: old.protocolVersion,
            sessionOrdinal: old.sessionOrdinal,
            condition: old.condition == .calibrationReplay
                ? .calibrationReplay : .behavior,
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
            touches: try old.touches.map(Self.migrateTouch),
            actions: actions,
            finalText: old.finalText,
            legacy: .known(.init(hadBackspace: old.hadBackspace)))
    }

    /// v2 kind → (kanonik kind, komut).
    ///
    /// `"backspace"` **belirsiz**: v2 hem tap'i hem character-repeat'i böyle
    /// yazıyordu. Kesin bir kipe uydurmak olguyu uydurmak olurdu.
    ///
    /// Tanınmayan bir değer ise "eski kayıt" değil **bozuk** kayıttır: onu
    /// yasal bir kipe düşürmek, bozukluğu sessizce yutmak olurdu.
    static func migrateKind(_ raw: String) throws
        -> (CanonicalSession.Action.Kind, Epistemic<ReplayCommand>) {
        // Komut biliniyorsa kip **komuttan** türüyor (`ReplayCommand.actionKind`);
        // ayrıca yazmak, eşlemenin ikinci bir kopyası olurdu.
        func known(_ c: ReplayCommand)
            -> (CanonicalSession.Action.Kind, Epistemic<ReplayCommand>) {
            (c.actionKind, .known(c))
        }
        switch raw {
        case "letter":         return (.letter, .unknown)   // baseKey/display yok
        case "symbol":         return (.symbol, .unknown)
        case "space":          return known(.space)
        case "newline":        return known(.newline)
        case "suggestionPick": return (.suggestionPick, .unknown)  // kimlik/köken yok
        case "backspace":      return (.backspaceUnspecified, .unknown)
        case "backspaceWord":  return known(.deleteWord)
        case "backspaceRepeat": return known(.backspaceRepeat)
        // Shift bir **olay**, "uygulanmaz" değil. Ama v2 sonuç durumunu
        // (kilitli / tek seferlik / kapalı) kaydetmiyordu → yük bilinmiyor.
        case "shift":          return (.shift, .unknown)
        // Hedef düzlem kind string'inde **açıkça kayıtlı**; üçünü tek değere
        // çökertmek, kayıtta duran bir olguyu atmak olurdu.
        case "plane.numbers":  return known(.planeChange("numbers"))
        case "plane.symbols":  return known(.planeChange("symbols"))
        case "plane.letters":  return known(.planeChange("letters"))
        default:
            throw ReadError.malformed(schema: TypingSession.schemaVersion, detail: "tanınmayan kind: \(raw)")
        }
    }

    /// v2 `Suggestion` → ham aday.
    ///
    /// `nil` = bu action'da anlık görüntü **alınmadı**; `[]` = alındı ve boştu.
    /// İkisini tek değere indirmek "öneri yoktu" ile "bakılmadı"yı karıştırırdı.
    private static func migrateCandidates(_ s: [TypingSession.Action.Suggestion]?)
        -> Epistemic<[CandidateSnapshot]> {
        guard let s else { return .notApplicable }
        return .known(s.map {
            // `id` ve `emitCount` v2'de yoktu; ama `word`/`cost`/`source`/
            // `language` biliniyordu. Tüm adayı `.unknown` saymak, bilinen
            // dördünü de atmak olurdu — bu yüzden alan bazında epistemik.
            .init(id: .unknown, word: $0.word, cost: $0.cost,
                  emitCount: .unknown, source: $0.source, language: $0.language)
        })
    }

    /// v2 `Suggestion.shown` bayrağı → gösterilenler listesi.
    ///
    /// Bu **gerçek bir v2 olgusu**: kullanıcının neyi gördüğü kaydediliyordu.
    private static func migrateShown(_ s: [TypingSession.Action.Suggestion]?)
        -> Epistemic<ShownSnapshot> {
        guard let s else { return .notApplicable }
        return .known(.init(
            items: s.filter(\.shown).map {
                // Köken üyelikten çıkarılamıyor: bir genişletme aynı anda ham
                // aday listesinde de olabilir. v2 kökeni kaydetmiyordu.
                .init(id: .unknown, surface: $0.word, origin: .unknown)
            },
            // **Eksiksiz değil.** v2 yalnız decoder adaylarını saklıyordu;
            // öneri çubuğunda ayrıca gösterilen genişletme yüzeyleri
            // (`suggestionSurfaces`) o listede yoktu. Bunu `complete` yazmak,
            // "kullanıcı genişletmeyi görmedi" sonucunu doğrulanmamış biçimde
            // üretirdi.
            completeness: .partial))
    }

    /// v2 `.inProgress` → `.recording`.
    ///
    /// Eskiden `.interrupted` yapılıyordu; bu bir **yargıydı**. Okuyucu
    /// dosyanın bayatladığını da, yazıcının hâlâ koştuğunu da bilmiyor —
    /// üstelik `endedAt == nil` olan terminal bir durum üretiyordu. Bayat
    /// kayıtları kesintiye çevirmek zaman ve kurtarma bağlamı olan **ayrı** bir
    /// işlemin işi, saf migrasyonun değil.
    private static func migrateStatus(_ s: TypingSession.Status)
        -> CanonicalSession.Status {
        switch s {
        case .inProgress:  return .recording
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

    /// v2 dokunma → kanonik.
    ///
    /// `phase` ve `outcome` v2'de serbest string'di ama değer kümesi kapalıydı.
    /// Tanınmayanı `.ended`/`.pending`'e düşürmek, bozuk bir kaydı yasal
    /// görünen bir olguya çevirirdi — üstelik `neverHit` ile `leftBounds`
    /// ayrımı tam olarak bu alanlarda yaşıyor.
    private static func migrateTouch(_ t: TypingSession.Touch) throws
        -> CanonicalSession.Touch {
        guard let phase = CanonicalSession.Touch.Phase(rawValue: t.phase) else {
            throw ReadError.malformed(schema: TypingSession.schemaVersion, detail: "tanınmayan phase: \(t.phase)")
        }
        guard let outcome = CanonicalSession.Touch.Outcome(rawValue: t.outcome) else {
            throw ReadError.malformed(schema: TypingSession.schemaVersion,
                                      detail: "tanınmayan outcome: \(t.outcome)")
        }
        return .init(touchID: t.touchID, phase: phase, outcome: outcome,
                     rawX: t.rawX, rawY: t.rawY, normX: t.normX, normY: t.normY,
                     decoderX: t.decoderX, decoderY: t.decoderY,
                     timestamp: t.timestamp, majorRadius: t.majorRadius,
                     majorRadiusTolerance: t.majorRadiusTolerance,
                     plane: t.plane, shift: t.shift,
                     hitKind: t.hitKind, key: t.key, keyIndex: t.keyIndex)
    }

    /// v2 commit'inde `tokenID` ve `cursorBefore` **yoktu**.
    ///
    /// İkisi de `.unknown`. `tokenID`'yi `actionID`'den türetmek deterministik
    /// olurdu ama deterministik olmak onu **gözlenmiş olgu** yapmaz: türetilmiş
    /// bir kimliği gerçek kimlik gibi yazmak §6.2 ihlalidir ve hedefli silme
    /// onun üzerinden yanlış token'ı işaretlerdi.
    private static func migrateCommit(_ c: TypingSession.Action.Commit) throws
        -> CanonicalSession.Action.Commit {
        guard let kind = CanonicalSession.Action.Commit.Kind(rawValue: c.kind) else {
            throw ReadError.malformed(schema: TypingSession.schemaVersion,
                                      detail: "tanınmayan commit kind: \(c.kind)")
        }
        // §12.5 etiketi v2'de serbest string'di ama değer kümesi kapalıydı.
        guard let source = CanonicalSession.Action.Commit.Label.Source(
                  rawValue: c.labelSource),
              let confidence = CanonicalSession.Action.Commit.Label.Confidence(
                  rawValue: c.confidence) else {
            throw ReadError.malformed(
                schema: TypingSession.schemaVersion,
                detail: "tanınmayan etiket: \(c.labelSource)/\(c.confidence)")
        }
        return .init(
            kind: kind, tokenID: .unknown,
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

    /// v2 yazıcısının **yer tutucu** motor anlık görüntüsü.
    ///
    /// Oturum başında, paketler yüklenmeden diske yazılıyor ve yükleme bitince
    /// üzerine yazılıyor. Deneme yükleme bitmeden yarıda kalırsa kayıtta yer
    /// tutucu kalıyor.
    ///
    /// Tespit **çıkarım değil**: `beamWidth == 0` yazıcının kendi nöbetçisi ve
    /// kurulmuş bir motorda imkânsız (`Decoder` sıfır genişlikle çalışmaz).
    /// Nöbetçiyi tanımak, onu gerçek konfigürasyon diye taşımaktan dürüst.
    private static func isPlaceholder(_ e: TypingSession.EngineSnapshot) -> Bool {
        // **Tam** biçim eşleşmesi. Yalnız `beamWidth == 0` bakmak bir çıkarımdı:
        // `Decoder` sıfır beam'i reddetmiyor ve `EngineSnapshot`'ın başka
        // üreticileri var. Yer tutucunun bütün alanlarını birden istemek,
        // yazıcının bilinen çıktısını **tanımak** oluyor.
        e.beamWidth == 0
            && e.packs.isEmpty
            && e.oovTheta == 0
            && e.suggestionWindow == 0
            && !e.autoCorrectsOutOfVocabulary
            && !e.calibration.applied
            && e.calibration.strongSamples == 0
            && e.calibration.biasX.isEmpty && e.calibration.biasY.isEmpty
            && e.initialLanguage == nil
    }

    private static func migrateEngine(_ e: TypingSession.EngineSnapshot)
        -> CanonicalSession.EngineSnapshot {
        .init(
            buildConfiguration: e.buildConfiguration,
            appVersion: e.appVersion,
            build: .init(
                // Build fazı hiç koşmadığı için v2 kayıtlarında bu alan
                // `"unknown"` olabiliyordu — yazıcının nöbetçisi.
                codeRevision: Self.isUnknownRevision(e.codeRevision)
                    ? .unknown : .known(e.codeRevision),
                provenance: .unknown),
            policy: .init(
                // Görünürlük ve düzeltme v2'de kaydedilmiyordu. `condition`'dan
                // türetmek çıkarım olurdu: koşul yalnız **niyeti** gösteriyor,
                // motorun fiilen nasıl kurulduğunu değil.
                feedbackVisible: .unknown,
                suggestionsVisible: .unknown,
                correction: .unknown,
                // Bu **biliniyor**: §12.3 şart koştuğu için v2 de yazıyordu.
                learning: e.learningFrozen ? .frozen : .live),
            // Yer tutucuda yalnız **konfigürasyon** bilinmiyor; derleme
            // kimliği, sürüm ve politika yer tutucuda da doğru.
            configuration: isPlaceholder(e) ? .unknown : .known(.init(
                packs: e.packs.map {
                    .init(name: $0.name,
                          // `RecordingView` özet hesaplamayı atladığında bu
                          // nöbetçiyi yazıyordu.
                          sha256: $0.sha256 == "hesaplanmadı"
                              ? .unknown : .known($0.sha256),
                          bytes: $0.bytes,
                          // v2 rol/dil/sıra/offset taşımıyordu.
                          topology: .unknown)
                },
                beamWidth: e.beamWidth, oovTheta: e.oovTheta,
                suggestionWindow: e.suggestionWindow,
                autoCorrectsOutOfVocabulary: e.autoCorrectsOutOfVocabulary,
                scoring: .unknown,
                calibration: .init(
                    applied: e.calibration.applied,
                    strongSamples: e.calibration.strongSamples,
                    biasX: e.calibration.biasX, biasY: e.calibration.biasY,
                    hierarchical: .init(globalX: e.calibration.globalX,
                                        globalY: e.calibration.globalY,
                                        rowX: e.calibration.rowX,
                                        rowY: e.calibration.rowY,
                                        keyX: e.calibration.keyX,
                                        keyY: e.calibration.keyY),
                    sigma: .unknown),
                initialLanguage: e.initialLanguage)))
    }

    /// Build fazı koşmadığında yazılan revision nöbetçileri.
    ///
    /// `RecordingView` manifest yoksa `"unknown"` yazıyor; manifest var ama
    /// git yoksa script `"unknown"` + `dirty=true` üretiyor ve accessor bunu
    /// `"unknown+dirty"` yapıyor. İkisi de "revision bilinmiyor" demek —
    /// yalnız birini tanımak, diğerini `.known("unknown+dirty")` diye geçerli
    /// bir kimlik sanmaktı.
    static func isUnknownRevision(_ raw: String) -> Bool {
        raw == "unknown" || raw.hasPrefix("unknown+")
    }
}
