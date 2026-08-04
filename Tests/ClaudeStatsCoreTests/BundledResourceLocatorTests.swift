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

    func testStageCopiesSourceIntoDirectoryWhenDestinationIsFree() throws {
        let source = URL(fileURLWithPath: "/bundle/script.sh")
        let directory = URL(fileURLWithPath: "/tmp")
        var removed = false
        var copied: (URL, URL)?
        let destination = try BundledResourceLocator.stage(
            source,
            into: directory,
            fileExists: { _ in false },
            remove: { _ in removed = true },
            copy: { from, to in copied = (from, to) }
        )
        XCTAssertEqual(destination, directory.appendingPathComponent("script.sh"))
        XCTAssertFalse(removed)
        XCTAssertEqual(copied?.0, source)
        XCTAssertEqual(copied?.1, destination)
    }

    func testStageRemovesExistingDestinationBeforeCopying() throws {
        let source = URL(fileURLWithPath: "/bundle/script.sh")
        let directory = URL(fileURLWithPath: "/tmp")
        var removed = false
        _ = try BundledResourceLocator.stage(
            source,
            into: directory,
            fileExists: { _ in true },
            remove: { _ in removed = true },
            copy: { _, _ in }
        )
        XCTAssertTrue(removed)
    }

    func testStagePropagatesCopyFailure() {
        struct CopyError: Error {}
        let source = URL(fileURLWithPath: "/bundle/script.sh")
        let directory = URL(fileURLWithPath: "/tmp")
        XCTAssertThrowsError(
            try BundledResourceLocator.stage(
                source,
                into: directory,
                fileExists: { _ in false },
                remove: { _ in },
                copy: { _, _ in throw CopyError() }
            )
        )
    }
}
