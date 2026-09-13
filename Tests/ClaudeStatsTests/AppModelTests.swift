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

        func setResult(_ result: Result<QuotaSnapshot, Error>) {
            self.result = result
        }

        func currentSnapshot() async throws -> QuotaSnapshot {
            callCount += 1
            return try result.get()
        }

        /// `nonisolated` because the protocol requirement is synchronous; there is
        /// no on-disk state here, so the scripted `result` stays as set.
        nonisolated func clearCache() throws {
            if let clearCacheError { throw clearCacheError }
        }
    }

    private struct FailingUsageStore: UsageStoring {
        struct Failure: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }

        func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown { throw Failure() }
        func modelUsage(last24h: Bool) throws -> [ModelUsage] { throw Failure() }
        func burnRateUsagePerHour() throws -> TokenUsage { throw Failure() }
        func estimatedCostToday() throws -> Double { throw Failure() }
        func detectedPlanTier() throws -> PlanTier { throw Failure() }
    }

    /// ``MockUsageStore``'s data, but counting the breakdown reads — the point
    /// of precomputing all three windows is that switching the picker makes no
    /// further read, which is only observable as a call count.
    /// `@unchecked Sendable` for the same reason as
    /// ``ScriptedPromoNoticeProvider``: `UsageStoring` is synchronous and only
    /// the single `@MainActor` test using one ever touches it.
    private final class CountingUsageStore: UsageStoring, @unchecked Sendable {
        private let backing = MockUsageStore()
        private(set) var breakdownCallCount = 0
        private(set) var requestedWindows: [TimeWindow] = []
        /// When set, that one window throws while the other two still succeed —
        /// the partial-failure case the one-shot assignment has to survive.
        var failingWindow: TimeWindow?

        func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown {
            breakdownCallCount += 1
            requestedWindows.append(window)
            if window == failingWindow { throw FailingUsageStore.Failure() }
            return try backing.entrypointBreakdown(for: window)
        }

        func modelUsage(last24h: Bool) throws -> [ModelUsage] { try backing.modelUsage(last24h: last24h) }
        func burnRateUsagePerHour() throws -> TokenUsage { try backing.burnRateUsagePerHour() }
        func estimatedCostToday() throws -> Double { try backing.estimatedCostToday() }
        func detectedPlanTier() throws -> PlanTier { try backing.detectedPlanTier() }
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

        XCTAssertEqual(model.activeErrors.count, 3)
        XCTAssertNotNil(model.localStatsError)
        XCTAssertNotNil(model.breakdownError)
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
        XCTAssertNotNil(model.quotaCacheClearedNotice)
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

    /// The cached total has to move with every reload — a stale sum would put
    /// the popover's cache-read caption on the wrong numbers.
    func testModelUsageTotalIsKeptInSyncWithTheLoadedRows() throws {
        let store = MockUsageStore()
        let model = makeModel(quota: ScriptedQuotaProvider(), store: store)
        XCTAssertEqual(model.modelUsageTotal, .zero)

        model.refresh(force: true)

        let expected = try store.modelUsage(last24h: true).reduce(TokenUsage.zero) { $0 + $1.usage }
        XCTAssertNotEqual(expected, .zero)
        XCTAssertEqual(model.modelUsageTotal, expected)

        model.updateUsageStore(MockUsageStore(modelUsageLast24h: []))

        XCTAssertEqual(model.modelUsageTotal, .zero)
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

    // MARK: - Entrypoint breakdown

    /// One reload fills in every window, so the picker has nothing left to
    /// compute when it changes.
    func testOneReloadPrecomputesEveryWindowsBreakdown() throws {
        let store = CountingUsageStore()
        let model = makeModel(quota: ScriptedQuotaProvider(), store: store)
        XCTAssertTrue(model.breakdownsByWindow.isEmpty)

        model.refresh(force: true)

        XCTAssertEqual(store.breakdownCallCount, TimeWindow.allCases.count)
        XCTAssertEqual(Set(store.requestedWindows), Set(TimeWindow.allCases))
        XCTAssertNil(model.breakdownError)
        for window in TimeWindow.allCases {
            let expected = try store.entrypointBreakdown(for: window)
            model.selectedWindow = window
            XCTAssertEqual(model.breakdownsByWindow[window], expected)
            XCTAssertEqual(model.breakdown, expected)
            XCTAssertEqual(model.breakdown?.window, window)
        }
    }

    /// The regression test for the picker stall: selecting a window is a
    /// dictionary lookup, never a re-sum of tens of thousands of events on the
    /// main actor.
    func testSwitchingWindowsAfterAReloadReadsTheStoreAgainNever() {
        let store = CountingUsageStore()
        let model = makeModel(quota: ScriptedQuotaProvider(), store: store)
        model.refresh(force: true)
        let callsAfterReload = store.breakdownCallCount

        model.selectedWindow = .twentyFourHour
        model.selectedWindow = .sevenDay
        model.selectedWindow = .fiveHour

        XCTAssertEqual(store.breakdownCallCount, callsAfterReload)
    }

    func testBreakdownFailureSetsTheErrorAndLeavesNoBreakdown() {
        let model = makeModel(quota: ScriptedQuotaProvider(), store: FailingUsageStore())

        model.refresh(force: true)

        XCTAssertNotNil(model.breakdownError)
        XCTAssertNil(model.breakdown)
        XCTAssertTrue(model.breakdownsByWindow.isEmpty)
    }

    /// One window throwing must not leave a cache mixing the windows that
    /// still succeeded with the previous reload's numbers — the whole
    /// dictionary is assigned once, or not at all.
    func testOneWindowFailingKeepsThePreviousBreakdownsIntact() throws {
        let store = CountingUsageStore()
        let model = makeModel(quota: ScriptedQuotaProvider(), store: store)
        model.refresh(force: true)
        let loaded = model.breakdownsByWindow
        XCTAssertEqual(loaded.count, TimeWindow.allCases.count)

        store.failingWindow = .sevenDay
        model.refresh(force: true)

        XCTAssertNotNil(model.breakdownError)
        XCTAssertEqual(model.breakdownsByWindow, loaded)
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
}
