import XCTest
@testable import ClaudeStatsCore

final class ClaudeStatsCoreTests: XCTestCase {
    /// Placeholder so `swift test` has something to run. Real coverage for
    /// parsing, quota, and plan detection lands with those implementations.
    func testEntrypointMapsRawJSONLValues() {
        XCTAssertEqual(Entrypoint(rawJSONLValue: "cli"), .cli)
        XCTAssertEqual(Entrypoint(rawJSONLValue: "claude-vscode"), .vscode)
        XCTAssertEqual(Entrypoint(rawJSONLValue: "sdk-cli"), .sdkAgent)
        XCTAssertNil(Entrypoint(rawJSONLValue: "something-new"))
    }

    func testEntrypointBreakdownOrderedRowsFillsZeros() {
        let breakdown = EntrypointBreakdown(window: .fiveHour, tokensByEntrypoint: [.cli: 10])
        XCTAssertEqual(breakdown.orderedRows.map(\.tokens), [10, 0, 0])
        XCTAssertEqual(breakdown.totalTokens, 10)
    }

    func testTimeWindowStartDate() {
        let end = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(TimeWindow.fiveHour.startDate(endingAt: end), end.addingTimeInterval(-5 * 60 * 60))
    }

    func testNearestKnownTierAtToleranceBoundary() {
        // 19_000 * 1.25 == 23_750, exactly at default tolerance
        XCTAssertEqual(PlanTier.nearestKnownTier(forFiveHourTokens: 23_750), .pro)
        XCTAssertEqual(PlanTier.nearestKnownTier(forFiveHourTokens: 23_751), .custom(tokens: 23_751))
    }

    func testMocksProvideDataForEveryWindow() async throws {
        let store = MockUsageStore()
        for window in TimeWindow.allCases {
            XCTAssertGreaterThan(try store.entrypointBreakdown(for: window).totalTokens, 0)
        }

        let snapshot = try await MockQuotaProvider().currentSnapshot()
        XCTAssertEqual(snapshot.confidence, .official)
        XCTAssertFalse(snapshot.isStale())
    }
}
