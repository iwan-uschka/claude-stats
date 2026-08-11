import XCTest
@testable import ClaudeStatsCore

final class ReleaseCheckResultTests: XCTestCase {
    private func json(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    func testUpdateAvailableWhenTagIsNewer() {
        let data = json(["tag_name": "v2.0.0", "html_url": "https://github.com/iwan-uschka/claude-stats/releases/tag/v2.0.0"])
        let result = decodeReleaseCheck(data: data, httpStatus: 200, localVersion: "1.9.0")
        XCTAssertEqual(result, .updateAvailable(version: "2.0.0", url: "https://github.com/iwan-uschka/claude-stats/releases/tag/v2.0.0"))
    }

    func testUpToDateWhenTagIsSameOrOlder() {
        let data = json(["tag_name": "v1.0.0", "html_url": "https://github.com/x/y"])
        XCTAssertEqual(decodeReleaseCheck(data: data, httpStatus: 200, localVersion: "1.0.0"), .upToDate(version: "1.0.0"))
        XCTAssertEqual(decodeReleaseCheck(data: data, httpStatus: 200, localVersion: "1.1.0"), .upToDate(version: "1.1.0"))
    }

    func testHTTPErrorStatusTakesPrecedenceOverBody() {
        let data = json(["tag_name": "v2.0.0", "html_url": "https://github.com/x/y"])
        XCTAssertEqual(decodeReleaseCheck(data: data, httpStatus: 404, localVersion: "1.0.0"), .httpError(404))
        XCTAssertEqual(decodeReleaseCheck(data: data, httpStatus: 403, localVersion: "1.0.0"), .httpError(403))
    }

    func testMalformedResponseWhenTagNameMissing() {
        let data = json(["html_url": "https://github.com/x/y"])
        XCTAssertEqual(decodeReleaseCheck(data: data, httpStatus: 200, localVersion: "1.0.0"), .malformedResponse)
    }

    func testMalformedResponseWhenHTMLURLMissing() {
        let data = json(["tag_name": "v2.0.0"])
        XCTAssertEqual(decodeReleaseCheck(data: data, httpStatus: 200, localVersion: "1.0.0"), .malformedResponse)
    }

    func testMalformedResponseWhenBodyIsNotJSON() {
        let data = Data("not json".utf8)
        XCTAssertEqual(decodeReleaseCheck(data: data, httpStatus: 200, localVersion: "1.0.0"), .malformedResponse)
    }

    func testMalformedResponseWhenBodyIsNotAnObject() {
        let data = Data("[1,2,3]".utf8)
        XCTAssertEqual(decodeReleaseCheck(data: data, httpStatus: 200, localVersion: "1.0.0"), .malformedResponse)
    }
}
