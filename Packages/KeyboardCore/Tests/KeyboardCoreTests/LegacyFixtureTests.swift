import Foundation
import Testing
@testable import KBGeometry
@testable import KBRuntime
@testable import KBSessions

/// Depoda duran **v2** kaydı — migrasyon yolunun donuk kanıtı.
///
/// ## Neden gerekiyordu
///
/// `kbbench --write-fixture` bir v2 JSON üretiyordu ve dosya `Data/` altında
/// duruyordu, ama **hiçbir şey onu okumuyordu**. Yani şema kayarsa ya da
/// migrasyon bozulursa dosya sessizce geçersiz oluyor ve bunu ancak elle
/// bakınca görüyorduk — tam olarak `golden-v3.bkj`'nin çözdüğü sorunun v2
/// karşılığı, çözümsüz hâli.
///
/// v2 yolu ölü değil: kullanıcının diskinde eski kayıtlar var ve
/// `RecordingLibrary` onları hâlâ okuyor.
///
/// ## Neden kod içi fixture yetmiyor
///
/// Kod içinde kurulan bir v2 nesnesi şemayla **birlikte** güncelleniyor:
/// bir alan eklenince derleyici onu zorluyor ve test yeşil kalıyor. Diskteki
/// dosya donuk; migrasyon bir olguyu düşürmeye başlarsa burada görünür.
@Suite("Eski (v2) fixture")
struct LegacyFixtureTests {

    private static let name = "golden-v2.json"

    private static var url: URL? {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil)
    }

    @Test("Depodaki v2 kaydı migrasyondan geçiyor")
    func legacyFixtureMigrates() throws {
        let url = try #require(Self.url,
                               "fixture bundle'da yok — Package.swift resources?")
        let data = try Data(contentsOf: url)

        // **Kitaplık üzerinden**: üretimdeki okuyucu bu. `SessionReader`'ı
        // doğrudan çağırmak, `.json` uzantısının kitaplıkta tanınıp
        // tanınmadığını atlardı — v3'e geçerken tam da o unutulmuştu.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try data.write(to: dir.appendingPathComponent(Self.name))

        let listing = RecordingLibrary.list(in: dir)
        #expect(listing.failures.isEmpty, "\(listing.failures)")
        let entry = try #require(listing.entries.first)
        #expect(entry.origin == .legacyJSON)

        let s = entry.session
        // **Geldiği şema korunuyor**: `.unknown` olguların nereden geldiğini
        // açıklayan tek şey bu.
        #expect(s.sourceSchema == 2)
        #expect(s.attemptID == "golden-0001")
        #expect(s.status == .completed)
        #expect(s.condition == .calibrationReplay)
        #expect(s.alignmentSource == .constructed)

        // v2'nin **taşıdığı** olgular düşmüyor.
        #expect(!s.touches.isEmpty)
        #expect(!s.actions.isEmpty)
        #expect(s.finalText.isEmpty == false)
        #expect(s.engine.buildConfiguration.isEmpty == false)
        let commits = s.actions.compactMap(\.commit)
        #expect(!commits.isEmpty)
        #expect(commits.allSatisfy { $0.label.targetWord != nil },
                "hedef etiketi v2'de vardı ve korunmalı")

        // v2'nin **taşımadığı** olgular uydurulmuyor.
        #expect(s.promptTokens.isUnknown, "v2 gösterilen diziyi kaydetmiyordu")
        #expect(s.geometry.layoutFingerprint.isUnknown)
        #expect(commits.allSatisfy { $0.tokenID.isUnknown },
                "v2'de token kimliği yoktu; türetmek §6.2 ihlali olurdu")

        // Yerel-v3 tamlık kuralı **migrate edilmiş kayda uygulanmıyor**:
        // eksiklik bozukluk değil, bilgi yokluğu.
        #expect(!SessionValidator.validate(s)
            .contains { $0.kind == .unknownFactInNativeRecord })
    }

    /// v2 tipinin **codec simetrisi**.
    ///
    /// `TypingSession` ölmedi: `SessionMigration` onu okuyor ve
    /// `kbbench --write-legacy-fixture` onu yazıyor. Yazıcı ve okuyucu aynı tipi
    /// kullanıyor; round-trip bunu kanıtlıyor. (`SessionReplay` silinirken bu
    /// test onunla birlikte gitmemeliydi — sınadığı şey ölen kod değil, yaşayan
    /// şema.)
    @Test("v2 tipi codec'ten kayıpsız geçiyor")
    func legacyTypeRoundTrips() throws {
        let url = try #require(Self.url)
        let original = try SessionCodec.decoder.decode(
            TypingSession.self, from: Data(contentsOf: url))
        let back = try SessionCodec.decoder.decode(
            TypingSession.self, from: SessionCodec.encoder.encode(original))

        #expect(back.attemptID == original.attemptID)
        #expect(back.status == original.status)
        #expect(back.touches.count == original.touches.count)
        #expect(back.actions.count == original.actions.count)
        #expect(back.engine.codeRevision == original.engine.codeRevision)
        #expect(back.alignmentSource == original.alignmentSource)
        #expect(back.finalText == original.finalText)
    }

    /// v2 kaydından kalibrasyon örneği **çıkmıyor**.
    ///
    /// Katlama bilinmeyen olgularda duruyor; oradan örnek çıkarmak bilmediğini
    /// bildiğini sanmak olurdu.
    @Test("v2 kaydı kalibrasyona girmiyor")
    func legacyRecordYieldsNoSamples() throws {
        let url = try #require(Self.url)
        let s = try #require(try? SessionReader.read(Data(contentsOf: url)).get())
        let ext = CalibrationExtraction.extract(s, layout: RecordingTestSupport.layout)
        #expect(ext.samples.isEmpty)
        #expect(ext.excludedSession != nil, "gerekçe raporlanmalı")
    }
}
