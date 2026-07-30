import Foundation
import KBGeometry
import KBLearning
import KBRuntime

/// Kayıt kümesinin **tek** özet üreticisi — `kbbench --sessions`'ın gördüğü şey.
///
/// ## Neden ayrı bir modül
///
/// Özet mantığı `Tools/kbbench/main.swift` içinde yaşarken test edilemiyordu:
/// aracı koşmak paket, layout ve gerçek kayıt gerektiriyor, dolayısıyla sayım
/// hataları ancak cihaz verisi toplandıktan sonra ve elle fark edilebiliyordu.
/// Burada oturduğunda aynı sayaçlar birim testinden geçiyor.
///
/// ## Neden `RecordingLibrary` üzerinden
///
/// `SessionReplay.load` yalnız `*.json` glob'luyordu; v3 `.bkj` kayıtları
/// **görünmüyordu** ve araç "klasörde okunabilir kayıt yok" diyip sıfır
/// raporluyordu. Analiz aracının sessizce boş dönmesi, veri toplanmamış olmakla
/// aynı şey — ama toplanmıştı.
public enum RecordingAnalysis {

    public enum DocumentOutcome: Equatable {
        case complete(String)
        /// Delta bilinmiyor; dize o noktaya kadarki önek.
        case unverifiable(prefix: String, fromAction: Int)
        /// Türetim **çeliştì**: mutasyonlar kayıttaki özeti tutturmuyor.
        case failed(String)
    }

    /// Bir kaydın **kendi başına** ne söylediği.
    public struct Record {
        public var url: URL
        public var origin: RecordingLibrary.Origin
        public var session: CanonicalSession
        public var truncatedTail: Bool
        public var state: SessionEventReducer.State
        /// Yapısal doğrulama bulguları — boşsa kayıt tutarlı.
        public var findings: [SessionValidator.Finding]
        public var calibration: CalibrationExtraction.Result
        /// Belge türetimi: kayıt kendi metnini üretebiliyor mu.
        ///
        /// `.failed` bir **kayıt** hatası: mutasyon dizisi kendi özetini
        /// tutturamıyor, demek ki yazıcı ile şema ayrışmış. `.unverifiable` ise
        /// hata değil bilgi eksikliği (v2 migrasyonunda delta yok) — ikisi tek
        /// bayrağa indirilirse eski kayıt bozuk kayıt gibi görünürdü.
        public var document: DocumentOutcome

        public var isDebugBuild: Bool {
            session.engine.buildConfiguration != "Release"
        }
        /// Motor konfigürasyonu yok — replay kurulamaz (v2 ya da yarım kalmış).
        public var isUnconfigured: Bool {
            session.engine.configuration.value == nil
        }
    }

    public struct Summary {
        // MARK: Küme
        public var total = 0
        public var byStatus: [CanonicalSession.Status: Int] = [:]
        public var byOrigin: [RecordingLibrary.Origin: Int] = [:]
        /// Son frame'i yarım kalmış (güç kaybı) kayıtlar.
        public var truncatedTails = 0
        public var debugBuilds = 0
        /// Motor anlık görüntüsü olmayan kayıtlar — golden replay kurulamaz.
        public var unconfigured = 0

        // MARK: Yapısal doğrulama
        /// Bulgu üreten kayıt sayısı ve toplam bulgu.
        ///
        /// **Ayrı sayılıyor**: tek bozuk kaydın 40 bulgusu ile 40 kaydın birer
        /// bulgusu aynı şey değil.
        public var recordsWithFindings = 0
        public var findings = 0
        public var documentFailures = 0
        public var documentUnverifiable = 0

        // MARK: Dokunma
        public var touchesTotal = 0
        public var touchesNeverHit = 0
        public var touchesLeftBounds = 0
        public var touchesCancelled = 0
        /// Hiçbir token'a girmeyen dokunmalar, gerekçesiyle.
        ///
        /// Ham `dropped` sayısı yetmiyordu: "kanıt kopmuşken geldi" ile "hiçbir
        /// tuşa denk gelmedi" farklı sorunlar ve farklı düzeltmeleri var.
        public var droppedByReason: [SessionEventReducer.DropReason: Int] = [:]

        // MARK: Token
        public var tokens = 0
        public var tokensMatchingTarget = 0
        public var tokensAfterDivergence = 0
        public var tokensInvalidated = 0
        public var tokensTouchCountMismatch = 0
        public var byCommitKind: [CanonicalSession.Action.Commit.Kind: Int] = [:]
        /// Doğru yazılmışı bozan düzeltme — kullanıcının hissettiği metrik.
        public var wrongAutocorrects = 0
        /// `θ = ∞` ile korunan token: sözlük dışı ama dokunulmadı.
        public var literalProtected = 0

        // MARK: Kalibrasyon
        public var calibrationSamples = 0
        public var excludedLengthMismatch = 0
        public var excludedDiverged = 0
        public var excludedWeakLabel = 0
        public var excludedTouchCountMismatch = 0
        public var recoveredDriftedTouches = 0
        /// **Tamamen** dışlanan kayıtlar, gerekçesiyle.
        public var excludedSessions: [(url: URL,
                                      reason: CalibrationExtraction.SessionExclusion)] = []
        public var keyCoverage: [Int: Int] = [:]

        public var abortRate: Double? {
            guard total > 0 else { return nil }
            return Double(byStatus[.aborted] ?? 0) / Double(total)
        }
    }

    // MARK: - Okuma

    /// Dizini okur, her kaydı katlar ve doğrular.
    ///
    /// Okunamayan dosyalar `Listing.failures`'ta kalıyor ve **çağırana
    /// gösteriliyor**: bozuk bir kaydı atlamak vazgeçme oranını olduğundan iyi
    /// gösterirdi.
    public static func read(directory: URL, layout: KeyLayout)
        -> (records: [Record], failures: [RecordingLibrary.Failure]) {
        let listing = RecordingLibrary.list(in: directory)
        return (listing.entries.map { analyze($0, layout: layout) },
                listing.failures)
    }

    public static func analyze(_ entry: RecordingLibrary.Entry,
                              layout: KeyLayout) -> Record {
        let state = SessionEventReducer.reduce(entry.session)
        let document: DocumentOutcome
        do {
            switch try DocumentReconstruction.replay(entry.session) {
            case let .complete(t): document = .complete(t)
            case let .unverifiable(prefix, from):
                document = .unverifiable(prefix: prefix, fromAction: from)
            }
        } catch { document = .failed("\(error)") }
        return Record(
            url: entry.url, origin: entry.origin, session: entry.session,
            truncatedTail: entry.truncatedTail, state: state,
            findings: SessionValidator.validate(entry.session, state: state),
            calibration: CalibrationExtraction.extract(entry.session,
                                                       layout: layout,
                                                       state: state),
            document: document)
    }

    // MARK: - Özet

    public static func summarize(_ records: [Record]) -> Summary {
        var s = Summary()
        for r in records {
            s.total += 1
            s.byStatus[r.session.status, default: 0] += 1
            s.byOrigin[r.origin, default: 0] += 1
            if r.truncatedTail { s.truncatedTails += 1 }
            if r.isDebugBuild { s.debugBuilds += 1 }
            if r.isUnconfigured { s.unconfigured += 1 }

            if !r.findings.isEmpty {
                s.recordsWithFindings += 1
                s.findings += r.findings.count
            }
            switch r.document {
            case .failed: s.documentFailures += 1
            case .unverifiable: s.documentUnverifiable += 1
            case .complete: break
            }

            // `began`/`moved` sayılmıyor: aynı dokunmanın ara evreleri, ayrı
            // dokunma değil. Sayarsak "hiç isabet etmeyen" oranı sürükleme
            // yoğunluğuna göre değişir ve karşılaştırılamaz hâle gelir.
            for t in r.session.touches
            where t.phase == .ended || t.phase == .cancelled {
                s.touchesTotal += 1
                switch t.outcome {
                case .neverHit: s.touchesNeverHit += 1
                case .leftBounds: s.touchesLeftBounds += 1
                case .cancelled: s.touchesCancelled += 1
                default: break
                }
            }
            for d in r.state.dropped {
                s.droppedByReason[d.reason, default: 0] += 1
            }

            // Commit olguları **token'la eşleştirilerek** okunuyor: katlama
            // geri açılmış token'ları listeden çıkarıyor ve yalnız `actions`'a
            // bakan bir sayım geri alınmış commit'leri de sayardı (§12.6).
            var commitByToken: [TokenID: CanonicalSession.Action.Commit] = [:]
            for a in r.session.actions {
                guard let c = a.commit, let id = c.tokenID.value else { continue }
                commitByToken[id] = c
            }
            for token in r.state.tokens {
                s.tokens += 1
                if token.afterDivergence { s.tokensAfterDivergence += 1 }
                if token.invalidated { s.tokensInvalidated += 1 }
                if !token.touchCountAgrees { s.tokensTouchCountMismatch += 1 }
                guard let c = commitByToken[token.tokenID] else { continue }
                s.byCommitKind[c.kind, default: 0] += 1
                if c.label.matchesTarget == true { s.tokensMatchingTarget += 1 }
                if c.literalProtected { s.literalProtected += 1 }
                // Yanlış düzeltme: literal hedefe eşitken klavye başka bir
                // yüzey yazdı. `kind` şart değil — genişletme ve öneri de
                // doğruyu bozabilir.
                if let target = c.label.targetWord,
                   c.literal == target, c.committed != target {
                    s.wrongAutocorrects += 1
                }
            }

            let ext = r.calibration
            s.calibrationSamples += ext.samples.count
            s.excludedLengthMismatch += ext.excludedLengthMismatch
            s.excludedDiverged += ext.excludedDiverged
            s.excludedWeakLabel += ext.excludedWeakLabel
            s.excludedTouchCountMismatch += ext.excludedTouchCountMismatch
            s.recoveredDriftedTouches += ext.recoveredDriftedTouches
            if let why = ext.excludedSession {
                s.excludedSessions.append((r.url, why))
            }
            for smp in ext.samples { s.keyCoverage[smp.keyIndex, default: 0] += 1 }
        }
        return s
    }

    /// Kalibrasyon örneklerini tek öğreniciye toplar.
    ///
    /// Ayrı bir yardımcı, çünkü çağıranın hangi kayıtların dışlandığını da
    /// bilmesi gerekiyor ve `samples`'ı tek tek gezmek o bilgiyi kaybettiriyordu.
    public static func learner(from records: [Record]) -> CalibrationLearner {
        var l = CalibrationLearner()
        for r in records {
            for smp in r.calibration.samples { l.append(smp) }
        }
        return l
    }
}
