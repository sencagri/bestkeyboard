// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyboardCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KeyboardCore", targets: ["KBGeometry", "KBSpatial", "KBLexicon", "KBMorphology", "KBDecoder", "KBRuntime", "KBLearning", "KBSessions"])
    ],
    targets: [
        .target(name: "KBGeometry"),
        .target(name: "KBSpatial", dependencies: ["KBGeometry"]),
        .target(name: "KBLexicon"),
        .target(name: "KBMorphology"),
        .target(name: "KBDecoder", dependencies: ["KBGeometry", "KBSpatial", "KBLexicon", "KBMorphology"]),
        .target(name: "KBRuntime", dependencies: ["KBGeometry", "KBSpatial", "KBLexicon", "KBDecoder", "KBLearning"]),
        .target(name: "KBLearning", dependencies: ["KBGeometry", "KBSpatial"]),
        // Yazım kaydı şeması ve replay — sözleşme §12.
        //
        // Uygulama (yazıcı) ve kbbench (okuyucu) AYNI tipi kullansın diye
        // çekirdekte: şema iki yerde tanımlıysa bir alan eklendiğinde sessizce
        // ayrışır ve golden testi bunu yakalayamaz (fixture'ı da okuyucu üretiyor).
        // Buraya taşınmasının ikinci sebebi test: `Apps/` ve `Tools/kbbench`
        // test hedefi taşımıyor, oysa token türetimi tam da hata yapılacak yer.
        .target(name: "KBSessions", dependencies: ["KBGeometry", "KBSpatial", "KBDecoder", "KBLearning", "KBRuntime"]),
        .testTarget(
            name: "KeyboardCoreTests",
            dependencies: ["KBGeometry", "KBSpatial", "KBLexicon", "KBMorphology", "KBDecoder", "KBRuntime", "KBLearning", "KBSessions"]
        ),
    ]
)
