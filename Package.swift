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
            path: "Sources/ClaudeStats",
            // The app icon catalog is compiled by `actool` in make_app.sh, not
            // by SwiftPM (the CLI toolchain has no asset-catalog build rule).
            // Declaring it as a resource instead would ship a
            // ClaudeStats_ClaudeStats.bundle that nothing ever reads — the mark
            // is drawn from `ClaudeMark`'s vector path at runtime.
            exclude: ["Assets.xcassets"]
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
