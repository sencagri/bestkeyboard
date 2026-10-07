// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "packbuild",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/KeyboardCore"),
        .package(path: "../ToolSupport"),
    ],
    targets: [
        .executableTarget(name: "packbuild", dependencies: [
            .product(name: "KeyboardCore", package: "KeyboardCore"),
            .product(name: "KBToolSupport", package: "ToolSupport"),
        ])
    ]
)
