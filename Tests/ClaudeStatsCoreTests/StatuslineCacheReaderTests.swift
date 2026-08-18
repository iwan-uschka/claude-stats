import XCTest
@testable import ClaudeStatsCore

/// Every test here writes its fixture into a per-test temp directory and injects
/// that path — the real `~/Library/Application Support/ClaudeStats` is never
/// touched, read or written.
final class StatuslineCacheReaderTests: XCTestCase {
    private var directory: URL!
    private var cacheURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatuslineCacheReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("statusline-cache.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Stands in for a removal that fails for any reason other than "already
    /// gone" — a real permission failure is platform-dependent and doesn't
    /// reproduce under a root CI user.
    private final class ThrowingFileManager: FileManager {
        struct RemovalFailure: Error, LocalizedError {
            var errorDescription: String? { "permission denied" }
        }

        override func removeItem(at url: URL) throws {
            throw RemovalFailure()
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: cacheURL)
    }

    private func makeReader(
        stalenessThreshold: TimeInterval = QuotaSnapshot.defaultStalenessThreshold,
        fileManager: FileManager = .default
    ) -> StatuslineCacheReader {
        let fixedNow = now
        return StatuslineCacheReader(
            cacheURL: cacheURL,
            stalenessThreshold: stalenessThreshold,
            fileManager: fileManager,
            now: { fixedNow }
        )
    }

    /// The shape the helper script writes when `jq` is available.
    private func filteredCache(capturedAt: Date) -> String {
        """
        {
          "captured_at": \(Int(capturedAt.timeIntervalSince1970)),
          "rate_limits": {
            "five_hour": { "used_percentage": 23.5, "resets_at": \(Int(capturedAt.timeIntervalSince1970) + 3600) },
            "seven_day": { "used_percentage": 41.2, "resets_at": \(Int(capturedAt.timeIntervalSince1970) + 86_400) }
          }
        }
        """
    }

    // MARK: - Happy path

    func testFreshCacheParsesBothWindowsAsOfficial() async throws {
        let capturedAt = now.addingTimeInterval(-30)
        try write(filteredCache(capturedAt: capturedAt))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .official)
        XCTAssertEqual(snapshot.fiveHour.percentUsed, 23.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.sevenDay.percentUsed, 41.2, accuracy: 0.001)
        XCTAssertEqual(snapshot.capturedAt.timeIntervalSince1970,
                       capturedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(snapshot.isStale(asOf: now))
        // resets_at is epoch seconds in the statusline payload.
        XCTAssertEqual(snapshot.fiveHour.resetsAt?.timeIntervalSince1970,
                       capturedAt.timeIntervalSince1970 + 3600)
        XCTAssertEqual(snapshot.sevenDay.timeUntilReset(from: now) ?? 0, 86_370, accuracy: 2)
    }

    /// The no-`jq` fallback: raw statusline payload, no `captured_at`, capture
    /// time taken from the file's modification date.
    func testRawPayloadWithoutCapturedAtFallsBackToFileModificationDate() async throws {
        try write("""
        {
          "session_id": "abc",
          "model": { "display_name": "Opus 5" },
          "context_window": { "used_percentage": 8 },
          "rate_limits": {
            "five_hour": { "used_percentage": 62, "resets_at": \(Int(now.timeIntervalSince1970) + 8040) },
            "seven_day": { "used_percentage": 31 }
          }
        }
        """)
        let modified = now.addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: cacheURL.path)

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .official)
        XCTAssertEqual(snapshot.fiveHour.percentUsed, 62)
        XCTAssertEqual(snapshot.sevenDay.percentUsed, 31)
        XCTAssertNil(snapshot.sevenDay.resetsAt)
        XCTAssertEqual(snapshot.capturedAt.timeIntervalSince1970,
                       modified.timeIntervalSince1970, accuracy: 1)
    }

    /// Docs say each window may be independently absent.
    func testMissingSevenDayWindowYieldsEmptyWindowNotFailure() async throws {
        try write("""
        {
          "captured_at": \(Int(now.timeIntervalSince1970) - 5),
          "rate_limits": { "five_hour": { "used_percentage": 10 } }
        }
        """)

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour.percentUsed, 10)
        XCTAssertEqual(snapshot.sevenDay, .empty)
    }

    // MARK: - Staleness

    func testCacheOlderThanThresholdThrowsStale() async throws {
        // 601s old — one second past the 600s default.
        try write(filteredCache(capturedAt: now.addingTimeInterval(-601)))

        await assertThrows(.staleQuotaSource(age: 601)) {
            try await self.makeReader().currentSnapshot()
        }
    }

    func testCacheJustInsideThresholdIsAccepted() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-599)))
        let snapshot = try await makeReader().currentSnapshot()
        XCTAssertEqual(snapshot.confidence, .official)
    }

    func testCustomStalenessThresholdIsHonoured() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-120)))

        // Fresh under the default, stale under a 60s threshold.
        let underDefault = try await makeReader().currentSnapshot()
        XCTAssertEqual(underDefault.confidence, .official)
        await assertThrows(.staleQuotaSource(age: 120)) {
            try await self.makeReader(stalenessThreshold: 60).currentSnapshot()
        }
    }

    // MARK: - Failure modes

    func testMissingCacheFileThrowsNoQuotaSourceAvailable() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    /// A payload captured before the first API response (or a non-subscriber) has
    /// no `rate_limits` — that's "no data", not a parse failure.
    func testPayloadWithoutRateLimitsThrowsNoQuotaSourceAvailable() async throws {
        try write(#"{ "session_id": "abc", "model": { "display_name": "Opus 5" } }"#)
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    func testMalformedJSONThrowsUnexpectedQuotaResponse() async throws {
        try write("{ this is not json")
        await assertThrowsUnexpectedQuotaResponse {
            try await self.makeReader().currentSnapshot()
        }
    }

    func testWindowWithoutPercentageIsNotReadAsZero() async throws {
        // Only a reset time, no percentage: must not be reported as "0% used".
        try write("""
        {
          "captured_at": \(Int(now.timeIntervalSince1970)),
          "rate_limits": { "five_hour": { "resets_at": \(Int(now.timeIntervalSince1970) + 60) } }
        }
        """)
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    // MARK: - Clearing

    func testClearCacheRemovesTheCacheFile() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        let reader = makeReader()
        try reader.clearCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        // Nothing has written a fresh cache yet — the expected post-clear state.
        await assertThrows(.noQuotaSourceAvailable) {
            try await reader.currentSnapshot()
        }
    }

    func testClearCacheWithNoCacheFileDoesNotThrow() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertNoThrow(try makeReader().clearCache())
    }

    /// Only "already gone" is swallowed — anything else has to reach the caller,
    /// which shows it instead of a false "cleared" notice.
    func testClearCachePropagatesGenuineFileSystemError() throws {
        let reader = makeReader(fileManager: ThrowingFileManager())
        XCTAssertThrowsError(try reader.clearCache()) { error in
            XCTAssertTrue(error is ThrowingFileManager.RemovalFailure, "\(error)")
        }
    }

    // MARK: - Default path

    func testDefaultCacheURLPointsAtApplicationSupport() {
        let path = StatuslineCacheReader.defaultCacheURL.path
        XCTAssertTrue(path.hasSuffix("/ClaudeStats/statusline-cache.json"), path)
        XCTAssertTrue(path.contains("Application Support"), path)
    }
}
