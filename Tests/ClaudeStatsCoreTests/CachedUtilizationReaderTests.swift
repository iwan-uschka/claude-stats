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
    /// the unrelated top-level keys (`projects`, `userID`, …). `accountUuid` is
    /// read (see the "Which account" tests below); the null scoped windows and
    /// the `session` / `weekly_all` entries of `limits[]` are still deliberately
    /// ignored and kept only so a future reader for them can't quietly change
    /// what this one sees. No `spend` / `extra_usage` here: those have their own
    /// fixtures below, and this one doubles as the "payload with no usage
    /// credits" case.
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
        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 11)
        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 97)
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

        let fiveHourReset = try XCTUnwrap(snapshot.fiveHour?.resetsAt)
        let sevenDayReset = try XCTUnwrap(snapshot.sevenDay?.resetsAt)
        XCTAssertEqual(fiveHourReset.timeIntervalSince1970, fiveHourResetEpoch, accuracy: 0.001)
        XCTAssertEqual(sevenDayReset.timeIntervalSince1970, sevenDayResetEpoch, accuracy: 0.001)
        // Fractional seconds survive, so a countdown can't be a second off.
        XCTAssertEqual(snapshot.fiveHour?.timeUntilReset(from: now) ?? 0, 300, accuracy: 1)
    }

    /// `optionalWindows(in:)`'s documented contract: each window is
    /// independently optional, and the missing one stays absent — `nil`, not a
    /// zeroed window claiming 0% — rather than failing the whole read.
    func testSevenDayOnlyYieldsNilFiveHourNotFailure() async throws {
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

        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 42)
        XCTAssertNil(snapshot.fiveHour)
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

        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 11)
        XCTAssertEqual(snapshot.sevenDay?.percentUsed, 97)
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

    // MARK: - Usage credits

    /// A state file whose `utilization` carries `extras` (a `spend` and/or
    /// `extra_usage` object) alongside the two windows, fetched a minute ago.
    private func stateFile(extras: String) -> String {
        """
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000) - 60_000),
            "utilization": {
              "five_hour": { "utilization": 11, "resets_at": "2026-08-28T16:50:00.401807+00:00" },
              "seven_day": { "utilization": 97, "resets_at": "2026-08-28T23:00:00.401826+00:00" },
              \(extras)
            }
          }
        }
        """
    }

    /// `spend` + `extra_usage` verbatim as observed on 2026-08-28: credits on,
    /// nothing spent against a €33 monthly cap.
    private let spendAndExtraUsage = """
        "spend": {
          "used":  { "amount_minor": 0, "currency": "EUR", "exponent": 2 },
          "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
          "percent": 0, "severity": "normal", "enabled": true, "disabled_reason": null
        },
        "extra_usage": {
          "is_enabled": true, "monthly_limit": 3300, "used_credits": 0,
          "currency": "EUR", "decimal_places": 2, "utilization": null,
          "disabled_reason": null, "user_disabled": false, "spend_limit_reached": false,
          "credits_ever_enabled": true, "daily": null, "weekly": null
        }
        """

    func testRealSpendPayloadBecomesUsageCredits() async throws {
        try write(stateFile(extras: spendAndExtraUsage))

        let snapshot = try await makeReader().currentSnapshot()
        let credits = try XCTUnwrap(snapshot.usageCredits)

        XCTAssertEqual(credits.used, MoneyAmount(amountMinor: 0, currency: "EUR", exponent: 2))
        XCTAssertEqual(credits.limit, MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2))
        // 0% is reported as 0%, exactly like a scoped limit.
        XCTAssertEqual(credits.percentUsed, 0)
        XCTAssertEqual(credits.severity, "normal")
        XCTAssertFalse(credits.limitReached)
        // Money, from the payload's own currency and exponent.
        XCTAssertEqual(
            DisplayFormat.moneySpend(
                used: credits.used, limit: credits.limit, locale: Locale(identifier: "en_US")
            ),
            "€0.00 of €33.00"
        )
        // No rollover timestamp in the payload, so no countdown.
        XCTAssertNil(credits.window.resetsAt)
    }

    /// The day before the `spend` object appeared: no `spend` key at all, and
    /// an `extra_usage` that says credits are off. Absence, not an error.
    func testPayloadWithoutSpendYieldsNoUsageCredits() async throws {
        try write(stateFile(extras: """
            "extra_usage": {
              "is_enabled": false, "monthly_limit": null, "used_credits": null,
              "user_disabled": true, "credits_ever_enabled": true, "disabled_reason": null
            }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertNil(snapshot.usageCredits)
        XCTAssertNil(snapshot.usageCreditsDisabledReason)
        // The rest of the reading is untouched by the absence.
        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 11)
    }

    func testDisabledSpendYieldsNoUsageCredits() async throws {
        try write(stateFile(extras: """
            "spend": {
              "used":  { "amount_minor": 0, "currency": "EUR", "exponent": 2 },
              "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "percent": 0, "severity": "normal", "enabled": false, "disabled_reason": null
            }
            """))

        let snapshot = try await makeReader().currentSnapshot()
        XCTAssertNil(snapshot.usageCredits)
    }

    /// `spend` can outlive the credits it describes, so `extra_usage` gets the
    /// veto: a user-disabled account has no credits row even with a populated,
    /// enabled `spend`.
    func testUserDisabledExtraUsageVetoesAPopulatedSpend() async throws {
        try write(stateFile(extras: """
            "spend": {
              "used":  { "amount_minor": 500, "currency": "EUR", "exponent": 2 },
              "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "percent": 15, "severity": "normal", "enabled": true, "disabled_reason": null
            },
            "extra_usage": { "is_enabled": true, "user_disabled": true, "spend_limit_reached": false }
            """))

        let snapshot = try await makeReader().currentSnapshot()
        XCTAssertNil(snapshot.usageCredits)
    }

    func testDisabledExtraUsageVetoesAPopulatedSpend() async throws {
        try write(stateFile(extras: """
            "spend": {
              "used":  { "amount_minor": 500, "currency": "EUR", "exponent": 2 },
              "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "percent": 15, "enabled": true
            },
            "extra_usage": { "is_enabled": false, "user_disabled": false }
            """))

        let snapshot = try await makeReader().currentSnapshot()
        XCTAssertNil(snapshot.usageCredits)
    }

    /// Two currencies can't be rendered as one spend figure, and half a figure
    /// would be worse than none.
    func testMismatchedCurrenciesYieldNoUsageCredits() async throws {
        try write(stateFile(extras: """
            "spend": {
              "used":  { "amount_minor": 500, "currency": "USD", "exponent": 2 },
              "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "percent": 15, "enabled": true
            }
            """))

        let snapshot = try await makeReader().currentSnapshot()
        XCTAssertNil(snapshot.usageCredits)
    }

    /// A nonsense exponent means the whole reading is untrustworthy — see
    /// ``QuotaJSON/money(_:)``.
    func testOutOfRangeExponentYieldsNoUsageCredits() async throws {
        try write(stateFile(extras: """
            "spend": {
              "used":  { "amount_minor": 100, "currency": "EUR", "exponent": 7 },
              "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "percent": 3, "enabled": true
            }
            """))

        let snapshot = try await makeReader().currentSnapshot()
        XCTAssertNil(snapshot.usageCredits)
    }

    /// Same principle as ``QuotaJSON/window(_:)``: a missing percentage is not
    /// 0%.
    func testSpendWithoutPercentYieldsNoUsageCredits() async throws {
        try write(stateFile(extras: """
            "spend": {
              "used":  { "amount_minor": 0, "currency": "EUR", "exponent": 2 },
              "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "severity": "normal", "enabled": true
            }
            """))

        let snapshot = try await makeReader().currentSnapshot()
        XCTAssertNil(snapshot.usageCredits)
    }

    func testMissingAmountOrCurrencyYieldsNoUsageCredits() async throws {
        try write(stateFile(extras: """
            "spend": {
              "used":  { "currency": "EUR", "exponent": 2 },
              "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "percent": 0, "enabled": true
            }
            """))
        let withoutAmount = try await makeReader().currentSnapshot()
        XCTAssertNil(withoutAmount.usageCredits)

        try write(stateFile(extras: """
            "spend": {
              "used":  { "amount_minor": 0, "exponent": 2 },
              "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "percent": 0, "enabled": true
            }
            """))
        let withoutCurrency = try await makeReader().currentSnapshot()
        XCTAssertNil(withoutCurrency.usageCredits)
    }

    /// A zero-decimal currency: `exponent: 0` means the minor units are whole
    /// yen, and the formatted string carries no decimals.
    func testZeroDecimalCurrencyKeepsItsExponent() async throws {
        try write(stateFile(extras: """
            "spend": {
              "used":  { "amount_minor": 1200, "currency": "JPY", "exponent": 0 },
              "limit": { "amount_minor": 50000, "currency": "JPY", "exponent": 0 },
              "percent": 2.4, "severity": "normal", "enabled": true
            },
            "extra_usage": { "is_enabled": true, "user_disabled": false }
            """))

        let snapshot = try await makeReader().currentSnapshot()
        let credits = try XCTUnwrap(snapshot.usageCredits)

        XCTAssertEqual(credits.used.exponent, 0)
        XCTAssertEqual(credits.percentUsed, 2.4)
        XCTAssertEqual(
            DisplayFormat.moneySpend(
                used: credits.used, limit: credits.limit, locale: Locale(identifier: "en_US")
            ),
            "¥1,200 of ¥50,000"
        )
    }

    func testSpendLimitReachedIsCarriedThrough() async throws {
        try write(stateFile(extras: """
            "spend": {
              "used":  { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "limit": { "amount_minor": 3300, "currency": "EUR", "exponent": 2 },
              "percent": 100, "severity": "critical", "enabled": true
            },
            "extra_usage": {
              "is_enabled": true, "user_disabled": false, "spend_limit_reached": true
            }
            """))

        let snapshot = try await makeReader().currentSnapshot()
        let credits = try XCTUnwrap(snapshot.usageCredits)

        XCTAssertTrue(credits.limitReached)
        XCTAssertEqual(credits.severity, "critical")
        XCTAssertEqual(credits.window.fractionUsed, 1)
    }

    /// Decoration for a tooltip, never an error — and only while there are no
    /// credits to show.
    func testDisabledReasonIsCarriedWhenCreditsAreAbsent() async throws {
        try write(stateFile(extras: """
            "extra_usage": {
              "is_enabled": false, "user_disabled": false,
              "disabled_reason": "billing_not_configured"
            }
            """))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertNil(snapshot.usageCredits)
        XCTAssertEqual(snapshot.usageCreditsDisabledReason, "billing_not_configured")
    }

    func testDisabledReasonIsDroppedWhenCreditsArePresent() async throws {
        try write(stateFile(extras: spendAndExtraUsage))

        let snapshot = try await makeReader().currentSnapshot()

        XCTAssertNotNil(snapshot.usageCredits)
        XCTAssertNil(snapshot.usageCreditsDisabledReason)
    }

    /// The credits half of ``testCurrentScopedWeeklyBypassesTheStalenessGate``:
    /// a month-to-date spend total an hour behind is still the right number.
    func testCurrentUsageCreditsBypassesTheStalenessGate() async throws {
        try write(stateFile(extras: spendAndExtraUsage).replacingOccurrences(
            of: "\(Int(now.timeIntervalSince1970 * 1000) - 60_000)",
            with: "\(Int(now.timeIntervalSince1970 * 1000) - 3_601_000)"
        ))

        await assertThrowsStale(age: 3_601) {
            try await self.makeReader().currentSnapshot()
        }

        let reading = try await makeReader().currentUsageCredits()
        XCTAssertEqual(reading.credits?.limit.amountMinor, 3_300)
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

    // MARK: - Which account the numbers describe

    /// The uuid inside `cachedUsageUtilization` says whose numbers these are;
    /// the sibling `oauthAccount` fills in the name the popover shows, since
    /// the two agree here.
    func testAccountCombinesTheCachedUuidWithTheLoggedInDetails() async throws {
        try write("""
        {
          "oauthAccount": { "accountUuid": "account-1", "emailAddress": "me@example.com",
                            "organizationName": "Bitgrip", "organizationUuid": "org-1" },
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000) - 60_000),
            "accountUuid": "account-1",
            "utilization": { "five_hour": { "utilization": 11 } }
          }
        }
        """)

        let snapshot = try await makeReader().currentSnapshot()

        let account = try XCTUnwrap(snapshot.account)
        XCTAssertEqual(account.uuid, "account-1")
        XCTAssertEqual(account.organizationName, "Bitgrip")
        XCTAssertEqual(account.email, "me@example.com")
        XCTAssertEqual(account.displayName, "me@example.com")
    }

    /// Claude Code has cached usage for one account and is logged in as
    /// another — the window right after a switch. The reading keeps its own
    /// uuid and nothing else: labelling last login's numbers with this login's
    /// organisation is exactly the mislabelling being fixed.
    func testMismatchedAccountKeepsOnlyTheReadingsOwnUuid() async throws {
        try write("""
        {
          "oauthAccount": { "accountUuid": "account-2", "organizationName": "creativytool" },
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000) - 60_000),
            "accountUuid": "account-1",
            "utilization": { "five_hour": { "utilization": 11 } }
          }
        }
        """)

        let snapshot = try await makeReader().currentSnapshot()

        let account = try XCTUnwrap(snapshot.account)
        XCTAssertEqual(account.uuid, "account-1")
        XCTAssertNil(account.organizationName)
    }

    /// An older payload with no `accountUuid` of its own: the logged-in account
    /// is the only claim there is.
    func testAccountFallsBackToOAuthAccountWhenTheBlobNamesNone() async throws {
        try write("""
        {
          "oauthAccount": { "accountUuid": "account-1", "organizationName": "Bitgrip" },
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000) - 60_000),
            "utilization": { "five_hour": { "utilization": 11 } }
          }
        }
        """)

        let account = try await makeReader().currentSnapshot().account
        XCTAssertEqual(account?.uuid, "account-1")
        XCTAssertEqual(account?.organizationName, "Bitgrip")
    }

    /// Neither key present: an unknown account, which is what every reading
    /// looked like before accounts were modelled — not a failure.
    func testNoAccountAnywhereLeavesTheSnapshotUnattributed() async throws {
        try write(stateFile(fetchedAt: now.addingTimeInterval(-60)))

        // The shared fixture carries `cachedUsageUtilization.accountUuid` but no
        // `oauthAccount`, so the uuid stands alone.
        let attributed = try await makeReader().currentSnapshot()
        let account = try XCTUnwrap(attributed.account)
        XCTAssertEqual(account.uuid, "0f9c1d3e-8a4b-4c2d-9e1f-6b7a8c9d0e1f")
        XCTAssertNil(account.organizationName)

        try write("""
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(now.timeIntervalSince1970 * 1000) - 60_000),
            "utilization": { "five_hour": { "utilization": 11 } }
          }
        }
        """)
        let unattributed = try await makeReader().currentSnapshot()
        XCTAssertNil(unattributed.account)
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
        XCTAssertEqual(snapshot.fiveHour?.percentUsed, 11)
    }

    // MARK: - Default candidates

    func testDefaultCandidatesMatchTheStateFileProbeOrder() {
        let reader = CachedUtilizationReader()
        XCTAssertEqual(reader.candidateURLs, ClaudeConfigDirectory.stateFileCandidates())
        XCTAssertTrue(reader.candidateURLs.allSatisfy { $0.lastPathComponent == ".claude.json" })
    }
}
