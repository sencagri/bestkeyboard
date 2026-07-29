import Foundation
import Testing
@testable import KBRuntime
@testable import KBSessions

/// Konteyner ve belge yeniden kurulumu — plan v8 §2.7.
@Suite("Günlük konteyneri")
struct SessionJournalTests {

    private func journal(_ frames: [SessionJournal.Frame]) -> Data {
        var d = SessionJournal.header()
        for f in frames { d.append(SessionJournal.encode(f)) }
        return d
    }

    private let sample: [SessionJournal.Frame] = [
        .init(type: .attemptStarted, payload: Data("a".utf8)),
        .init(type: .touch, payload: Data("t".utf8)),
        .init(type: .action, payload: Data("x".utf8)),
        .init(type: .terminal, payload: Data("z".utf8)),
    ]

    @Test("Frame'ler sırasıyla gidip geliyor")
    func roundTrip() throws {
        let loaded = try SessionJournal.load(journal(sample)).get()
        #expect(loaded.frames == sample)
        #expect(!loaded.truncatedTail)
    }

    @Test("Günlük olmayan dosya reddediliyor")
    func nonJournalRejected() {
        #expect(SessionJournal.load(Data("{}".utf8)) == .failure(.notAJournal))
    }

    @Test("Frame'siz günlük reddediliyor")
    func emptyRejected() {
        #expect(SessionJournal.load(SessionJournal.header())
                == .failure(.emptyJournal))
    }

    /// Güç kaybı son frame'i yarım bırakabilir. Onu kurtarmak meşru — ama
    /// **sessizce** kırpmak değil: kaybolan bir action hiç olmamış gibi
    /// görünürdü.
    @Test("Yarım kalan SON frame kurtarılıyor ve bildiriliyor")
    func truncatedTailIsRecoverable() throws {
        var d = journal(sample)
        d.removeLast(3)                       // son frame'in yükü yarım
        let loaded = try SessionJournal.load(d).get()
        #expect(loaded.frames.count == 3)
        #expect(loaded.truncatedTail, "kayıp sessizce geçilmemeli")
    }

    @Test("Yarım kalan frame BAŞLIĞI da kurtarılıyor")
    func truncatedHeaderIsRecoverable() throws {
        var d = journal(sample)
        d.removeLast(sample[3].payload.count + 5)   // başlığın ortasında kesildi
        let loaded = try SessionJournal.load(d).get()
        #expect(loaded.frames.count == 3)
        #expect(loaded.truncatedTail)
    }

    /// Ortadaki bozuk frame'i atlamak, kaydın ortasından bir olayı sessizce
    /// silmek ve katlamayı yanlış sonuca götürmek olurdu.
    @Test("Ortadaki bozuk frame yükleme hatası")
    func corruptMiddleFrameIsFatal() {
        var d = journal(sample)
        // İkinci frame'in yükünü boz: dosya başlığı(8) + f0(13+1) + f1 başlığı(13).
        let offset = 8 + 14 + 13
        d[d.startIndex + offset] = 0xFF
        switch SessionJournal.load(d) {
        case let .failure(.corruptFrame(index, _)): #expect(index == 1)
        case let other: Issue.record("beklenen corruptFrame, gelen: \(other)")
        }
    }

    @Test("Tanınmayan frame türü yükleme hatası")
    func unknownFrameTypeIsFatal() {
        var d = journal(sample)
        d[d.startIndex + 8 + 14] = 99          // ikinci frame'in türü
        switch SessionJournal.load(d) {
        case let .failure(.corruptFrame(_, detail)): #expect(detail.contains("99"))
        case let other: Issue.record("beklenen corruptFrame, gelen: \(other)")
        }
    }

    /// Konteyner biçimi ile içerik şeması bağımsız evrilmeli; tek sürüm
    /// numarası, çerçevelemeye dokunmayan bir şema değişikliğinde eski
    /// dosyaları okunamaz yapardı.
    @Test("Bilinmeyen konteyner sürümü reddediliyor")
    func unsupportedContainerRejected() {
        var d = journal(sample)
        d[d.startIndex + 4] = 99
        #expect(SessionJournal.load(d) == .failure(.unsupportedContainer(99)))
    }

    /// **Codex bulgusu.** Uzunluk alanı yük checksum'ının kapsamında değil ve
    /// olamaz: checksum'ı doğrulamak için yükü, yükü okumak için uzunluğu
    /// bilmek gerekiyor. Ortadaki bir frame'in uzunluğu dosyadan büyük bir
    /// değere bozulursa okuyucu bunu "yarım son frame" sayıp arkasındaki
    /// **sağlam** frame'leri sessizce atıyordu.
    @Test("Ortadaki bozuk uzunluk yarım kuyruk sanılmıyor")
    func corruptLengthIsNotMistakenForTruncation() {
        var d = journal(sample)
        // İkinci frame'in uzunluk alanı: dosya başlığı(8) + f0(14) + tür(1).
        let lengthOffset = 8 + 14 + 1
        d[d.startIndex + lengthOffset] = 0xFF
        d[d.startIndex + lengthOffset + 1] = 0xFF

        switch SessionJournal.load(d) {
        case let .failure(.corruptFrame(index, detail)):
            #expect(index == 1)
            #expect(detail.contains("tümleyen"))
        case let other:
            Issue.record("sağlam frame'ler sessizce atıldı: \(other)")
        }
    }
}

/// Belge yeniden kurulumu — plan v8 §2.7.
@Suite("Belge yeniden kurulumu")
struct DocumentReconstructionTests {

    private func delta(_ mutations: [DocumentMutation], after text: String)
        -> Epistemic<CanonicalSession.Action.DocumentDelta> {
        .known(.init(mutations: mutations,
                     hashAfter: DocumentReconstruction.hash(text)))
    }

    private func session(_ deltas: [Epistemic<CanonicalSession.Action.DocumentDelta>],
                         finalText: String = "",
                         status: CanonicalSession.Status = .completed)
        -> CanonicalSession {
        CanonicalSession(
            attemptID: "t", participantID: "p", sessionOrdinal: 0,
            condition: .behavior, status: status,
            promptID: "p", promptText: "", promptSource: .builtin,
            split: "train", promptTokens: .known([]),
            alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: status == .recording ? nil : Date(timeIntervalSince1970: 1),
            engine: .unconfigured(),
            geometry: .init(layoutID: "tr-q", layoutFingerprint: .known("f"),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"),
            actions: deltas.enumerated().map { i, d in
                .init(actionID: i, t: Double(i), kind: .letter, touchID: nil,
                      event: .unknown, effect: .notApplicable, document: d,
                      targetTokenIndex: nil, targetToken: nil,
                      candidates: .notApplicable, shown: .notApplicable,
                      commit: nil)
            },
            finalText: finalText)
    }

    @Test("Metin mutasyonlardan kuruluyor")
    func replayBuildsText() throws {
        let s = session([delta([.insert("e")], after: "e"),
                         delta([.insert("v")], after: "ev"),
                         delta([.insert(" ")], after: "ev ")],
                        finalText: "ev ")
        #expect(try DocumentReconstruction.replay(s) == .complete("ev "))
    }

    /// Yanlış bir mutasyon dizisi de kendi içinde tutarlı görünür; özet
    /// türetimin **gerçekten** olanı ürettiğini kanıtlıyor.
    @Test("Özet uyuşmazlığı yakalanıyor")
    func hashMismatchIsCaught() {
        let s = session([delta([.insert("e")], after: "YANLIŞ")])
        #expect(throws: DocumentReconstruction.Failure.self) {
            try DocumentReconstruction.replay(s)
        }
    }

    @Test("Underflow yakalanıyor")
    func underflowIsCaught() {
        let s = session([delta([.deleteBackward(count: 3)], after: "")])
        #expect(throws: DocumentReconstruction.Failure.self) {
            try DocumentReconstruction.replay(s)
        }
    }

    /// Silme birimi **grapheme**: `"\r\n"` Swift'te tek `Character` ve
    /// `ComposingSession.deleteBackward` onu tek birim sayıyor. UTF-16
    /// saysaydık bir birim fazla silerdik.
    @Test("Silme birimi grapheme, UTF-16 değil")
    func deletionCountsGraphemes() throws {
        var text = "a\r\n"
        #expect(text.utf16.count == 3)
        try DocumentReconstruction.apply([.deleteBackward(count: 1)],
                                         to: &text, actionID: 0)
        #expect(text == "a", "CRLF tek birim")
    }

    @Test("Emoji de tek grapheme sayılıyor")
    func emojiIsOneGrapheme() throws {
        var text = "a👨‍👩‍👧"
        try DocumentReconstruction.apply([.deleteBackward(count: 1)],
                                         to: &text, actionID: 0)
        #expect(text == "a")
    }

    @Test("Terminal metin uyuşmazlığı yakalanıyor")
    func finalTextMismatchIsCaught() {
        let s = session([delta([.insert("ev")], after: "ev")], finalText: "başka")
        #expect(throws: DocumentReconstruction.Failure.self) {
            try DocumentReconstruction.replay(s)
        }
    }

    /// v2'den migrate edilmiş kayıtta mutasyon yok; türetim orada **durur**
    /// ama bu bir hata değil, bilgi eksikliği.
    /// Düz `String` döndürmek, çağıranın **tam** metni mi yoksa kesilmiş bir
    /// öneki mi aldığını ayırt etmesini imkânsız kılıyordu.
    @Test("Bilinmeyen delta hata değil ama sonuç doğrulanamaz")
    func unknownDeltaStopsWithoutError() throws {
        let s = session([delta([.insert("e")], after: "e"), .unknown],
                        finalText: "")
        #expect(try DocumentReconstruction.replay(s)
                == .unverifiable(prefix: "e", fromAction: 1))
    }

    /// **Codex bulgusu.** Boş `finalText` de bir iddia: eylemleri `"ev"` üreten
    /// tamamlanmış bir kayıt boş metinle geçiyordu, çünkü boşluk
    /// karşılaştırmadan muaf tutulmuştu.
    @Test("Boş finalText karşılaştırmadan muaf değil")
    func emptyFinalTextIsStillCompared() {
        let s = session([delta([.insert("ev")], after: "ev")], finalText: "")
        #expect(throws: DocumentReconstruction.Failure.self) {
            try DocumentReconstruction.replay(s)
        }
    }
}
