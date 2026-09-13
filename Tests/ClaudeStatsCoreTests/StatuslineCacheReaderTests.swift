import XCTest
@testable import ClaudeStatsCore

/// Every test here writes its fixtures into a per-test temp directory standing
/// in for `~/Library/Application Support/ClaudeStats`, and injects that path —
/// the real one is never touched, read or written.
final class StatuslineCacheReaderTests: XCTestCase {
    /// Stands in for the `ClaudeStats` Application Support directory.
    private var directory: URL!
    /// `…/statusline-cache/`, where the hook writes one file per session.
    private var sessionDirectory: URL!
    /// `…/statusline-cache.json`, what older copies of the hook wrote.
    private var legacyURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatuslineCacheReaderTests-\(UUID().uuidString)", isDirectory: true)
        sessionDirectory = directory.appendingPathComponent(
            StatuslineCacheReader.sessionCacheDirectoryName, isDirectory: true)
        legacyURL = directory.appendingPathComponent(
            StatuslineCacheReader.legacyCacheFileName, isDirectory: false)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
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

    /// Writes one session's cache file. Most tests only need one session, so
    /// the name has a default; the merge tests pass their own.
    ///
    /// The modification date is pinned relative to this suite's fake `now` —
    /// otherwise a fixture the reader has to date from mtime (a payload with
    /// no `captured_at`, or one that isn't JSON at all) would look years old
    /// against that clock and be pruned before the test got to it.
    @discardableResult
    private func write(session: String = "session-a", _ json: String) throws -> URL {
        let url = sessionDirectory.appendingPathComponent("\(session).json")
        try Data(json.utf8).write(to: url)
        try setModificationDate(now.addingTimeInterval(-30), of: url)
        return url
    }

    /// Writes the single pre-per-session cache file, which the reader still
    /// accepts as one more input.
    @discardableResult
    private func writeLegacy(_ json: String) throws -> URL {
        try Data(json.utf8).write(to: legacyURL)
        try setModificationDate(now.addingTimeInterval(-30), of: legacyURL)
        return legacyURL
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Scripted stand-in for ``ActiveAccountReader`` — the real one reads
    /// `~/.claude.json`, which this suite must never touch.
    private struct StubActiveAccount: ActiveAccountProviding {
        let reading: ActiveAccountReading
        func readActiveAccount() -> ActiveAccountReading { reading }
    }

    private func makeReader(
        stalenessThreshold: TimeInterval = QuotaSnapshot.defaultStalenessThreshold,
        fileManager: FileManager = .default,
        activeAccount: ActiveAccountReading = .unknown
    ) -> StatuslineCacheReader {
        let fixedNow = now
        return StatuslineCacheReader(
            cacheDirectoryURL: directory,
            stalenessThreshold: stalenessThreshold,
            fileManager: fileManager,
            activeAccount: StubActiveAccount(reading: activeAccount),
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

    /// One window object, for the merge fixtures — each of which cares about a
    /// different combination of percentage, reset time and presence.
    private func windowJSON(_ key: String, percent: Double, resetsAt: Date?) -> String {
        let reset = resetsAt.map { ", \"resets_at\": \(Int($0.timeIntervalSince1970))" } ?? ""
        return "\"\(key)\": { \"used_percentage\": \(percent)\(reset) }"
    }

    /// A cache file carrying exactly the windows given — Claude Code omits a
    /// window from the payload once it has rolled over, so "carrying only one"
    /// is a shape that really occurs.
    private func cache(
        capturedAt: Date,
        _ windows: String...,
        utilization: String? = nil,
        account: QuotaAccount? = nil
    ) -> String {
        let extra = utilization.map { ",\n  \"utilization\": \($0)" } ?? ""
        // Exactly the stamp the helper script writes — snake_cased keys, and
        // only the ones the state file had.
        let stamp = account.map { account in
            let fields = [
                "\"uuid\": \"\(account.uuid)\"",
                account.organizationName.map { "\"organization_name\": \"\($0)\"" },
            ].compactMap { $0 }
            return ",\n  \"account\": { \(fields.joined(separator: ", ")) }"
        } ?? ""
        return """
        {
          "captured_at": \(Int(capturedAt.timeIntervalSince1970)),
          "rate_limits": { \(windows.joined(separator: ", ")) }\(extra)\(stamp)
        }
        """
    }

    /// The two accounts the switching tests use: the login the user moved to,
    /// and the one they moved away from.
    private let exampleOrg = QuotaAccount(
        uuid: "0f9c1d3e-8a4b-4c2d-9e1f-6b7a8c9d0e1f", organizationName: "Example Org")
    private let otherOrg = QuotaAccount(
        uuid: "7d2b6a10-3c55-4f8e-9a21-0b4c5d6e7f80", organizationName: "Other Org")

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
        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).percentUsed, 23.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.sevenDay).percentUsed, 41.2, accuracy: 0.001)
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
        XCTAssertEqual(snapshot.fiveHour?.resetsAt?.timeIntervalSince1970,
                       capturedAt.timeIntervalSince1970 + 3600)
        XCTAssertEqual(snapshot.sevenDay?.timeUntilReset(from: now) ?? 0, 86_370, accuracy: 2)
    }

    /// The no-`jq` fallback: raw statusline payload, no `captured_at`, capture
    /// time taken from the file's modification date.
    func testRawPayloadWithoutCapturedAtFallsBackToFileModificationDate() async throws {
        let url = try write("""
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
        try setModificationDate(modified, of: url)

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .official)
        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 62)
        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 31)
        XCTAssertNil(snapshot.sevenDay?.resetsAt)
        XCTAssertEqual(snapshot.capturedAt.timeIntervalSince1970,
                       modified.timeIntervalSince1970, accuracy: 1)
    }

    /// Docs say each window may be independently absent — and absent means
    /// absent: the snapshot carries `nil`, not a window reading 0%.
    func testMissingSevenDayWindowYieldsNilWindowNotFailure() async throws {
        try write("""
        {
          "captured_at": \(Int(now.timeIntervalSince1970) - 5),
          "rate_limits": { "five_hour": { "used_percentage": 10 } }
        }
        """)

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 10)
        XCTAssertNil(snapshot.sevenDay)
    }

    // MARK: - Merging across sessions

    /// Two sessions, same window, different readings. Utilization within one
    /// window never decreases, so the higher number is the newer one — whatever
    /// the files' own capture stamps say. (Which is the whole point: a quiet
    /// session restamps hours-old numbers as captured "now".)
    func testSameWindowPrefersTheHigherPercentageWhateverTheCaptureTime() async throws {
        try write(session: "busy", cache(
            capturedAt: now.addingTimeInterval(-300),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(3600)),
            windowJSON("seven_day", percent: 44, resetsAt: now.addingTimeInterval(86_400))
        ))
        try write(session: "idle", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("five_hour", percent: 25, resetsAt: now.addingTimeInterval(3600)),
            windowJSON("seven_day", percent: 20, resetsAt: now.addingTimeInterval(86_400))
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 68)
        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 44)
        // Only the busy session contributed, so its capture time is the one the
        // freshness line has any business showing.
        XCTAssertEqual(snapshot.capturedAt.timeIntervalSince1970,
                       now.timeIntervalSince1970 - 300, accuracy: 1)
    }

    /// The reported symptom: an idle session's payload had dropped `five_hour`
    /// entirely (Claude Code omits a rolled-over window), was written last, and
    /// the missing window read back as a confident 0%.
    func testWindowMissingFromTheNewestFileComesFromAnotherSessionNotZero() async throws {
        try write(session: "busy", cache(
            capturedAt: now.addingTimeInterval(-200),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(1800)),
            windowJSON("seven_day", percent: 44, resetsAt: now.addingTimeInterval(86_400))
        ))
        try write(session: "idle", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("seven_day", percent: 25, resetsAt: now.addingTimeInterval(86_400))
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 68)
        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 44)
    }

    /// The same thing one step earlier: the idle session still carries the
    /// window, but its reset has already passed. Expired, not 0%.
    func testExpiredWindowIsIgnoredRatherThanReadAsAReading() async throws {
        try write(session: "busy", cache(
            capturedAt: now.addingTimeInterval(-200),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(1800))
        ))
        try write(session: "idle", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("five_hour", percent: 3, resetsAt: now.addingTimeInterval(-60))
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 68)
    }

    /// The rollover boundary: every file's `five_hour` has already reset while
    /// their `seven_day` is still live, so nothing on disk says anything about
    /// the 5-hour window. That is a `nil` window — "no reading" on screen —
    /// and the 7-day one is unaffected.
    func testWindowExpiredInEveryFileIsNilWhileTheOtherStillReads() async throws {
        try write(session: "busy", cache(
            capturedAt: now.addingTimeInterval(-200),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(-120)),
            windowJSON("seven_day", percent: 44, resetsAt: now.addingTimeInterval(86_400))
        ))
        try write(session: "idle", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("five_hour", percent: 25, resetsAt: now.addingTimeInterval(-600)),
            windowJSON("seven_day", percent: 20, resetsAt: now.addingTimeInterval(86_400))
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 44)
        // Only the file that contributed the surviving window sets the stamp.
        XCTAssertEqual(snapshot.capturedAt.timeIntervalSince1970,
                       now.timeIntervalSince1970 - 200, accuracy: 1)
    }

    /// Every reading of a window has expired: that is "no data", not 0%.
    func testAllWindowsExpiredThrowsNoQuotaSourceAvailable() async throws {
        try write(cache(
            capturedAt: now.addingTimeInterval(-60),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(-30)),
            windowJSON("seven_day", percent: 44, resetsAt: now.addingTimeInterval(-10))
        ))

        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    /// A later reset is a later window, and a fresh window legitimately starts
    /// near zero — so `resets_at` outranks the percentage.
    func testLaterResetsAtBeatsAHigherPercentage() async throws {
        try write(session: "old-window", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("five_hour", percent: 90, resetsAt: now.addingTimeInterval(60))
        ))
        try write(session: "new-window", cache(
            capturedAt: now.addingTimeInterval(-20),
            windowJSON("five_hour", percent: 5, resetsAt: now.addingTimeInterval(18_000))
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 5)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, now.addingTimeInterval(18_000))
    }

    /// A reading with no `resets_at` can't be ranked against one that has it,
    /// so it only ever wins when nothing dated survives — and then the newest
    /// capture is all there is to go on.
    func testUndatedReadingLosesToADatedOneAndWinsOnlyAmongItsOwnKind() async throws {
        try write(session: "dated", cache(
            capturedAt: now.addingTimeInterval(-300),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(1800))
        ))
        try write(session: "undated-old", cache(
            capturedAt: now.addingTimeInterval(-200),
            windowJSON("five_hour", percent: 12, resetsAt: nil),
            windowJSON("seven_day", percent: 30, resetsAt: nil)
        ))
        try write(session: "undated-new", cache(
            capturedAt: now.addingTimeInterval(-100),
            windowJSON("seven_day", percent: 31, resetsAt: nil)
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 68)
        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 31)
    }

    /// A machine whose hook script hasn't been reinstalled yet still has a
    /// single `statusline-cache.json`, and it takes part in the merge like any
    /// session file.
    func testLegacySingleCacheFileIsStillReadAndMerged() async throws {
        try writeLegacy(cache(
            capturedAt: now.addingTimeInterval(-120),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(1800))
        ))
        try write(session: "new-style", cache(
            capturedAt: now.addingTimeInterval(-60),
            windowJSON("seven_day", percent: 44, resetsAt: now.addingTimeInterval(86_400))
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 68)
        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 44)
        // Newest of the two contributors.
        XCTAssertEqual(snapshot.capturedAt.timeIntervalSince1970,
                       now.timeIntervalSince1970 - 60, accuracy: 1)
    }

    /// The legacy file on its own still works — the pre-upgrade state, until
    /// the next status line render writes a session file.
    func testLegacySingleCacheFileAloneIsEnough() async throws {
        try writeLegacy(filteredCache(capturedAt: now.addingTimeInterval(-30)))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).percentUsed, 23.5, accuracy: 0.001)
    }

    /// Whichever file supplied a chosen window dates the snapshot — and the
    /// staleness gate is applied to that, not to the oldest file lying around.
    func testCapturedAtIsTheNewestContributingFile() async throws {
        try write(session: "old", cache(
            capturedAt: now.addingTimeInterval(-700),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(1800))
        ))
        try write(session: "new", cache(
            capturedAt: now.addingTimeInterval(-100),
            windowJSON("seven_day", percent: 44, resetsAt: now.addingTimeInterval(86_400))
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.capturedAt.timeIntervalSince1970,
                       now.timeIntervalSince1970 - 100, accuracy: 1)
        XCTAssertFalse(snapshot.isStale(asOf: now))
    }

    /// …and when every contributor is old, the merged snapshot is stale as a
    /// whole, aged from the newest of them.
    func testMergedSnapshotGoesStaleOnItsNewestContributor() async throws {
        try write(session: "old", cache(
            capturedAt: now.addingTimeInterval(-900),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(1800))
        ))
        try write(session: "less-old", cache(
            capturedAt: now.addingTimeInterval(-650),
            windowJSON("seven_day", percent: 44, resetsAt: now.addingTimeInterval(86_400))
        ))

        let carriedOrNil = await assertThrowsStale(age: 650) {
            try await self.makeReader().currentSnapshot()
        }
        let carried = try XCTUnwrap(carriedOrNil)
        XCTAssertEqual(carried.fiveHour?.percentUsed, 68)
        XCTAssertEqual(carried.sevenDay?.percentUsed, 44)
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
        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).percentUsed, 23.5, accuracy: 0.001)
        // Sorted by percent descending, same as out of `~/.claude.json`.
        XCTAssertEqual(snapshot.scopedWeekly.map(\.label), ["Sonnet", "Fable"])
        XCTAssertEqual(snapshot.scopedWeekly.map(\.percentUsed), [42, 0])

        let credits = try XCTUnwrap(snapshot.usageCredits)
        XCTAssertEqual(credits.limit, MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2))
        XCTAssertEqual(credits.percentUsed, 0)
        XCTAssertNil(snapshot.usageCreditsDisabledReason)
    }

    /// Every session copies the same `~/.claude.json`, so this object isn't
    /// merged window-style — the most recent copy simply wins, even when the
    /// session that wrote it contributed no window at all.
    func testUtilizationComesFromTheNewestFileCarryingOne() async throws {
        try write(session: "older", cache(
            capturedAt: now.addingTimeInterval(-300),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(1800)),
            utilization: copiedUtilization
        ))
        try write(session: "newer", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("five_hour", percent: 10, resetsAt: now.addingTimeInterval(1800)),
            utilization: """
                { "limits": [ { "kind": "weekly_scoped", "percent": 51,
                                "scope": { "model": { "display_name": "Opus" } } } ] }
                """
        ))

        let snapshot = try await makeReader().currentSnapshot()

        // The window still comes from the higher (i.e. newer) reading…
        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 68)
        // …but the copied object comes from the newest file that has one.
        XCTAssertEqual(snapshot.scopedWeekly.map(\.label), ["Opus"])
        XCTAssertNil(snapshot.usageCredits)
    }

    /// The newest file having no copy is the normal mixed state on a machine
    /// where one session runs without `jq` or lost the state file for a render:
    /// fall back to the newest file that does carry one rather than dropping
    /// the two bars.
    func testUtilizationFallsBackToAnOlderFileWhenTheNewestHasNone() async throws {
        try write(session: "older", cache(
            capturedAt: now.addingTimeInterval(-300),
            windowJSON("five_hour", percent: 68, resetsAt: now.addingTimeInterval(1800)),
            utilization: copiedUtilization
        ))
        try write(session: "newer", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("five_hour", percent: 70, resetsAt: now.addingTimeInterval(1800))
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 70)
        XCTAssertEqual(snapshot.scopedWeekly.map(\.label), ["Sonnet", "Fable"])
        XCTAssertEqual(snapshot.usageCredits?.limit.amountMinor, 3_300)
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

        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).percentUsed, 23.5, accuracy: 0.001)
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

    /// Same "newest copy wins" rule as in the snapshot, on the bypass path.
    func testBypassAccessorsAlsoTakeTheNewestUtilization() async throws {
        try write(session: "older", filteredCache(
            capturedAt: now.addingTimeInterval(-900), utilization: copiedUtilization))
        try write(session: "newer", filteredCache(
            capturedAt: now.addingTimeInterval(-700), utilization: """
                { "limits": [ { "kind": "weekly_scoped", "percent": 51,
                                "scope": { "model": { "display_name": "Opus" } } } ] }
                """))

        let reader = makeReader()
        let scopedWeekly = try await reader.currentScopedWeekly()
        let reading = try await reader.currentUsageCredits()

        XCTAssertEqual(scopedWeekly.map(\.label), ["Opus"])
        XCTAssertEqual(reading, .unavailable)
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

    /// The whole-source faults still throw, though — "no cache at all" and "no
    /// cache file that is even JSON" are the same two errors for these
    /// accessors as for ``StatuslineCacheReader/currentSnapshot()``.
    func testBypassAccessorsStillThrowOnFileLevelFaults() async throws {
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
        XCTAssertEqual(try XCTUnwrap(carried.fiveHour).percentUsed, 23.5, accuracy: 0.001)
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
        XCTAssertEqual(try XCTUnwrap(carried.fiveHour).percentUsed, 23.5, accuracy: 0.001)
    }

    // MARK: - Failure modes

    func testEmptyCacheDirectoryThrowsNoQuotaSourceAvailable() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader().currentSnapshot()
        }
    }

    /// Nothing has ever been written — not even the directory exists, which is
    /// the state on a machine where the hook was never installed.
    func testMissingCacheDirectoryThrowsNoQuotaSourceAvailable() async throws {
        try FileManager.default.removeItem(at: sessionDirectory)
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
        let message = await assertThrowsUnexpectedQuotaResponse {
            try await self.makeReader().currentSnapshot()
        }
        XCTAssertEqual(message?.contains("session-a.json"), true, message ?? "")
    }

    /// One session writing garbage must not take down the bars every other
    /// session is still feeding.
    func testMalformedFileAmongGoodOnesIsSkipped() async throws {
        try write(session: "broken", "{ this is not json")
        try write(session: "good", filteredCache(capturedAt: now.addingTimeInterval(-30)))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).percentUsed, 23.5, accuracy: 0.001)
    }

    /// Nothing on disk is JSON at all: that is a fault worth naming, unlike
    /// "nothing is installed".
    func testAllFilesMalformedThrowsUnexpectedQuotaResponse() async throws {
        try write(session: "broken-a", "{ this is not json")
        try write(session: "broken-b", "]]]")
        try writeLegacy("nope")

        await assertThrowsUnexpectedQuotaResponse {
            try await self.makeReader().currentSnapshot()
        }
    }

    /// Files that aren't ours don't take part — the directory is ours, but a
    /// stray `.txt` in it shouldn't become a parse failure.
    func testNonJSONFilesInTheDirectoryAreIgnored() async throws {
        try Data("garbage".utf8).write(to: sessionDirectory.appendingPathComponent("notes.txt"))
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30)))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(try XCTUnwrap(snapshot.fiveHour).percentUsed, 23.5, accuracy: 0.001)
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

    // MARK: - Pruning

    /// A session file nobody has written in a week has nothing to contribute —
    /// even the 7-day window it last saw has rolled over — so reading cleans it
    /// up rather than letting one file per session accumulate forever.
    func testReadingPrunesSessionFilesOlderThanTheRetentionWindow() async throws {
        let ancient = try write(session: "gone", cache(
            capturedAt: now.addingTimeInterval(-StatuslineCacheReader.sessionRetention - 60),
            windowJSON("seven_day", percent: 44, resetsAt: now.addingTimeInterval(86_400))
        ))
        let fresh = try write(session: "kept", filteredCache(capturedAt: now.addingTimeInterval(-30)))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ancient.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        // …and the pruned file's reading is gone with it.
        XCTAssertEqual(try XCTUnwrap(snapshot.sevenDay).percentUsed, 41.2, accuracy: 0.001)
    }

    /// Pruning falls back to the file's modification time, so a session file
    /// that is both ancient and unparseable still goes away.
    func testPruningUsesModificationTimeWhenThePayloadHasNoCapturedAt() async throws {
        let ancient = try write(session: "gone", "{ this is not json")
        try setModificationDate(
            now.addingTimeInterval(-StatuslineCacheReader.sessionRetention - 60), of: ancient)
        try write(session: "kept", filteredCache(capturedAt: now.addingTimeInterval(-30)))

        _ = try await makeReader().currentSnapshot()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ancient.path))
    }

    /// The legacy file isn't pruned: it is the only reading a machine whose
    /// hook hasn't been reinstalled has, and deleting it would be a migration
    /// this reader has no business performing.
    func testPruningLeavesTheLegacyFileAlone() async throws {
        try writeLegacy(cache(
            capturedAt: now.addingTimeInterval(-StatuslineCacheReader.sessionRetention - 60),
            windowJSON("seven_day", percent: 44, resetsAt: now.addingTimeInterval(86_400))
        ))
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30)))

        _ = try await makeReader().currentSnapshot()

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    // MARK: - Clearing

    func testClearCacheRemovesTheSessionDirectoryAndTheLegacyFile() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30)))
        try writeLegacy(filteredCache(capturedAt: now.addingTimeInterval(-30)))

        let reader = makeReader()
        try reader.clearCache()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        // Nothing has written a fresh cache yet — the expected post-clear state.
        await assertThrows(.noQuotaSourceAvailable) {
            try await reader.currentSnapshot()
        }
    }

    func testClearCacheWithNothingCachedDoesNotThrow() throws {
        try FileManager.default.removeItem(at: sessionDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
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

    // MARK: - One group per account

    /// The reported bug, end to end. The user switched the global login from
    /// Other Org (7-day window resetting later, 56% used) to exampleOrg (7-day
    /// resetting sooner, 0%), and one idle session kept re-rendering Other Org's
    /// payload. "Latest `resets_at` wins" then handed the machine's 7-day bar
    /// Other Org's 56%. Grouping by account is what stops it: the merge never
    /// crosses the two groups, and the active account's group is what serves.
    func testMergeNeverCrossesAccountsAndTheActiveOneServes() async throws {
        try write(session: "left-behind", cache(
            capturedAt: now.addingTimeInterval(-60),
            windowJSON("seven_day", percent: 56, resetsAt: now.addingTimeInterval(20 * 3600)),
            account: otherOrg
        ))
        try write(session: "current", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("seven_day", percent: 0, resetsAt: now.addingTimeInterval(4 * 3600)),
            account: exampleOrg
        ))

        let snapshot = try await makeReader(
            activeAccount: ActiveAccountReading(account: exampleOrg)
        ).currentSnapshot()

        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 0)
        XCTAssertEqual(snapshot.sevenDay?.resetsAt, now.addingTimeInterval(4 * 3600))
        XCTAssertEqual(snapshot.account, exampleOrg)
    }

    /// Same two files, the other way round: the account the user is logged in
    /// as is the one that serves, whatever the other group's numbers look like.
    func testTheOtherAccountServesWhenItIsTheActiveOne() async throws {
        try write(session: "otherOrg", cache(
            capturedAt: now.addingTimeInterval(-60),
            windowJSON("five_hour", percent: 56, resetsAt: now.addingTimeInterval(3600)),
            account: otherOrg
        ))
        try write(session: "Example Org", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("five_hour", percent: 4, resetsAt: now.addingTimeInterval(3600)),
            account: exampleOrg
        ))

        let snapshot = try await makeReader(
            activeAccount: ActiveAccountReading(account: otherOrg)
        ).currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 56)
        XCTAssertEqual(snapshot.account, otherOrg)
    }

    /// The state file names an account no cache file is stamped with — a
    /// machine still running a script copy from before the stamp, or a login
    /// that hasn't rendered a status line yet. That is "nothing from this
    /// source", so `FreshestQuotaProvider` falls through to Claude Code's own
    /// cached blob, which belongs to that same login. Another account's files
    /// are never substituted.
    func testActiveAccountWithNoFilesReportsNoQuotaSourceAvailable() async throws {
        try write(session: "other", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("five_hour", percent: 56, resetsAt: now.addingTimeInterval(3600)),
            account: otherOrg
        ))
        try write(session: "unstamped", cache(
            capturedAt: now.addingTimeInterval(-20),
            windowJSON("five_hour", percent: 12, resetsAt: now.addingTimeInterval(3600))
        ))

        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeReader(
                activeAccount: ActiveAccountReading(account: self.exampleOrg)
            ).currentSnapshot()
        }
    }

    /// No state file, or one that names no account: the most recently captured
    /// group serves. On the one-account machine every existing test describes,
    /// that is exactly the behaviour from before accounts were modelled.
    func testUnknownActiveAccountServesTheNewestGroup() async throws {
        try write(session: "older", cache(
            capturedAt: now.addingTimeInterval(-300),
            windowJSON("five_hour", percent: 56, resetsAt: now.addingTimeInterval(3600)),
            account: otherOrg
        ))
        try write(session: "newer", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("five_hour", percent: 4, resetsAt: now.addingTimeInterval(3600)),
            account: exampleOrg
        ))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 4)
        XCTAssertEqual(snapshot.account, exampleOrg)
    }

    /// An unstamped file can't be claimed for a named account — it may well be
    /// the other one's. The legacy single file is unstamped by definition, so
    /// it lands in the unknown group with the rest.
    func testLegacyAndUnstampedFilesFormTheUnknownGroup() async throws {
        try writeLegacy(cache(
            capturedAt: now.addingTimeInterval(-120),
            windowJSON("five_hour", percent: 90, resetsAt: now.addingTimeInterval(18_000))
        ))
        try write(session: "stamped", cache(
            capturedAt: now.addingTimeInterval(-60),
            windowJSON("five_hour", percent: 10, resetsAt: now.addingTimeInterval(3600)),
            account: exampleOrg
        ))

        let reader = makeReader(activeAccount: ActiveAccountReading(account: exampleOrg))
        let snapshot = try await reader.currentSnapshot()

        // The legacy file's later reset would have won a cross-account merge.
        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 10)
        let others = await reader.otherAccountSnapshots()
        XCTAssertEqual(others.count, 1)
        XCTAssertNil(others.first?.account)
        XCTAssertEqual(others.first?.fiveHour?.percentUsed, 90)
    }

    /// The `utilization` copy is per-login too — it is lifted out of
    /// `~/.claude.json` — so the scoped rows and the credits come from the
    /// active account's files only, however recently another account's file was
    /// written.
    func testCopiedUtilizationComesFromTheActiveAccountsFilesOnly() async throws {
        try write(session: "current", cache(
            capturedAt: now.addingTimeInterval(-300),
            windowJSON("five_hour", percent: 10, resetsAt: now.addingTimeInterval(3600)),
            utilization: """
                { "limits": [ { "kind": "weekly_scoped", "percent": 7,
                                "scope": { "model": { "display_name": "Mine" } } } ] }
                """,
            account: exampleOrg
        ))
        try write(session: "left-behind", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("five_hour", percent: 56, resetsAt: now.addingTimeInterval(3600)),
            utilization: copiedUtilization,
            account: otherOrg
        ))

        let reader = makeReader(activeAccount: ActiveAccountReading(account: exampleOrg))
        let snapshot = try await reader.currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.map(\.label), ["Mine"])
        XCTAssertNil(snapshot.usageCredits)
        // …and the staleness-bypassing accessors are scoped the same way.
        let scopedWeekly = try await reader.currentScopedWeekly()
        let credits = try await reader.currentUsageCredits()
        XCTAssertEqual(scopedWeekly.map(\.label), ["Mine"])
        XCTAssertEqual(credits, .unavailable)
    }

    // MARK: - Other accounts

    /// Everything except the group that served, newest first, each carrying its
    /// own account and its own capture time.
    func testOtherAccountSnapshotsExcludeTheActiveGroup() async throws {
        try write(session: "current", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("five_hour", percent: 4, resetsAt: now.addingTimeInterval(3600)),
            account: exampleOrg
        ))
        try write(session: "left-behind", cache(
            capturedAt: now.addingTimeInterval(-3 * 3600),
            windowJSON("seven_day", percent: 56, resetsAt: now.addingTimeInterval(20 * 3600)),
            account: otherOrg
        ))
        try write(session: "unstamped", cache(
            capturedAt: now.addingTimeInterval(-2 * 3600),
            windowJSON("seven_day", percent: 31, resetsAt: now.addingTimeInterval(20 * 3600))
        ))

        let others = await makeReader(
            activeAccount: ActiveAccountReading(account: exampleOrg)
        ).otherAccountSnapshots()

        XCTAssertEqual(others.map { $0.account }, [nil, otherOrg])
        XCTAssertEqual(others.map { $0.sevenDay?.percentUsed }, [31, 56])
        // Ungated on staleness — these rows carry their own freshness tag, and
        // an account nobody is logged in as is exactly the cold one.
        XCTAssertTrue(others.allSatisfy { $0.isStale(asOf: now) })
    }

    /// The state file names an account with no matching group — the same setup
    /// `testActiveAccountWithNoFilesReportsNoQuotaSourceAvailable` throws on.
    /// Every group on disk, the unstamped one included, is then "other":
    /// nothing is currently being served, and that is what lets
    /// `FreshestQuotaProvider` tell "readings exist, none of them this
    /// account's" from "nothing at all".
    func testOtherAccountSnapshotsIncludeEveryGroupWhenTheActiveAccountHasNone() async throws {
        try write(session: "other", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("five_hour", percent: 56, resetsAt: now.addingTimeInterval(3600)),
            account: otherOrg
        ))
        try write(session: "unstamped", cache(
            capturedAt: now.addingTimeInterval(-20),
            windowJSON("five_hour", percent: 12, resetsAt: now.addingTimeInterval(3600))
        ))

        let others = await makeReader(
            activeAccount: ActiveAccountReading(account: exampleOrg)
        ).otherAccountSnapshots()

        XCTAssertEqual(others.map { $0.account }, [nil, otherOrg])
        XCTAssertEqual(others.map { $0.fiveHour?.percentUsed }, [12, 56])
    }

    /// A group whose every window has rolled over has nothing to draw: no
    /// label, no two "no reading" lines. This is the rule that keeps the
    /// unknown-account group from appearing on a machine whose only unstamped
    /// files are ancient.
    func testOtherAccountGroupWithNoLiveWindowIsLeftOut() async throws {
        try write(session: "current", cache(
            capturedAt: now.addingTimeInterval(-30),
            windowJSON("five_hour", percent: 4, resetsAt: now.addingTimeInterval(3600)),
            account: exampleOrg
        ))
        try write(session: "expired", cache(
            capturedAt: now.addingTimeInterval(-600),
            windowJSON("five_hour", percent: 56, resetsAt: now.addingTimeInterval(-60)),
            account: otherOrg
        ))

        let others = await makeReader(
            activeAccount: ActiveAccountReading(account: exampleOrg)
        ).otherAccountSnapshots()

        XCTAssertEqual(others, [])
    }

    /// One account, the ordinary case: nothing to list beside it.
    func testSingleAccountHasNoOtherAccounts() async throws {
        try write(filteredCache(capturedAt: now.addingTimeInterval(-30)))

        let others = await makeReader().otherAccountSnapshots()

        XCTAssertEqual(others, [])
    }

    /// Decoration, never a failure: a file-level fault is the snapshot path's
    /// to report, and these rows just don't appear.
    func testOtherAccountSnapshotsNeverThrow() async throws {
        try write(session: "broken-a", "{ this is not json")
        var others = await makeReader().otherAccountSnapshots()
        XCTAssertEqual(others, [])

        try FileManager.default.removeItem(at: sessionDirectory)
        others = await makeReader().otherAccountSnapshots()
        XCTAssertEqual(others, [])
    }

    // MARK: - The mislabel guard

    /// The reference a switched-to account's state file provides: its own
    /// account uuid and the 7-day reset its cached reading reported.
    private func reference(_ account: QuotaAccount, sevenDayResetsIn seconds: TimeInterval)
        -> ActiveAccountReference {
        ActiveAccountReference(
            accountUuid: account.uuid,
            sevenDayResetsAt: now.addingTimeInterval(seconds)
        )
    }

    /// The case grouping alone can't catch: an idle session re-renders from its
    /// *last* API payload, so right after the switch the hook writes a file
    /// stamped with the new account carrying the old account's numbers. Its
    /// 7-day reset disagrees with the one Claude Code has already cached for
    /// that account, which is what gives it away.
    func testForeignReadingStampedWithTheActiveAccountIsDropped() async throws {
        try write(session: "mislabelled", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("seven_day", percent: 56, resetsAt: now.addingTimeInterval(20 * 3600)),
            account: exampleOrg
        ))
        try write(session: "honest", cache(
            capturedAt: now.addingTimeInterval(-60),
            windowJSON("seven_day", percent: 3, resetsAt: now.addingTimeInterval(4 * 3600)),
            account: exampleOrg
        ))

        let snapshot = try await makeReader(activeAccount: ActiveAccountReading(
            account: exampleOrg,
            reference: reference(exampleOrg, sevenDayResetsIn: 4 * 3600)
        )).currentSnapshot()

        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 3)
        XCTAssertEqual(snapshot.sevenDay?.resetsAt, now.addingTimeInterval(4 * 3600))
    }

    /// A reading that agrees with the cached reset is this account's, and is
    /// kept — including when it is the only one there is.
    func testMatchingReadingIsKept() async throws {
        try write(session: "honest", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("seven_day", percent: 41, resetsAt: now.addingTimeInterval(4 * 3600)),
            account: exampleOrg
        ))

        let snapshot = try await makeReader(activeAccount: ActiveAccountReading(
            account: exampleOrg,
            reference: reference(exampleOrg, sevenDayResetsIn: 4 * 3600)
        )).currentSnapshot()

        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 41)
    }

    /// The two sources spell the same instant differently — whole epoch seconds
    /// from the statusline payload, ISO-8601 with fractional seconds from
    /// `cachedUsageUtilization` — so a sub-tolerance difference is the same
    /// window, not a foreign reading.
    func testSubSecondFormattingDifferenceIsWithinTolerance() async throws {
        try write(session: "honest", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("seven_day", percent: 41, resetsAt: now.addingTimeInterval(4 * 3600)),
            account: exampleOrg
        ))

        let snapshot = try await makeReader(activeAccount: ActiveAccountReading(
            account: exampleOrg,
            reference: reference(exampleOrg, sevenDayResetsIn: 4 * 3600 + 0.401826)
        )).currentSnapshot()

        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 41)
    }

    /// The tolerance is a minute, and both sides of it behave.
    func testToleranceBoundary() async throws {
        for (offset, expected) in [(ActiveAccountReference.tolerance, 41.0),
                                   (ActiveAccountReference.tolerance + 1, nil)] as [(TimeInterval, Double?)] {
            try FileManager.default.removeItem(at: sessionDirectory)
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            try write(session: "reading", cache(
                capturedAt: now.addingTimeInterval(-10),
                windowJSON("seven_day", percent: 41, resetsAt: now.addingTimeInterval(4 * 3600 + offset)),
                account: exampleOrg
            ))

            let reader = makeReader(activeAccount: ActiveAccountReading(
                account: exampleOrg,
                reference: reference(exampleOrg, sevenDayResetsIn: 4 * 3600)
            ))

            if let expected {
                let snapshot = try await reader.currentSnapshot()
                XCTAssertEqual(snapshot.sevenDay?.percentUsed, expected)
            } else {
                await assertThrows(.noQuotaSourceAvailable) {
                    try await reader.currentSnapshot()
                }
            }
        }
    }

    /// With no cached reading to compare against there is no reference, and the
    /// guard accepts everything rather than dropping readings against nothing.
    func testWithoutAReferenceEverythingIsKept() async throws {
        try write(session: "unverifiable", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("seven_day", percent: 56, resetsAt: now.addingTimeInterval(20 * 3600)),
            account: exampleOrg
        ))

        let snapshot = try await makeReader(
            activeAccount: ActiveAccountReading(account: exampleOrg)
        ).currentSnapshot()

        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 56)
    }

    /// A payload whose 7-day window has rolled over carries only `five_hour` —
    /// there is nothing to compare, so the guard has no opinion and the reading
    /// stands.
    func testReadingWithoutASevenDayWindowIsNotSubjectToTheGuard() async throws {
        try write(session: "five-hour-only", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("five_hour", percent: 22, resetsAt: now.addingTimeInterval(3600)),
            account: exampleOrg
        ))

        let snapshot = try await makeReader(activeAccount: ActiveAccountReading(
            account: exampleOrg,
            reference: reference(exampleOrg, sevenDayResetsIn: 4 * 3600)
        )).currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 22)
    }

    /// The guard is about *this* account's files only. Another account's
    /// reading is expected to disagree — that is what makes it another
    /// account's — and grouping, not the guard, is what keeps it out.
    func testAnotherAccountsReadingIsNotDroppedByTheGuard() async throws {
        try write(session: "left-behind", cache(
            capturedAt: now.addingTimeInterval(-60),
            windowJSON("seven_day", percent: 56, resetsAt: now.addingTimeInterval(20 * 3600)),
            account: otherOrg
        ))
        try write(session: "current", cache(
            capturedAt: now.addingTimeInterval(-10),
            windowJSON("seven_day", percent: 3, resetsAt: now.addingTimeInterval(4 * 3600)),
            account: exampleOrg
        ))

        let others = await makeReader(activeAccount: ActiveAccountReading(
            account: exampleOrg,
            reference: reference(exampleOrg, sevenDayResetsIn: 4 * 3600)
        )).otherAccountSnapshots()

        XCTAssertEqual(others.map { $0.account }, [otherOrg])
        XCTAssertEqual(others.first?.sevenDay?.percentUsed, 56)
    }

    // MARK: - Default path

    func testDefaultCacheDirectoryURLPointsAtApplicationSupport() {
        let reader = StatuslineCacheReader()
        XCTAssertTrue(reader.cacheDirectoryURL.path.hasSuffix("/ClaudeStats"),
                      reader.cacheDirectoryURL.path)
        XCTAssertTrue(reader.cacheDirectoryURL.path.contains("Application Support"),
                      reader.cacheDirectoryURL.path)
        XCTAssertTrue(reader.sessionCacheDirectoryURL.path.hasSuffix("/ClaudeStats/statusline-cache"),
                      reader.sessionCacheDirectoryURL.path)
        XCTAssertTrue(reader.legacyCacheURL.path.hasSuffix("/ClaudeStats/statusline-cache.json"),
                      reader.legacyCacheURL.path)
    }
}
