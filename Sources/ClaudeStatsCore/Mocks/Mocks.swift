import Foundation

/// In-memory ``QuotaProviding`` returning plausible static data, so the app
/// target builds and runs end-to-end before the real providers land.
public struct MockQuotaProvider: QuotaProviding {
    /// Reference-type backing store so ``clearCache()`` can update state without
    /// requiring `mutating` — the protocol's non-mutating contract is what lets
    /// real providers (also structs) be called through an immutable `let`.
    /// `@unchecked Sendable` is safe here: this mock only ever runs on a single
    /// actor at a time (SwiftUI previews on `@MainActor`, or test code awaiting
    /// one call before making the next) — nothing here executes concurrently.
    private final class Box: @unchecked Sendable {
        var snapshot: QuotaSnapshot?
        var error: ClaudeStatsError?

        init(snapshot: QuotaSnapshot?, error: ClaudeStatsError?) {
            self.snapshot = snapshot
            self.error = error
        }
    }

    private let box: Box

    /// `nil` once ``clearCache()`` has run — see that method.
    public var snapshot: QuotaSnapshot? {
        get { box.snapshot }
        set { box.snapshot = newValue }
    }

    /// When set, ``currentSnapshot()`` throws instead of returning — useful for
    /// exercising the app's error path.
    public var error: ClaudeStatsError? {
        get { box.error }
        set { box.error = newValue }
    }

    public init(snapshot: QuotaSnapshot = MockQuotaProvider.sampleSnapshot(), error: ClaudeStatsError? = nil) {
        self.box = Box(snapshot: snapshot, error: error)
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        if let error = box.error { throw error }
        guard let snapshot = box.snapshot else { throw ClaudeStatsError.noQuotaSourceAvailable }
        return snapshot
    }

    /// Clears the in-memory snapshot, matching the documented contract:
    /// ``currentSnapshot()`` throws ``ClaudeStatsError/noQuotaSourceAvailable``
    /// until a new snapshot is set (a fresh `MockQuotaProvider`, or assigning
    /// ``snapshot`` directly for tests/previews simulating a later write).
    public func clearCache() throws {
        box.snapshot = nil
    }

    /// Matches the numbers in the popover sketch in `AGENTS.md`.
    public static func sampleSnapshot(now: Date = Date()) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(
                percentUsed: 62,
                resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)
            ),
            sevenDay: QuotaWindow(
                percentUsed: 31,
                resetsAt: now.addingTimeInterval(4 * 86_400 + 6 * 3600)
            ),
            confidence: .official,
            capturedAt: now.addingTimeInterval(-40)
        )
    }
}

/// In-memory ``UsageStoring`` returning plausible static data.
public struct MockUsageStore: UsageStoring {
    public var breakdowns: [TimeWindow: EntrypointBreakdown]
    public var modelUsageLast24h: [ModelUsage]
    public var modelUsageAllTime: [ModelUsage]
    public var burnRateUsage: TokenUsage
    public var costToday: Double
    public var planTier: PlanTier

    public init(
        breakdowns: [TimeWindow: EntrypointBreakdown] = MockUsageStore.sampleBreakdowns,
        modelUsageLast24h: [ModelUsage] = MockUsageStore.sampleModelUsage,
        modelUsageAllTime: [ModelUsage]? = nil,
        burnRateUsage: TokenUsage = MockUsageStore.sampleBurnRateUsage,
        costToday: Double = 4.82,
        planTier: PlanTier = .max20
    ) {
        self.breakdowns = breakdowns
        self.modelUsageLast24h = modelUsageLast24h
        self.modelUsageAllTime = modelUsageAllTime ?? modelUsageLast24h
        self.burnRateUsage = burnRateUsage
        self.costToday = costToday
        self.planTier = planTier
    }

    public func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown {
        breakdowns[window] ?? .empty(window: window)
    }

    public func modelUsage(last24h: Bool) throws -> [ModelUsage] {
        last24h ? modelUsageLast24h : modelUsageAllTime
    }

    public func burnRateUsagePerHour() throws -> TokenUsage { burnRateUsage }

    public func estimatedCostToday() throws -> Double { costToday }

    public func detectedPlanTier() throws -> PlanTier { planTier }

    /// Trailing-hour split summing to 12.4k tok/hr, cache-read-heavy like real
    /// sessions are.
    public static let sampleBurnRateUsage = TokenUsage(
        inputTokens: 200,
        outputTokens: 700,
        cacheCreationInputTokens: 1_500,
        cacheReadInputTokens: 10_000
    )

    /// Token totals consistent with ``sampleBurnRateUsage`` (12.4k tok/hr)
    /// across every window, so the popover never shows two contradictory
    /// numbers for the same underlying rate.
    public static let sampleBreakdowns: [TimeWindow: EntrypointBreakdown] = [
        .fiveHour: EntrypointBreakdown(
            window: .fiveHour,
            tokensByEntrypoint: [.cli: 18_000, .vscode: 3_400, .sdkAgent: 40_600]
        ),
        .twentyFourHour: EntrypointBreakdown(
            window: .twentyFourHour,
            tokensByEntrypoint: [.cli: 90_000, .vscode: 28_000, .sdkAgent: 179_600]
        ),
        .sevenDay: EntrypointBreakdown(
            window: .sevenDay,
            tokensByEntrypoint: [.cli: 566_500, .vscode: 164_500, .sdkAgent: 1_352_200]
        ),
    ]

    /// Matches the "By model" rows in the popover sketch in `AGENTS.md`.
    public static let sampleModelUsage: [ModelUsage] = [
        ModelUsage(
            modelID: "claude-sonnet-5",
            usage: TokenUsage(
                inputTokens: 12_000,
                outputTokens: 88_000,
                cacheCreationInputTokens: 200_000,
                cacheReadInputTokens: 1_800_000
            ),
            estimatedCostUSD: 3.15
        ),
        ModelUsage(
            modelID: "claude-opus-5",
            usage: TokenUsage(
                inputTokens: 2_000,
                outputTokens: 8_000,
                cacheCreationInputTokens: 20_000,
                cacheReadInputTokens: 150_000
            ),
            estimatedCostUSD: 2.70
        ),
        ModelUsage(
            modelID: "claude-haiku-4-5",
            usage: TokenUsage(
                inputTokens: 5_000,
                outputTokens: 35_000,
                cacheCreationInputTokens: 100_000,
                cacheReadInputTokens: 500_000
            ),
            estimatedCostUSD: 0.19
        ),
        ModelUsage(
            modelID: "claude-fable-5",
            usage: TokenUsage(
                inputTokens: 1_000,
                outputTokens: 4_000,
                cacheCreationInputTokens: 10_000,
                cacheReadInputTokens: 75_000
            ),
            estimatedCostUSD: 0.08
        ),
    ]
}
