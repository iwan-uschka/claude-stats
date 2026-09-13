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
        var otherAccounts: [QuotaSnapshot]

        init(snapshot: QuotaSnapshot?, error: ClaudeStatsError?, otherAccounts: [QuotaSnapshot]) {
            self.snapshot = snapshot
            self.error = error
            self.otherAccounts = otherAccounts
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

    /// Readings for accounts other than the active one — empty on the
    /// one-account machine every other fixture describes.
    public var otherAccounts: [QuotaSnapshot] {
        get { box.otherAccounts }
        set { box.otherAccounts = newValue }
    }

    public init(
        snapshot: QuotaSnapshot = MockQuotaProvider.sampleSnapshot(),
        error: ClaudeStatsError? = nil,
        otherAccounts: [QuotaSnapshot] = []
    ) {
        self.box = Box(snapshot: snapshot, error: error, otherAccounts: otherAccounts)
    }

    public func otherAccountSnapshots() async -> [QuotaSnapshot] { box.otherAccounts }

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
            capturedAt: now.addingTimeInterval(-40),
            // The scoped entry as the real payload carries it: 0%, inactive,
            // no reset timestamp — so previews exercise the row that shows a
            // zero and an empty countdown column rather than a tidy fake.
            scopedWeekly: [QuotaScopedLimit(label: "Fable", percentUsed: 0)]
        )
    }

    /// The account the sample readings belong to — an organisation name, since
    /// that is what ``QuotaAccount/displayName`` shows first.
    /// `email` is what ``QuotaAccount/displayName`` actually renders, so it is
    /// a parameter: two fixtures sharing one address would label both account
    /// groups in the two-account preview identically.
    public static func sampleAccount(
        uuid: String = "0f9c1d3e-8a4b-4c2d-9e1f-6b7a8c9d0e1f",
        email: String? = "me@example.com",
        organizationName: String? = "Example Org"
    ) -> QuotaAccount {
        QuotaAccount(
            uuid: uuid,
            email: email,
            organizationName: organizationName,
            organizationUuid: "a1b2c3d4-0000-0000-0000-000000000000"
        )
    }

    /// A second account's reading, as it looks after the user switched the
    /// global login away from it: same shape, its own account stamp, older.
    public static func sampleOtherAccountSnapshot(now: Date = Date()) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: nil,
            sevenDay: QuotaWindow(
                percentUsed: 56,
                resetsAt: now.addingTimeInterval(2 * 86_400 + 3 * 3600)
            ),
            confidence: .official,
            capturedAt: now.addingTimeInterval(-3 * 3600),
            account: sampleAccount(
                uuid: "7d2b6a10-3c55-4f8e-9a21-0b4c5d6e7f80",
                email: "other@example.com",
                organizationName: "Other Org"
            )
        )
    }

    /// The `spend` object as observed on 2026-08-28: credits on, nothing spent
    /// yet against a €33 monthly cap.
    public static func sampleUsageCredits() -> UsageCredits {
        UsageCredits(
            used: MoneyAmount(amountMinor: 0, currency: "EUR", exponent: 2),
            limit: MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2),
            percentUsed: 0,
            severity: "normal",
            limitReached: false
        )
    }

    /// ``sampleSnapshot(now:)`` plus usage credits.
    ///
    /// A separate factory rather than a field on the default sample: credits
    /// are absent on most accounts, and the app's sample-data mode must not
    /// invent a monthly spend cap for an account that has none.
    public static func sampleSnapshotWithUsageCredits(
        now: Date = Date(),
        credits: UsageCredits = MockQuotaProvider.sampleUsageCredits()
    ) -> QuotaSnapshot {
        var snapshot = sampleSnapshot(now: now)
        snapshot.usageCredits = credits
        return snapshot
    }

    /// Every quota row the popover can draw, in one snapshot: both fixed
    /// windows, the scoped weekly entry, and usage credits part-spent.
    ///
    /// Exists for the README asset renderer, which wants one image showing the
    /// full layout rather than the common-case subset ``sampleSnapshot(now:)``
    /// covers. Credits and the scoped weekly row are both deliberately
    /// non-zero here for the same reason: each is 0% on purpose in the
    /// snapshot it's drawn from (a fresh cap, an inactive scoped limit,
    /// respectively), but a 0% bar renders as an empty track, which shows
    /// nothing of what that bar exists to demonstrate.
    public static func sampleShowcaseSnapshot(now: Date = Date()) -> QuotaSnapshot {
        var snapshot = sampleSnapshotWithUsageCredits(
            now: now,
            credits: UsageCredits(
                used: MoneyAmount(amountMinor: 2_087, currency: "EUR", exponent: 2),
                limit: MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2),
                percentUsed: 63,
                severity: "normal",
                limitReached: false
            )
        )
        snapshot.scopedWeekly = [QuotaScopedLimit(label: "Fable", percentUsed: 42)]
        return snapshot
    }
}

/// In-memory ``PromoNoticeProviding`` for previews.
///
/// Not used by the app's sample-data mode: the notice comes from
/// `~/.claude.json`, not the session logs, so a machine with no readable
/// `~/.claude` can still have a real promo cached.
///
/// A plain struct with no reference box, unlike ``MockQuotaProvider``: nothing
/// here mutates — reads have no side effects and there is no cache to clear.
public struct MockPromoNoticeProvider: PromoNoticeProviding {
    public var notices: [RateLimitPromoNotice]

    public init(notices: [RateLimitPromoNotice] = [MockPromoNoticeProvider.sampleNotice()]) {
        self.notices = notices
    }

    /// Always a full read: with no file behind it there is nothing for the
    /// unchanged-since gate to compare against, and `nil` keeps callers
    /// re-reading, which is what a mock wants.
    public func read(unchangedSince previous: ClaudeStateFileFingerprint?) -> PromoNoticeReadResult {
        .read(notices: notices, fingerprint: nil)
    }

    /// The exact string cached on a real machine, so previews and the
    /// `AGENTS.md` sketch show what the CLI shows rather than invented copy.
    public static let sampleText = "+50% weekly limits promo through Aug 31 · clau.de/cc-50-promo"

    public static func sampleNotice(bar: QuotaWindowKind = .sevenDay) -> RateLimitPromoNotice {
        RateLimitPromoNotice(
            bar: bar,
            // `sampleText` is a linkable literal, so the fallback is
            // unreachable — it exists only to keep this non-optional.
            body: LinkifiedText.linkify(sampleText)
                ?? LinkifiedText(prefix: sampleText, linkLabel: nil, linkURL: nil, suffix: ""),
            variant: "claude"
        )
    }
}

/// In-memory ``UsageStoring`` returning plausible static data.
public struct MockUsageStore: UsageStoring {
    public var breakdowns: [TimeWindow: EntrypointBreakdown]
    public var modelUsageLast24h: [ModelUsage]
    public var modelUsageAllTime: [ModelUsage]
    public var costToday: Double
    /// Calendar and clock behind ``dailyUsage(days:)``'s day boundaries — the
    /// only member of this mock whose answer depends on "when", so they are
    /// injected here rather than assumed like the static fixtures above.
    public var calendar: Calendar
    public var now: @Sendable () -> Date

    public init(
        breakdowns: [TimeWindow: EntrypointBreakdown] = MockUsageStore.sampleBreakdowns,
        modelUsageLast24h: [ModelUsage] = MockUsageStore.sampleModelUsage,
        modelUsageAllTime: [ModelUsage]? = nil,
        costToday: Double = MockUsageStore.sampleCostToday,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.breakdowns = breakdowns
        self.modelUsageLast24h = modelUsageLast24h
        self.modelUsageAllTime = modelUsageAllTime ?? modelUsageLast24h
        self.costToday = costToday
        self.calendar = calendar
        self.now = now
    }

    public func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown {
        breakdowns[window] ?? .empty(window: window)
    }

    public func modelUsage(last24h: Bool) throws -> [ModelUsage] {
        last24h ? modelUsageLast24h : modelUsageAllTime
    }

    public func estimatedCostToday() throws -> Double { costToday }

    /// Today's spend, taken from the same generator that draws the "Estimated cost"
    /// chart, so the curve's last point and the `Today` row under it cannot
    /// disagree — the invariant the real store gets for free, both of its
    /// numbers being events since the same local midnight.
    ///
    /// Derived rather than written out: a literal here drifts silently the
    /// first time the fixture's token base or blended rate moves.
    public static let sampleCostToday: Double =
        sampleDailyUsage(days: 1).total.first?.estimatedCostUSD ?? 0

    public func dailyUsage(days: Int) throws -> DailyUsageHistory {
        MockUsageStore.sampleDailyUsage(days: days, now: now(), calendar: calendar)
    }

    /// Token totals that stay in proportion across every window, so the popover
    /// never shows two contradictory numbers for the same underlying usage.
    /// Each row is split cache-read-heavy, the way real sessions are.
    public static let sampleBreakdowns: [TimeWindow: EntrypointBreakdown] = [
        .fiveHour: EntrypointBreakdown(
            window: .fiveHour,
            usageByEntrypoint: [
                .cli: TokenUsage(
                    inputTokens: 300,
                    outputTokens: 1_000,
                    cacheCreationInputTokens: 2_200,
                    cacheReadInputTokens: 14_500
                ),
                .vscode: TokenUsage(
                    inputTokens: 100,
                    outputTokens: 200,
                    cacheCreationInputTokens: 400,
                    cacheReadInputTokens: 2_700
                ),
                .sdkAgent: TokenUsage(
                    inputTokens: 600,
                    outputTokens: 2_300,
                    cacheCreationInputTokens: 4_900,
                    cacheReadInputTokens: 32_800
                ),
            ]
        ),
        .twentyFourHour: EntrypointBreakdown(
            window: .twentyFourHour,
            usageByEntrypoint: [
                .cli: TokenUsage(
                    inputTokens: 1_500,
                    outputTokens: 5_000,
                    cacheCreationInputTokens: 11_000,
                    cacheReadInputTokens: 72_500
                ),
                .vscode: TokenUsage(
                    inputTokens: 500,
                    outputTokens: 1_600,
                    cacheCreationInputTokens: 3_400,
                    cacheReadInputTokens: 22_500
                ),
                .sdkAgent: TokenUsage(
                    inputTokens: 2_900,
                    outputTokens: 10_200,
                    cacheCreationInputTokens: 21_700,
                    cacheReadInputTokens: 144_800
                ),
            ]
        ),
        .sevenDay: EntrypointBreakdown(
            window: .sevenDay,
            usageByEntrypoint: [
                .cli: TokenUsage(
                    inputTokens: 9_100,
                    outputTokens: 32_000,
                    cacheCreationInputTokens: 68_400,
                    cacheReadInputTokens: 457_000
                ),
                .vscode: TokenUsage(
                    inputTokens: 2_600,
                    outputTokens: 9_300,
                    cacheCreationInputTokens: 19_900,
                    cacheReadInputTokens: 132_700
                ),
                .sdkAgent: TokenUsage(
                    inputTokens: 21_800,
                    outputTokens: 76_400,
                    cacheCreationInputTokens: 163_400,
                    cacheReadInputTokens: 1_090_600
                ),
            ]
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

    /// Deterministic daily history for previews and for the no-logs sample
    /// mode: a weekly rhythm with quiet weekends, split across sources and
    /// models in the same proportions as ``sampleBreakdowns`` and
    /// ``sampleModelUsage``.
    ///
    /// No RNG and no dependence on the real date beyond the day boundaries, so
    /// a SwiftUI preview redrawn twice draws the same chart twice. The source
    /// series sum to the same per-day total as the model series, so the two
    /// charts a popover shows side by side never contradict each other.
    public static func sampleDailyUsage(
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyUsageHistory {
        guard days > 0 else { return .empty }
        let today = calendar.startOfDay(for: now)
        let axis: [Date] = stride(from: days - 1, through: 0, by: -1).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        guard !axis.isEmpty else { return .empty }

        // Indexed by the day's distance from the newest, so the rhythm stays
        // pinned to the right-hand edge however long the window is.
        let rhythm: [Double] = [1.0, 0.82, 1.18, 0.64, 1.34, 0.28, 0.19]
        let sourceShare: [Entrypoint: Double] = [.cli: 0.34, .vscode: 0.08, .sdkAgent: 0.58]
        let modelShare: [ModelFamily?: Double] = [.sonnet: 0.46, .opus: 0.34, .haiku: 0.11, .fable: 0.09]
        let baseTokensPerDay = 1_850_000.0

        func series(share: Double) -> [DailyUsagePoint] {
            axis.enumerated().map { index, day in
                let fromNewest = axis.count - 1 - index
                let scale = rhythm[fromNewest % rhythm.count]
                let tokens = Int((baseTokensPerDay * share * scale).rounded())
                let usage = sampleTokenSplit(totalTokens: tokens)
                // Roughly the blended rate the real per-model math lands on for
                // a cache-read-heavy day; the exact figure doesn't matter for a
                // fixture, its proportionality to the tokens does.
                return DailyUsagePoint(
                    day: day,
                    usage: usage,
                    estimatedCostUSD: Double(tokens) / 1_000_000 * 1.65
                )
            }
        }

        return DailyUsageHistory(
            days: axis,
            total: series(share: 1.0),
            bySource: Dictionary(uniqueKeysWithValues: Entrypoint.allCases.map {
                ($0, series(share: sourceShare[$0] ?? 0))
            }),
            byModelFamily: Dictionary(uniqueKeysWithValues: modelShare.map { family, share in
                (family, series(share: share))
            })
        )
    }

    /// Split a token total the way a real session splits: cache-read heavy,
    /// with the reads taking the rounding remainder so the parts sum exactly.
    private static func sampleTokenSplit(totalTokens: Int) -> TokenUsage {
        let input = Int(Double(totalTokens) * 0.03)
        let output = Int(Double(totalTokens) * 0.07)
        let cacheCreation = Int(Double(totalTokens) * 0.12)
        return TokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheCreationInputTokens: cacheCreation,
            cacheReadInputTokens: max(0, totalTokens - input - output - cacheCreation)
        )
    }
}
