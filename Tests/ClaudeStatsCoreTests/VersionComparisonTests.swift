import XCTest
@testable import ClaudeStatsCore

final class VersionComparisonTests: XCTestCase {
    func testDetectsHigherMajorVersion() {
        XCTAssertTrue(isVersionNewer("2.0.0", than: "1.9.9"))
    }

    func testDetectsHigherMinorOrPatchVersion() {
        XCTAssertTrue(isVersionNewer("1.2.1", than: "1.2.0"))
        XCTAssertTrue(isVersionNewer("1.3.0", than: "1.2.9"))
    }

    func testReturnsFalseForEqualOrOlderVersion() {
        XCTAssertFalse(isVersionNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(isVersionNewer("1.1.0", than: "1.2.0"))
    }

    func testIgnoresLeadingVPrefix() {
        XCTAssertTrue(isVersionNewer("v1.2.0", than: "V1.1.0"))
    }

    func testTreatsMissingComponentsAsZero() {
        XCTAssertTrue(isVersionNewer("1.2", than: "1.1.9"))
        XCTAssertFalse(isVersionNewer("1.1", than: "1.1.0"))
    }

    func testNonNumericComponentMapsToZeroRatherThanShiftingPositions() {
        // "1.0-rc1.5" → [1, 0, 5], not [1, 5] — the "-rc1" component stays in place as 0.
        XCTAssertTrue(isVersionNewer("1.0-rc1.5", than: "1.0.4"))
    }
}
