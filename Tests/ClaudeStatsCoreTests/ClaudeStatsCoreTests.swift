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
        let breakdown = EntrypointBreakdown(
            window: .fiveHour,
            usageByEntrypoint: [.cli: TokenUsage(inputTokens: 4, cacheReadInputTokens: 6)]
        )
        XCTAssertEqual(breakdown.orderedRows.map(\.usage.totalTokens), [10, 0, 0])
        XCTAssertEqual(breakdown.orderedRows.map(\.usage), [
            TokenUsage(inputTokens: 4, cacheReadInputTokens: 6),
            .zero,
            .zero,
        ])
        XCTAssertEqual(breakdown.totalTokens, 10)
        XCTAssertEqual(breakdown.totalUsage, TokenUsage(inputTokens: 4, cacheReadInputTokens: 6))
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

    // MARK: - QuotaSnapshot coding

    private func roundTripped(_ snapshot: QuotaSnapshot) throws -> QuotaSnapshot {
        let encoded = try JSONEncoder().encode(snapshot)
        return try JSONDecoder().decode(QuotaSnapshot.self, from: encoded)
    }

    func testQuotaSnapshotRoundTripsWithoutScopedLimits() throws {
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: 11, resetsAt: Date(timeIntervalSince1970: 1_787_935_800)),
            sevenDay: QuotaWindow(percentUsed: 97),
            confidence: .cachedOfficial,
            capturedAt: Date(timeIntervalSince1970: 1_787_935_500)
        )

        XCTAssertEqual(snapshot.scopedWeekly, [])
        XCTAssertEqual(try roundTripped(snapshot), snapshot)
    }

    func testQuotaSnapshotRoundTripsWithScopedLimits() throws {
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: 11),
            sevenDay: QuotaWindow(percentUsed: 97),
            confidence: .cachedOfficial,
            capturedAt: Date(timeIntervalSince1970: 1_787_935_500),
            scopedWeekly: [
                QuotaScopedLimit(
                    label: "Sonnet",
                    percentUsed: 42,
                    resetsAt: Date(timeIntervalSince1970: 1_787_958_000),
                    isActive: true,
                    severity: "warning"
                ),
                QuotaScopedLimit(label: "Fable", percentUsed: 0),
            ]
        )

        let decoded = try roundTripped(snapshot)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.scopedWeekly.map(\.label), ["Sonnet", "Fable"])
        XCTAssertNil(decoded.scopedWeekly[1].resetsAt)
        XCTAssertNil(decoded.scopedWeekly[1].severity)
    }

    /// A snapshot encoded before ``QuotaSnapshot/scopedWeekly`` existed has no
    /// such key — it must decode to the empty default, not fail.
    func testQuotaSnapshotDecodesJSONWithoutScopedWeeklyKey() throws {
        let json = """
        { "fiveHour": { "percentUsed": 62 },
          "sevenDay": { "percentUsed": 31 },
          "confidence": "official",
          "capturedAt": 776543210 }
        """

        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.fiveHour.percentUsed, 62)
        XCTAssertEqual(decoded.confidence, .official)
        XCTAssertEqual(decoded.scopedWeekly, [])
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

    func testMockQuotaProviderClearCacheThrowsNoQuotaSourceAvailable() async throws {
        let provider = MockQuotaProvider()
        let seeded = try await provider.currentSnapshot()
        XCTAssertEqual(seeded.confidence, .official)

        try provider.clearCache()

        await assertThrows(.noQuotaSourceAvailable) {
            try await provider.currentSnapshot()
        }
    }
}
