import ClaudeStatsCore
import XCTest

@testable import ClaudeStats

@MainActor
final class AppModelTests: XCTestCase {
    private actor ScriptedQuotaProvider: QuotaProviding {
        var result: Result<QuotaSnapshot, Error> = .failure(ClaudeStatsError.noQuotaSourceAvailable)
        /// Incremented on every `currentSnapshot()` read, so tests can
        /// deterministically wait for an async poll to actually run instead of
        /// relying on a published-property condition that may already be true
        /// synchronously before the poll task is scheduled.
        var callCount = 0
        /// When set, `clearCache()` throws it. `nonisolated(unsafe)` because
        /// `clearCache()` itself has to be `nonisolated`; only the single
        /// `@MainActor` test that sets it ever touches this.
        nonisolated(unsafe) var clearCacheError: Error?
        /// Every `clearCache()` attempt, including ones that throw. Same
        /// `nonisolated(unsafe)` reasoning as `clearCacheError`: only ever
        /// touched from the `@MainActor` model and test.
        nonisolated(unsafe) var clearCacheCallCount = 0
        /// What `currentAccount()` reports — the login a poll sees.
        var account: QuotaAccount?
        /// When set, the next `currentAccount()` suspends until
        /// `releaseHeldAccountRead()`, answering with the account as it was when
        /// the call began — how a test gets a poll to be superseded mid-read.
        private var holdNextAccountRead = false
        private var heldAccountRead: CheckedContinuation<Void, Never>?

        func setResult(_ result: Result<QuotaSnapshot, Error>) {
            self.result = result
        }

        func setAccount(_ account: QuotaAccount?) {
            self.account = account
        }

        func holdNextAccountReadUntilReleased() {
            holdNextAccountRead = true
        }

        var isHoldingAnAccountRead: Bool { heldAccountRead != nil }

        func releaseHeldAccountRead() {
            heldAccountRead?.resume()
            heldAccountRead = nil
        }

        func currentSnapshot() async throws -> QuotaSnapshot {
            callCount += 1
            return try result.get()
        }

        func currentAccount() async -> QuotaAccount? {
            let answer = account
            if holdNextAccountRead {
                holdNextAccountRead = false
                await withCheckedContinuation { heldAccountRead = $0 }
            }
            return answer
        }

        /// `nonisolated` because the protocol requirement is synchronous; there is
        /// no on-disk state here, so the scripted `result` stays as set.
        nonisolated func clearCache() throws {
            clearCacheCallCount += 1
            if let clearCacheError { throw clearCacheError }
        }
    }

    private struct FailingUsageStore: UsageStoring {
        struct Failure: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }

        func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown { throw Failure() }
        func modelUsage(last24h: Bool) throws -> [ModelUsage] { throw Failure() }
        func estimatedCostToday() throws -> Double { throw Failure() }
        func dailyUsage(days: Int) throws -> DailyUsageHistory { throw Failure() }
    }

    /// ``MockUsageStore``'s data, but counting the reads the popover's reload
    /// actually makes. The point of the two blocks sharing one
    /// ``DailyUsageHistory`` is that nothing else is summed per reload, and a
    /// query that crept back in is only observable as a call count.
    /// `@unchecked Sendable` for the same reason as
    /// ``ScriptedPromoNoticeProvider``: `UsageStoring` is synchronous and only
    /// the single `@MainActor` test using one ever touches it.
    private final class CountingUsageStore: UsageStoring, @unchecked Sendable {
        private let backing: MockUsageStore
        private(set) var dailyUsageCallCount = 0
        /// When set, `dailyUsage(days:)` throws — still counted.
        var failsDailyUsage = false

        init(backing: MockUsageStore = MockUsageStore()) {
            self.backing = backing
        }
        private(set) var breakdownCallCount = 0
        private(set) var modelUsageCallCount = 0
        private(set) var costTodayCallCount = 0

        func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown {
            breakdownCallCount += 1
            return try backing.entrypointBreakdown(for: window)
        }

        func modelUsage(last24h: Bool) throws -> [ModelUsage] {
            modelUsageCallCount += 1
            return try backing.modelUsage(last24h: last24h)
        }

        func estimatedCostToday() throws -> Double {
            costTodayCallCount += 1
            return try backing.estimatedCostToday()
        }

        func dailyUsage(days: Int) throws -> DailyUsageHistory {
            dailyUsageCallCount += 1
            if failsDailyUsage { throw FailingUsageStore.Failure() }
            return try backing.dailyUsage(days: days)
        }
    }

    /// Hands back whatever the test scripted, and records what the model asked
    /// with — the fingerprint gate is part of the contract, not an internal
    /// detail. `@unchecked Sendable` for the same reason as `MockQuotaProvider`'s
    /// box: `PromoNoticeProviding` is `Sendable` and synchronous, and only the
    /// single `@MainActor` test touching one ever runs.
    private final class ScriptedPromoNoticeProvider: PromoNoticeProviding, @unchecked Sendable {
        var result: PromoNoticeReadResult
        private(set) var callCount = 0
        private(set) var lastRequestedFingerprint: ClaudeStateFileFingerprint?

        init(result: PromoNoticeReadResult = .read(notices: [], fingerprint: nil)) {
            self.result = result
        }

        func read(unchangedSince previous: ClaudeStateFileFingerprint?) -> PromoNoticeReadResult {
            callCount += 1
            lastRequestedFingerprint = previous
            return result
        }
    }

    /// One place for the constructor churn: every test needs a promo provider,
    /// and almost none of them care which one.
    private func makeModel(
        quota: any QuotaProviding,
        store: any UsageStoring = MockUsageStore(),
        promo: any PromoNoticeProviding = MockPromoNoticeProvider(notices: [])
    ) -> AppModel {
        AppModel(quotaProvider: quota, usageStore: store, promoNoticeProvider: promo)
    }

    /// The reading a `.staleQuotaSource` failure carries. Deliberately unlike
    /// ``MockQuotaProvider/sampleSnapshot()`` in every field the tests assert
    /// on, so "which snapshot ended up on screen" is never ambiguous.
    private static let staleReading = QuotaSnapshot(
        fiveHour: QuotaWindow(percentUsed: 42),
        sevenDay: nil,
        confidence: .cachedOfficial,
        capturedAt: Date(timeIntervalSince1970: 1_787_935_500)
    )

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testRefreshOnSuccessSetsSnapshotAndClearsErrors() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.success(MockQuotaProvider.sampleSnapshot()))
        let model = makeModel(quota: provider)

        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        XCTAssertNotNil(model.snapshot)
        XCTAssertNil(model.quotaError)
        XCTAssertNil(model.quotaWarning)
    }

    func testRefreshOnStaleSourceSetsWarningAndPreservesSnapshot() async {
        let provider = ScriptedQuotaProvider()
        let sample = MockQuotaProvider.sampleSnapshot()
        await provider.setResult(.success(sample))
        let model = makeModel(quota: provider)
        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        await provider.setResult(.failure(ClaudeStatsError.staleQuotaSource(
            snapshot: Self.staleReading,
            age: 600
        )))
        model.refresh(force: true)
        await waitUntil { model.quotaWarning != nil }

        // The already-present reading wins: it was fresh when it landed, where
        // the one the error carries never was.
        XCTAssertEqual(model.snapshot, sample)
        XCTAssertNil(model.quotaError)
        XCTAssertNotNil(model.quotaWarning)
    }

    /// Cold start against an already-stale source: no earlier poll ever
    /// succeeded, so there is no "last good reading" to preserve. Leaving
    /// `snapshot` nil would mean empty bars for as long as the source stays
    /// stale — hours, for Claude Code's own cache — even though the reader had
    /// real numbers in hand. Show them, with the warning.
    func testRefreshOnStaleSourceWithNoPriorSnapshotShowsTheStaleReading() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.failure(ClaudeStatsError.staleQuotaSource(
            snapshot: Self.staleReading,
            age: 600
        )))
        let model = makeModel(quota: provider)
        XCTAssertNil(model.snapshot)

        await model.refresh(force: true)?.value

        XCTAssertEqual(model.snapshot, Self.staleReading)
        XCTAssertNotNil(model.quotaWarning)
        XCTAssertNil(model.quotaError)
    }

    func testRefreshOnHardErrorClearsSnapshotAndSetsError() async {
        let provider = ScriptedQuotaProvider()
        let sample = MockQuotaProvider.sampleSnapshot()
        await provider.setResult(.success(sample))
        let model = makeModel(quota: provider)
        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        await provider.setResult(.failure(ClaudeStatsError.noQuotaSourceAvailable))
        model.refresh(force: true)
        await waitUntil { model.quotaError != nil }

        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.quotaError)
        XCTAssertNil(model.quotaWarning)
    }

    func testActiveErrorsIncludesEveryLiveFailureNotJustTheHighestPriority() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.failure(ClaudeStatsError.noQuotaSourceAvailable))
        let model = makeModel(quota: provider, store: FailingUsageStore())

        model.refresh(force: true)
        await waitUntil { model.quotaError != nil }

        XCTAssertEqual(model.activeErrors.count, 2)
        XCTAssertNotNil(model.localStatsError)
        XCTAssertNotNil(model.quotaError)
    }

    func testClearQuotaCacheDropsSnapshotAndShowsNoticeInsteadOfError() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.success(MockQuotaProvider.sampleSnapshot()))
        let model = makeModel(quota: provider)
        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        // Nothing has written a fresh cache yet — the expected post-clear state.
        await provider.setResult(.failure(ClaudeStatsError.noQuotaSourceAvailable))
        let callsBeforeClear = await provider.callCount
        model.clearQuotaCache()

        // Wait for a poll that the clear itself started, not just any poll —
        // the setup `refresh()` above has already run one, and
        // `quotaCacheClearedNotice` is true synchronously, so neither on its
        // own exercises the async catch branch. The longer timeout covers the
        // retry ladder's initial 2s delay before its first attempt.
        await waitUntil(timeout: 5) { await provider.callCount > callsBeforeClear }

        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.quotaError)
        XCTAssertNil(model.quotaWarning)
        XCTAssertEqual(model.quotaCacheClearedNotice, AppModel.QuotaCacheClear.manualNotice)
    }

    func testClearQuotaCacheOnStaleSourceSetsWarningAndDropsNotice() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.success(MockQuotaProvider.sampleSnapshot()))
        let model = makeModel(quota: provider)
        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        // A stale-but-present reading is not the "waiting for a fresh render"
        // state the notice describes, so the post-clear poll replaces it with a
        // warning instead of leaving it set.
        await provider.setResult(.failure(ClaudeStatsError.staleQuotaSource(
            snapshot: Self.staleReading,
            age: 600
        )))
        model.clearQuotaCache()
        await waitUntil(timeout: 5) { model.quotaWarning != nil }

        XCTAssertNotNil(model.quotaWarning)
        XCTAssertNil(model.quotaCacheClearedNotice)
        XCTAssertNil(model.quotaError)
    }

    func testClearQuotaCacheNoticeIsDroppedOnceAFreshReadingLands() async {
        let provider = ScriptedQuotaProvider()
        let sample = MockQuotaProvider.sampleSnapshot()
        await provider.setResult(.success(sample))
        let model = makeModel(quota: provider)

        model.clearQuotaCache()
        await waitUntil(timeout: 5) { model.snapshot != nil }

        XCTAssertEqual(model.snapshot, sample)
        XCTAssertNil(model.quotaCacheClearedNotice)
    }

    func testClearQuotaCacheStillReportsAGenuineFailure() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.failure(ClaudeStatsError.unexpectedQuotaResponse("nope")))
        let model = makeModel(quota: provider)

        model.clearQuotaCache()
        await waitUntil(timeout: 5) { model.quotaError != nil }

        XCTAssertNil(model.quotaCacheClearedNotice)
        XCTAssertNotNil(model.quotaError)
    }

    func testClearQuotaCacheDeleteFailureSurfacesErrorAndLeavesStateUntouched() async {
        let provider = ScriptedQuotaProvider()
        let sample = MockQuotaProvider.sampleSnapshot()
        await provider.setResult(.success(sample))
        let model = makeModel(quota: provider)
        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        provider.clearCacheError = ClaudeStatsError.unexpectedQuotaResponse("disk full")
        let callsBeforeClear = await provider.callCount
        model.clearQuotaCache()

        // Nothing was cleared, so the whole post-clear sequence is skipped
        // synchronously — no notice, no dropped snapshot, no repoll.
        XCTAssertNotNil(model.quotaError)
        XCTAssertEqual(model.snapshot, sample)
        XCTAssertNil(model.quotaCacheClearedNotice)
        let callsAfterClear = await provider.callCount
        XCTAssertEqual(callsAfterClear, callsBeforeClear)
    }

    func testPollAfterInstallRetriesUntilSnapshotLands() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.failure(ClaudeStatsError.noQuotaSourceAvailable))
        let model = makeModel(quota: provider)

        model.pollAfterInstall()
        await provider.setResult(.success(MockQuotaProvider.sampleSnapshot()))
        await waitUntil(timeout: 5) { model.snapshot != nil }

        XCTAssertNotNil(model.snapshot)
    }

    // MARK: - Daily history

    /// Both popover blocks read `dailyHistory` directly — it is the only local
    /// reading either of them has — so a reload has to fill it. An empty one is
    /// the sections' "no local usage yet" state, not a "still loading" one, and
    /// the two must not be confused.
    func testReloadFillsInTheDailyHistoryTheChartDraws() {
        let model = makeModel(quota: ScriptedQuotaProvider(), store: MockUsageStore())
        XCTAssertTrue(model.dailyHistory.isEmpty)

        model.refresh(force: true)

        XCTAssertEqual(model.dailyHistory.days.count, AppModel.chartWindowDays)
        // `bySource` is keyed by `Entrypoint?` — the `nil` key is the "Other"
        // band — so the expected set has to be optional too. The fixture fills
        // every recognised source and nothing else, so there is no `nil` key.
        XCTAssertEqual(
            Set(model.dailyHistory.bySource.keys),
            Set(Entrypoint.allCases.map { Entrypoint?.some($0) })
        )
    }

    func testDailyHistoryFailureSetsTheLocalStatsErrorAndLeavesNoHistory() {
        let model = makeModel(quota: ScriptedQuotaProvider(), store: FailingUsageStore())

        model.refresh(force: true)

        XCTAssertNotNil(model.localStatsError)
        XCTAssertTrue(model.dailyHistory.isEmpty)
    }

    /// A reload that throws must leave the last-good history on screen rather
    /// than blanking both charts.
    ///
    /// The cold-start case above can't see this: with nothing loaded first,
    /// `dailyHistory.isEmpty` holds whether or not the `catch` clears it. The
    /// failure that matters is the later one — an FSEvents batch swapping the
    /// store under a popover that is already drawing thirty days — where
    /// emptying the history would replace two charts with an empty state
    /// beside an error banner.
    func testAFailedReloadAfterASuccessfulOneKeepsTheHistoryItAlreadyHas() {
        let model = makeModel(quota: ScriptedQuotaProvider(), store: MockUsageStore())
        model.refresh(force: true)
        let loaded = model.dailyHistory
        XCTAssertFalse(loaded.isEmpty)

        // `updateUsageStore(_:localStats:)` with no load reads as it swaps, so
        // this is the failing reload — no extra test double needed to script one.
        model.updateUsageStore(FailingUsageStore())

        XCTAssertNotNil(model.localStatsError)
        XCTAssertEqual(model.dailyHistory, loaded)
    }

    /// The two blocks read one history, so a reload has to make exactly one
    /// store query — and none of the three the popover used to also make.
    ///
    /// The call counts are the assertion. `entrypointBreakdown` fed the old
    /// five-hour legend, `modelUsage(last24h:)` the `fixed 24h` rows and
    /// `estimatedCostToday()` the `Today` row; all three walked tens of
    /// thousands of `UsageEvent`s on the main actor for numbers nothing shows
    /// now. Silently reinstating one would cost that walk on every FSEvents
    /// batch with nothing failing to catch it.
    func testAReloadQueriesTheDailyHistoryAndNothingElse() {
        let store = CountingUsageStore()
        let model = makeModel(quota: ScriptedQuotaProvider(), store: store)

        model.refresh(force: true)

        XCTAssertEqual(store.dailyUsageCallCount, 1)
        XCTAssertEqual(store.breakdownCallCount, 0)
        XCTAssertEqual(store.modelUsageCallCount, 0)
        XCTAssertEqual(store.costTodayCallCount, 0)
    }

    // MARK: - Daily history caching

    /// A settable clock, shared by the model and the store so both agree on
    /// what "today" is. `@unchecked Sendable`: only the `@MainActor` test that
    /// owns one ever touches it.
    private final class TestClock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `2026-09-15T12:00:00Z` — midday, so a few hours either way stays on the
    /// same UTC day.
    private static let midday = Date(timeIntervalSince1970: 1_789_473_600)

    private func makeClockedModel(store: any UsageStoring, clock: TestClock) -> AppModel {
        AppModel(
            quotaProvider: ScriptedQuotaProvider(),
            usageStore: store,
            promoNoticeProvider: MockPromoNoticeProvider(notices: []),
            calendar: Self.utc,
            now: { clock.now }
        )
    }

    /// The history depends only on the store and the day, so reloading with
    /// neither changed reads nothing — which is what makes a popover open, the
    /// rebuild path's follow-up refresh and each account-switch ladder rung
    /// free. Manual Refresh (`force`) included: the store is in memory, and a
    /// second read can only say the same.
    func testRefreshWithTheSameStoreOnTheSameDayDoesNotReadTheHistoryAgain() {
        let clock = TestClock(Self.midday)
        let store = CountingUsageStore(backing: MockUsageStore(calendar: Self.utc, now: { clock.now }))
        let model = makeClockedModel(store: store, clock: clock)

        model.refresh(force: true)
        let loaded = model.dailyHistory
        clock.now = Self.midday.addingTimeInterval(3 * 3600)
        model.refresh(force: true)
        model.refresh()

        XCTAssertEqual(store.dailyUsageCallCount, 1)
        XCTAssertEqual(model.dailyHistory, loaded)
    }

    /// A swapped store is a different answer: the new one is read once, and
    /// the refresh that follows it doesn't read it again.
    func testANewStoreIsReadOnceAndThenCached() {
        let clock = TestClock(Self.midday)
        let first = CountingUsageStore(backing: MockUsageStore(calendar: Self.utc, now: { clock.now }))
        let model = makeClockedModel(store: first, clock: clock)
        model.refresh(force: true)

        let second = CountingUsageStore(backing: MockUsageStore(calendar: Self.utc, now: { clock.now }))
        model.updateUsageStore(second)
        model.refresh()

        XCTAssertEqual(first.dailyUsageCallCount, 1)
        XCTAssertEqual(second.dailyUsageCallCount, 1)
    }

    /// The rebuild path hands the history over already read, off the main
    /// actor — the model publishes it without touching the store at all.
    func testAHandedOverLoadIsPublishedWithoutReadingTheStore() {
        let clock = TestClock(Self.midday)
        let model = makeClockedModel(store: MockUsageStore(calendar: Self.utc, now: { clock.now }), clock: clock)
        model.refresh(force: true)

        let fresh = CountingUsageStore(backing: MockUsageStore(calendar: Self.utc, now: { clock.now }))
        let load = LocalStatsLoad.load(from: fresh, calendar: Self.utc, now: clock.now)
        XCTAssertEqual(fresh.dailyUsageCallCount, 1)

        model.updateUsageStore(fresh, localStats: load)
        model.refresh()

        XCTAssertEqual(fresh.dailyUsageCallCount, 1)
        XCTAssertEqual(LocalStatsLoad.Outcome.history(model.dailyHistory), load.outcome)
        XCTAssertNil(model.localStatsError)
    }

    /// Midnight changes the answer without changing the store: the window
    /// ends with "today", so the cached history must not survive into the
    /// next day — the newest point has to move along.
    func testDayRolloverReadsTheHistoryAgain() throws {
        let clock = TestClock(Self.midday)
        let store = CountingUsageStore(backing: MockUsageStore(calendar: Self.utc, now: { clock.now }))
        let model = makeClockedModel(store: store, clock: clock)
        model.refresh(force: true)
        let today = Self.utc.startOfDay(for: Self.midday)
        XCTAssertEqual(model.dailyHistory.days.last, today)

        clock.now = Self.midday.addingTimeInterval(86_400)
        model.refresh()

        XCTAssertEqual(store.dailyUsageCallCount, 2)
        XCTAssertEqual(model.dailyHistory.days.last, Self.utc.date(byAdding: .day, value: 1, to: today))
    }

    /// A load read just before midnight and delivered just after is labelled
    /// with the day it was read on, so the model reads the store again rather
    /// than showing yesterday's window as today's.
    func testAHandedOverLoadFromYesterdayIsReadAgain() {
        let clock = TestClock(Self.midday)
        let model = makeClockedModel(store: MockUsageStore(calendar: Self.utc, now: { clock.now }), clock: clock)
        let fresh = CountingUsageStore(backing: MockUsageStore(calendar: Self.utc, now: { clock.now }))
        let stale = LocalStatsLoad.load(from: fresh, calendar: Self.utc, now: clock.now)

        clock.now = Self.midday.addingTimeInterval(86_400)
        model.updateUsageStore(fresh, localStats: stale)

        XCTAssertEqual(fresh.dailyUsageCallCount, 2)
        XCTAssertEqual(model.dailyHistory.days.last, Self.utc.startOfDay(for: clock.now))
    }

    /// A handed-over load that failed isn't worth retrying immediately against
    /// the same, unchanged store — that would just pay the main-actor cost the
    /// handoff exists to avoid. The next natural reload still retries it.
    func testAHandedOverFailureIsNotImmediatelyRetried() {
        let clock = TestClock(Self.midday)
        let model = makeClockedModel(store: MockUsageStore(calendar: Self.utc, now: { clock.now }), clock: clock)
        let fresh = CountingUsageStore(backing: MockUsageStore(calendar: Self.utc, now: { clock.now }))
        fresh.failsDailyUsage = true
        let failed = LocalStatsLoad.load(from: fresh, calendar: Self.utc, now: clock.now)
        XCTAssertEqual(fresh.dailyUsageCallCount, 1)

        model.updateUsageStore(fresh, localStats: failed)

        XCTAssertEqual(fresh.dailyUsageCallCount, 1)
        XCTAssertNotNil(model.localStatsError)
    }

    /// A failed read is not remembered as an answer: the next reload tries the
    /// same store again, and recovers once it reads.
    func testAFailedReadIsRetriedOnTheNextReload() {
        let clock = TestClock(Self.midday)
        let store = CountingUsageStore(backing: MockUsageStore(calendar: Self.utc, now: { clock.now }))
        store.failsDailyUsage = true
        let model = makeClockedModel(store: store, clock: clock)

        model.refresh(force: true)
        XCTAssertNotNil(model.localStatsError)

        store.failsDailyUsage = false
        model.refresh()

        XCTAssertEqual(store.dailyUsageCallCount, 2)
        XCTAssertNil(model.localStatsError)
        XCTAssertFalse(model.dailyHistory.isEmpty)
    }

    /// The load itself: a throwing store becomes a failure carrying its
    /// message, dated like a success.
    func testLocalStatsLoadCarriesAFailureAndTheDayItWasReadOn() {
        let load = LocalStatsLoad.load(from: FailingUsageStore(), calendar: Self.utc, now: Self.midday)

        XCTAssertEqual(load.outcome, .failure("boom"))
        XCTAssertEqual(load.day, Self.utc.startOfDay(for: Self.midday))
    }

    // MARK: - Usage credits

    /// The statusline payload has no `spend` object at all, so a poll served by
    /// that source alone simply has no credits — and that is silence, not an
    /// error. ``MockQuotaProvider/sampleSnapshot(now:)`` is deliberately
    /// creditless for the same reason.
    func testStatuslineOnlySnapshotCarriesNoUsageCredits() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.success(MockQuotaProvider.sampleSnapshot()))
        let model = makeModel(quota: provider)

        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        XCTAssertNil(model.snapshot?.usageCredits)
        XCTAssertNil(model.snapshot?.usageCreditsDisabledReason)
        XCTAssertTrue(model.activeErrors.isEmpty)
    }

    /// Credits are transient — an admin can switch them off between two polls.
    /// The row goes away and nothing else changes: no error, no warning, no
    /// dropped snapshot.
    func testUsageCreditsDisappearingBetweenPollsOnlyRemovesTheRow() async {
        let provider = ScriptedQuotaProvider()
        let now = Date()
        await provider.setResult(.success(MockQuotaProvider.sampleSnapshotWithUsageCredits(now: now)))
        let model = makeModel(quota: provider)
        model.refresh(force: true)
        await waitUntil { model.snapshot?.usageCredits != nil }

        let callsBefore = await provider.callCount
        await provider.setResult(.success(MockQuotaProvider.sampleSnapshot(now: now)))
        model.refresh(force: true)
        await waitUntil { await provider.callCount > callsBefore }
        await waitUntil { model.snapshot?.usageCredits == nil }

        XCTAssertNotNil(model.snapshot)
        XCTAssertNil(model.snapshot?.usageCredits)
        XCTAssertNil(model.quotaError)
        XCTAssertNil(model.quotaWarning)
        XCTAssertTrue(model.activeErrors.isEmpty)
    }

    // MARK: - Accounts

    /// Scripted stand-in for `ActiveAccountReader`: the state file it would
    /// read is the user's real `~/.claude.json`, which this suite never touches.
    private struct StubActiveAccount: ActiveAccountProviding {
        let reading: ActiveAccountReading
        func readActiveAccount() -> ActiveAccountReading { reading }
    }

    private static let exampleOrg = QuotaAccount(
        uuid: "0f9c1d3e-8a4b-4c2d-9e1f-6b7a8c9d0e1f", organizationName: "Example Org")
    private static let otherOrg = QuotaAccount(
        uuid: "7d2b6a10-3c55-4f8e-9a21-0b4c5d6e7f80", organizationName: "Other Org")

    /// A statusline cache file as the hook writes it, stamped with `account`.
    private func writeCacheFile(
        in directory: URL,
        session: String,
        account: QuotaAccount?,
        fiveHourPercent: Double,
        capturedAt: Date,
        resetsAt: Date
    ) throws {
        let stamp = account.map {
            """
            ,
              "account": { "uuid": "\($0.uuid)", "organization_name": "\($0.organizationName ?? "")" }
            """
        } ?? ""
        let json = """
        {
          "captured_at": \(Int(capturedAt.timeIntervalSince1970)),
          "rate_limits": {
            "five_hour": { "used_percentage": \(fiveHourPercent),
                           "resets_at": \(Int(resetsAt.timeIntervalSince1970)) }
          }\(stamp)
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(session).json"))
    }

    /// A provider wired the way the app wires it — statusline cache plus the
    /// backup — but pointed at a scratch cache directory, with no state file
    /// candidates at all and the logged-in account scripted.
    private func makeAccountAwareProvider(
        cacheDirectory: URL, activeAccount: QuotaAccount?
    ) -> any QuotaProviding {
        let active = StubActiveAccount(reading: ActiveAccountReading(account: activeAccount))
        return FreshestQuotaProvider(
            statusline: StatuslineCacheReader(
                cacheDirectoryURL: cacheDirectory,
                activeAccount: active
            ),
            // No candidates: the backup source must not reach the real
            // `~/.claude.json` from a test.
            cachedState: CachedUtilizationReader(candidateURLs: []),
            activeAccount: active
        )
    }

    private func makeScratchCacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(
                StatuslineCacheReader.sessionCacheDirectoryName, isDirectory: true),
            withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// End to end: two accounts' cache files on disk, and the account Claude
    /// Code is logged in as decides which one the bars show — the other one is
    /// neither merged in nor displayed.
    func testActiveAccountFromTheStateFileDecidesWhichReadingIsShown() async throws {
        let directory = try makeScratchCacheDirectory()
        let sessions = directory.appendingPathComponent(
            StatuslineCacheReader.sessionCacheDirectoryName, isDirectory: true)
        let now = Date()
        try writeCacheFile(in: sessions, session: "left-behind", account: Self.otherOrg,
                           fiveHourPercent: 56, capturedAt: now.addingTimeInterval(-60),
                           resetsAt: now.addingTimeInterval(3600))
        try writeCacheFile(in: sessions, session: "current", account: Self.exampleOrg,
                           fiveHourPercent: 4, capturedAt: now.addingTimeInterval(-30),
                           resetsAt: now.addingTimeInterval(3600))

        let model = makeModel(quota: makeAccountAwareProvider(
            cacheDirectory: directory, activeAccount: Self.exampleOrg))
        await model.refresh(force: true)?.value

        XCTAssertEqual(model.snapshot?.account, Self.exampleOrg)
        XCTAssertEqual(model.snapshot?.fiveHour?.percentUsed, 4)
        XCTAssertNil(model.quotaError)
    }

    /// The quota section's own title: the account's name when the reading was
    /// stamped, and the section's own name when nothing on disk said whose
    /// reading this is — never a guessed account.
    func testQuotaSectionTitleNamesTheAccountOrFallsBackToQuota() async {
        var stamped = MockQuotaProvider.sampleSnapshot()
        stamped.account = Self.otherOrg

        func titledModel(active: QuotaSnapshot?) async -> AppModel {
            let provider = ScriptedQuotaProvider()
            await provider.setResult(active.map { .success($0) }
                ?? .failure(ClaudeStatsError.noQuotaSourceAvailable))
            let model = makeModel(quota: provider)
            await model.refresh(force: true)?.value
            return model
        }

        // Stamped: the account's own name.
        let named = await titledModel(active: stamped)
        XCTAssertEqual(named.snapshot?.account, Self.otherOrg)
        XCTAssertEqual(named.quotaSectionTitle, "Other Org")

        // Unstamped: the section names itself rather than guessing.
        let anonymous = await titledModel(active: MockQuotaProvider.sampleSnapshot())
        XCTAssertEqual(anonymous.quotaSectionTitle, "Quota")

        // No snapshot at all is the same case — there is no account to name.
        let empty = await titledModel(active: nil)
        XCTAssertNil(empty.snapshot)
        XCTAssertEqual(empty.quotaSectionTitle, "Quota")
    }

    // MARK: - Account switch clears the cache

    /// A provider answering every poll with a reading, logged in as `account`.
    private func makeSwitchingProvider(account: QuotaAccount?) async -> ScriptedQuotaProvider {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.success(MockQuotaProvider.sampleSnapshot()))
        await provider.setAccount(account)
        return provider
    }

    /// Polls once per entry, logged in as that account (`nil` = the state file
    /// said nothing), and returns how many cache clears that sequence caused.
    private func clearsCaused(by accounts: [QuotaAccount?]) async -> Int {
        let provider = await makeSwitchingProvider(account: nil)
        let model = makeModel(quota: provider)
        for account in accounts {
            await provider.setAccount(account)
            await model.refresh(force: true)?.value
        }
        return provider.clearCacheCallCount
    }

    /// Known → different known: the old login's cache goes, the popover says
    /// why in its own words, and the retry ladder polls again — without that
    /// repoll, which sees the same new account, clearing a second time.
    func testAccountSwitchClearsTheCacheAndRepolls() async {
        let provider = await makeSwitchingProvider(account: Self.exampleOrg)
        let model = makeModel(quota: provider)
        await model.refresh(force: true)?.value
        XCTAssertNotNil(model.snapshot)

        // Right after a switch the new account usually has no reading yet.
        await provider.setAccount(Self.otherOrg)
        await provider.setResult(.failure(ClaudeStatsError.noQuotaSourceAvailable))
        let callsBeforeSwitch = await provider.callCount
        await model.refresh(force: true)?.value

        XCTAssertEqual(provider.clearCacheCallCount, 1)
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.quotaError)
        XCTAssertEqual(
            model.quotaCacheClearedNotice,
            AppModel.QuotaCacheClear.accountSwitchNotice(for: Self.otherOrg))
        // The switching poll hands over instead of reading a snapshot itself.
        let callsAfterSwitch = await provider.callCount
        XCTAssertEqual(callsAfterSwitch, callsBeforeSwitch)

        // The ladder's first attempt lands after its 2s delay.
        await waitUntil(timeout: 5) { await provider.callCount > callsBeforeSwitch }
        XCTAssertEqual(provider.clearCacheCallCount, 1, "the repoll must not clear again")
        // `noQuotaSourceAvailable` is expected while the notice is up.
        XCTAssertNil(model.quotaError)
        XCTAssertNotNil(model.quotaCacheClearedNotice)
    }

    /// The automatic notice names what happened; the manual text would claim
    /// the user pressed a button they didn't.
    func testAccountSwitchNoticeIsWordedDifferentlyFromTheManualOne() {
        let notice = AppModel.QuotaCacheClear.accountSwitchNotice(for: Self.otherOrg)
        XCTAssertNotEqual(notice, AppModel.QuotaCacheClear.manualNotice)
        XCTAssertTrue(notice.contains(Self.otherOrg.displayName), notice)
    }

    /// The first account seen after launch has nothing to be compared with.
    func testFirstPollAfterLaunchDoesNotClear() async {
        let provider = await makeSwitchingProvider(account: Self.exampleOrg)
        let model = makeModel(quota: provider)

        await model.refresh(force: true)?.value

        XCTAssertEqual(provider.clearCacheCallCount, 0)
        XCTAssertNotNil(model.snapshot)
        XCTAssertNil(model.quotaCacheClearedNotice)
    }

    func testSameAccountAgainDoesNotClear() async {
        let clears = await clearsCaused(by: [Self.exampleOrg, Self.exampleOrg, Self.exampleOrg])
        XCTAssertEqual(clears, 0)
    }

    /// A state file that can't name the login — absent, half-written — is not
    /// a switch in either direction.
    func testUnknownAndKnownTransitionsDoNotClear() async {
        let clears = await clearsCaused(by: [nil, Self.exampleOrg, nil, Self.exampleOrg, nil])
        XCTAssertEqual(clears, 0)
    }

    /// The last *known* account is what counts: the file blinking out mid-swap
    /// must not hide a switch from A to B.
    func testSwitchAcrossAnUnknownPollStillClears() async {
        let clears = await clearsCaused(by: [Self.exampleOrg, nil, Self.otherOrg])
        XCTAssertEqual(clears, 1)
    }

    /// Same contract as the button: nothing was cleared, so no notice and no
    /// dropped snapshot — the failure shows instead. The switch still counts as
    /// handled, so the next poll reads normally rather than retrying the delete.
    func testAccountSwitchDeleteFailureSurfacesErrorAndNoNotice() async {
        let provider = await makeSwitchingProvider(account: Self.exampleOrg)
        let model = makeModel(quota: provider)
        await model.refresh(force: true)?.value
        let shown = model.snapshot

        provider.clearCacheError = ClaudeStatsError.unexpectedQuotaResponse("disk full")
        await provider.setAccount(Self.otherOrg)
        await model.refresh(force: true)?.value

        XCTAssertEqual(provider.clearCacheCallCount, 1)
        XCTAssertNotNil(model.quotaError)
        XCTAssertNil(model.quotaCacheClearedNotice)
        XCTAssertEqual(model.snapshot, shown)

        await model.refresh(force: true)?.value
        XCTAssertEqual(provider.clearCacheCallCount, 1)
    }

    /// A poll superseded while it was asking who is logged in must not record
    /// its out-of-date answer: here it saw B, but by the time it resumed a newer
    /// poll had already seen A. Recording B would make the next A poll look
    /// like a switch back.
    func testCancelledPollDoesNotRecordTheAccountItSaw() async {
        let provider = await makeSwitchingProvider(account: Self.exampleOrg)
        let model = makeModel(quota: provider)
        await model.refresh(force: true)?.value

        await provider.setAccount(Self.otherOrg)
        await provider.holdNextAccountReadUntilReleased()
        let superseded = model.refresh(force: true)
        await waitUntil { await provider.isHoldingAnAccountRead }

        await provider.setAccount(Self.exampleOrg)
        await model.refresh(force: true)?.value
        await provider.releaseHeldAccountRead()
        await superseded?.value
        XCTAssertEqual(provider.clearCacheCallCount, 0)

        await model.refresh(force: true)?.value
        XCTAssertEqual(provider.clearCacheCallCount, 0)
        XCTAssertNil(model.quotaCacheClearedNotice)
    }

    // MARK: - Promo notices

    private func sampleFingerprint(size: Int = 42) -> ClaudeStateFileFingerprint {
        ClaudeStateFileFingerprint(
            url: URL(fileURLWithPath: "/tmp/.claude.json"),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            size: size,
            inode: 7
        )
    }

    func testRefreshPopulatesPromoNotices() async {
        let quota = ScriptedQuotaProvider()
        await quota.setResult(.success(MockQuotaProvider.sampleSnapshot()))
        let notice = MockPromoNoticeProvider.sampleNotice()
        let promo = ScriptedPromoNoticeProvider(
            result: .read(notices: [notice], fingerprint: sampleFingerprint())
        )
        let model = makeModel(quota: quota, promo: promo)

        model.refresh(force: true)

        XCTAssertEqual(model.promoNotices, [notice])
        XCTAssertEqual(promo.callCount, 1)
        // First read has nothing to compare against.
        XCTAssertNil(promo.lastRequestedFingerprint)
    }

    func testPromoNoticeLookupMatchesOnlyTheNoticesOwnBar() async {
        let promo = ScriptedPromoNoticeProvider(
            result: .read(
                notices: [MockPromoNoticeProvider.sampleNotice(bar: .sevenDay)],
                fingerprint: sampleFingerprint()
            )
        )
        let model = makeModel(quota: ScriptedQuotaProvider(), promo: promo)

        model.refresh(force: true)

        XCTAssertNotNil(model.promoNotice(for: .sevenDay))
        XCTAssertNil(model.promoNotice(for: .fiveHour))
    }

    /// The silence contract: no promo is never a failure the user has to act on.
    func testEmptyPromoReadNeverSurfacesAnError() async {
        let quota = ScriptedQuotaProvider()
        await quota.setResult(.success(MockQuotaProvider.sampleSnapshot()))
        let promo = ScriptedPromoNoticeProvider(result: .read(notices: [], fingerprint: nil))
        let model = makeModel(quota: quota, promo: promo)

        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        XCTAssertTrue(model.promoNotices.isEmpty)
        XCTAssertNil(model.quotaError)
        XCTAssertTrue(model.activeErrors.isEmpty)
    }

    func testUnchangedPromoReadKeepsTheNoticesAlreadyOnScreen() async {
        let notice = MockPromoNoticeProvider.sampleNotice()
        let fingerprint = sampleFingerprint()
        let promo = ScriptedPromoNoticeProvider(
            result: .read(notices: [notice], fingerprint: fingerprint)
        )
        let model = makeModel(quota: ScriptedQuotaProvider(), promo: promo)
        model.refresh(force: true)
        XCTAssertEqual(model.promoNotices, [notice])

        promo.result = .unchanged
        model.refresh(force: true)

        XCTAssertEqual(model.promoNotices, [notice])
        // The gate is driven by the fingerprint of what was last parsed.
        XCTAssertEqual(promo.lastRequestedFingerprint, fingerprint)
    }

    /// A malformed payload with two entries for one bar has to resolve
    /// deterministically — there is one line under the bar.
    func testTwoNoticesForOneBarResolveToTheFirst() async {
        let first = MockPromoNoticeProvider.sampleNotice(bar: .sevenDay)
        let second = RateLimitPromoNotice(
            bar: .sevenDay,
            body: LinkifiedText(prefix: "second", linkLabel: nil, linkURL: nil, suffix: ""),
            variant: nil
        )
        let promo = ScriptedPromoNoticeProvider(
            result: .read(notices: [first, second], fingerprint: sampleFingerprint())
        )
        let model = makeModel(quota: ScriptedQuotaProvider(), promo: promo)

        model.refresh(force: true)

        XCTAssertEqual(model.promoNotice(for: .sevenDay), first)
    }

    /// The promo read sits behind the same throttle as the quota poll, so
    /// filesystem churn can't cause a state-file read per write.
    func testReloadPromoNoticesIsSkippedWhenQuotaPollIsThrottled() async {
        let promo = ScriptedPromoNoticeProvider(result: .read(notices: [], fingerprint: nil))
        let model = makeModel(quota: ScriptedQuotaProvider(), promo: promo)
        model.refresh(force: true) // primes lastQuotaPoll
        let callsAfterFirst = promo.callCount

        model.refresh() // not forced, interval not elapsed

        XCTAssertEqual(promo.callCount, callsAfterFirst)
    }

    /// The notice comes from a different file than the quota reading, so an
    /// empty-state popover still shows it.
    func testPromoNoticesSurviveAQuotaHardFailure() async {
        let quota = ScriptedQuotaProvider()
        await quota.setResult(.failure(ClaudeStatsError.noQuotaSourceAvailable))
        let notice = MockPromoNoticeProvider.sampleNotice()
        let promo = ScriptedPromoNoticeProvider(
            result: .read(notices: [notice], fingerprint: sampleFingerprint())
        )
        let model = makeModel(quota: quota, promo: promo)

        model.refresh(force: true)
        await waitUntil { model.quotaError != nil }

        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.promoNotices, [notice])
    }

    /// A real (non-`.unchanged`) read with no notices must clear whatever was
    /// already on screen — the promo campaign ending while the popover is open.
    func testRealReadWithNoNoticesClearsAPreviouslyShownOne() async {
        let notice = MockPromoNoticeProvider.sampleNotice()
        let promo = ScriptedPromoNoticeProvider(
            result: .read(notices: [notice], fingerprint: sampleFingerprint())
        )
        let model = makeModel(quota: ScriptedQuotaProvider(), promo: promo)
        model.refresh(force: true)
        XCTAssertEqual(model.promoNotices, [notice])

        promo.result = .read(notices: [], fingerprint: sampleFingerprint(size: 43))
        model.refresh(force: true)

        XCTAssertTrue(model.promoNotices.isEmpty)
    }

    // MARK: - Settings: default display range

    /// A defaults domain of this test's own, so the preference can be written
    /// and read back without touching whatever the process's standard domain
    /// holds. Removed afterwards, so one test can't seed the next.
    private func makeDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "de.bitgrip.claude-stats.tests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeModel(defaults: UserDefaults) -> AppModel {
        AppModel(
            quotaProvider: MockQuotaProvider(),
            usageStore: MockUsageStore(),
            promoNoticeProvider: MockPromoNoticeProvider(notices: []),
            defaults: defaults
        )
    }

    func testTheDefaultDisplayRangeStartsAtTheWholeWindow() throws {
        // The window the popover has always opened on: nothing stored means the
        // thirty-day sum, not a silently different default for a new install.
        let model = makeModel(defaults: try makeDefaults())

        XCTAssertEqual(model.defaultDisplayRange, .last30Days)
    }

    func testSettingTheDisplayRangePersistsItForTheNextLaunch() throws {
        let defaults = try makeDefaults()
        let model = makeModel(defaults: defaults)

        model.setDefaultDisplayRange(.latestDay)
        XCTAssertEqual(model.defaultDisplayRange, .latestDay)

        // Written through immediately — there is no Apply button in the
        // Settings pane — so a model built fresh over the same domain, which is
        // what the next launch is, comes up on the same setting.
        XCTAssertEqual(makeModel(defaults: defaults).defaultDisplayRange, .latestDay)

        model.setDefaultDisplayRange(.last30Days)
        XCTAssertEqual(makeModel(defaults: defaults).defaultDisplayRange, .last30Days)
    }

    func testAnUnreadableStoredRangeFallsBackToTheWholeWindow() throws {
        let defaults = try makeDefaults()
        defaults.set("lastFortnight", forKey: "de.bitgrip.claude-stats.defaultDisplayRange")

        // A value written by a version that spelled the cases differently must
        // not leave the popover with no setting at all.
        XCTAssertEqual(makeModel(defaults: defaults).defaultDisplayRange, .last30Days)
    }

    func testEveryRangeIsOfferedAndNamesTheWindowItShows() {
        // The picker lists both, and the thirty is spelled from the window the
        // charts actually draw rather than typed into the label.
        XCTAssertEqual(DefaultDisplayRange.allCases, [.last30Days, .latestDay])
        XCTAssertEqual(DefaultDisplayRange.last30Days.label, "Last \(AppModel.chartWindowDays) days")
        XCTAssertEqual(DefaultDisplayRange.latestDay.label, "Latest day")
    }

    // MARK: - README showcase fixture

    func testShowcaseFixtureTitlesTheQuotaSectionWithAGenericAccount() throws {
        let model = AppModel.previewShowcase(now: Date())

        // This fixture *is* the README screenshot, so what it carries is a
        // published claim about what the app looks like: the quota section
        // titled with the logged-in account, as it is on every stamped reading.
        let active = try XCTUnwrap(model.snapshot?.account)
        XCTAssertEqual(model.quotaSectionTitle, active.displayName)

        // And generic, because the picture is published: no real address and no
        // real organisation. `example.com` is reserved for exactly this by
        // RFC 2606, so it can never collide with someone's actual account.
        XCTAssertTrue(
            try XCTUnwrap(active.email).hasSuffix("@example.com"),
            "\(active.displayName) is not a reserved example address"
        )
    }
}
