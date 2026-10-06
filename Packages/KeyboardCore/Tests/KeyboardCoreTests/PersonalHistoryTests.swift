import Testing
import Foundation
@testable import KBLearning

@Suite("Kişisel geçmiş: sonraki kelime ve hatırlama")
struct PersonalHistoryTests {

    @Test("Önceki kelimeden sonra en sık yazılan önce geliyor")
    func nextWordRanking() {
        var h = PersonalHistory()
        h.observe(text: "dün akşam geldim\ndün akşam yedik\ndün gece uyudum")
        #expect(h.nextWords(after: "dün") == ["akşam", "gece"])
        #expect(h.nextWords(after: "Dün").first == "akşam", "büyük harf aynı anahtar")
    }

    @Test("IP adresi bir kullanımda hatırlanıyor, önekle geliyor")
    func recallIP() {
        var h = PersonalHistory()
        h.observe(token: "192.168.1.10", previous: nil)
        #expect(h.recall(prefix: "192.1") == ["192.168.1.10"])
        #expect(h.recall(prefix: "1").isEmpty, "tek karakter önek yok")
        #expect(h.recall(prefix: "192.168.1.10").isEmpty, "tamamı yazılmışsa öneri yok")
    }

    @Test("Düz kelimeler hatırlama teklifine girmiyor — onları decoder tamamlıyor")
    func wordsAreNotRecalled() {
        var h = PersonalHistory()
        h.observe(text: "kalemlerimizden kalemlerimizden")
        #expect(h.recall(prefix: "kal").isEmpty)
    }

    @Test("12'den fazla rakamlı token (kart, IBAN) saklanmıyor")
    func longDigitsRejected() {
        var h = PersonalHistory()
        h.observe(token: "4111111111111111", previous: nil)
        h.observe(token: "TR120006400000112345678901", previous: nil)
        #expect(h.tokens.isEmpty)
    }

    @Test("Uç noktalama atılıyor, IP'nin içi korunuyor")
    func tokenizeEdges() {
        #expect(PersonalHistory.tokenize("akşam, 192.168.1.10. tamam!") == ["akşam", "192.168.1.10", "tamam"])
    }

    @Test("Kodlama gidiş-dönüş eşit")
    func codableRoundTrip() throws {
        var h = PersonalHistory()
        h.observe(text: "dün akşam ornek@posta.com")
        let back = try JSONDecoder().decode(PersonalHistory.self, from: JSONEncoder().encode(h))
        #expect(back == h)
        #expect(back.recall(prefix: "orn") == ["ornek@posta.com"])
    }

    @Test("Çift kapasitesi aşılınca en az görülen düşüyor")
    func pairEviction() {
        var h = PersonalHistory()
        for _ in 0..<5 { h.observe(token: "akşam", previous: "dün") }
        for i in 0..<(PersonalHistory.pairCapacity + 10) {
            h.observe(token: "k\(String(repeating: "a", count: i % 50 + 2))x\(i)".filter(\.isLetter), previous: "w\(i)".filter(\.isLetter) + "a")
        }
        #expect(h.nextWords(after: "dün") == ["akşam"], "sık çift korunuyor")
    }

    @Test("WhatsApp iOS ve Android biçimi, devam satırı")
    func whatsAppParse() {
        let txt = """
        [06.10.2026 17:34:12] Ayşe: Akşam geliyor musun?
        [06.10.2026 17:35:01] Ben: Evet, yedi gibi
        oradayım
        06.10.2026 17:36 - Ben: tamam
        [06.10.2026 17:37:00] Ayşe: ‎<Medya dahil edilmedi>
        """
        let m = ChatExportParser.whatsApp(txt)
        #expect(m.count == 3)
        #expect(m[1] == .init(sender: "Ben", text: "Evet, yedi gibi\noradayım"))
        #expect(ChatExportParser.senders(m) == ["Ben", "Ayşe"])
    }

    @Test("Telegram JSON: dizgi ve parça dizisi metinler")
    func telegramParse() throws {
        let json = """
        {"messages":[{"from":"Ben","text":"selam"},{"from":"Ali","text":[{"type":"bold","text":"bak"}," şuna"]},{"type":"service"}]}
        """
        let m = ChatExportParser.telegram(Data(json.utf8))
        #expect(m == [.init(sender: "Ben", text: "selam"), .init(sender: "Ali", text: "bak şuna")])
    }
}
