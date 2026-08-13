import ClaudeStatsCore
import Foundation

/// Bridges the Core data layer into the UI. Holds the last successful
/// readings for local stats/breakdown; the quota snapshot is cleared when
/// its source hard-fails (see `refresh()`) so stale numbers don't read as live.
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
    /// another's still-live failure — see `activeErrors`.
    @Published private(set) var localStatsError: String?
    @Published private(set) var breakdownError: String?
    @Published private(set) var quotaError: String?
    /// Set instead of `quotaError` for `.staleQuotaSource` — the source has a
    /// real (if old) reading, not nothing, so ``snapshot`` is left in place
    /// and this is shown as a warning, not an error.
    @Published private(set) var quotaWarning: String?

    /// Every still-live failure, not just the highest-priority one — the
    /// popover clears `snapshot` on a quota failure, so a masked `quotaError`
    /// would otherwise leave empty bars with no stated cause.
    var activeErrors: [String] { [localStatsError, breakdownError, quotaError].compactMap { $0 } }

    /// Window selected by the "This Mac" toggle.
    @Published var selectedWindow: TimeWindow = .fiveHour {
        didSet { reloadBreakdown() }
    }

    private let quotaProvider: any QuotaProviding
    private var usageStore: any UsageStoring
    private var refreshTask: Task<Void, Never>?
    private var lastQuotaPoll: Date?
    private var postInstallPollTask: Task<Void, Never>?

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
    /// `quotaPollInterval` unless `force` is set (manual "Refresh"). Returns
    /// the spawned quota-poll task (`nil` if throttled) so callers that need
    /// to know when it lands — e.g. ``pollAfterInstall()`` — can await it.
    @discardableResult
    func refresh(force: Bool = false) -> Task<Void, Never>? {
        reloadLocalStats()
        reloadBreakdown()

        let shouldPollQuota = force || lastQuotaPoll.map {
            Date().timeIntervalSince($0) >= quotaPollInterval
        } ?? true
        guard shouldPollQuota else { return nil }
        lastQuotaPoll = Date()

        refreshTask?.cancel()
        refreshTask = Task { [quotaProvider] in
            do {
                let snapshot = try await quotaProvider.currentSnapshot()
                guard !Task.isCancelled else { return }
                self.snapshot = snapshot
                self.quotaError = nil
                self.quotaWarning = nil
            } catch let error as ClaudeStatsError where error.isStaleQuotaSource {
                guard !Task.isCancelled else { return }
                // The source has a real reading, just an old one — leave
                // `snapshot` as-is (the popover's own staleness check already
                // marks it) and surface this as a warning, not an error.
                self.quotaWarning = error.localizedDescription
                self.quotaError = nil
            } catch {
                guard !Task.isCancelled else { return }
                // Replaces the last snapshot rather than leaving it on screen:
                // once the source has genuinely failed (not just a throttled
                // skip — this closure only runs when a poll was attempted),
                // frozen old numbers with no visual change read as live.
                self.snapshot = nil
                self.quotaError = error.localizedDescription
                self.quotaWarning = nil
            }
        }
        return refreshTask
    }

    /// Right after installing the hook, the cache file doesn't exist yet — an
    /// immediate poll can only fail with `noQuotaSourceAvailable`. Retry a few
    /// times over ~15s instead of waiting for the next popover open: catches
    /// the common case of Claude Code already running in a terminal and
    /// firing the hook almost immediately.
    func pollAfterInstall() {
        postInstallPollTask?.cancel()
        postInstallPollTask = Task { [weak self] in
            for delay in [2.0, 4.0, 8.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.refresh(force: true)?.value
                if self.quotaError == nil, self.snapshot != nil { return }
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
            localStatsError = error.localizedDescription
        }
    }

    private func reloadBreakdown() {
        do {
            breakdown = try usageStore.entrypointBreakdown(for: selectedWindow)
            breakdownError = nil
        } catch {
            breakdownError = error.localizedDescription
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
        error: String? = nil,
        warning: String? = nil
    ) -> AppModel {
        let store = MockUsageStore()
        // Inlined here (not a public Core factory) so a preview-only "no
        // data yet" fixture can't be mistaken for or reused as a real
        // placeholder elsewhere. `confidence` has no non-official case to
        // express "not real data" — this fixture is never rendered as-is;
        // it only backstops the mock provider when `snapshot` is nil.
        let previewPlaceholder = QuotaSnapshot(
            fiveHour: .empty,
            sevenDay: .empty,
            confidence: .official,
            capturedAt: Date()
        )
        let model = AppModel(
            quotaProvider: MockQuotaProvider(snapshot: snapshot ?? previewPlaceholder),
            usageStore: store
        )
        model.selectedWindow = window // already populates `breakdown` via didSet
        model.snapshot = snapshot
        model.planTier = try? store.detectedPlanTier()
        model.burnRatePerHour = try? store.burnRatePerHour()
        model.estimatedCostToday = try? store.estimatedCostToday()
        model.modelUsage = (try? store.modelUsage(last24h: true)) ?? []
        model.quotaError = error
        model.quotaWarning = warning
        return model
    }

    /// Cold-start state: nothing has been read yet.
    static func previewEmpty() -> AppModel {
        AppModel(quotaProvider: MockQuotaProvider(), usageStore: MockUsageStore())
    }

    /// Live source, but stale — quota still shown, plus a warning line.
    static func previewStaleWarning() -> AppModel {
        preview(warning: "Statusline cache is 14 minutes old.")
    }

    /// Worst case: a stale snapshot, a window over budget, and a quota
    /// staleness warning to surface.
    static func previewDegraded() -> AppModel {
        let now = Date()
        let model = preview(
            window: .sevenDay,
            snapshot: QuotaSnapshot(
                fiveHour: QuotaWindow(percentUsed: 104, resetsAt: now.addingTimeInterval(90)),
                sevenDay: QuotaWindow(percentUsed: 88, resetsAt: nil),
                confidence: .official,
                capturedAt: now.addingTimeInterval(-42 * 60)
            )
        )
        model.quotaWarning = ClaudeStatsError.staleQuotaSource(age: 42 * 60).localizedDescription
        return model
    }
}
#endif
