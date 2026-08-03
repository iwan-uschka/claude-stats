import XCTest
@testable import ClaudeStatsCore

final class BundledResourceLocatorTests: XCTestCase {
    func testResolvesFirstCandidateDirectoryWhereFileExists() {
        let match = URL(fileURLWithPath: "/app/Contents/Resources/Bundle.bundle/script.sh")
        let url = BundledResourceLocator.resolve(
            bundleName: "Bundle.bundle",
            fileName: "script.sh",
            candidateDirectories: [
                URL(fileURLWithPath: "/app/Contents/Resources"),
                URL(fileURLWithPath: "/app"),
            ],
            fileExists: { $0 == match.path }
        )
        XCTAssertEqual(url, match)
    }

    func testFallsThroughToLaterCandidateDirectories() {
        let match = URL(fileURLWithPath: "/app/Bundle.bundle/script.sh")
        let url = BundledResourceLocator.resolve(
            bundleName: "Bundle.bundle",
            fileName: "script.sh",
            candidateDirectories: [
                URL(fileURLWithPath: "/app/Contents/Resources"),
                URL(fileURLWithPath: "/app"),
            ],
            fileExists: { $0 == match.path }
        )
        XCTAssertEqual(url, match)
    }

    func testReturnsNilWhenNoCandidateHasTheFile() {
        let url = BundledResourceLocator.resolve(
            bundleName: "Bundle.bundle",
            fileName: "script.sh",
            candidateDirectories: [
                URL(fileURLWithPath: "/app/Contents/Resources"),
                nil,
            ],
            fileExists: { _ in false }
        )
        XCTAssertNil(url)
    }
}
