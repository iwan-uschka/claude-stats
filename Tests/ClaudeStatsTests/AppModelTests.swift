import ClaudeStatsCore
import XCTest

@testable import ClaudeStats

@MainActor
final class AppModelTests: XCTestCase {
    private actor ScriptedQuotaProvider: QuotaProviding {
        var result: Result<QuotaSnapshot, Error> = .failure(ClaudeStatsError.noQuotaSourceAvailable)

        func setResult(_ result: Result<QuotaSnapshot, Error>) {
            self.result = result
        }

        func currentSnapshot() async throws -> QuotaSnapshot {
            try result.get()
        }

        /// `nonisolated` because the protocol requirement is synchronous; there is
        /// no on-disk state here, so the scripted `result` stays as set.
        nonisolated func clearCache() throws {}
    }

    private struct FailingUsageStore: UsageStoring {
        struct Failure: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }

        func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown { throw Failure() }
        func modelUsage(last24h: Bool) throws -> [ModelUsage] { throw Failure() }
        func burnRatePerHour() throws -> Double { throw Failure() }
        func estimatedCostToday() throws -> Double { throw Failure() }
        func detectedPlanTier() throws -> PlanTier { throw Failure() }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
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
        model.clearQuotaCache()
        await waitUntil { model.quotaCacheClearedNotice != nil }

        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.quotaError)
        XCTAssertNil(model.quotaWarning)
        XCTAssertNotNil(model.quotaCacheClearedNotice)
    }

    func testClearQuotaCacheNoticeIsDroppedOnceAFreshReadingLands() async {
        let provider = ScriptedQuotaProvider()
        let sample = MockQuotaProvider.sampleSnapshot()
        await provider.setResult(.success(sample))
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())

        model.clearQuotaCache()
        await waitUntil { model.snapshot != nil }

        XCTAssertEqual(model.snapshot, sample)
        XCTAssertNil(model.quotaCacheClearedNotice)
    }

    func testClearQuotaCacheStillReportsAGenuineFailure() async {
        let provider = ScriptedQuotaProvider()
        await provider.setResult(.failure(ClaudeStatsError.unexpectedQuotaResponse("nope")))
        let model = AppModel(quotaProvider: provider, usageStore: MockUsageStore())

        model.clearQuotaCache()
        await waitUntil { model.quotaError != nil }

        XCTAssertNil(model.quotaCacheClearedNotice)
        XCTAssertNotNil(model.quotaError)
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
