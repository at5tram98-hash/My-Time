// swift-tools-version: 5.9
// My Time の共通ロジック（画面に依存しない）。iOS アプリから使い、Linux / macOS の `swift test` でも検証できる。
import PackageDescription

let package = Package(
    name: "MyTimeCore",
    defaultLocalization: "ja",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MyTimeCore", targets: ["MyTimeCore"]),
    ],
    targets: [
        .target(name: "MyTimeCore"),
        .testTarget(name: "MyTimeCoreTests", dependencies: ["MyTimeCore"], resources: [.copy("Fixtures")]),
    ]
)
