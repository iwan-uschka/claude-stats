import XCTest
@testable import ClaudeStatsCore

/// Every test here writes its fixture into a per-test temp directory and injects
/// that path — the real `~/.claude.json` is never touched, read or written.
final class CachedUtilizationReaderTests: XCTestCase {
    private var directory: URL!
    private var stateFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CachedUtilizationReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateFileURL = directory.appendingPathComponent(".claude.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// `2026-08-28T16:45:00Z` — the reference "now" every fixture is offset
    /// from, five minutes before the `five_hour` reset in the real payload
    /// below.
    private let now = Date(timeIntervalSince1970: 1_787_935_500)

    /// The two `resets_at` values in ``stateFile(fetchedAt:)``, as epoch
    /// seconds.
    private let fiveHourResetEpoch: TimeInterval = 1_787_935_800.401807
    private let sevenDayResetEpoch: TimeInterval = 1_787_958_000.401826

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: stateFileURL)
    }

    private func makeReader(
        stalenessThreshold: TimeInterval = CachedUtilizationReader.defaultStalenessThreshold
    ) -> CachedUtilizationReader {
        let fixedNow = now
        return CachedUtilizationReader(
            candidateURLs: [stateFileURL],
            stalenessThreshold: stalenessThreshold,
            now: { fixedNow }
        )
    }

    /// The payload as it actually appears on a real machine, trimmed only of
    /// the unrelated top-level keys (`projects`, `userID`, …). Keys this reader
    /// deliberately ignores — `limits`, `spend`, `accountUuid`, the null scoped
    /// windows — are kept, so a future reader for them can't quietly change
    /// what this one sees.
    private func stateFile(fetchedAt: Date) -> String {
        """
        {
          "numStartups": 412,
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(fetchedAt.timeIntervalSince1970 * 1000)),
            "accountUuid": "0f9c1d3e-8a4b-4c2d-9e1f-6b7a8c9d0e1f",
            "utilization": {
              "five_hour": { "utilization": 11, "resets_at": "2026-08-28T16:50:00.401807+00:00" },
              "seven_day": { "utilization": 97, "resets_at": "2026-08-28T23:00:00.401826+00:00" },
              "seven_day_opus": null,
              "seven_day_sonnet": null,
              "member_dashboard_available": false,
              "limits": [
                { "kind": "session", "group": "session", "percent": 11, "severity": "normal",
                  "is_active": false, "resets_at": "2026-08-28T16:50:00.401807+00:00" },
                { "kind": "weekly_all", "group": "weekly", "percent": 97, "severity": "critical",
                  "is_active": true, "resets_at": "2026-08-28T23:00:00.401826+00:00" }
              ]
            }
          }
        }
        """
    }

    // MARK: - Happy path

    func testRealPayloadParsesBothWindowsAsCachedOfficial() async throws {
        let fetchedAt = now.addingTimeInterval(-5 * 60)
        try write(stateFile(fetchedAt: fetchedAt))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .cachedOfficial)
        XCTAssertEqual(snapshot.confidence.displayLabel, "official (cached)")
        XCTAssertEqual(snapshot.fiveHour.percentUsed, 11)
        XCTAssertEqual(snapshot.sevenDay.percentUsed, 97)
        // `fetchedAtMs` is epoch milliseconds.
        XCTAssertEqual(snapshot.capturedAt.timeIntervalSince1970,
                       fetchedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// ISO-8601 with fractional seconds *and* a `+00:00` offset — the shape the
    /// statusline payload never uses, so it has its own assertion.
    func testResetTimestampsParseFromFractionalISO8601() async throws {
        try write(stateFile(fetchedAt: now.addingTimeInterval(-60)))

        let snapshot = try await makeReader().currentSnapshot()

        let fiveHourReset = try XCTUnwrap(snapshot.fiveHour.resetsAt)
        let sevenDayReset = try XCTUnwrap(snapshot.sevenDay.resetsAt)
        XCTAssertEqual(fiveHourReset.timeIntervalSince1970, fiveHourResetEpoch, accuracy: 0.001)
        XCTAssertEqual(sevenDayReset.timeIntervalSince1970, sevenDayResetEpoch, accuracy: 0.001)
        // Fractional seconds survive, so a countdown can't be a second off.
        XCTAssertEqual(snapshot.fiveHour.timeUntilReset(from: now) ?? 0, 300, accuracy: 1)
    }

    /// `windows(in:)`'s documented contract: each window is independently
    /// optional, and the missing one becomes `.empty` rather than failing.
    func testSevenDayOnlyYieldsEmptyFiveHourNotFailure() async throws {
        try write("""
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000) - 60_000),
            "utilization": {
              "seven_day": { "utilization": 42, "resets_at": "2026-08-28T23:00:00.401826+00:00" },
              "seven_day_opus": null
            }
          }
        }
        """)

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.sevenDay.percentUsed, 42)
        XCTAssertEqual(snapshot.fiveHour, .empty)
    }

    // MARK: - Staleness

    func testReadingOlderThanThirtyMinutesThrowsStale() async throws {
        try write(stateFile(fetchedAt: now.addingTimeInterval(-1801)))

        await assertThrows(.staleQuotaSource(age: 1801)) {
            try await self.makeReader().currentSnapshot()
        }
    }

    /// The whole point of the 30-minute threshold: a 15-minute-old reading was
    /// measured mid-session and is normal, where the statusline's 10-minute
    /// threshold would have rejected it.
    func testFifteenMinuteOldReadingIsAccepted() async throws {
        try write(stateFile(fetchedAt: now.addingTimeInterval(-15 * 60)))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .cachedOfficial)
        XCTAssertEqual(CachedUtilizationReader.defaultStalenessThreshold, 30 * 60)
    }

    // MARK: - Failure modes

    func testMissingStateFileThrowsNoQuotaSourceAvailable() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateFileURL.path))
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    /// A Claude Code install that has never had a rate-limited response has no
    /// such key — "no data yet", not a fault.
    func testMissingCachedUsageUtilizationThrowsNoQuotaSourceAvailable() async throws {
        try write(#"{ "numStartups": 3, "cachedGrowthBookFeatures": {} }"#)
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    func testCachedUtilizationWithoutAnyWindowThrowsNoQuotaSourceAvailable() async throws {
        try write("""
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000)),
            "utilization": { "seven_day_opus": null, "seven_day_sonnet": null }
          }
        }
        """)
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    /// No `fetchedAtMs` means the reading's age is unknown, and the state
    /// file's own mtime is not a stand-in — Claude Code rewrites it for
    /// unrelated keys constantly.
    func testMissingFetchedAtThrowsNoQuotaSourceAvailable() async throws {
        try write("""
        {
          "cachedUsageUtilization": {
            "utilization": { "five_hour": { "utilization": 11 } }
          }
        }
        """)
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    /// Present but corrupt is distinct from absent: the file exists and is
    /// broken, which is something a user could look at.
    func testMalformedJSONThrowsUnexpectedQuotaResponse() async throws {
        try write("{ this is not json")

        let message = await assertThrowsUnexpectedQuotaResponse {
            try await self.makeReader().currentSnapshot()
        }

        // Names the file, never its contents.
        XCTAssertEqual(message, ".claude.json is not a JSON object")
    }

    func testWindowWithoutPercentageIsNotReadAsZero() async throws {
        try write("""
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000)),
            "utilization": { "five_hour": { "resets_at": "2026-08-28T16:50:00.401807+00:00" } }
          }
        }
        """)
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    // MARK: - Clearing

    /// Documented no-op: `~/.claude.json` is Claude Code's live state file, not
    /// ours to delete.
    func testClearCacheLeavesTheStateFileUntouched() async throws {
        try write(stateFile(fetchedAt: now.addingTimeInterval(-60)))
        let before = try Data(contentsOf: stateFileURL)

        let reader = makeReader()
        XCTAssertNoThrow(try reader.clearCache())

        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFileURL.path))
        XCTAssertEqual(try Data(contentsOf: stateFileURL), before)
        // Still reads, because nothing was cleared.
        let snapshot = try await reader.currentSnapshot()
        XCTAssertEqual(snapshot.fiveHour.percentUsed, 11)
    }

    // MARK: - Default candidates

    func testDefaultCandidatesMatchTheStateFileProbeOrder() {
        let reader = CachedUtilizationReader()
        XCTAssertEqual(reader.candidateURLs, ClaudeConfigDirectory.stateFileCandidates())
        XCTAssertTrue(reader.candidateURLs.allSatisfy { $0.lastPathComponent == ".claude.json" })
    }
}
