import XCTest
@testable import ClaudeStatsCore

final class ReleaseURLValidationTests: XCTestCase {
    func testAcceptsHTTPSGitHubURL() {
        let url = URL(string: "https://github.com/iwan-uschka/claude-stats/releases/tag/v1.2.0")!
        XCTAssertTrue(isTrustedReleaseURL(url))
    }

    func testRejectsNonHTTPSScheme() {
        let url = URL(string: "http://github.com/iwan-uschka/claude-stats")!
        XCTAssertFalse(isTrustedReleaseURL(url))
    }

    func testRejectsSubdomainOrOtherHost() {
        XCTAssertFalse(isTrustedReleaseURL(URL(string: "https://raw.github.com/x")!))
        XCTAssertFalse(isTrustedReleaseURL(URL(string: "https://github.com.evil.com/x")!))
        XCTAssertFalse(isTrustedReleaseURL(URL(string: "https://evil.com/github.com")!))
    }
}
