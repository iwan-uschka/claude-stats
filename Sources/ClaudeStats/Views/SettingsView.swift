import AppKit
import ClaudeStatsCore
import Foundation
import SwiftUI

/// Content of the Settings window (`AppModel.openSettings()` /
/// `SettingsWindowController`).
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            refreshSection
            Divider()
            quotaSourceSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Refresh

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Refresh").font(.headline)
            Picker(
                "Poll interval",
                selection: Binding(
                    get: { model.quotaPollInterval },
                    set: { model.setQuotaPollInterval($0) }
                )
            ) {
                ForEach(AppModel.pollIntervalOptions, id: \.self) { interval in
                    Text(Self.pollIntervalLabel(interval)).tag(interval)
                }
            }
            .labelsHidden()
            Text("Minimum time between live quota polls. Refreshes triggered by opening the popover or by new session activity are throttled to this; manual Refresh always bypasses it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func pollIntervalLabel(_ interval: TimeInterval) -> String {
        switch interval {
        case 30: return "Every 30 seconds"
        case 60: return "Every minute"
        case 120: return "Every 2 minutes"
        case 300: return "Every 5 minutes"
        default: return "Every \(DisplayFormat.duration(interval))"
        }
    }

    // MARK: - Quota source

    private var quotaSourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quota source").font(.headline)
            HStack(spacing: 4) {
                Text("Active tier:")
                    .foregroundStyle(.secondary)
                Text(model.snapshot?.confidence.displayLabel ?? "none yet")
            }
            .font(.system(size: 12))

            if model.snapshot?.confidence != .official {
                Text(
                    "For live 5-hour/7-day percentages straight from Claude Code (the \"official\" tier), install the statusline hook: reveal the bundled script below, copy it to ~/.claude/, then point statusLine at it in ~/.claude/settings.json. The script's header comment has the exact command."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button("Reveal Script in Finder") { revealBundledScript() }
                    .controlSize(.small)
            }
        }
    }

    /// The statusline cache script is bundled as a bare-file resource (not an
    /// `.app`-in-`.app` — no `Info.plist`/executable bit), so `NSWorkspace`
    /// selection is the only way to hand it to the user; it can't be launched.
    private func revealBundledScript() {
        guard let url = Self.bundledScriptURL() else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Checks the actual locations the resource bundle can be in:
    /// `Contents/Resources` for a packaged `.app` (what `make_app.sh` writes,
    /// and the only one codesign's sealing covers), or next to the executable
    /// for a `swift run`/`swift build` dev build. See
    /// `BundledResourceLocator` for why `Bundle.module` isn't used.
    private static func bundledScriptURL() -> URL? {
        BundledResourceLocator.resolve(
            bundleName: "ClaudeStats_ClaudeStats.bundle",
            fileName: "claude-stats-statusline-cache.sh",
            candidateDirectories: [Bundle.main.resourceURL, Bundle.main.bundleURL],
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }
}

#if DEBUG
#Preview("Settings — official tier") {
    SettingsView(model: .preview())
}

#Preview("Settings — local estimate, hook not installed") {
    SettingsView(model: .previewDegraded())
}
#endif
