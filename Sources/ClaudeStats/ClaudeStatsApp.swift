import AppKit
import ClaudeStatsCore
import Foundation

/// Pure-AppKit entry point: a menu bar (accessory) app with no dock icon and no
/// main window. SwiftUI is hosted inside the popover only.
@main
enum ClaudeStatsApp {
    /// `NSApplication.delegate` is unowned — keep a strong reference here.
    private static var delegate: AppDelegate?

    static func main() {
        // Unbuffered so `print()` diagnostics land immediately when stdout is
        // redirected to a file — a killed (not `terminate()`d) process never
        // runs libc's normal flush-on-exit, and buffered output is lost.
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quotaProvider: any QuotaProviding
    /// Only read once, at launch, to seed `AppModel`; `rebuildUsageStore`
    /// hands later generations straight to `model.updateUsageStore` instead
    /// of keeping a second copy here.
    private let usageStore: any UsageStoring
    /// Whether `usageStore` started out backed by `MockUsageStore` because no
    /// readable `~/.claude` was found — surfaced through `AppModel` so the
    /// popover can mark the numbers as sample data instead of showing them as real.
    private let usingSampleData: Bool

    private var statusItemController: StatusItemController?
    private var model: AppModel?
    private var watcher: ConfigDirectoryWatcher?

    /// Serial, so overlapping FSEvents batches rebuild one at a time instead of
    /// racing several concurrent full-corpus parses; a burst just queues a few
    /// redundant-but-correct rebuilds rather than corrupting anything.
    private let rebuildQueue = DispatchQueue(label: "de.bitgrip.claude-stats.usage-rebuild", qos: .utility)

    override init() {
        // Real local-log store when `~/.claude` (or `$CLAUDE_CONFIG_DIR`) is
        // readable; the mock keeps the UI populated on a machine that has
        // never run Claude Code rather than crashing on first launch.
        let usageStore: any UsageStoring
        let usingSampleData: Bool
        do {
            usageStore = try LocalLogUsageStore()
            usingSampleData = false
        } catch {
            usageStore = MockUsageStore()
            usingSampleData = true
        }
        self.usingSampleData = usingSampleData
        self.usageStore = usageStore

        // The only wired-up quota source: the statusline hook's disk cache.
        // No fallback — until it's installed and has fired at least once,
        // `AppModel.refresh()` surfaces `noQuotaSourceAvailable` as an error
        // instead of showing an estimated number.
        self.quotaProvider = StatuslineCacheReader()

        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel(
            quotaProvider: quotaProvider,
            usageStore: usageStore,
            usingSampleData: usingSampleData
        )
        self.model = model
        statusItemController = StatusItemController(model: model)
        model.refresh(force: true)
        UpdateChecker.shared.check(silent: true)

        // Watch only the session-log tree, not the whole config root: Claude
        // Code continuously writes `todos/`, `history.jsonl`,
        // `shell-snapshots/`, and `statsig/` under the config root, none of
        // which affect usage stats, and a full-corpus reparse on every one of
        // those writes was queuing far more rebuilds than real session
        // activity warranted.
        let watcher = ConfigDirectoryWatcher(
            configuration: .init(
                path: ClaudeConfigDirectory.candidate()
                    .appendingPathComponent("projects", isDirectory: true)
                    .path,
                requiresExistingPaths: false
            )
        ) { [weak self] batch in
            self?.rebuildUsageStore(changed: batch)
        }
        self.watcher = watcher
        do {
            try watcher.start()
        } catch {
            print("[ClaudeStats] Failed to start config-directory watcher: \(error)")
        }
    }

    /// Any relevant change is treated as "reparse everything": `LocalLogUsageStore`
    /// is an immutable in-memory index, and a full rebuild (~4.5s for 1.8GB, per
    /// the parser's own benchmark) is simpler and safer than reconciling the
    /// per-file `FileChangeBatch` against it (`adding(events:)` also has no
    /// dedup guard yet, so wiring it in here would double-count re-parsed
    /// files). Revisit with an incremental path if real-world corpora make
    /// full-rebuild latency noticeable.
    ///
    /// The batch is still consulted for *whether* to rebuild at all: changes
    /// outside the `.jsonl` session tree (or a dropped-events rescan signal)
    /// are the only things that should trigger the expensive reparse.
    private func rebuildUsageStore(changed batch: FileChangeBatch) {
        guard batch.requiresFullRescan || !batch.contentChanges(withExtension: "jsonl").isEmpty else { return }
        rebuildQueue.async { [weak self] in
            guard let fresh = try? LocalLogUsageStore() else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.model?.updateUsageStore(fresh)
                // Local stats already refreshed by `updateUsageStore`; this
                // additionally re-reads the statusline cache, throttled
                // internally by `AppModel` so filesystem churn can't cause a
                // read on every write.
                self.model?.refresh()
            }
        }
    }
}
