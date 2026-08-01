import ClaudeStatsCore
import Foundation

/// Bridges the Core data layer into the UI. Holds the last successful readings
/// and republishes them on the main actor.
///
/// The views read these published properties and nothing else — the two
/// protocol-typed dependencies are the seam the real providers plug into.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var planTier: PlanTier?
    @Published private(set) var burnRatePerHour: Double?
    @Published private(set) var estimatedCostToday: Double?
    @Published private(set) var breakdown: EntrypointBreakdown?
    @Published private(set) var modelUsage: [ModelUsage] = []
    @Published private(set) var usingSampleData: Bool

    /// Kept independent per subsystem so one reload's success can't clobber
    /// another's still-live failure — see `lastError`.
    @Published private(set) var localStatsError: String?
    @Published private(set) var breakdownError: String?
    @Published private(set) var quotaError: String?

    /// The line shown in the popover's error banner, if any.
    var lastError: String? { localStatsError ?? breakdownError ?? quotaError }

    /// Window selected by the "This Mac" toggle.
    @Published var selectedWindow: TimeWindow = .fiveHour {
        didSet { reloadBreakdown() }
    }

    private let quotaProvider: any QuotaProviding
    private var usageStore: any UsageStoring
    private var refreshTask: Task<Void, Never>?
    private var lastQuotaPoll: Date?
    private let minimumQuotaPollInterval: TimeInterval = 60

    init(quotaProvider: any QuotaProviding, usageStore: any UsageStoring, usingSampleData: Bool = false) {
        self.quotaProvider = quotaProvider
        self.usageStore = usageStore
        self.usingSampleData = usingSampleData
    }

    /// Swaps in a freshly-rebuilt store (the FSEvents-triggered refresh path)
    /// without replacing the `AppModel` instance the views are bound to, and
    /// reloads the published local-stats/breakdown state from it immediately.
    func updateUsageStore(_ newStore: any UsageStoring) {
        usageStore = newStore
        reloadLocalStats()
        reloadBreakdown()
    }

    /// Reload everything. The quota network poll is throttled to
    /// `minimumQuotaPollInterval` unless `force` is set (manual "Refresh").
    func refresh(force: Bool = false) {
        reloadLocalStats()
        reloadBreakdown()

        let shouldPollQuota = force || lastQuotaPoll.map {
            Date().timeIntervalSince($0) >= minimumQuotaPollInterval
        } ?? true
        guard shouldPollQuota else { return }
        lastQuotaPoll = Date()

        refreshTask?.cancel()
        refreshTask = Task { [quotaProvider] in
            do {
                let snapshot = try await quotaProvider.currentSnapshot()
                guard !Task.isCancelled else { return }
                self.snapshot = snapshot
                self.quotaError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.quotaError = String(describing: error)
            }
        }
    }

    private func reloadLocalStats() {
        do {
            planTier = try usageStore.detectedPlanTier()
            burnRatePerHour = try usageStore.burnRatePerHour()
            estimatedCostToday = try usageStore.estimatedCostToday()
            modelUsage = try usageStore.modelUsage(last24h: true)
            localStatsError = nil
        } catch {
            localStatsError = String(describing: error)
        }
    }

    private func reloadBreakdown() {
        do {
            breakdown = try usageStore.entrypointBreakdown(for: selectedWindow)
            breakdownError = nil
        } catch {
            breakdownError = String(describing: error)
        }
    }

    /// Placeholder for the settings window. Settings UI is out of scope for this
    /// pass; the popover button is wired now so the layout is final.
    // TODO: open a real settings window (refresh interval, quota source opt-ins).
    func openSettings() {
        print("[ClaudeStats] Settings requested — not implemented yet.")
    }
}

#if DEBUG
extension AppModel {
    /// Fully-populated model for SwiftUI previews.
    ///
    /// Lives in this file because the published properties are `private(set)`, so
    /// only same-file code can seed them synchronously — previews would otherwise
    /// render one frame of empty state before the async quota read lands.
    static func preview(
        window: TimeWindow = .fiveHour,
        snapshot: QuotaSnapshot? = MockQuotaProvider.sampleSnapshot(),
        error: String? = nil
    ) -> AppModel {
        let store = MockUsageStore()
        let model = AppModel(
            quotaProvider: MockQuotaProvider(snapshot: snapshot ?? .placeholder()),
            usageStore: store
        )
        model.selectedWindow = window // already populates `breakdown` via didSet
        model.snapshot = snapshot
        model.planTier = try? store.detectedPlanTier()
        model.burnRatePerHour = try? store.burnRatePerHour()
        model.estimatedCostToday = try? store.estimatedCostToday()
        model.modelUsage = (try? store.modelUsage(last24h: true)) ?? []
        model.quotaError = error
        return model
    }

    /// Cold-start state: nothing has been read yet.
    static func previewEmpty() -> AppModel {
        AppModel(quotaProvider: MockQuotaProvider(), usageStore: MockUsageStore())
    }

    /// Worst case: a stale low-confidence snapshot, a window over budget, and a
    /// data-source error to surface.
    static func previewDegraded() -> AppModel {
        let now = Date()
        return preview(
            window: .sevenDay,
            snapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(percentUsed: 104, resetsAt: now.addingTimeInterval(90)),
                sevenDay: QuotaWindow(percentUsed: 88, resetsAt: nil),
                confidence: .localEstimate,
                capturedAt: now.addingTimeInterval(-42 * 60)
            ),
            error: String(describing: ClaudeStatsError.noQuotaSourceAvailable)
        )
    }
}
#endif
