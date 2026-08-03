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
            Text("How often the live quota source is polled while the popover is closed. Manual Refresh always bypasses this.")
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
        guard let url = Self.bundledScriptURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Deliberately doesn't use SwiftPM's generated `Bundle.module` accessor:
    /// that only checks `Bundle.main.bundleURL` (the `.app` bundle's own root,
    /// *not* `Contents/Resources` — nothing ever copies the resource bundle
    /// there) and a `.build/...` path baked in at compile time on whichever
    /// machine built the release — never present on a machine that only
    /// downloaded the zip. Worse, merely referencing `Bundle.module` crashes
    /// the process outright if both candidates miss, rather than returning
    /// `nil`. This checks the actual locations the resource bundle can be in:
    /// `Contents/Resources` for a packaged `.app` (what `make_app.sh` writes,
    /// and the only one codesign's sealing covers), or next to the executable
    /// for a `swift run`/`swift build` dev build.
    private static func bundledScriptURL() -> URL? {
        let bundleName = "ClaudeStats_ClaudeStats.bundle"
        let fileName = "claude-stats-statusline-cache.sh"
        let candidateDirectories = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ]
        for directory in candidateDirectories {
            guard let fileURL = directory?
                .appendingPathComponent(bundleName)
                .appendingPathComponent(fileName)
            else { continue }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
        }
        return nil
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
