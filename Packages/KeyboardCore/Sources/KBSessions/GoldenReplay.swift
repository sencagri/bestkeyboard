import Foundation
import KBAssembly
import KBGeometry
import KBRuntime
import KBSpatial

/// Kaydı **bağımsız** olarak yeniden oynatır ve çıktısını kayıtla karşılaştırır
/// — plan v8 §2.9.
///
/// ## Neden bağımsız
///
/// Kaydedilmiş sonucu motora geri beslemek replay'i bir doğrulama olmaktan
/// çıkarır: motor zaten "doğru" cevabı almış olur ve her zaman uyuşur. Burada
/// motor yalnız **komutlarla** sürülüyor (hangi tuşa basıldı, boşluk, silme) ve
/// ürettiği commit kararı kayıtla karşılaştırılıyor.
///
/// ## Fark ne anlama geliyor
///
/// Fark tek başına "hata" değil — regression replay'in **amacı** kod
/// değişikliğinin sonucu nasıl değiştirdiğini görmek. Anlamlı olması için
/// ortamın eşleşmesi gerekiyor: `Environment.isVerifiable` yanlışsa fark kod
/// farkı diye okunamaz.
public enum GoldenReplay {

    public struct Divergence: Equatable, Sendable, CustomStringConvertible {
        public let actionID: Int
        public let field: String
        public let recorded: String
        public let replayed: String

        public var description: String {
            "action \(actionID) · \(field): kayıt \"\(recorded)\", replay \"\(replayed)\""
        }
    }

    public struct Report: Sendable {
        public var environment: ReplayEngineFactory.Environment
        public var divergences: [Divergence]
        /// Karşılaştırılan action sayısı.
        public var compared: Int
        /// Olgusu bilinmediği için **karşılaştırılamayan** action'lar.
        ///
        /// Sayılıyor ve raporlanıyor: sessizce atlamak, doğrulanmamış bir
        /// kaydı "hiç fark yok" diye göstermek olurdu.
        public var unverifiable: [Int]

        /// Fark yok, her şey karşılaştırılabildi **ve** ortam eşleşiyor.
        ///
        /// Ortamı hesaba katmamak en tehlikelisiydi: paketleri farklı bir
        /// makinede koşan replay "hiç fark yok" diyebiliyordu, oysa
        /// karşılaştırdığı şey başka bir motordu.
        public var isClean: Bool {
            divergences.isEmpty && unverifiable.isEmpty
                && environment.isVerifiable
        }
    }

    /// Replay sırasında belgeyi tutan tampon.
    ///
    /// Host yok; kayıt zaten host'un ne yaptığını değil **bizim** ne yazdığımızı
    /// ölçüyor. Seçim desteklenmiyor: §12 kaydında seçim türevi olgu
    /// bulunamıyor (`selectedText` daima `nil`), dolayısıyla replay'in de
    /// seçime girmesi gerekmiyor.
    private final class Buffer: DocumentEditor {
        var text = ""
        func insertText(_ t: String) { text += t }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }
        var contextBeforeInput: String? { text }
        var contextAfterInput: String? { "" }
        var selectedText: String? { nil }
    }

    public static func run(_ session: CanonicalSession,
                           layout: KeyLayout,
                           packs: PackSource,
                           currentRevision: String? = nil) throws -> Report {
        let built = try ReplayEngineFactory.make(for: session, layout: layout,
                                                 packs: packs,
                                                 currentRevision: currentRevision)
        var coordinator = built.coordinator
        let buffer = Buffer()
        // **Son** faz — canlı motorun decoder'a verdiği nokta. İlk fazı
        // sürmek replay'i kayıttan farklı bir kanıtla besliyordu.
        let touches = session.terminalTouches

        var divergences: [Divergence] = []
        var unverifiable: [Int] = []
        var compared = 0

        // Bilinmeyen bir **durum değiştiren** olaydan sonra motor kayıttan
        // ayrışıyor: sonraki her karşılaştırma iki farklı geçmişi kıyaslar ve
        // sahte fark üretir. O noktadan itibaren hepsi doğrulanamaz.
        var desynced = false

        for action in session.actions {
            guard !desynced else {
                unverifiable.append(action.actionID)
                continue
            }
            guard let command = action.event.value else {
                // v2'den gelen kayıtlarda komut bilinmiyor; motoru
                // "muhtemelen şuydu" diye sürmek replay'i uydurmak olurdu.
                unverifiable.append(action.actionID)
                // Kip durumu değiştiriyorsa suffix de doğrulanamaz.
                if action.kind != .shift && action.kind != .planeChange {
                    desynced = true
                }
                continue
            }

            switch command {
            case let .letter(baseKey, display, shifted):
                guard let id = action.touchID, let t = touches[id],
                      let ch = baseKey.first, baseKey.count == 1,
                      // Decoder'a verilen nokta yoksa harfi `(0,0)`'dan
                      // sürmek uzamsal kanıtı **uydurmak** olurdu.
                      t.decoderX != nil || t.normX != nil else {
                    unverifiable.append(action.actionID)
                    desynced = true
                    continue
                }
                let s = sample(from: t)
                if shifted {
                    coordinator.insertUppercaseLetter(ch, uppercase: display,
                                                      touch: s, into: buffer)
                } else {
                    coordinator.insertLetter(ch, touch: s, into: buffer)
                }

            case let .symbol(sym):
                guard let ch = sym.first, sym.count == 1 else {
                    unverifiable.append(action.actionID)
                    continue
                }
                let report = coordinator.insertSymbol(ch, into: buffer)
                compare(report, with: action, into: &divergences)
                compared += 1

            case .space:
                // Adaylar **commit'ten önce**: sınır beam'i sıfırlıyor.
                compareCandidates(coordinator, with: action, into: &divergences)
                let report = coordinator.space(into: buffer)
                compare(report, with: action, into: &divergences)
                compared += 1

            case .newline:
                // Adaylar **commit'ten önce**: sınır beam'i sıfırlıyor.
                compareCandidates(coordinator, with: action, into: &divergences)
                let report = coordinator.newline(into: buffer)
                compare(report, with: action, into: &divergences)
                compared += 1

            case let .suggestionPick(_, surface, _):
                let report = coordinator.pickSuggestion(surface, into: buffer)
                compare(report, with: action, into: &divergences)
                compared += 1

            case .backspaceTap:
                compare(coordinator.backspaceTap(into: buffer),
                        with: action, into: &divergences)
                compared += 1

            case .backspaceRepeat:
                compare(coordinator.backspaceRepeat(into: buffer),
                        with: action, into: &divergences)
                compared += 1

            case .deleteWord:
                compare(coordinator.deleteWord(into: buffer),
                        with: action, into: &divergences)
                compared += 1

            case .planeChange, .shift:
                // Düzlem ve shift motorun durumuna dokunmuyor; yüzey farkı
                // zaten `letter` komutunun `display` alanında.
                continue
            }
        }

        // Nihai metin: replay'in ürettiği belge kayıtla aynı olmalı — **ama
        // yalnız replay kayıtla aynı geçmişi sürdüyse**. Ayrışmış bir
        // tampondan fark üretmek, bilinmeyen bir olguyu "kod değişti" diye
        // raporlamak olurdu.
        if !desynced, session.status != .recording, !session.finalText.isEmpty,
           session.finalText != buffer.text {
            divergences.append(.init(actionID: -1, field: "finalText",
                                     recorded: session.finalText,
                                     replayed: buffer.text))
        }

        return Report(environment: built.environment, divergences: divergences,
                      compared: compared, unverifiable: unverifiable)
    }

    // MARK: - Karşılaştırma

    private static func compare(_ report: InputCoordinator.TokenCommitReport,
                                with action: CanonicalSession.Action,
                                into out: inout [Divergence]) {
        guard let recorded = action.commit else {
            // Kayıtta commit yok ama replay bir token kapattıysa bu bir fark.
            if report.kind != .empty {
                out.append(.init(actionID: action.actionID, field: "commit",
                                 recorded: "yok", replayed: report.committed))
            }
            return
        }
        add(&out, action.actionID, "kind",
            recorded.kind.rawValue, report.kind.rawValue)
        add(&out, action.actionID, "committed",
            recorded.committed, report.committed)
        add(&out, action.actionID, "literal", recorded.literal, report.literal)
        // `displayBefore` düzeltmeden **önceki** yüzey; `committed` ile aynı
        // olmadığı durumlar tam da düzeltmenin çalıştığı durumlar.
        add(&out, action.actionID, "displayBefore",
            recorded.displayBefore, report.displayBefore)
        add(&out, action.actionID, "touchCount",
            "\(recorded.touchCount)", "\(report.touchCount)")
        add(&out, action.actionID, "language",
            recorded.language.map { "\($0)" } ?? "-",
            report.language.map { "\($0)" } ?? "-")
        add(&out, action.actionID, "casingApplied",
            "\(recorded.casingApplied)", "\(report.casingApplied)")
        // `θ = ∞` ayrı bayrakta; koruma kararının değişmesi sessiz kalmamalı.
        add(&out, action.actionID, "literalProtected",
            "\(recorded.literalProtected)",
            "\(report.theta?.isFinite == false)")
        add(&out, action.actionID, "bestCost",
            recorded.bestCost.map { "\($0)" } ?? "-",
            report.bestCost.map { "\($0)" } ?? "-")
        add(&out, action.actionID, "tokenID",
            recorded.tokenID.value.map { "\($0.raw)" } ?? "-",
            report.tokenID.map { "\($0.raw)" } ?? "-")
        // `Δ` ve `θ` kayan nokta: birebir eşitlik istemek her toolchain
        // sürümünde sahte fark üretirdi. Eşik ölçüm gürültüsünün altında.
        addNumeric(&out, action.actionID, "delta", recorded.delta, report.delta)
        addNumeric(&out, action.actionID, "theta", recorded.theta, report.theta)
        add(&out, action.actionID, "bestWord",
            recorded.bestWord ?? "-", report.bestWord ?? "-")
    }

    /// Aday ve gösterilen listeleri — decoder'ın **sıralaması** dahil.
    ///
    /// Sıra anlamlı: kullanıcı ilk üçü görüyor ve sıra değişmesi hangi adayın
    /// göründüğünü değiştiriyor.
    private static func compareCandidates(
        _ coordinator: InputCoordinator,
        with action: CanonicalSession.Action,
        into out: inout [Divergence]) {
        guard let recorded = action.candidates.value else { return }
        let replayed = coordinator.candidates(topK: 8)
        add(&out, action.actionID, "candidates",
            recorded.map { "\($0.word)@\($0.cost)" }.joined(separator: ","),
            replayed.map { "\($0.word)@\($0.cost)" }.joined(separator: ","))
        add(&out, action.actionID, "candidates.emitCount",
            recorded.map { $0.emitCount.value.map(String.init) ?? "-" }
                .joined(separator: ","),
            replayed.map { "\($0.emitCount)" }.joined(separator: ","))
    }

    private static func compare(_ effect: Epistemic<DestructiveEffect>,
                                with action: CanonicalSession.Action,
                                into out: inout [Divergence]) {
        guard let recorded = action.effect.value, let effect = effect.value
        else { return }
        guard recorded != effect else { return }
        out.append(.init(actionID: action.actionID, field: "effect",
                         recorded: "\(recorded)", replayed: "\(effect)"))
    }

    private static func add(_ out: inout [Divergence], _ id: Int,
                            _ field: String, _ a: String, _ b: String) {
        guard a != b else { return }
        out.append(.init(actionID: id, field: field, recorded: a, replayed: b))
    }

    private static func addNumeric(_ out: inout [Divergence], _ id: Int,
                                   _ field: String, _ a: Double?, _ b: Double?) {
        switch (a, b) {
        case (nil, nil): return
        case let (x?, y?) where abs(x - y) < 1e-9: return
        default:
            out.append(.init(actionID: id, field: field,
                             recorded: a.map { "\($0)" } ?? "-",
                             replayed: b.map { "\($0)" } ?? "-"))
        }
    }

    private static func sample(from t: CanonicalSession.Touch) -> TouchSample {
        TouchSample(down: Point(x: t.decoderX ?? t.normX ?? 0,
                                y: t.decoderY ?? t.normY ?? 0),
                    timestamp: t.timestamp)
    }
}
