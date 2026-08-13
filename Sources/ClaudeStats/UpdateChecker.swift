import AppKit
import ClaudeStatsCore
import Foundation

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let apiURL = URL(string: "https://api.github.com/repos/iwan-uschka/claude-stats/releases/latest")!

    /// How often a silent (periodic/launch) check is allowed to run.
    /// Explicit checks (the Settings button) always bypass this.
    private let checkInterval: TimeInterval = 24 * 60 * 60
    /// How often the periodic timer ticks. Shorter than `checkInterval` so a
    /// tick that lands just before a check is due (e.g. delayed behind a
    /// modal alert, or skipped because of an intervening explicit check)
    /// gets retried soon instead of waiting a whole extra `checkInterval`.
    private let tickInterval: TimeInterval = 60 * 60
    private static let lastCheckDefaultsKey = "de.bitgrip.claude-stats.lastUpdateCheck"
    private static let skippedVersionDefaultsKey = "de.bitgrip.claude-stats.skippedUpdateVersion"

    private var isChecking = false
    private var periodicTimer: Timer?

    private init() {}

    /// Runs an immediate check (silently skipped if not due yet — covers the
    /// relaunch-within-24h case) and schedules a repeating timer so a
    /// long-running session also gets checked without needing a relaunch.
    func startPeriodicChecks() {
        periodicTimer?.invalidate()
        check(silent: true)
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.check(silent: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    private var lastCheckDate: Date? {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.lastCheckDefaultsKey)
            return stored == 0 ? nil : Date(timeIntervalSince1970: stored)
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastCheckDefaultsKey)
        }
    }

    /// Version the user dismissed with "Later" on a silent check. Suppresses
    /// repeat silent alerts for that version — an explicit "Check for
    /// Updates…" click always shows the result regardless.
    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedVersionDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.skippedVersionDefaultsKey) }
    }

    func check(silent: Bool) {
        // Prevents overlapping network requests / stacked alerts if the launch
        // silent check and an explicit "Check for Updates…" click race. Checked
        // before touching lastCheckDate so a silent check that loses the race
        // isn't recorded as having run.
        guard !isChecking else { return }
        // A silent (periodic/launch) check only runs if it's actually due;
        // explicit checks (from Settings) always run regardless.
        if silent {
            guard shouldRunUpdateCheck(lastCheck: lastCheckDate, now: Date(), interval: checkInterval) else { return }
        }
        guard let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            print("[ClaudeStats] skipping update check: no bundle version (development build)")
            if !silent { presentCheckFailed("Update checks aren't available in development builds.") }
            return
        }
        isChecking = true
        // Recorded as soon as a check attempt actually starts a network
        // request (not gated on success/failure), matching the "attempted,
        // not necessarily successful" throttle style used elsewhere — a
        // flaky network shouldn't cause a retry storm. Only silent checks
        // advance the clock; an explicit "Check for Updates…" click
        // shouldn't push out the next automatic check.
        if silent {
            lastCheckDate = Date()
        }
        Task {
            defer { isChecking = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: apiURL)
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
                switch decodeReleaseCheck(data: data, httpStatus: httpStatus, localVersion: local) {
                case .updateAvailable(let version, let url):
                    presentUpdateAvailable(version: version, localVersion: local, url: url, silent: silent)
                case .upToDate(let version):
                    if !silent { presentUpToDate(version: version) }
                case .httpError(let status):
                    print("[ClaudeStats] update check failed: HTTP \(status)")
                    if !silent { presentCheckFailed("The update server returned an error (HTTP \(status)). Please try again later.") }
                case .malformedResponse:
                    print("[ClaudeStats] update check failed: unexpected API response format")
                    if !silent { presentCheckFailed("The update server response could not be read. Please try again later.") }
                }
            } catch {
                print("[ClaudeStats] update check failed: \(error)")
                if !silent { presentError(error) }
            }
        }
    }

    // MARK: - Alerts

    private func presentUpdateAvailable(version: String, localVersion: String, url: String, silent: Bool) {
        if silent && version == skippedVersion { return }
        // An `.accessory`-policy app has no Dock icon; without activating first,
        // an alert triggered by the silent launch check can appear behind other
        // windows instead of frontmost.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Claude Stats \(version) is available. You have \(localVersion)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            // url comes straight from the GitHub API JSON — only open it if it's an https
            // github.com URL, never an arbitrary scheme/host from a tampered response.
            guard let releaseURL = URL(string: url), isTrustedReleaseURL(releaseURL) else {
                print("[ClaudeStats] refusing to open untrusted release URL: \(url)")
                return
            }
            NSWorkspace.shared.open(releaseURL)
        } else {
            skippedVersion = version
        }
    }

    private func presentUpToDate(version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "Claude Stats \(version) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentError(_ error: Error) {
        presentCheckFailed(error.localizedDescription)
    }

    private func presentCheckFailed(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
