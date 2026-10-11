import XCTest
import Foundation
import KBAssembly
import KBGeometry
import KBSpatial
import KBRuntime

/// Opt-in audit: real production packs, fresh user profile per phrase.
/// Run with KB_SUFFIX_AUDIT=/absolute/output.csv swift test --filter TurkishSuffixAuditTests
final class TurkishSuffixAuditTests: XCTestCase {
    private struct AuditCase: Decodable {
        let input: String
        let source: String
        let group: String
        let learnedBase: String?
    }

    func testProductionSuffixCorpus() throws {
        guard let output = ProcessInfo.processInfo.environment["KB_SUFFIX_AUDIT"] else {
            throw XCTSkip("Set KB_SUFFIX_AUDIT to export the production corpus audit")
        }
        let layout = TurkishQ.layout()
        let pack = try PackLoader.load(layout: layout, source: RecordingTestSupport.packSource)
        let tdk = "https://tdk.gov.tr/icerik/yazim-kurallari/kesme-isareti/"
        // Short published examples; remaining cases below are authored stress cases.
        let published = ["Türkleşmekte", "Hollandalıdan", "Atatürkçülüğün", "Türkiye’mizin", "TBMM’nin", "TDK’nin", "TV’ye", "Samanyolu’nda",
                         "Başvurular 17 Aralık’a kadar sürecektir."]
        let generated = [
            "ev", "evde", "evdeki", "evdekiler", "evdekilerimiz", "evdekilerimizden", "evdekilerinkinden",
            "kitabım", "kitabımız", "kitabımızın", "kitaplarımızdakiler", "kitaplarımızdakilerden", "kitapçıklarımızdan",
            "çocuğum", "çocuğumuzun", "çocuklarımızın", "çocuklarımızdakilerden", "ağzımızdan", "burnumuzdan", "rengimizden",
            "annem", "anneminki", "anneminkiler", "anneminkilerden", "sizinkilerden", "bizimkilerinki",
            "okuldakiler", "okuldakilerdenmiş", "evdeydim", "evdeymişsiniz", "evdeyseniz", "evdekilerdendim",
            "geleceğim", "gelecektim", "gelecekmişsiniz", "geliyordunuz", "geliyormuşsunuz", "gelmişsinizdir", "gelmemiştiniz",
            "gelebilirim", "gelebiliyordum", "gelebilecekmişsiniz", "gelemeyecektik", "gelemeyebilirim", "gelemeseydik",
            "yapabilirdim", "yapamayacakmışız", "yapılabilecek", "yapılabileceklerden", "yaptırabileceklerimizden",
            "yazdırdım", "yazdıracağım", "yazdıramıyorum", "yazdıramayacağım", "yazdıramadıklarımız", "yazamayabiliyorum",
            "okuyamıyorum", "okuyabileceklerimiz", "anlayamadım", "anlayamayacağım", "anlatabilecekmişim",
            "paylaşılabilirlik", "özelleştirilebilir", "kişiselleştiremediklerimiz", "güzelleşiyormuş", "küçücüğüm", "kitapçığımdan",
            "çaycılarımız", "kahveciğim", "zeynepciğim", "zeynepcim", "çağrıcım", "görüşürüzcü", "tamamdırmış",
            "qrmenü", "qrmenüler", "qrmenümüz", "qrmenülerimizden", "cepmenü", "cepmenülerimiz", "dijitalmenümüz",
            "menümüzdekiler", "menülerimizdekilerden", "ödemelinkim", "siparişkodum", "iştakibimizden",
            "ankara'ya", "ankara'dayım", "ankara'dakilerden", "ankara’daymışız", "izmir'deydim", "izmir'dekiler",
            "ahmet'inki", "ayşe'ninkilerden", "tdk'nin", "tbmm'nin", "2026'dayız", "3'üncü", "whatsapp'tan",
            "Ankara'dakilerden haber bekliyorum", "evdekilerimizden birini arayabilecekmişsiniz",
            "qrmenümüzdekiler güncellenemeyebiliyormuş", "kitapçıklarımızdakilerden bahsedemeyecekmişiz",
            "gelecek misiniz", "geliyor muydunuz", "yapabilecek miydiniz", "seninki benimkilerdenmiş",
            "merhabaaa", "tamammmm", "napıyorsunuz", "bişeyler", "gelcem", "yazcam",
            "geliyprum", "merhabs", "kitsp", "teşekkğr", "yazıyprum"
        ]
        let corpus: [AuditCase]
        if let path = ProcessInfo.processInfo.environment["KB_SUFFIX_CORPUS"] {
            corpus = try JSONDecoder().decode([AuditCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            corpus = published.map { AuditCase(input: $0, source: tdk, group: "published", learnedBase: nil) }
                + generated.map { AuditCase(input: $0, source: "synthetic", group: "original", learnedBase: nil) }
        }
        let offsets = ProcessInfo.processInfo.environment["KB_SUFFIX_OFFSETS"]?
            .split(separator: ",").compactMap { Double($0) } ?? [-0.2, 0.0, 0.2]
        XCTAssertFalse(offsets.isEmpty)
        var rows = ["input,offset,output,changed,oov_tokens,decisions,source,group,learned_base,suggestions_before_final_space"]
        var changed = 0
        func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for item in corpus {
            let phrase = item.input
            for offset in offsets {
                var c = InputCoordinator(layout: layout)
                c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                if let base = item.learnedBase {
                    let training = FakeDocument()
                    for ch in base {
                        let index = try XCTUnwrap(layout.keyIndex(for: ch))
                        c.insertLetter(ch, touch: .init(down: layout.keys[index].center), into: training)
                    }
                    let original = try XCTUnwrap(c.suggestions().first)
                    try c.perform(.suggestionPick(id: original.id, surface: base, origin: .literal), touch: nil, into: training)
                    XCTAssertTrue(c.engine!.literalChannel.score(base).isInVocabulary)
                    // Restart with the learned dictionary: no preceding training-word context.
                    let personal = c.personal
                    c = InputCoordinator(layout: layout)
                    c.setEngine(.init(decoder: pack.decoder, literalChannel: pack.literalChannel))
                    c.replacePersonalLexicon(personal)
                }
                let doc = FakeDocument()
                var decisions: [String] = []
                var unknown: [String] = []
                func boundary() {
                    let literal = c.session.literal
                    if !literal.isEmpty && !c.engine!.literalChannel.score(literal).isInVocabulary { unknown.append(literal) }
                    let report = c.space(into: doc)
                    if report.committed != report.displayBefore {
                        decisions.append("\(report.displayBefore)→\(report.committed) Δ=\(report.delta ?? 0) θ=\(report.theta ?? 0)")
                    }
                }
                for ch in phrase {
                    if ch == " " { boundary(); continue }
                    let lower = String(ch).lowercased(with: Locale(identifier: "tr_TR"))
                    if let keyChar = lower.first, let index = layout.keyIndex(for: keyChar) {
                        let key = layout.keys[index]
                        let touch = KBSpatial.TouchSample(down: .init(x: key.center.x + offset * key.width, y: key.center.y + offset * key.height))
                        if ch.isUppercase {
                            c.insertUppercaseLetter(keyChar, uppercase: String(ch), touch: touch, synthetic: false, into: doc)
                        } else { c.insertLetter(ch, touch: touch, into: doc) }
                        XCTAssertEqual(c.suggestions().first?.surface, c.session.display)
                    } else { c.insertSymbol(ch, into: doc) }
                }
                let suggestionsBeforeFinalSpace = c.suggestions().map(\.surface).joined(separator: " | ")
                boundary()
                let result = String(doc.text.dropLast())
                if result != phrase { changed += 1 }
                rows.append([phrase, String(offset), result, String(result != phrase), unknown.joined(separator: ";"), decisions.joined(separator: ";"), item.source, item.group, item.learnedBase ?? "", suggestionsBeforeFinalSpace].map(csv).joined(separator: ","))
            }
        }
        try (rows.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        print("SUFFIX AUDIT: \(corpus.count) phrases, \(corpus.count * offsets.count) runs, \(changed) changed; \(output)")
    }
}
