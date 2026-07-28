// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kbbench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/KeyboardCore")],
    targets: [
        .executableTarget(
            name: "kbbench",
            dependencies: [.product(name: "KeyboardCore", package: "KeyboardCore")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
