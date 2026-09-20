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
}
