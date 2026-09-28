import XCTest

@testable import ClaudeStatsCore

final class ClaudeStateFileTests: XCTestCase {
    private var directory: URL!
    private var url: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeStateFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(".claude.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// `CachedUtilizationReader` traps if `.unchanged` ever comes back for a
    /// `nil` previous fingerprint, trusting exactly this guarantee.
    ///
    /// breaks-if: the `if let previous, previous == fingerprint` guard at
    /// `ClaudeStateFile.swift:112` is loosened to fire without a previous
    /// fingerprint to compare against.
    func testLoadWithNoPreviousFingerprintNeverReturnsUnchanged() throws {
        try Data("{}".utf8).write(to: url)

        guard case .loaded = ClaudeStateFile.load(candidates: [url], unchangedSince: nil) else {
            return XCTFail("expected .loaded for a present file with no previous fingerprint")
        }
    }
}
