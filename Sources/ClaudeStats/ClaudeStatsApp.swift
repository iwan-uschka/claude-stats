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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared mutable "current store" so both `AppModel` and the quota
    /// closure below observe the same generation after a rebuild — the
    /// closure captures this box, never a specific store instance.
    private final class UsageStoreBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _current: any UsageStoring
        init(_ store: any UsageStoring) { _current = store }
        var current: any UsageStoring {
            get { lock.lock(); defer { lock.unlock() }; return _current }
            set { lock.lock(); defer { lock.unlock() }; _current = newValue }
        }
    }

    private let quotaProvider: any QuotaProviding
    private let usageStoreBox: UsageStoreBox
    /// Whether `usageStoreBox` started out backed by `MockUsageStore` because
    /// no readable `~/.claude` was found — surfaced through `AppModel` so the
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
        let box = UsageStoreBox(usageStore)
        self.usageStoreBox = box

        // Lowest-confidence fallback tier for `CompositeQuotaProvider`: no live
        // source, so approximate window usage from local token counts against
        // the detected plan's budget. The 7-day budget has no official
        // per-plan number, so it's scaled from the 5-hour one by the number of
        // 5-hour windows in a week (33.6) — a stated approximation, not a fact.
        // Uses `quotaWeightedTokens`, the same metric `detectedPlanTier()` is
        // calibrated against — dividing raw tokens by a quota-weighted budget
        // would inflate the percentage by an order of magnitude.
        self.quotaProvider = CompositeQuotaProvider.makeDefault(
            localEstimateSource: ClosureQuotaProvider {
                let store = box.current
                let tier = try store.detectedPlanTier()
                let fiveHourBudget = Double(tier.fiveHourTokenBudget)
                let sevenDayBudget = fiveHourBudget * (7 * 24 / 5)
                let fiveHourTokens = Double(try store.quotaWeightedTokens(in: .fiveHour))
                let sevenDayTokens = Double(try store.quotaWeightedTokens(in: .sevenDay))
                return QuotaSnapshot(
                    fiveHour: QuotaWindow(percentUsed: fiveHourBudget > 0 ? fiveHourTokens / fiveHourBudget * 100 : 0),
                    sevenDay: QuotaWindow(percentUsed: sevenDayBudget > 0 ? sevenDayTokens / sevenDayBudget * 100 : 0),
                    confidence: .localEstimate,
                    capturedAt: Date()
                )
            }
        )

        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel(
            quotaProvider: quotaProvider,
            usageStore: usageStoreBox.current,
            usingSampleData: usingSampleData
        )
        self.model = model
        statusItemController = StatusItemController(model: model)
        model.refresh(force: true)

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
                self.usageStoreBox.current = fresh
                self.model?.updateUsageStore(fresh)
                // Local stats already refreshed by `updateUsageStore`; this
                // additionally (re)polls the quota tier, throttled internally
                // by `AppModel` so filesystem churn can't hammer `oauth/usage`.
                self.model?.refresh()
            }
        }
    }
}
