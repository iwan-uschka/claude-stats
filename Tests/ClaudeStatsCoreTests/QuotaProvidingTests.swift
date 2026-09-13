import XCTest
@testable import ClaudeStatsCore

final class QuotaProvidingTests: XCTestCase {
    private func staleSnapshot(_ confidence: QuotaConfidence) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: nil,
            sevenDay: nil,
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

    /// A source that can't tell accounts apart reports none — the default, so
    /// that a conformer which knows nothing about accounts (and the tests'
    /// stubs) can't be mistaken for one reporting a machine with a single
    /// account's worth of readings.
    func testDefaultOtherAccountSnapshotsIsEmpty() async {
        struct MinimalProvider: QuotaProviding {
            func currentSnapshot() async throws -> QuotaSnapshot {
                MockQuotaProvider.sampleSnapshot()
            }
            func clearCache() throws {}
        }

        let others = await MinimalProvider().otherAccountSnapshots()

        XCTAssertEqual(others, [])
    }

    /// The mock's own override of the same call, which the "two accounts"
    /// popover preview is built on: the init parameter has to reach the box and
    /// back out again, and nothing else in `swift test` runs that path.
    func testMockQuotaProviderReturnsConfiguredOtherAccounts() async {
        let other = MockQuotaProvider.sampleOtherAccountSnapshot()
        let provider = MockQuotaProvider(otherAccounts: [other])

        let others = await provider.otherAccountSnapshots()

        XCTAssertEqual(others, [other])
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
