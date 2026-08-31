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

    /// The shape the helper script writes when `jq` is available and it found
    /// nothing to copy out of `~/.claude.json` — also the shape every cache
    /// written before the script learned to copy has.
    private func filteredCache(capturedAt: Date) -> String {
        filteredCache(capturedAt: capturedAt, utilization: nil)
    }

    /// The same, plus the `utilization` object the script copies out of
    /// `cachedUsageUtilization.utilization`.
    private func filteredCache(capturedAt: Date, utilization: String?) -> String {
        let epoch = Int(capturedAt.timeIntervalSince1970)
        let extra = utilization.map { ",\n  \"utilization\": \($0)" } ?? ""
        return """
        {
          "captured_at": \(epoch),
          "rate_limits": {
            "five_hour": { "used_percentage": 23.5, "resets_at": \(epoch + 3600) },
            "seven_day": { "used_percentage": 41.2, "resets_at": \(epoch + 86_400) }
          }\(extra)
        }
        """
    }

    /// `weekly_scoped` + `spend` + `extra_usage` as the script copies them:
    /// verbatim sub-objects of `cachedUsageUtilization.utilization`, so
    /// ``QuotaJSON/scopedLimits(in:)`` and ``QuotaJSON/usageCredits(in:)`` read
    /// them here exactly as they do out of `~/.claude.json` — see the mirror
    /// fixtures in `CachedUtilizationReaderTests`.
    private let copiedUtilization = """
        {
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
              "resets_at": null, "is_active": false,
              "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null } },
            { "kind": "weekly_scoped", "percent": 42, "is_active": true,
              "scope": { "model": { "display_name": "Sonnet" } } }
          ],
          "spend": {
            "used":  { "amount_minor": 0, "currency": "EUR", "exponent": 2 },
            "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
            "percent": 0, "severity": "normal", "enabled": true, "disabled_reason": null
          },
          "extra_usage": {
            "is_enabled": true, "monthly_limit": 3300, "used_credits": 0,
            "user_disabled": false, "spend_limit_reached": false, "disabled_reason": null
          }
        }
        """

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
        // No `utilization` key in this fixture — the shape of every cache the
        // script wrote before it learned to copy one, and of every cache
        // written without `jq`. Empty and `nil`, never a throw.
        XCTAssertEqual(snapshot.scopedWeekly, [])
        XCTAssertNil(snapshot.usageCredits)
        XCTAssertNil(snapshot.usageCreditsDisabledReason)
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

    // MARK: - The copied `utilization` object

    /// The whole point of the copy: a hook-only reading now carries all four
    /// bars, at the one `captured_at` the script stamped.
    func testCopiedUtilizationPopulatesScopedLimitsAndCredits() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30), utilization: copiedUtilization))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .official)
        // The account-wide windows still come from `rate_limits`, not from the
        // copy — the copy deliberately carries no `five_hour` / `seven_day`.
        XCTAssertEqual(snapshot.fiveHour.percentUsed, 23.5, accuracy: 0.001)
        // Sorted by percent descending, same as out of `~/.claude.json`.
        XCTAssertEqual(snapshot.scopedWeekly.map(\.label), ["Sonnet", "Fable"])
        XCTAssertEqual(snapshot.scopedWeekly.map(\.percentUsed), [42, 0])

        let credits = try XCTUnwrap(snapshot.usageCredits)
        XCTAssertEqual(credits.limit, MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2))
        XCTAssertEqual(credits.percentUsed, 0)
        XCTAssertNil(snapshot.usageCreditsDisabledReason)
    }

    /// `extra_usage` is copied across too, not just `spend` — without it the
    /// veto could never fire here, and this reader would show credits the
    /// backup source correctly hides.
    func testCopiedExtraUsageStillVetoesAPopulatedSpend() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30), utilization: """
            {
              "limits": [],
              "spend": {
                "used":  { "amount_minor": 500, "currency": "EUR", "exponent": 2 },
                "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
                "percent": 15, "enabled": true
              },
              "extra_usage": {
                "is_enabled": false, "user_disabled": false,
                "disabled_reason": "billing_not_configured"
              }
            }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertNil(snapshot.usageCredits)
        XCTAssertEqual(snapshot.usageCreditsDisabledReason, "billing_not_configured")
    }

    /// A copy that found `weekly_scoped` rows but no `spend` — an org with
    /// credits switched off. Half a copy is fine; the halves are independent.
    func testCopiedUtilizationWithoutSpendStillYieldsScopedLimits() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30), utilization: """
            { "limits": [ { "kind": "weekly_scoped", "percent": 7,
                            "scope": { "model": { "display_name": "Opus" } } } ] }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.map(\.label), ["Opus"])
        XCTAssertNil(snapshot.usageCredits)
    }

    /// A `utilization` of the wrong type is treated as absent, not as a parse
    /// failure: the rate limits beside it are still good, and this key is
    /// optional in every direction.
    func testNonObjectUtilizationIsTreatedAsAbsent() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30), utilization: "\"nope\""))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour.percentUsed, 23.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.scopedWeekly, [])
        XCTAssertNil(snapshot.usageCredits)
    }

    // MARK: - Staleness bypass

    /// The mirror of `CachedUtilizationReaderTests`' bypass tests, and the
    /// reason this source needs them now that it is the primary: when the
    /// *backup* is serving the account-wide windows and this cache has merely
    /// gone quiet, its scoped rows are still the freshest copy on disk.
    func testCurrentScopedWeeklyBypassesTheStalenessGate() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-601), utilization: copiedUtilization))

        await assertThrowsStale(age: 601) {
            try await self.makeReader().currentSnapshot()
        }

        let scopedWeekly = try await makeReader().currentScopedWeekly()
        XCTAssertEqual(scopedWeekly.map(\.label), ["Sonnet", "Fable"])
    }

    func testCurrentUsageCreditsBypassesTheStalenessGate() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-601), utilization: copiedUtilization))

        await assertThrowsStale(age: 601) {
            try await self.makeReader().currentSnapshot()
        }

        let reading = try await makeReader().currentUsageCredits()
        XCTAssertEqual(reading.credits?.limit.amountMinor, 3_300)
    }

    /// No `utilization` to bypass to is a normal state, not a fault — an old
    /// cache file must not turn `FreshestQuotaProvider`'s best-effort backfill
    /// into an error it has to swallow.
    func testBypassAccessorsReturnNothingWhenThereIsNoUtilization() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30)))

        let reader = makeReader()
        let scopedWeekly = try await reader.currentScopedWeekly()
        let reading = try await reader.currentUsageCredits()

        XCTAssertEqual(scopedWeekly, [])
        XCTAssertEqual(reading, .unavailable)
    }

    /// The file-level faults still throw, though — "the cache isn't there" and
    /// "the cache isn't JSON" are the same two errors for these accessors as
    /// for ``StatuslineCacheReader/currentSnapshot()``.
    func testBypassAccessorsStillThrowOnFileLevelFaults() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentScopedWeekly()
        }
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentUsageCredits()
        }

        try write("{ this is not json")
        await assertThrowsUnexpectedQuotaResponse {
            try await self.makeReader().currentScopedWeekly()
        }
        await assertThrowsUnexpectedQuotaResponse {
            try await self.makeReader().currentUsageCredits()
        }
    }

    // MARK: - Staleness

    func testCacheOlderThanThresholdThrowsStale() async throws {
        // 601s old — one second past the 600s default.
        try write(filteredCache(capturedAt: now.addingTimeInterval(-601)))

        let carriedOrNil = await assertThrowsStale(age: 601) {
            try await self.makeReader().currentSnapshot()
        }
        let carried = try XCTUnwrap(carriedOrNil)
        XCTAssertEqual(carried.confidence, .official)
        XCTAssertEqual(carried.fiveHour.percentUsed, 23.5, accuracy: 0.001)
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
        let carriedOrNil = await assertThrowsStale(age: 120) {
            try await self.makeReader(stalenessThreshold: 60).currentSnapshot()
        }
        let carried = try XCTUnwrap(carriedOrNil)
        XCTAssertEqual(carried.confidence, .official)
        XCTAssertEqual(carried.fiveHour.percentUsed, 23.5, accuracy: 0.001)
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
