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
    /// Best-effort reader for Claude Code's own promo notices — see
    /// `PromoNoticeProviding`. Never fails, so there is nothing to fall back to.
    private let promoNoticeProvider: any PromoNoticeProviding
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

    /// Merges watcher batches that arrive while a rebuild is already queued —
    /// without this, batches every ~2s each queueing their own would pile up
    /// behind a slow one indefinitely. A batch arriving while one is queued
    /// used to be dropped outright, on the grounds that the queued rebuild
    /// would stat-scan the whole corpus anyway and find its files regardless.
    /// That stopped being true when rebuilds became scoped to the batch
    /// they're given: a dropped batch is now a set of paths nothing would
    /// ever look at. So they merge (see `FileChangeBatch.merging`) and drain
    /// together.
    private let rebuildCoalescer = RebuildCoalescer()

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

        // Both account-wide sources, newest reading wins: Claude Code's own
        // cached `cachedUsageUtilization` blob (no setup required) and the
        // statusline hook's disk cache (opt-in, but seconds rather than
        // minutes old). Still no estimate fallback — when neither has a
        // reading, `AppModel.refresh()` surfaces the error rather than a guess.
        self.quotaProvider = FreshestQuotaProvider()
        self.promoNoticeProvider = RateLimitPromoNoticeReader()

        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always set in `init`; consumed here exactly once.
        guard let usageStore else { return }
        let model = AppModel(
            quotaProvider: quotaProvider,
            usageStore: usageStore,
            promoNoticeProvider: promoNoticeProvider,
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
            // The watcher only reports events from this point on
            // (`kFSEventStreamEventIdSinceNow`), so anything created or
            // modified between the launch scan above and here would
            // otherwise sit unreported until the app relaunches. Route a
            // synthetic full-rescan batch through the normal path so it
            // merges correctly with any real batch the watcher delivers in
            // the same window.
            rebuildUsageStore(changed: FileChangeBatch(changes: [FileChange(path: "", flags: [.requiresRescan])]))
        } catch {
            print("[ClaudeStats] Failed to start config-directory watcher: \(error)")
        }
    }

    /// The batch decides both *whether* to rebuild and *what* to reparse. Only
    /// `.jsonl` content changes matter, plus the two signals that say the batch
    /// itself is an incomplete account of what happened — a dropped-events
    /// rescan, and a removed or renamed directory, for which FSEvents names no
    /// children. Anything else is `todos/`-style noise and is dropped here.
    ///
    /// Everything that survives is handed to the index, which stats just those
    /// paths and reparses the ones whose mtime/size actually moved — so a
    /// rebuild costs a handful of `stat` calls rather than the ~190 ms
    /// corpus-wide scan it used to (itself down from a ~4.5s full-corpus parse).
    /// The two incomplete-batch signals make it scan the whole corpus instead,
    /// which is what keeps a lost event or a vanished project directory from
    /// leaving stale data behind indefinitely.
    ///
    /// Bursts collapse via `rebuildCoalescer` — at most one rebuild runs and
    /// one waits, with the waiting one's changes accumulating for it to drain.
    private func rebuildUsageStore(changed batch: FileChangeBatch) {
        guard batch.requiresFullRescan
                || batch.containsRemovedOrRenamedDirectory
                || !batch.contentChanges(withExtension: "jsonl").isEmpty
        else { return }

        guard rebuildCoalescer.enqueue(batch) else { return }

        rebuildQueue.async { [weak self] in
            guard let self else { return }
            // Draining before any early exit or rebuild: changes that land
            // mid-rebuild must queue a follow-up carrying their own paths,
            // and a `nil` index (sample-data mode) must not latch the queued
            // flag forever.
            let changes = self.rebuildCoalescer.drain()

            guard let index = self.corpusIndex else { return }
            let fresh = index.rebuild(changed: changes)
            // Read here, beside the store it describes, so the main actor
            // doesn't pay for the ~11 ms history walk on every rebuild — it
            // only assigns the result.
            let localStats = LocalStatsLoad.load(from: fresh)
            DispatchQueue.main.async {
                self.model?.updateUsageStore(fresh, localStats: localStats)
                // The history is already published; `AppModel` caches it per
                // store and day, so this refresh doesn't read it again. What it
                // adds is a re-read of the statusline cache, throttled
                // internally by `AppModel` so filesystem churn can't cause a
                // read on every write.
                self.model?.refresh()
            }
        }
    }
}
