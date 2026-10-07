import Foundation
import Testing
@testable import KBGeometry
@testable import KBRuntime
@testable import KBSessions

/// Karışık dizin okuyucusu — plan v8 §2.7.
///
/// Asıl risk: yeni konteyner uzantısına geçmek diskte duran `*.json`
/// kayıtlarını **görünmez** bırakır. Kullanıcının bugüne kadar topladığı veri
/// sessizce yok olurdu.
@MainActor
@Suite("Kayıt kitaplığı")
struct RecordingLibraryTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        return url
    }

    private func writeLegacy(_ id: String, at dir: URL,
                             started: TimeInterval = 0) throws {
        var s = TypingSession(
            attemptID: id, participantID: "p", sessionOrdinal: 0,
            condition: .calibrationReplay, promptID: "p", promptText: "ev",
            promptSource: .builtin, split: "train", alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: started), posture: .init(),
            engine: .init(buildConfiguration: "Release", appVersion: "1",
                          packs: [.init(name: "tr", sha256: "a", bytes: 1)],
                          beamWidth: 128, oovTheta: 17, suggestionWindow: 3,
                          autoCorrectsOutOfVocabulary: true,
                          calibration: .init(applied: false, strongSamples: 0,
                                             globalX: 0, globalY: 0, rowX: [],
                                             rowY: [], keyX: [], keyY: [],
                                             biasX: [], biasY: []),
                          learningFrozen: true, codeRevision: "abc",
                          initialLanguage: nil),
            geometry: .init(layoutID: "tr-q", boundsX: 0, boundsY: 0,
                            boundsWidth: 393, boundsHeight: 216,
                            frameInScreenX: 0, frameInScreenY: 600,
                            frameInScreenWidth: 393, frameInScreenHeight: 216,
                            safeAreaBottom: 34, screenScale: 3,
                            interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
        s.status = .completed
        s.endedAt = Date(timeIntervalSince1970: started + 1)
        try SessionCodec.encoder.encode(s)
            .write(to: dir.appendingPathComponent("\(id).json"))
    }

    private func descriptor(_ id: String, started: TimeInterval)
        -> CanonicalSession {
        CanonicalSession(
            attemptID: id, participantID: "p", sessionOrdinal: 0,
            condition: .behavior, status: .recording,
            promptID: "p", promptText: "ev", promptSource: .builtin,
            split: "train", promptTokens: .known(["ev"]),
            alignmentSource: .constructed,
            startedAt: Date(timeIntervalSince1970: started),
            engine: RecordingTestSupport.unconfigured(),
            geometry: .init(layoutID: "tr-q", layoutFingerprint: .known("f"),
                            boundsX: 0, boundsY: 0, boundsWidth: 393,
                            boundsHeight: 216, frameInScreenX: 0,
                            frameInScreenY: 600, frameInScreenWidth: 393,
                            frameInScreenHeight: 216, safeAreaBottom: 34,
                            screenScale: 3, interfaceOrientation: "portrait",
                            deviceModel: "t", systemVersion: "18"))
    }

    /// Yalnız sona yazan belge — replay'in kullandığı tampon.
    private typealias Doc = RecordingTestSupport.Doc

    @discardableResult
    private func writeJournal(_ id: String, at dir: URL,
                              started: TimeInterval = 100,
                              finish: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent("\(id).bkj")
        let writer = try FileJournalWriter(url: url)
        let layout = KeyLayout(id: "test",
                               keys: [Key(char: "e", center: .init(x: 0.1, y: 0.5),
                                          width: 0.1, height: 0.3)],
                               asciiBase: [:])
        let e = RecordingEngine(writer: writer,
                                coordinator: InputCoordinator(layout: layout),
                                layout: layout)
        try e.begin(descriptor(id, started: started), at: 0)
        try RecordingTestSupport.configure(e)
        let doc = Doc()
        try e.record(.init(touchID: 0, phase: .ended, outcome: .committed,
                           rawX: 40, rawY: 100, normX: 0.1, normY: 0.5,
                           decoderX: 0.1, decoderY: 0.5, timestamp: 1,
                           majorRadius: 5, majorRadiusTolerance: 1,
                           plane: "letters", shift: "off",
                           hitKind: "letter", key: "e", keyIndex: 0))
        try e.perform(.init(command: .letter(baseKey: "e", display: "e",
                                             shifted: false),
                            touchID: 0, timestamp: 1), into: doc)
        try e.perform(.init(command: .space, timestamp: 2), into: doc)
        if finish { _ = try e.finish(.completed, at: 3, finalText: doc.text) }
        try writer.closeFile()
        return url
    }

    /// **Asıl kural.** Yeni biçime geçmek eskileri görünmez bırakamaz.
    @Test("İki biçim de listeleniyor")
    func bothFormatsAreListed() throws {
        let dir = try tempDir()
        try writeLegacy("eski", at: dir, started: 0)
        try writeJournal("yeni", at: dir, started: 100)

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.failures.isEmpty)
        #expect(listing.entries.count == 2)
        // En yeni önce.
        #expect(listing.entries[0].origin == .journal)
        #expect(listing.entries[1].origin == .legacyJSON)
        #expect(listing.entries.map { $0.session.attemptID } == ["yeni", "eski"])
    }

    @Test("Günlük kanonik oturuma katlanıyor")
    func journalFoldsToSession() throws {
        let dir = try tempDir()
        try writeJournal("a", at: dir)

        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        #expect(entry.session.status == .completed)
        #expect(entry.session.endedAt != nil)
        #expect(entry.session.touches.count == 1)
        #expect(entry.session.actions.count == 2)
        #expect(entry.session.finalText == "e ")
        #expect(!entry.truncatedTail)
    }

    /// Sessizce atlamak, bozuk bir kaydı hiç var olmamış gibi gösterip abort
    /// oranını bozardı.
    @Test("Bozuk dosya atlanmıyor, raporlanıyor")
    func corruptFileIsReported() throws {
        let dir = try tempDir()
        try writeLegacy("iyi", at: dir)
        try Data("çöp".utf8).write(to: dir.appendingPathComponent("kotu.json"))
        try Data("çöp".utf8).write(to: dir.appendingPathComponent("kotu.bkj"))

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.entries.count == 1)
        #expect(listing.failures.count == 2)
    }

    /// `attemptStarted` olmadan denemenin kimliği, hedefi ve koşulları yok;
    /// geri kalan frame'ler bağlamsız veri.
    @Test("attemptStarted'sız günlük reddediliyor")
    func journalWithoutAttemptStartIsRejected() throws {
        let dir = try tempDir()
        var d = SessionJournal.header()
        d.append(SessionJournal.encode(.init(type: .touch, payload: Data("{}".utf8))))
        try d.write(to: dir.appendingPathComponent("a.bkj"))

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.entries.isEmpty)
        #expect(listing.failures.first?.reason.contains("attemptStarted") == true)
    }

    /// Güç kaybı son frame'i yarım bırakabilir; kurtarılıyor ama **bildiriliyor**.
    @Test("Yarım kalan kuyruk bildiriliyor")
    func truncatedTailIsSurfaced() throws {
        let dir = try tempDir()
        let url = try writeJournal("a", at: dir)
        var data = try Data(contentsOf: url)
        data.removeLast(4)
        try data.write(to: url)

        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        #expect(entry.truncatedTail)
    }

    /// Kurtarma kararı zaman ve bağlam gerektiriyor; okuma sırasında verilecek
    /// bir karar değil. Okuyucu yalnız **buluyor**.
    @Test("Yarım kalmış kayıt bulunuyor ama işaretlenmiyor")
    func staleIsFoundNotMutated() throws {
        let dir = try tempDir()
        try writeJournal("yarim", at: dir, finish: false)

        let stale = RecordingLibrary.stale(in: dir)
        #expect(stale.count == 1)
        #expect(stale[0].session.status == .recording)
        // Dosya değişmedi: ikinci okuma da aynı sonucu vermeli.
        #expect(RecordingLibrary.stale(in: dir).count == 1)
    }

    /// Sıra-duyarsız bir okuyucuda iki `engineConfigured`'dan sonuncusu
    /// sessizce kazanıyor ve dosya kendi anlattığından başka bir denemeyi
    /// tarif ediyordu.
    @Test("İkinci engineConfigured reddediliyor")
    func secondConfigureIsRejected() throws {
        let dir = try tempDir()
        let url = try writeJournal("a", at: dir)
        var data = try Data(contentsOf: url)
        // Sona fazladan bir configure frame'i ekle.
        data.append(SessionJournal.encode(
            .init(type: .engineConfigured, payload: Data("{}".utf8))))
        try data.write(to: url)

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.entries.isEmpty)
        #expect(listing.failures.first?.reason.contains("terminalden sonra") == true
                || listing.failures.first?.reason.contains("ikinci") == true)
    }

    /// Terminal **son** frame olmak zorunda: sonrasına yazılan bir action,
    /// tamamlanmış bir denemeyi sonradan büyütürdü.
    @Test("Terminalden sonraki frame reddediliyor")
    func frameAfterTerminalIsRejected() throws {
        let dir = try tempDir()
        let url = try writeJournal("a", at: dir)
        var data = try Data(contentsOf: url)
        data.append(SessionJournal.encode(
            .init(type: .touch, payload: Data("{}".utf8))))
        try data.write(to: url)

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.entries.isEmpty)
        #expect(listing.failures.first?.reason.contains("terminalden sonra") == true)
    }

    /// Terminal katlanmış durumun özetini taşıyor; ikisi ayrışıyorsa ya yazıcı
    /// ya okuyucu yanlış ve sessizce birini seçmek en kötüsü.
    @Test("Terminal özeti türetimle çapraz doğrulanıyor")
    func terminalSummaryIsCrossChecked() throws {
        let dir = try tempDir()
        let url = try writeJournal("a", at: dir)
        var data = try Data(contentsOf: url)

        // Terminal frame'ini bozuk bir cursor ile yeniden yaz.
        let loaded = try SessionJournal.load(data).get()
        let kept = loaded.frames.dropLast()
        var rebuilt = SessionJournal.header()
        for f in kept { rebuilt.append(SessionJournal.encode(f)) }
        // Yük **gerçek tiple** kuruluyor. Elle yazılmış bir JSON, terminal
        // şemasına alan eklendiğinde sessizce çözülemez oluyor ve test artık
        // "bozuk cursor yakalanıyor mu"yu değil "JSON decode ediliyor mu"yu
        // sınıyordu — yakaladığı hata da başka bir hataydı.
        rebuilt.append(SessionJournal.encode(.init(
            type: .terminal,
            payload: try SessionCodec.encoder.encode(SessionJournal.Terminal(
                reason: "completed", at: 3, finalText: "e ", cursor: 99,
                promptTokenCount: 1, violations: [], unverifiable: [])))))
        data = rebuilt
        try data.write(to: url)

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.entries.isEmpty)
        #expect(listing.failures.first?.reason.contains("cursor") == true)
    }

    /// **Motor kurulmadan olay olamaz.**
    ///
    /// `configured` yalnız ikinci `engineConfigured`'ı engelliyordu; üretimde
    /// imkânsız olan `attemptStarted → action → engineConfigured` sırası kabul
    /// ediliyor ve kayıt, eylemlerin hangi motorla üretildiği hakkında yanlış
    /// bir şey söylüyordu.
    @Test("engineConfigured'dan önceki olay reddediliyor")
    func eventBeforeConfigureIsRejected() throws {
        let dir = try tempDir()
        let url = try writeJournal("a", at: dir)
        let loaded = try SessionJournal.load(try Data(contentsOf: url)).get()
        // Frame'leri yeniden sırala: action'ı configure'ın önüne al.
        var reordered = [loaded.frames[0]]
        reordered += loaded.frames.dropFirst().filter { $0.type != .engineConfigured }
        reordered.insert(
            try #require(loaded.frames.first { $0.type == .engineConfigured }),
            at: min(2, reordered.count))
        var data = SessionJournal.header()
        for f in reordered { data.append(SessionJournal.encode(f)) }
        try data.write(to: url)

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.entries.isEmpty)
        #expect(listing.failures.first?.reason.contains("önce") == true,
                "\(listing.failures)")
    }

    /// Başlıktaki şema **okunuyor**: konteyner kendi içeriği hakkında iddiada
    /// bulunuyor ve iddiayı yok sayıp yükten çıkarım yapmak, dosyanın kendi
    /// anlattığını görmezden gelmek olurdu.
    @Test("Bilinmeyen şema iddiası reddediliyor")
    func unsupportedSchemaInHeaderIsRejected() throws {
        let dir = try tempDir()
        let url = try writeJournal("a", at: dir)
        var data = try Data(contentsOf: url)
        // Başlıktaki şema alanı: magic(4) + containerVersion(2).
        data[data.startIndex + 6] = 4
        data[data.startIndex + 7] = 0
        try data.write(to: url)
        #expect(SessionJournal.load(data) == .failure(.unsupportedSchema(4)))
        #expect(RecordingLibrary.list(in: dir).entries.isEmpty)
    }

    /// Dizin okunamadı ≠ dizin boş. İkisini tek sonuca indirmek, izin sorununu
    /// "hiç kayıt yok" diye gösterirdi.
    /// **Sonradan eklenen not günlüğe dokunmuyor.**
    ///
    /// Append-only konteynerde terminal son frame ve sonrasına ekleme
    /// reddediliyor. Yan dosya bunu bir kısıt değil, doğru modelleme yapıyor:
    /// not gözlem değil, gözlem hakkında bir yorum — ve "o an mı yazdı,
    /// sonradan mı" ayrımı ancak ayrı durunca korunuyor.
    @Test("Sonradan eklenen not kaydı değiştirmiyor")
    func annotationDoesNotTouchTheJournal() throws {
        let dir = try tempDir()
        let url = try writeJournal("a", at: dir)
        let before = try Data(contentsOf: url)

        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        #expect(entry.annotation == nil)
        try RecordingLibrary.setAnnotation("boşluk çalışmadı", for: entry)

        #expect(try Data(contentsOf: url) == before, "günlük değişmemeli")
        let reread = try #require(RecordingLibrary.list(in: dir).entries.first)
        #expect(reread.annotation == "boşluk çalışmadı")
        // Kaydın kendi notu **ayrı** kalıyor.
        #expect(reread.session.note == nil)

        // Boş not = not yok; boş dosya bırakmak "yazdı ama bir şey söylemedi"
        // gibi görünürdü.
        try RecordingLibrary.setAnnotation("   ", for: reread)
        #expect(RecordingLibrary.list(in: dir).entries.first?.annotation == nil)
    }

    /// **Aynı kök adlı iki kayıt notu paylaşmıyor.**
    ///
    /// Not dosyası uzantıyı atıyordu (`a.json` ve `a.bkj` ikisi de `a.bknote`):
    /// birine not eklemek ikisinde görünüyor, birini silmek diğerinin notunu
    /// siliyordu. İki biçim testi farklı kök adlar kullandığı için görünmüyordu.
    @Test("Aynı kök adlı iki kayıt notu paylaşmıyor")
    func recordsWithTheSameStemDoNotShareANote() throws {
        let dir = try tempDir()
        _ = try writeJournal("a", at: dir)
        try writeLegacy("a", at: dir)
        let entries = RecordingLibrary.list(in: dir).entries
        #expect(entries.count == 2)
        let journal = try #require(entries.first { $0.origin == .journal })
        let legacy = try #require(entries.first { $0.origin == .legacyJSON })

        try RecordingLibrary.setAnnotation("boşluk bozuldu", for: journal)
        let after = RecordingLibrary.list(in: dir).entries
        #expect(after.first { $0.origin == .journal }?.annotation == "boşluk bozuldu")
        #expect(after.first { $0.origin == .legacyJSON }?.annotation == nil,
                "not diğer kayda sızmamalı")

        // Legacy'yi silmek journal'ın notunu **götürmemeli**.
        try RecordingLibrary.delete(legacy)
        #expect(RecordingLibrary.list(in: dir).entries.first?.annotation
                == "boşluk bozuldu")
    }

    /// Kayıt silinince notu da gidiyor (§12.9: silme hakkı toptan).
    @Test("Silinen kaydın notu da siliniyor")
    func deletingARecordRemovesItsAnnotation() throws {
        let dir = try tempDir()
        _ = try writeJournal("a", at: dir)
        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        try RecordingLibrary.setAnnotation("bir şey", for: entry)
        try RecordingLibrary.delete(entry)
        // Yan dosya kalırsa sahibi olmayan bir yorum bırakılmış olur.
        #expect(try FileManager.default
            .contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// Not dosyası **kayıt sanılmıyor**.
    @Test("Not dosyası listede kayıt olarak görünmüyor")
    func annotationFileIsNotListedAsARecording() throws {
        let dir = try tempDir()
        _ = try writeJournal("a", at: dir)
        let entry = try #require(RecordingLibrary.list(in: dir).entries.first)
        try RecordingLibrary.setAnnotation("not", for: entry)
        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.entries.count == 1)
        #expect(listing.failures.isEmpty, "\(listing.failures)")
    }

    /// **Hiç oluşmamış dizin hata değil.**
    ///
    /// Kayıt dizinini ilk `FileJournalWriter` yaratıyor; temiz kurulumda yokluğu
    /// normal. Cihazda liste ekranı bu yüzden kırmızı bir `NSCocoaErrorDomain
    /// 260` basıyordu ve analiz aracı hiç kayıt üretilmemiş bir cihazda 1 ile
    /// çıkıyordu — yani "veri yok" ile "bir şey bozuk" karışmıştı.
    @Test("Var olmayan dizin boş liste, hata değil")
    func missingDirectoryIsEmptyNotAFailure() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let listing = RecordingLibrary.list(in: missing)
        #expect(listing.entries.isEmpty)
        #expect(listing.failures.isEmpty, "\(listing.failures)")
        // `stale` de patlamıyor: kurtarma yolu ilk açılışta hata göstermemeli.
        #expect(RecordingLibrary.stale(in: missing).isEmpty)
    }

    /// İzin sorunu **hata**: "hiç kayıt yok" diye göstermek bozukluğu gizlerdi.
    ///
    /// Eski hâli var olmayan bir yol kullanıyordu ve o yol artık meşru bir boş
    /// durum — yani test okunamazlığı hiç sınamıyor, ENOENT'i sınıyordu. Gerçek
    /// bir izin hatası üretiliyor.
    @Test("Okunamayan dizin boş liste değil")
    func unreadableDirectoryIsAFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: dir.path)
        // root olarak koşan bir ortamda izin yine de geçerdi; o durumda test
        // hiçbir şey kanıtlamıyor demektir ve bunu sessizce yeşile saymıyoruz.
        try withKnownIssue("root olarak koşuluyor: izin kapısı uygulanmıyor",
                           isIntermittent: true) {
            let listing = RecordingLibrary.list(in: dir)
            #expect(listing.entries.isEmpty)
            #expect(listing.failures.count == 1)
            #expect(listing.failures.first?.reason.contains("dizin okunamadı")
                    == true)
        }
    }

    @Test("İlgisiz dosyalar yok sayılıyor")
    func unrelatedFilesAreIgnored() throws {
        let dir = try tempDir()
        try writeLegacy("iyi", at: dir)
        try Data().write(to: dir.appendingPathComponent(".gecici.tmp"))
        try Data().write(to: dir.appendingPathComponent("notlar.txt"))

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.entries.count == 1)
        #expect(listing.failures.isEmpty)
    }
}
