// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyboardCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KeyboardCore", targets: ["KBGeometry", "KBSpatial", "KBLexicon", "KBDecoder"])
    ],
    targets: [
        .target(name: "KBGeometry"),
        .target(name: "KBSpatial", dependencies: ["KBGeometry"]),
        .target(name: "KBLexicon"),
        .target(name: "KBDecoder", dependencies: ["KBGeometry", "KBSpatial", "KBLexicon"]),
        .testTarget(
            name: "KeyboardCoreTests",
            dependencies: ["KBGeometry", "KBSpatial", "KBLexicon", "KBDecoder"]
        ),
    ]
)
