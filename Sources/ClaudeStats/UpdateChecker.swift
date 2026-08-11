import AppKit
import ClaudeStatsCore
import Foundation

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let apiURL = URL(string: "https://api.github.com/repos/iwan-uschka/claude-stats/releases/latest")!

    private var didRunSilentCheck = false

    private init() {}

    func check(silent: Bool) {
        // Only the first silent check (on launch) runs; explicit checks (from
        // Settings) always run regardless of how many already happened.
        if silent {
            guard !didRunSilentCheck else { return }
            didRunSilentCheck = true
        }
        guard let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            print("[ClaudeStats] skipping update check: no bundle version (development build)")
            return
        }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: apiURL)
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
                switch decodeReleaseCheck(data: data, httpStatus: httpStatus, localVersion: local) {
                case .updateAvailable(let version, let url):
                    presentUpdateAvailable(version: version, localVersion: local, url: url)
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

    private func presentUpdateAvailable(version: String, localVersion: String, url: String) {
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
