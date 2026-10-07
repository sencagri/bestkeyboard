// swift-tools-version: 6.0
import PackageDescription

// Araçların (kbbench, kbdiag, packbuild) ortak kodu.
//
// Ayrı paket, çekirdeğin içinde değil: dokunma simülatörü, rapor biçimleme ve
// TSV okuma uygulamaya hiç girmemeli. Önce dosya sembolik bağla iki araca
// kopyalanıyordu; yardımcıların geri kalanı (yüzdelik, dolgu, hata çıkışı,
// kelime listesi) her araçta yeniden yazılıyordu ve aynı istatistik iki araçta
// iki farklı tanımla raporlanıyordu.
let package = Package(
    name: "ToolSupport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KBToolSupport", targets: ["KBToolSupport"])
    ],
    dependencies: [.package(path: "../../Packages/KeyboardCore")],
    targets: [
        .target(name: "KBToolSupport", dependencies: [
            .product(name: "KeyboardCore", package: "KeyboardCore")
        ]),
        .testTarget(name: "KBToolSupportTests", dependencies: ["KBToolSupport"]),
    ]
)
