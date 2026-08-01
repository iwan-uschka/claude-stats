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
