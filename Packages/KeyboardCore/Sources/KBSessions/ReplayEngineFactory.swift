import Foundation
import KBAssembly
import KBDecoder
import KBGeometry
import KBRuntime
import KBSpatial

/// Kayıttan **üretimle aynı** motoru kurar — plan v8 §2.8.
///
/// ## Neden ayrı bir fabrika değil de ortak kurulum
///
/// Motoru replay için ikinci kez kurmak, "replay üretimle aynı şeyi ölçüyor"
/// iddiasını doğrulanamaz yapardı. `PackLoader` bu yüzden `KBAssembly`'ye
/// taşındı; fabrika onu **çağırıyor**, taklit etmiyor.
///
/// ## Kod farkı ile ortam farkı
///
/// Kaydın revision'ı ile güncel revision'ın **farklı olması regression
/// replay'in amacıdır** — tek başına ortam uyuşmazlığı **değildir**. Ortam
/// uyuşmazlığı üç şeydir: paket hash'i, **layout parmak izi**, ya da
/// çözülemeyen paket. Bu ayrımı yapmayan bir replay her kod değişikliğini
/// "ortam bozuk" diye elerdi.
public enum ReplayEngineFactory {

    /// Replay'in ne kadar güvenilir olduğu.
    public struct Environment: Equatable, Sendable {
        /// Kayıttaki hash ile diskteki paket uyuşmuyor.
        public var packMismatches: [String] = []
        /// Kayıtta olup diskte bulunamayan paketler.
        public var missingPacks: [String] = []
        /// Layout içeriği değişmiş — `layoutID` aynı olsa bile.
        public var layoutMismatch: Bool = false
        /// Kayıtta `.unknown` olan ve replay'i etkileyen olgular.
        public var unknownFacts: [String] = []
        /// Kayıt ile bugünkü kodun revision'ı farklı.
        ///
        /// **Uyuşmazlık değil**: regression replay'in amacı tam olarak bu.
        public var codeRevisionDiffers: Bool = false

        /// Farkların "kod değişikliği" diye yorumlanabilmesi için ortamın
        /// eşleşmesi şart.
        public var isVerifiable: Bool {
            packMismatches.isEmpty && missingPacks.isEmpty
                && !layoutMismatch && unknownFacts.isEmpty
        }
    }

    public enum FactoryError: Error, CustomStringConvertible {
        case engineUnknown
        case packLoadFailed(String)

        public var description: String {
            switch self {
            case .engineUnknown:
                return "kayıtta motor anlık görüntüsü yok (v2 ya da yarım kalmış)"
            case let .packLoadFailed(d):
                return "paketler yüklenemedi: \(d)"
            }
        }
    }

    public struct Built {
        public var coordinator: InputCoordinator
        public var environment: Environment
    }

    /// - Parameter currentRevision: bugünkü kodun revision'ı; yalnız
    ///   raporlamak için — eşitsizlik replay'i geçersiz kılmaz.
    public static func make(for session: CanonicalSession,
                            layout: KeyLayout,
                            packs source: PackSource,
                            currentRevision: String? = nil) throws -> Built {
        let engine = session.engine
        guard let snapshot = engine.configuration.value else {
            throw FactoryError.engineUnknown
        }
        var env = Environment()

        // Layout parmak izi: `layoutID` tekil değil, aynı kimlikle tuş sırası
        // ve geometri değişebilir ve bu kod regresyonu diye sınıflanırdı.
        switch session.geometry.layoutFingerprint {
        case let .known(recorded):
            env.layoutMismatch = recorded != layout.fingerprint
        case .unknown:
            env.unknownFacts.append("layoutFingerprint")
        case .notApplicable:
            break
        }

        if let current = currentRevision,
           let recorded = engine.build.codeRevision.value {
            env.codeRevisionDiffers = current != recorded
        }

        // Skor modeli **yükleme sırasında** veriliyor: decoder'ın ağırlıkları
        // `let` ve olması gerektiği gibi — sonradan değiştirmek, motorun
        // yarısını bir konfigürasyonla, yarısını başkasıyla kurmak olurdu.
        //
        // Bilinmiyorsa varsayılana düşmek sessiz bir yalan: replay farkı "kod
        // değişti" diye okunurdu, oysa sebep kayda hiç girmemiş bir parametre.
        var scoreWeights = ScoreWeights()
        var sigmaMin = 0.012
        var channelWeights: ScoreWeights?
        var cUnk: Double?
        var prior: [UInt8: Double]?
        switch snapshot.scoring {
        case let .known(scoring):
            // Dönüşüm `EngineSnapshotCapture`'da, yazma yönünün **yanında**:
            // iki yön ayrı dosyalarda olsaydı biri güncellenip diğeri
            // unutulurdu.
            scoreWeights = scoring.decoder.scoreWeights
            sigmaMin = scoring.sigmaMin
            channelWeights = scoring.literalChannel.scoreWeights
            cUnk = scoring.cUnk
            prior = scoring.decoderLanguageModel.prior
        case .unknown:
            env.unknownFacts.append("scoring")
        case .notApplicable:
            break
        }

        let loaded: PackLoader.Loaded
        do {
            loaded = try PackLoader.load(layout: layout, source: source,
                                         beamWidth: snapshot.beamWidth,
                                         weights: scoreWeights,
                                         sigmaMin: sigmaMin,
                                         computeHashes: true)
        } catch {
            throw FactoryError.packLoadFailed("\(error)")
        }

        // Paket kimlikleri: ad **ve** hash. Yalnız ada bakmak, aynı adla
        // yeniden üretilmiş bir paketi aynı sanmak olurdu.
        let onDisk = Dictionary(loaded.packs.map { ($0.name, $0) },
                                uniquingKeysWith: { a, _ in a })
        for pack in snapshot.packs {
            guard let disk = onDisk[pack.name] else {
                env.missingPacks.append(pack.name)
                continue
            }
            switch pack.sha256 {
            case let .known(recorded):
                if disk.sha256 != recorded { env.packMismatches.append(pack.name) }
            case .unknown:
                env.unknownFacts.append("pack.sha256(\(pack.name))")
            case .notApplicable:
                break
            }
        }

        var coordinator = InputCoordinator(layout: layout)
        var decoder = loaded.decoder
        var channel = loaded.literalChannel
        if let p = prior { decoder.languageModel.prior = p }
        // Literal kanalının ağırlıkları decoder'ınkinden **ayrı** kaydediliyor:
        // `PackLoader` bugün onları eşitliyor ama bu bir çalışma anı davranışı,
        // şema değişmezi değil.
        if let w = channelWeights { channel.weights = w }
        if let c = cUnk { channel.cUnk = c }

        coordinator.setEngine(.init(decoder: decoder, literalChannel: channel,
                                    expansions: loaded.expansions))
        coordinator.oovTheta = snapshot.oovTheta
        coordinator.suggestionWindow = snapshot.suggestionWindow

        return Built(coordinator: coordinator, environment: env)
    }

}
