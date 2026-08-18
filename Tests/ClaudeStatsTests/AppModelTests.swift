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
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())

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
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())
        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        await provider.setResult(.failure(ClaudeStatsError.staleQuotaSource(age: 600)))
        model.refresh(force: true)
        await waitUntil { model.quotaWarning != nil }

        XCTAssertEqual(model.snapshot, sample)
        XCTAssertNil(model.quotaError)
        XCTAssertNotNil(model.quotaWarning)
    }

    func testRefreshOnHardErrorClearsSnapshotAndSetsError() async {
        let provider = ScriptedQuotaProvider()
        let sample = MockQuotaProvider.sampleSnapshot()
        await provider.setResult(.success(sample))
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())
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
        let model = AppModel(quotaProvider: provider, usageStore: FailingUsageStore())

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
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())
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
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())
        model.refresh(force: true)
        await waitUntil { model.snapshot != nil }

        // A stale-but-present reading is not the "waiting for a fresh render"
        // state the notice describes, so the post-clear poll replaces it with a
        // warning instead of leaving it set.
        await provider.setResult(.failure(ClaudeStatsError.staleQuotaSource(age: 600)))
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
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())

        model.clearQuotaCache()
        await waitUntil(timeout: 5) { model.snapshot != nil }

        XCTAssertEqual(model.snapshot, sample)
        XCTAssertNil(model.quotaCacheClearedNotice)
    }

    func testClearQuotaCacheStillReportsAGenuineFailure() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.failure(ClaudeStatsError.unexpectedQuotaResponse("nope")))
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())

        model.clearQuotaCache()
        await waitUntil(timeout: 5) { model.quotaError != nil }

        XCTAssertNil(model.quotaCacheClearedNotice)
        XCTAssertNotNil(model.quotaError)
    }

    func testClearQuotaCacheDeleteFailureSurfacesErrorAndLeavesStateUntouched() async {
        let provider = ScriptedQuotaProvider()
        let sample = MockQuotaProvider.sampleSnapshot()
        await provider.setResult(.success(sample))
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())
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
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())

        model.pollAfterInstall()
        await provider.setResult(.success(MockQuotaProvider.sampleSnapshot()))
        await waitUntil(timeout: 5) { model.snapshot != nil }

        XCTAssertNotNil(model.snapshot)
    }
}
