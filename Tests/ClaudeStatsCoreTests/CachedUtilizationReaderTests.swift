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
    /// deliberately ignores — `spend`, `accountUuid`, the null scoped windows,
    /// and the `session` / `weekly_all` entries of `limits[]` — are kept, so a
    /// future reader for them can't quietly change what this one sees.
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

    /// `capturedAtKeys` also accepts the snake_case spelling, even though every
    /// other fixture in this file uses the camelCase one Claude Code actually
    /// stamps.
    func testSnakeCaseFetchedAtMsSpellingIsAlsoAccepted() async throws {
        let fetchedAt = now.addingTimeInterval(-5 * 60)
        try write(
            """
            {
              "cachedUsageUtilization": {
                "fetched_at_ms": \(Int(fetchedAt.timeIntervalSince1970 * 1000)),
                "utilization": {
                  "five_hour": { "utilization": 11, "resets_at": "2026-08-28T16:50:00.401807+00:00" },
                  "seven_day": { "utilization": 97, "resets_at": "2026-08-28T23:00:00.401826+00:00" }
                }
              }
            }
            """
        )

        let snapshot = try await makeReader().currentSnapshot()

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

    // MARK: - Scoped weekly limits

    /// A state file whose `limits[]` is exactly `entries`, fetched a minute ago.
    private func stateFile(limits entries: String) -> String {
        """
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000) - 60_000),
            "utilization": {
              "five_hour": { "utilization": 11, "resets_at": "2026-08-28T16:50:00.401807+00:00" },
              "seven_day": { "utilization": 97, "resets_at": "2026-08-28T23:00:00.401826+00:00" },
              "limits": [\(entries)]
            }
          }
        }
        """
    }

    /// The entry as observed verbatim on a real machine: 0%, inactive, no
    /// reset timestamp.
    private let fableEntry = """
        { "kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
          "resets_at": null, "is_active": false,
          "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null } }
        """

    func testWeeklyScopedEntryBecomesOneScopedLimit() async throws {
        try write(stateFile(limits: fableEntry))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.count, 1)
        let limit = try XCTUnwrap(snapshot.scopedWeekly.first)
        XCTAssertEqual(limit.label, "Fable")
        XCTAssertEqual(limit.id, "Fable")
        // 0% is reported as 0%, never hidden.
        XCTAssertEqual(limit.percentUsed, 0)
        XCTAssertEqual(limit.window, QuotaWindow(percentUsed: 0, resetsAt: nil))
        XCTAssertFalse(limit.isActive)
        XCTAssertEqual(limit.severity, "normal")
    }

    /// `null` is the common case for an inactive scope — nil, not an error, and
    /// the row simply shows no countdown.
    func testNullResetsAtLeavesTheScopedLimitWithoutAReset() async throws {
        try write(stateFile(limits: fableEntry))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertNil(snapshot.scopedWeekly.first?.resetsAt)
    }

    func testPopulatedResetsAtIsParsed() async throws {
        try write(stateFile(limits: """
            { "kind": "weekly_scoped", "percent": 4, "is_active": true, "severity": "warning",
              "resets_at": "2026-08-28T23:00:00.401826+00:00",
              "scope": { "model": { "display_name": "Opus" } } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        let limit = try XCTUnwrap(snapshot.scopedWeekly.first)
        XCTAssertEqual(try XCTUnwrap(limit.resetsAt).timeIntervalSince1970,
                       sevenDayResetEpoch, accuracy: 0.001)
        XCTAssertTrue(limit.isActive)
        XCTAssertEqual(limit.severity, "warning")
    }

    /// `session` and `weekly_all` restate `five_hour` / `seven_day`; parsing
    /// them would duplicate the two main bars. The real payload fixture carries
    /// both and nothing else.
    func testSessionAndWeeklyAllEntriesAreIgnored() async throws {
        try write(stateFile(fetchedAt: now.addingTimeInterval(-60)))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour.percentUsed, 11)
        XCTAssertEqual(snapshot.sevenDay.percentUsed, 97)
        XCTAssertEqual(snapshot.scopedWeekly, [])
    }

    func testEntryThatNamesNoScopeIsSkipped() async throws {
        try write(stateFile(limits: """
            { "kind": "weekly_scoped", "percent": 7 },
            { "kind": "weekly_scoped", "percent": 8,
              "scope": { "model": { "id": null, "display_name": "" }, "surface": null } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly, [])
    }

    func testSurfaceIsTheFallbackLabelWhenDisplayNameIsMissing() async throws {
        try write(stateFile(limits: """
            { "kind": "weekly_scoped", "percent": 3,
              "scope": { "model": { "id": null, "display_name": "" }, "surface": "Claude Code" } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.map(\.label), ["Claude Code"])
    }

    /// Same principle as ``QuotaJSON/window(_:)``: an entry with no percentage
    /// carries no information and is not 0%.
    func testEntryWithoutPercentIsSkipped() async throws {
        try write(stateFile(limits: """
            { "kind": "weekly_scoped", "severity": "normal", "resets_at": null,
              "scope": { "model": { "display_name": "Fable" } } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly, [])
    }

    func testScopedLimitsAreSortedByPercentDescending() async throws {
        try write(stateFile(limits: """
            \(fableEntry),
            { "kind": "weekly_scoped", "percent": 42, "is_active": true,
              "scope": { "model": { "display_name": "Sonnet" } } },
            { "kind": "weekly_scoped", "percent": 12,
              "scope": { "model": { "display_name": "Opus" } } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.map(\.label), ["Sonnet", "Opus", "Fable"])
        XCTAssertEqual(snapshot.scopedWeekly.map(\.percentUsed), [42, 12, 0])
    }

    /// Equal percentages — the common all-zero case — fall back to the label so
    /// the order can't shuffle between polls.
    func testEqualPercentagesAreOrderedByLabel() async throws {
        try write(stateFile(limits: """
            { "kind": "weekly_scoped", "percent": 0, "scope": { "model": { "display_name": "Sonnet" } } },
            { "kind": "weekly_scoped", "percent": 0, "scope": { "model": { "display_name": "Fable" } } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.map(\.label), ["Fable", "Sonnet"])
    }

    /// Two entries that resolve to the same label — one via
    /// `scope.model.display_name`, one via the `scope.surface` fallback —
    /// collapse to a single row, keeping whichever sorted first (the higher
    /// percentage). Exercises the `seenLabels` dedup filter in
    /// ``QuotaJSON/scopedLimits(in:)``.
    func testDuplicateLabelsCollapseToTheHigherPercentEntry() async throws {
        try write(stateFile(limits: """
            { "kind": "weekly_scoped", "percent": 30, "scope": { "model": { "display_name": "Opus" } } },
            { "kind": "weekly_scoped", "percent": 5, "scope": { "surface": "Opus" } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.count, 1)
        XCTAssertEqual(snapshot.scopedWeekly.first?.percentUsed, 30)
    }

    /// `utilization` is the percentage's other spelling, one level up in the
    /// same payload — ``QuotaJSON/scopedPercentKeys`` accepts both.
    func testUtilizationSpellingIsAcceptedForScopedPercent() async throws {
        try write(stateFile(limits: """
            { "kind": "weekly_scoped", "utilization": 5,
              "scope": { "model": { "display_name": "Opus" } } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.map(\.percentUsed), [5])
    }

    /// `kind` is trimmed and lowercased before comparison, same as the other
    /// lenient key handling in ``QuotaJSON``.
    func testKindMatchingIsCaseAndWhitespaceInsensitive() async throws {
        try write(stateFile(limits: """
            { "kind": " Weekly_Scoped ", "percent": 9,
              "scope": { "model": { "display_name": "Opus" } } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.map(\.percentUsed), [9])
    }

    /// `is_active` has a camelCase fallback, same as the rest of `QuotaJSON`'s
    /// key spellings.
    func testCamelCaseIsActiveIsAccepted() async throws {
        try write(stateFile(limits: """
            { "kind": "weekly_scoped", "percent": 6, "isActive": true,
              "scope": { "model": { "display_name": "Opus" } } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.first?.isActive, true)
    }

    /// `is_active` also accepts a string spelling (`"yes"/"1"`, case-insensitive,
    /// trimmed) — ``QuotaJSON/bool(_:)``'s string-coercion branch.
    func testStringIsActiveSpellingsAreAccepted() async throws {
        try write(stateFile(limits: """
            { "kind": "weekly_scoped", "percent": 6, "is_active": "yes",
              "scope": { "model": { "display_name": "Opus" } } }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly.first?.isActive, true)
    }

    func testMissingLimitsArrayYieldsNoScopedLimits() async throws {
        try write("""
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000) - 60_000),
            "utilization": { "five_hour": { "utilization": 11 } }
          }
        }
        """)

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.scopedWeekly, [])
    }

    /// The whole reason ``QuotaProviding/currentScopedWeekly()`` exists:
    /// `currentSnapshot()` throws once the reading is older than the
    /// staleness threshold, but the scoped rows in that same reading are
    /// still worth handing to ``FreshestQuotaProvider`` when the statusline
    /// hook is covering the account-wide numbers.
    func testCurrentScopedWeeklyBypassesTheStalenessGate() async throws {
        try write(stateFile(limits: fableEntry).replacingOccurrences(
            of: "\(Int(now.timeIntervalSince1970 * 1000) - 60_000)",
            with: "\(Int(now.timeIntervalSince1970 * 1000) - 3_601_000)"
        ))

        await assertThrowsStale(age: 3_601) {
            try await self.makeReader().currentSnapshot()
        }

        let scopedWeekly = try await makeReader().currentScopedWeekly()
        XCTAssertEqual(scopedWeekly.map(\.label), ["Fable"])
    }

    // MARK: - Staleness

    func testReadingOlderThanSixtyMinutesThrowsStale() async throws {
        try write(stateFile(fetchedAt: now.addingTimeInterval(-3601)))

        await assertThrowsStale(age: 3601) {
            try await self.makeReader().currentSnapshot()
        }
    }

    /// The whole point of the 60-minute threshold: a 15-minute-old reading was
    /// measured mid-session and is normal, where the statusline's 10-minute
    /// threshold would have rejected it — and the blob has since been seen
    /// unmoved for hours at a stretch.
    func testFifteenMinuteOldReadingIsAccepted() async throws {
        try write(stateFile(fetchedAt: now.addingTimeInterval(-15 * 60)))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .cachedOfficial)
        XCTAssertEqual(CachedUtilizationReader.defaultStalenessThreshold, 60 * 60)
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
