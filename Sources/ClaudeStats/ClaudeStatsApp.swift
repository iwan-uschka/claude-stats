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
    /// of keeping a second copy here. Cleared once `AppModel` owns the store
    /// so the launch snapshot's event array isn't pinned for the process
    /// lifetime.
    private var usageStore: (any UsageStoring)?
    /// Whether `usageStore` started out backed by `MockUsageStore` because no
    /// readable `~/.claude` was found — surfaced through `AppModel` so the
    /// popover can mark the numbers as sample data instead of showing them as real.
    private let usingSampleData: Bool

    private var statusItemController: StatusItemController?
    private var model: AppModel?
    private var watcher: ConfigDirectoryWatcher?

    /// Serial home of `corpusIndex`: every rebuild — and every touch of the
    /// index after `init` — happens here, so the index needs no locking.
    private let rebuildQueue = DispatchQueue(label: "de.bitgrip.claude-stats.usage-rebuild", qos: .utility)

    /// Incremental parser state. `nil` when running on sample data. Created on
    /// the main thread in `init` (before the watcher exists), then confined to
    /// `rebuildQueue`.
    private let corpusIndex: SessionCorpusIndex?

    /// `true` while a rebuild is queued but not yet started, guarded by
    /// `rebuildFlagLock`. Watcher batches arriving in that window are already
    /// covered — the queued rebuild stat-scans the whole corpus when it runs —
    /// so they don't enqueue another one. Without this, batches every ~2s each
    /// queueing their own rebuild would pile up behind a slow one indefinitely.
    private var rebuildQueued = false
    private let rebuildFlagLock = NSLock()

    override init() {
        // Real local-log store when `~/.claude` (or `$CLAUDE_CONFIG_DIR`) is
        // readable; the mock keeps the UI populated on a machine that has
        // never run Claude Code rather than crashing on first launch.
        let usageStore: any UsageStoring
        let usingSampleData: Bool
        do {
            let index = try SessionCorpusIndex()
            self.corpusIndex = index
            usageStore = index.rebuild()
            usingSampleData = false
        } catch {
            self.corpusIndex = nil
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
        // Always set in `init`; consumed here exactly once.
        guard let usageStore else { return }
        let model = AppModel(
            quotaProvider: quotaProvider,
            usageStore: usageStore,
            usingSampleData: usingSampleData
        )
        self.usageStore = nil
        self.model = model
        statusItemController = StatusItemController(model: model)
        model.refresh(force: true)
        UpdateChecker.shared.startPeriodicChecks()

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

    /// The batch decides *whether* to rebuild — only `.jsonl` content changes
    /// (or a dropped-events rescan signal) matter. *What* to reparse is the
    /// index's job: it stat-scans the corpus and reparses only files whose
    /// mtime/size actually changed, so a rebuild is milliseconds, not the
    /// ~4.5s full-corpus parse this used to be. Bursts collapse via
    /// `rebuildQueued` — at most one rebuild runs and one waits.
    private func rebuildUsageStore(changed batch: FileChangeBatch) {
        guard batch.requiresFullRescan || !batch.contentChanges(withExtension: "jsonl").isEmpty else { return }

        rebuildFlagLock.lock()
        let alreadyQueued = rebuildQueued
        rebuildQueued = true
        rebuildFlagLock.unlock()
        guard !alreadyQueued else { return }

        rebuildQueue.async { [weak self] in
            guard let self else { return }
            // Clear the flag before any early exit or rebuild: changes that
            // land mid-rebuild must queue a follow-up, and a `nil` index
            // (sample-data mode) must not latch the flag forever.
            self.rebuildFlagLock.lock()
            self.rebuildQueued = false
            self.rebuildFlagLock.unlock()

            guard let index = self.corpusIndex else { return }
            let fresh = index.rebuild()
            DispatchQueue.main.async {
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
