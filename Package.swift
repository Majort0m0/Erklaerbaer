// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Screenkast",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Screenkast",
            path: "Sources/Screenkast",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
