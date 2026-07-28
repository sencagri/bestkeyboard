// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyboardCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KeyboardCore", targets: ["KBGeometry", "KBSpatial", "KBLexicon", "KBMorphology", "KBDecoder", "KBRuntime", "KBLearning"])
    ],
    targets: [
        .target(name: "KBGeometry"),
        .target(name: "KBSpatial", dependencies: ["KBGeometry"]),
        .target(name: "KBLexicon"),
        .target(name: "KBMorphology"),
        .target(name: "KBDecoder", dependencies: ["KBGeometry", "KBSpatial", "KBLexicon", "KBMorphology"]),
        .target(name: "KBRuntime", dependencies: ["KBGeometry", "KBSpatial", "KBLexicon", "KBDecoder", "KBLearning"]),
        .target(name: "KBLearning", dependencies: ["KBGeometry", "KBSpatial"]),
        .testTarget(
            name: "KeyboardCoreTests",
            dependencies: ["KBGeometry", "KBSpatial", "KBLexicon", "KBMorphology", "KBDecoder", "KBRuntime", "KBLearning"]
        ),
    ]
)
