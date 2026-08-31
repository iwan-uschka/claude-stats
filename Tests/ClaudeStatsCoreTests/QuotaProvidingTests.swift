import XCTest
@testable import ClaudeStatsCore

final class QuotaProvidingTests: XCTestCase {
    private func staleSnapshot(_ confidence: QuotaConfidence) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: .empty,
            sevenDay: .empty,
            confidence: confidence,
            capturedAt: Date(timeIntervalSince1970: 1_787_935_500)
        )
    }

    func testStaleQuotaSourceErrorDescriptionIncludesAge() {
        let error = ClaudeStatsError.staleQuotaSource(snapshot: staleSnapshot(.official), age: 601)
        XCTAssertEqual(error.errorDescription, "Quota data is stale (hasn't reported in \(DisplayFormat.duration(601))). Open a terminal running Claude Code to refresh it.")
    }

    /// The statusline hook's "open a terminal" advice is wrong for the other
    /// source: Claude Code rewrites its own usage cache on a schedule of its
    /// own, which no terminal of ours prods.
    func testStaleQuotaSourceErrorDescriptionForCachedOfficialDoesNotBlameTheTerminal() {
        let error = ClaudeStatsError.staleQuotaSource(snapshot: staleSnapshot(.cachedOfficial), age: 601)
        XCTAssertEqual(error.errorDescription, "Quota data is stale (hasn't reported in \(DisplayFormat.duration(601))). Claude Code hasn't refreshed its own usage cache yet — this isn't triggered by having a terminal open, and can take a while.")
    }

    /// `currentUsageCredits()`'s default implementation just reads the
    /// snapshot's credits fields off ``QuotaProviding/currentSnapshot()`` — the
    /// path every conformer without its own staleness gate to bypass takes.
    func testDefaultCurrentUsageCreditsReadsOffSnapshot() async throws {
        let snapshot = MockQuotaProvider.sampleSnapshotWithUsageCredits()
        let provider = MockQuotaProvider(snapshot: snapshot)

        let reading = try await provider.currentUsageCredits()

        XCTAssertEqual(reading.credits, snapshot.usageCredits)
        XCTAssertEqual(reading.disabledReason, snapshot.usageCreditsDisabledReason)
    }
}
