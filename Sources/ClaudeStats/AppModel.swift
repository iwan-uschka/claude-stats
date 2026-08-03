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

    /// Minimum time between live quota polls. Refreshes are triggered by opening
    /// the popover or by new session activity, not by a repeating timer; manual
    /// "Refresh" always bypasses this. User-configurable in Settings.
    @Published private(set) var quotaPollInterval: TimeInterval

    /// Selectable cadences shown in the Settings poll-interval picker.
    static let pollIntervalOptions: [TimeInterval] = [30, 60, 120, 300]
    private static let pollIntervalDefaultsKey = "de.bitgrip.claude-stats.quotaPollInterval"

    init(quotaProvider: any QuotaProviding, usageStore: any UsageStoring, usingSampleData: Bool = false) {
        self.quotaProvider = quotaProvider
        self.usageStore = usageStore
        self.usingSampleData = usingSampleData

        let stored = UserDefaults.standard.double(forKey: Self.pollIntervalDefaultsKey)
        self.quotaPollInterval = Self.pollIntervalOptions.contains(stored) ? stored : 60
    }

    /// Persists the new cadence immediately so it survives the next launch.
    func setQuotaPollInterval(_ interval: TimeInterval) {
        quotaPollInterval = interval
        UserDefaults.standard.set(interval, forKey: Self.pollIntervalDefaultsKey)
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
    /// `quotaPollInterval` unless `force` is set (manual "Refresh").
    func refresh(force: Bool = false) {
        reloadLocalStats()
        reloadBreakdown()

        let shouldPollQuota = force || lastQuotaPoll.map {
            Date().timeIntervalSince($0) >= quotaPollInterval
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

    func openSettings() {
        SettingsWindowController.show(model: self)
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
