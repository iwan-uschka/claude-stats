import Foundation

/// In-memory ``QuotaProviding`` returning plausible static data, so the app
/// target builds and runs end-to-end before the real providers land.
public struct MockQuotaProvider: QuotaProviding {
    public var snapshot: QuotaSnapshot
    /// When set, ``currentSnapshot()`` throws instead of returning — useful for
    /// exercising the app's error path.
    public var error: ClaudeStatsError?

    public init(snapshot: QuotaSnapshot = MockQuotaProvider.sampleSnapshot(), error: ClaudeStatsError? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        if let error { throw error }
        return snapshot
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
    public var burnRate: Double
    public var costToday: Double
    public var planTier: PlanTier

    public init(
        breakdowns: [TimeWindow: EntrypointBreakdown] = MockUsageStore.sampleBreakdowns,
        modelUsageLast24h: [ModelUsage] = MockUsageStore.sampleModelUsage,
        modelUsageAllTime: [ModelUsage]? = nil,
        burnRate: Double = 12_400,
        costToday: Double = 4.82,
        planTier: PlanTier = .max20
    ) {
        self.breakdowns = breakdowns
        self.modelUsageLast24h = modelUsageLast24h
        self.modelUsageAllTime = modelUsageAllTime ?? modelUsageLast24h
        self.burnRate = burnRate
        self.costToday = costToday
        self.planTier = planTier
    }

    public func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown {
        breakdowns[window] ?? .empty(window: window)
    }

    public func modelUsage(last24h: Bool) throws -> [ModelUsage] {
        last24h ? modelUsageLast24h : modelUsageAllTime
    }

    public func burnRatePerHour() throws -> Double { burnRate }

    public func estimatedCostToday() throws -> Double { costToday }

    public func detectedPlanTier() throws -> PlanTier { planTier }

    public static let sampleBreakdowns: [TimeWindow: EntrypointBreakdown] = [
        .fiveHour: EntrypointBreakdown(
            window: .fiveHour,
            tokensByEntrypoint: [.cli: 210_000, .vscode: 40_000, .sdkAgent: 480_000]
        ),
        .twentyFourHour: EntrypointBreakdown(
            window: .twentyFourHour,
            tokensByEntrypoint: [.cli: 820_000, .vscode: 260_000, .sdkAgent: 1_640_000]
        ),
        .sevenDay: EntrypointBreakdown(
            window: .sevenDay,
            tokensByEntrypoint: [.cli: 3_100_000, .vscode: 900_000, .sdkAgent: 7_400_000]
        ),
    ]

    /// Matches the "By model" rows in the popover sketch in `AGENTS.md`.
    public static let sampleModelUsage: [ModelUsage] = [
        ModelUsage(modelID: "claude-sonnet-5", tokens: 2_100_000, estimatedCostUSD: 3.15),
        ModelUsage(modelID: "claude-opus-5", tokens: 180_000, estimatedCostUSD: 2.70),
        ModelUsage(modelID: "claude-haiku-4-5", tokens: 640_000, estimatedCostUSD: 0.19),
        ModelUsage(modelID: "claude-fable-5", tokens: 90_000, estimatedCostUSD: 0.08),
    ]
}
