import AppKit
import ClaudeStatsCore
import Foundation
import SwiftUI

/// Content of the Settings window (`AppModel.openSettings()` /
/// `SettingsWindowController`).
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var hookState: StatuslineHookInstaller.State?
    @State private var hookActionFailed = false
    @State private var pendingHookAction: PendingHookAction?

    /// A confirmation sheet in flight, carrying what it'll show and what to run
    /// on confirm. `Identifiable` so `.sheet(item:)` can drive it. `fileprivate`
    /// so `HookConfirmationSheet` below can reference `Kind`.
    fileprivate struct PendingHookAction: Identifiable {
        enum Kind {
            case install(before: String?, after: String)
            case uninstall(StatuslineHookInstaller.UninstallPreview)
        }
        let id = UUID()
        let kind: Kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            generalSection
            Divider()
            refreshSection
            Divider()
            quotaSourceSection
            Divider()
            aboutSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 380)
        // The window is created once and kept alive across close/reopen
        // (`SettingsWindowController`), so this view's @State never
        // reinitializes — resync on every appearance and every reactivation,
        // since the login item can also change from System Settings behind
        // our back.
        .onAppear {
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            refreshHookState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            refreshHookState()
        }
        .sheet(item: $pendingHookAction) { pending in
            HookConfirmationSheet(
                kind: pending.kind,
                onCancel: { pendingHookAction = nil },
                onConfirm: {
                    pendingHookAction = nil
                    performHookAction(pending.kind)
                }
            )
        }
        .alert("Couldn't update statusline hook", isPresented: $hookActionFailed) {
            Button("OK") {}
        } message: {
            Text("Nothing was changed. Use the manual steps in the script's header comment instead.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("General").font(.headline)
            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { newValue in
                        // SMAppService register()/unregister()/status are
                        // synchronous IPC round-trips to launchd that can take
                        // noticeably long (first-time approval checks) —
                        // offload off the main thread so the toggle doesn't
                        // freeze the only window this `.accessory`-policy app
                        // has.
                        Task.detached {
                            let succeeded = LaunchAtLogin.setEnabled(newValue)
                            let actual = LaunchAtLogin.isEnabled
                            await MainActor.run {
                                launchAtLoginEnabled = actual
                                // Registration call failed, or macOS silently
                                // left the item at a different state than
                                // requested (e.g. `.requiresApproval`) —
                                // either way the toggle snapping back needs
                                // some signal, matching the existing
                                // "Reveal Script" failure pattern.
                                if !succeeded || actual != newValue {
                                    NSSound.beep()
                                }
                            }
                        }
                    }
                )
            )
            .disabled(!LaunchAtLogin.isSupported)
            if !LaunchAtLogin.isSupported {
                Text("Not available in development builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

            hookStatusView

            if model.snapshot?.confidence != .official {
                Button("Reveal Script in Finder") { revealBundledScript() }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var hookStatusView: some View {
        switch hookState {
        case nil, .notInstalled:
            Text(
                "For live 5-hour/7-day percentages straight from Claude Code (the \"official\" tier), install the statusline hook. This edits ~/.claude/settings.json — you'll see exactly what changes before anything is written."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Set Up Automatically") { beginInstall() }
                .controlSize(.small)

        case .installed(let wrapping):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Official tier installed")
                    .font(.caption)
            }
            if let wrapping {
                Text("Your existing statusline (`\(wrapping)`) is preserved and still runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Remove") { beginUninstall() }
                .controlSize(.small)

        case .installedStale(let wrapping):
            Text("The installed hook script is out of date.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Update Script") { updateStaleScript() }
                    .controlSize(.small)
                Button("Remove") { beginUninstall() }
                    .controlSize(.small)
            }
            if let wrapping {
                Text("Wraps: `\(wrapping)`")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func installer() -> StatuslineHookInstaller? {
        StatuslineHookInstaller.standard()
    }

    private func bundledScriptData() -> Data? {
        guard let url = Self.bundledScriptURL() else { return nil }
        return try? Data(contentsOf: url)
    }

    private func refreshHookState() {
        guard let installer = installer() else {
            hookState = nil
            return
        }
        hookState = try? installer.detectState(bundledScript: bundledScriptData())
    }

    private func beginInstall() {
        guard let installer = installer(),
              let preview = try? installer.previewInstallCommand()
        else {
            hookActionFailed = true
            return
        }
        pendingHookAction = PendingHookAction(kind: .install(before: preview.before, after: preview.after))
    }

    private func beginUninstall() {
        guard let installer = installer(),
              let preview = try? installer.previewUninstall()
        else {
            hookActionFailed = true
            return
        }
        pendingHookAction = PendingHookAction(kind: .uninstall(preview))
    }

    private func updateStaleScript() {
        guard let installer = installer(), let script = bundledScriptData() else {
            hookActionFailed = true
            return
        }
        do {
            try installer.updateScriptContentOnly(bundledScript: script)
            refreshHookState()
        } catch {
            NSLog("updateStaleScript failed: \(error)")
            hookActionFailed = true
        }
    }

    private func performHookAction(_ kind: PendingHookAction.Kind) {
        guard let installer = installer() else {
            hookActionFailed = true
            return
        }
        do {
            switch kind {
            case .install:
                guard let script = bundledScriptData() else {
                    hookActionFailed = true
                    return
                }
                _ = try installer.install(bundledScript: script)
            case .uninstall:
                try installer.uninstall()
            }
            refreshHookState()
        } catch {
            NSLog("performHookAction failed: \(error)")
            hookActionFailed = true
        }
    }

    /// The statusline cache script is bundled as a bare-file resource (not an
    /// `.app`-in-`.app` — no `Info.plist`/executable bit), so `NSWorkspace`
    /// selection is the only way to hand it to the user; it can't be launched.
    private func revealBundledScript() {
        guard let bundledURL = Self.bundledScriptURL() else {
            NSSound.beep()
            return
        }
        // `ClaudeStats_ClaudeStats.bundle`'s `.bundle` extension makes
        // LaunchServices type its parent folder as `com.apple.package`
        // (`com.apple.generic-bundle`), so Finder treats it as opaque and
        // won't browse inside to select a contained file — it just reveals
        // the package itself, not the script. Copy the script out to a plain
        // (non-package) temp location first so selection isn't blocked.
        let destination: URL
        do {
            destination = try BundledResourceLocator.stage(
                bundledURL,
                into: FileManager.default.temporaryDirectory,
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                remove: { try FileManager.default.removeItem(at: $0) },
                copy: { try FileManager.default.copyItem(at: $0, to: $1) }
            )
        } catch {
            NSLog("revealBundledScript: copy failed: \(error)")
            NSSound.beep()
            return
        }
        // Deferred past the current run-loop turn: calling this synchronously
        // from within the button's mouse-up handling gets silently dropped —
        // WindowServer's focus-stealing suppression blocks the Finder
        // activation request while this `.accessory`-policy app is still
        // mid-event. Letting the click finish first avoids that.
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
        // The temp copy has a fixed filename (see comment above), so it's
        // overwritten on the next reveal rather than accumulating — but clean
        // it up once Finder has had time to select it, rather than leaving it
        // parked in the user's temp dir indefinitely between reveals.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        HStack {
            Text("About").font(.headline)
            Spacer()
            Button("Check for Updates…") { UpdateChecker.shared.check(silent: false) }
                .controlSize(.small)
        }
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

/// Before/after confirmation shown ahead of any `install`/`uninstall` call —
/// these mutate the user's real `~/.claude/settings.json`, so nothing happens
/// without an explicit look at the diff first.
private struct HookConfirmationSheet: View {
    let kind: SettingsView.PendingHookAction.Kind
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text("This changes `statusLine` in ~/.claude/settings.json. A timestamped backup of the file is kept alongside it first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Before").font(.caption).foregroundStyle(.secondary)
                Text(beforeText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("After").font(.caption).foregroundStyle(.secondary)
                Text(afterText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var title: String {
        switch kind {
        case .install: return "Install the statusline hook?"
        case .uninstall: return "Remove the statusline hook?"
        }
    }

    private var confirmLabel: String {
        switch kind {
        case .install: return "Install"
        case .uninstall: return "Remove"
        }
    }

    private var beforeText: String {
        switch kind {
        case .install(let before, _):
            return before ?? "(no statusLine configured)"
        case .uninstall(let preview):
            switch preview {
            case .notInstalled: return "(not installed)"
            case .willRemoveStatusLine, .willRestore:
                return "ClaudeStats' statusline hook"
            }
        }
    }

    private var afterText: String {
        switch kind {
        case .install(_, let after):
            return after
        case .uninstall(let preview):
            switch preview {
            case .notInstalled: return "(no change)"
            case .willRemoveStatusLine: return "(no statusLine configured)"
            case .willRestore(let original): return original
            }
        }
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
