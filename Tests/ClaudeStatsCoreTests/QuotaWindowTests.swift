import XCTest
@testable import ClaudeStatsCore

final class QuotaWindowTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_787_935_800)

    /// The rule both quota readers drop expired windows by. Live *at* the
    /// reset instant: `resets_at` is the last moment the window still exists.
    func testWindowIsLiveUpToAndIncludingItsReset() {
        let window = QuotaWindow(percentUsed: 11, resetsAt: reset)

        XCTAssertTrue(window.isLive(asOf: reset.addingTimeInterval(-1)))
        XCTAssertTrue(window.isLive(asOf: reset))
        XCTAssertFalse(window.isLive(asOf: reset.addingTimeInterval(1)))
    }

    /// No `resets_at` means nothing can show the window has expired.
    func testWindowWithoutAResetIsAlwaysLive() {
        XCTAssertTrue(QuotaWindow(percentUsed: 11).isLive(asOf: .distantFuture))
    }

    /// The snapshot-level form of the same rule: each window is judged on its
    /// own, and everything that isn't a window passes through untouched.
    func testDroppingExpiredWindowsClearsOnlyTheExpiredOnes() {
        let snapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: 11, resetsAt: reset),
            sevenDay: QuotaWindow(percentUsed: 5, resetsAt: reset.addingTimeInterval(86_400)),
            confidence: .official,
            capturedAt: reset.addingTimeInterval(-600)
        )

        let aged = snapshot.droppingExpiredWindows(asOf: reset.addingTimeInterval(1))

        XCTAssertNil(aged.fiveHour)
        XCTAssertEqual(aged.sevenDay, snapshot.sevenDay)
        XCTAssertEqual(aged.capturedAt, snapshot.capturedAt)
        XCTAssertEqual(aged.confidence, snapshot.confidence)
    }
}
