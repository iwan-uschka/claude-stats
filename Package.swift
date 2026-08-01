// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeStats",
    platforms: [.macOS(.v14)],
    targets: [
        // Data layer: models, protocols, parsing, watching, quota.
        .target(
            name: "ClaudeStatsCore",
            path: "Sources/ClaudeStatsCore"
        ),
        // Menu bar app.
        .executableTarget(
            name: "ClaudeStats",
            dependencies: ["ClaudeStatsCore"],
            path: "Sources/ClaudeStats"
        ),
        .testTarget(
            name: "ClaudeStatsCoreTests",
            dependencies: ["ClaudeStatsCore"],
            path: "Tests/ClaudeStatsCoreTests",
            // Hand-crafted JSONL fixtures, so log-parsing tests never touch ~/.claude.
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
