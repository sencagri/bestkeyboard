// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kbdiag",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/KeyboardCore")],
    targets: [
        .executableTarget(name: "kbdiag", dependencies: [
            .product(name: "KeyboardCore", package: "KeyboardCore")
        ])
    ]
)
