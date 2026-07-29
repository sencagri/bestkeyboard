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

        /// Fark yok **ve** her şey karşılaştırılabildi.
        public var isClean: Bool {
            divergences.isEmpty && unverifiable.isEmpty
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
        let touches = Dictionary(session.touches.map { ($0.touchID, $0) },
                                 uniquingKeysWith: { a, _ in a })

        var divergences: [Divergence] = []
        var unverifiable: [Int] = []
        var compared = 0

        for action in session.actions {
            guard let command = action.event.value else {
                // v2'den gelen kayıtlarda komut bilinmiyor; motoru
                // "muhtemelen şuydu" diye sürmek replay'i uydurmak olurdu.
                unverifiable.append(action.actionID)
                continue
            }

            switch command {
            case let .letter(baseKey, display, shifted):
                guard let id = action.touchID, let t = touches[id],
                      let ch = baseKey.first, baseKey.count == 1 else {
                    unverifiable.append(action.actionID)
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
                let report = coordinator.space(into: buffer)
                compare(report, with: action, into: &divergences)
                compared += 1

            case .newline:
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

        // Nihai metin: replay'in ürettiği belge kayıtla aynı olmalı.
        if session.status != .recording, !session.finalText.isEmpty,
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
        add(&out, action.actionID, "touchCount",
            "\(recorded.touchCount)", "\(report.touchCount)")
        // `Δ` ve `θ` kayan nokta: birebir eşitlik istemek her toolchain
        // sürümünde sahte fark üretirdi. Eşik ölçüm gürültüsünün altında.
        addNumeric(&out, action.actionID, "delta", recorded.delta, report.delta)
        addNumeric(&out, action.actionID, "theta", recorded.theta, report.theta)
        add(&out, action.actionID, "bestWord",
            recorded.bestWord ?? "-", report.bestWord ?? "-")
    }

    private static func compare(_ effect: DestructiveEffect,
                                with action: CanonicalSession.Action,
                                into out: inout [Divergence]) {
        guard let recorded = action.effect.value else { return }
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
