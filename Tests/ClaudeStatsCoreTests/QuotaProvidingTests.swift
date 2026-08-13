import XCTest
@testable import ClaudeStatsCore

final class QuotaProvidingTests: XCTestCase {
    func testStaleQuotaSourceErrorDescriptionIncludesAge() {
        let error = ClaudeStatsError.staleQuotaSource(age: 601)
        XCTAssertEqual(error.errorDescription, "Quota data is stale (hasn't reported in \(DisplayFormat.duration(601))). Open a terminal running Claude Code to refresh it.")
    }
}
