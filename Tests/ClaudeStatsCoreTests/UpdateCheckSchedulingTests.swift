import XCTest
@testable import ClaudeStatsCore

final class UpdateCheckSchedulingTests: XCTestCase {
    func testNilLastCheckIsDue() {
        XCTAssertTrue(shouldRunUpdateCheck(lastCheck: nil, now: Date(), interval: 3600))
    }

    func testReturnsTrueOnceIntervalHasElapsed() {
        let now = Date()
        let lastCheck = now.addingTimeInterval(-3601)
        XCTAssertTrue(shouldRunUpdateCheck(lastCheck: lastCheck, now: now, interval: 3600))
    }

    func testReturnsFalseWhenIntervalHasNotYetElapsed() {
        let now = Date()
        let lastCheck = now.addingTimeInterval(-3599)
        XCTAssertFalse(shouldRunUpdateCheck(lastCheck: lastCheck, now: now, interval: 3600))
    }

    func testExactBoundaryIsDue() {
        let now = Date()
        let lastCheck = now.addingTimeInterval(-3600)
        XCTAssertTrue(shouldRunUpdateCheck(lastCheck: lastCheck, now: now, interval: 3600))
    }
}
