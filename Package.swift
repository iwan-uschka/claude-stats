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
            // Declaring it as a resource instead would ship a second,
            // unread copy in the same ClaudeStats_ClaudeStats.bundle produced
            // below — the mark is drawn from `ClaudeMark`'s vector path at
            // runtime.
            exclude: ["Assets.xcassets"],
            // Bundled so Settings can reveal it regardless of distribution
            // channel (release zip vs. repo checkout) — SettingsView resolves
            // the path itself rather than using the generated `Bundle.module`
            // accessor (see its comment for why). `make_app.sh` copies the
            // generated ClaudeStats_ClaudeStats.bundle into the packaged .app's
            // Contents/Resources.
            resources: [.copy("Resources/claude-stats-statusline-cache.sh")]
        ),
        .testTarget(
            name: "ClaudeStatsCoreTests",
            dependencies: ["ClaudeStatsCore"],
            path: "Tests/ClaudeStatsCoreTests",
            // Hand-crafted JSONL fixtures, so log-parsing tests never touch ~/.claude.
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ClaudeStatsTests",
            dependencies: ["ClaudeStats"],
            path: "Tests/ClaudeStatsTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
