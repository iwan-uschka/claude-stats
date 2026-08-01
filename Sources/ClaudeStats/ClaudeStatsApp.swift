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
    private let quotaProvider: any QuotaProviding
    private let usageStore: any UsageStoring

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
        do {
            usageStore = try LocalLogUsageStore()
        } catch {
            usageStore = MockUsageStore()
        }
        self.usageStore = usageStore

        // Lowest-confidence fallback tier for `CompositeQuotaProvider`: no live
        // source, so approximate window usage from local token counts against
        // the detected plan's budget. The 7-day budget has no official
        // per-plan number, so it's scaled from the 5-hour one by the number of
        // 5-hour windows in a week (33.6) — a stated approximation, not a fact.
        self.quotaProvider = CompositeQuotaProvider.makeDefault(
            localEstimateSource: ClosureQuotaProvider {
                let tier = try usageStore.detectedPlanTier()
                let fiveHourBudget = Double(tier.fiveHourTokenBudget)
                let sevenDayBudget = fiveHourBudget * (7 * 24 / 5)
                let fiveHourTokens = Double(try usageStore.entrypointBreakdown(for: .fiveHour).totalTokens)
                let sevenDayTokens = Double(try usageStore.entrypointBreakdown(for: .sevenDay).totalTokens)
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
        let model = AppModel(quotaProvider: quotaProvider, usageStore: usageStore)
        self.model = model
        statusItemController = StatusItemController(model: model)
        model.refresh()

        let watcher = ConfigDirectoryWatcher(configuration: .claudeConfigDirectory()) { [weak self] _ in
            self?.rebuildUsageStore()
        }
        self.watcher = watcher
        try? watcher.start()
    }

    /// Any change is treated as "reparse everything": `LocalLogUsageStore` is
    /// an immutable in-memory index, and a full rebuild (~4.5s for 1.8GB, per
    /// the parser's own benchmark) is simpler and safer than reconciling the
    /// per-file `FileChangeBatch` against it. Revisit with an incremental path
    /// if real-world corpora make that latency noticeable.
    private func rebuildUsageStore() {
        rebuildQueue.async { [weak self] in
            guard let fresh = try? LocalLogUsageStore() else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.model?.updateUsageStore(fresh)
                self.model?.refresh()
            }
        }
    }
}
