import XCTest
@testable import ClaudeStatsCore

final class FreshestQuotaProviderTests: XCTestCase {
    // MARK: - Fixtures

    /// A ``QuotaProviding`` whose every call is scripted, and which records
    /// whether ``clearCache()`` reached it.
    private struct StubProvider: QuotaProviding, OtherAccountReadingsReporting {
        final class Box: @unchecked Sendable {
            var clearCacheCallCount = 0
        }

        let result: Result<QuotaSnapshot, ClaudeStatsError>
        /// `nil` falls back to the protocol default (derive from `result`) —
        /// set only to simulate a source like ``CachedUtilizationReader``,
        /// whose ``QuotaProviding/currentScopedWeekly()`` bypasses whatever
        /// made `currentSnapshot()` itself fail.
        let scopedWeeklyResult: Result<[QuotaScopedLimit], ClaudeStatsError>?
        /// Same idea as `scopedWeeklyResult`, for the credits half of the
        /// staleness bypass.
        let usageCreditsResult: Result<UsageCreditsReading, ClaudeStatsError>?
        /// Whether some account other than the active one has readings.
        /// `false` unless a test says otherwise.
        let otherAccounts: Bool
        let box = Box()

        init(
            _ result: Result<QuotaSnapshot, ClaudeStatsError>,
            scopedWeekly scopedWeeklyResult: Result<[QuotaScopedLimit], ClaudeStatsError>? = nil,
            usageCredits usageCreditsResult: Result<UsageCreditsReading, ClaudeStatsError>? = nil,
            otherAccounts: Bool = false
        ) {
            self.result = result
            self.scopedWeeklyResult = scopedWeeklyResult
            self.usageCreditsResult = usageCreditsResult
            self.otherAccounts = otherAccounts
        }

        func hasReadingsForOtherAccounts() -> Bool { otherAccounts }

        func currentSnapshot() async throws -> QuotaSnapshot {
            try result.get()
        }

        func currentScopedWeekly() async throws -> [QuotaScopedLimit] {
            guard let scopedWeeklyResult else {
                return try result.get().scopedWeekly
            }
            return try scopedWeeklyResult.get()
        }

        func currentUsageCredits() async throws -> UsageCreditsReading {
            guard let usageCreditsResult else {
                let snapshot = try result.get()
                return UsageCreditsReading(
                    credits: snapshot.usageCredits,
                    disabledReason: snapshot.usageCreditsDisabledReason
                )
            }
            return try usageCreditsResult.get()
        }

        func clearCache() throws {
            box.clearCacheCallCount += 1
        }
    }

    private let now = Date(timeIntervalSince1970: 1_787_935_500)

    private func snapshot(
        _ confidence: QuotaConfidence,
        percent: Double,
        capturedAgo: TimeInterval,
        scopedWeekly: [QuotaScopedLimit] = [],
        usageCredits: UsageCredits? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: percent),
            sevenDay: QuotaWindow(percentUsed: percent),
            confidence: confidence,
            capturedAt: now.addingTimeInterval(-capturedAgo),
            scopedWeekly: scopedWeekly,
            usageCredits: usageCredits
        )
    }

    private let credits = UsageCredits(
        used: MoneyAmount(amountMinor: 0, currency: "EUR", exponent: 2),
        limit: MoneyAmount(amountMinor: 3_300, currency: "EUR", exponent: 2),
        percentUsed: 0
    )

    // MARK: - The hook is primary

    func testSucceedingStatuslineHookWins() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 11, capturedAgo: 900)))
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.fiveHour?.percentUsed, 62)
    }

    /// The priority flip in one test: this used to be a freshness compare, so
    /// an older-but-succeeding hook reading lost to a newer `cachedState` one.
    /// It no longer does — a hook reading that made it past its own 10-minute
    /// staleness gate is trusted whatever `capturedAt` the backup claims, since
    /// that timestamp moves on Claude Code's schedule rather than ours.
    func testNewerCachedStateReadingNoLongerBeatsTheHook() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 540))),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 97, capturedAgo: 120)))
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.fiveHour?.percentUsed, 62)
    }

    /// A hook reading that carries its own `utilization` copy is complete:
    /// `cachedState` is not consulted for the scoped rows or the credits, and
    /// specifically must not overwrite them with its own older ones.
    func testCompleteHookReadingIsNotBackfilled() async throws {
        let hookScoped = [QuotaScopedLimit(label: "Fable", percentUsed: 4)]
        let cachedScoped = [QuotaScopedLimit(label: "Opus", percentUsed: 99)]
        let staleCredits = UsageCredits(
            used: MoneyAmount(amountMinor: 9_900, currency: "EUR", exponent: 2),
            limit: MoneyAmount(amountMinor: 9_900, currency: "EUR", exponent: 2),
            percentUsed: 100
        )

        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(
                .official, percent: 62, capturedAgo: 30,
                scopedWeekly: hookScoped, usageCredits: credits
            ))),
            cachedState: StubProvider(
                .success(snapshot(
                    .cachedOfficial, percent: 11, capturedAgo: 900,
                    scopedWeekly: cachedScoped, usageCredits: staleCredits
                )),
                scopedWeekly: .success(cachedScoped),
                usageCredits: .success(UsageCreditsReading(credits: staleCredits))
            )
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.scopedWeekly, hookScoped)
        XCTAssertEqual(result.usageCredits, credits)
    }

    /// A hook reading carrying only a `disabled_reason` has still answered the
    /// credits question — "there are none, and here is why" — so it is left
    /// alone rather than re-asked and overwritten with the backup's.
    func testHookDisabledReasonIsNotOverwrittenByTheBackfill() async throws {
        var hook = snapshot(.official, percent: 62, capturedAgo: 30)
        hook.usageCreditsDisabledReason = "billing_not_configured"

        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(hook)),
            cachedState: StubProvider(
                .success(snapshot(.cachedOfficial, percent: 11, capturedAgo: 900, usageCredits: credits)),
                usageCredits: .success(UsageCreditsReading(credits: credits))
            )
        )

        let result = try await provider.currentSnapshot()

        XCTAssertNil(result.usageCredits)
        XCTAssertEqual(result.usageCreditsDisabledReason, "billing_not_configured")
    }

    // MARK: - Backfilling a partial hook reading

    /// A cache file written before the helper script learned to copy
    /// `utilization` across (or written with no `jq`, or while `~/.claude.json`
    /// was unreadable) yields a hook reading with no scoped rows and no
    /// credits. Both are backfilled from `cachedState` rather than left dark.
    func testPartialHookReadingIsBackfilledFromCachedState() async throws {
        let scoped = [QuotaScopedLimit(label: "Fable", percentUsed: 0)]

        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(
                .success(snapshot(
                    .cachedOfficial, percent: 11, capturedAgo: 900,
                    scopedWeekly: scoped, usageCredits: credits
                ))
            )
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.fiveHour?.percentUsed, 62)
        XCTAssertEqual(result.scopedWeekly, scoped)
        XCTAssertEqual(result.usageCredits, credits)
    }

    /// Nothing is invented: a backup with nothing of its own to add leaves the
    /// third and fourth bars empty.
    func testBackfillAddsNothingWhenTheBackupHasNothing() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 11, capturedAgo: 900)))
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.scopedWeekly, [])
        XCTAssertNil(result.usageCredits)
    }

    /// The backfill goes through the staleness-bypassing accessors, so a
    /// `cachedState` whose *snapshot* fails on ``CachedUtilizationReader``'s
    /// 60-minute gate still contributes: its scoped rows and its month-to-date
    /// spend carry no freshness claim the stale windows could invalidate.
    func testBackfillSurvivesACachedStateSnapshotThatFailsOnStaleness() async throws {
        let scoped = [QuotaScopedLimit(label: "Fable", percentUsed: 0)]

        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(
                .failure(.staleQuotaSource(
                    snapshot: snapshot(.cachedOfficial, percent: 11, capturedAgo: 13_400),
                    age: 13_400
                )),
                scopedWeekly: .success(scoped),
                usageCredits: .success(UsageCreditsReading(credits: credits))
            )
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.scopedWeekly, scoped)
        XCTAssertEqual(result.usageCredits, credits)
    }

    /// Genuinely best-effort: a backup that can't answer either question leaves
    /// both rows out rather than failing the poll.
    func testFailedBackfillDoesNotFailThePoll() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(
                .failure(.noQuotaSourceAvailable),
                scopedWeekly: .failure(.noQuotaSourceAvailable),
                usageCredits: .failure(.noQuotaSourceAvailable)
            )
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.scopedWeekly, [])
        XCTAssertNil(result.usageCredits)
    }

    /// The hook wins outright, windows included: a `nil` window is a reading
    /// ("nobody reported it"), so it must not be filled in from `cachedState`,
    /// which would mix two capture times into one bar.
    func testHookNilFiveHourIsNotBackfilledFromCachedState() async throws {
        var hook = snapshot(.official, percent: 62, capturedAgo: 30)
        hook.fiveHour = nil

        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(hook)),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 97, capturedAgo: 900)))
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertNil(result.fiveHour)
        XCTAssertEqual(result.sevenDay?.percentUsed, 62)
    }

    // MARK: - One source down

    /// The hook not being installed is the case the backup exists for, and it
    /// stands in whole: this source parses the scoped rows and `spend`
    /// natively, so all four bars come from it with nothing grafted on.
    func testMissingStatuslineHookIsInvisible() async throws {
        let scoped = [QuotaScopedLimit(label: "Fable", percentUsed: 0)]
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.noQuotaSourceAvailable)),
            cachedState: StubProvider(.success(snapshot(
                .cachedOfficial, percent: 97, capturedAgo: 600,
                scopedWeekly: scoped, usageCredits: credits
            )))
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .cachedOfficial)
        XCTAssertEqual(result.fiveHour?.percentUsed, 97)
        XCTAssertEqual(result.scopedWeekly, scoped)
        XCTAssertEqual(result.usageCredits, credits)
    }

    func testMissingCachedStateIsInvisible() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(.failure(.noQuotaSourceAvailable))
        )

        let result = try await provider.currentSnapshot()
        XCTAssertEqual(result.confidence, .official)
    }

    /// A live reading beats the *other* source being stale — the stale error
    /// must not shadow a good snapshot.
    func testStaleSourceDoesNotShadowAFreshOne() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.staleQuotaSource(
                snapshot: snapshot(.official, percent: 62, capturedAgo: 3_600),
                age: 3_600
            ))),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 97, capturedAgo: 60)))
        )

        let result = try await provider.currentSnapshot()
        XCTAssertEqual(result.confidence, .cachedOfficial)
    }

    /// A corrupt state file must not take the bars down while the hook works.
    func testUnexpectedResponseDoesNotShadowAFreshOne() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(.failure(.unexpectedQuotaResponse("nope")))
        )

        let result = try await provider.currentSnapshot()
        XCTAssertEqual(result.confidence, .official)
    }

    // MARK: - Both sources down

    func testBothMissingThrowsNoQuotaSourceAvailable() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.noQuotaSourceAvailable)),
            cachedState: StubProvider(.failure(.noQuotaSourceAvailable))
        )

        await assertThrows(.noQuotaSourceAvailable) {
            try await provider.currentSnapshot()
        }
    }

    /// Both have real-but-old readings: report the *freshest* of the two ages,
    /// since that is how long ago the app last saw a number — and carry that
    /// same source's own snapshot along with it, not the other one's. The two
    /// stub snapshots differ in `percentUsed` purely so the assertion can tell
    /// which of them survived.
    func testBothStaleReportsTheFreshestAge() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.staleQuotaSource(
                snapshot: snapshot(.official, percent: 62, capturedAgo: 4_200),
                age: 4_200
            ))),
            cachedState: StubProvider(.failure(.staleQuotaSource(
                snapshot: snapshot(.cachedOfficial, percent: 97, capturedAgo: 1_900),
                age: 1_900
            )))
        )

        let carried = await assertThrowsStale(age: 1_900) {
            try await provider.currentSnapshot()
        }
        XCTAssertEqual(carried?.confidence, .cachedOfficial)
        XCTAssertEqual(carried?.fiveHour?.percentUsed, 97)
    }

    /// The freshest of the two stale snapshots already carries a
    /// `usageCreditsDisabledReason` — a live re-read failing must not wipe it,
    /// same as it must not invent credits that don't exist.
    func testBothStaleFailedCreditsRetryPreservesAnAlreadyKnownDisabledReason() async {
        let winningSnapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: 97),
            sevenDay: QuotaWindow(percentUsed: 97),
            confidence: .cachedOfficial,
            capturedAt: now.addingTimeInterval(-1_900),
            usageCreditsDisabledReason: "org_disabled"
        )
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.staleQuotaSource(
                snapshot: snapshot(.official, percent: 62, capturedAgo: 4_200),
                age: 4_200
            ))),
            cachedState: StubProvider(
                .failure(.staleQuotaSource(snapshot: winningSnapshot, age: 1_900)),
                usageCredits: .failure(.unexpectedQuotaResponse("boom"))
            )
        )

        let carried = await assertThrowsStale(age: 1_900) {
            try await provider.currentSnapshot()
        }
        XCTAssertEqual(carried?.confidence, .cachedOfficial)
        XCTAssertNil(carried?.usageCredits)
        XCTAssertEqual(carried?.usageCreditsDisabledReason, "org_disabled")
    }

    /// A stale reading is more informative than "nothing installed", so it wins
    /// the error slot.
    func testStaleBeatsAbsentWhenBothFail() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.noQuotaSourceAvailable)),
            cachedState: StubProvider(.failure(.staleQuotaSource(
                snapshot: snapshot(.cachedOfficial, percent: 97, capturedAgo: 2_500),
                age: 2_500
            )))
        )

        let carried = await assertThrowsStale(age: 2_500) {
            try await provider.currentSnapshot()
        }
        XCTAssertEqual(carried?.confidence, .cachedOfficial)
    }

    /// …and a parse failure names something the user can look at, where
    /// "nothing installed" does not.
    func testUnexpectedResponseBeatsAbsentWhenBothFail() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.noQuotaSourceAvailable)),
            cachedState: StubProvider(.failure(.unexpectedQuotaResponse(".claude.json is not a JSON object")))
        )

        let message = await assertThrowsUnexpectedQuotaResponse {
            try await provider.currentSnapshot()
        }
        XCTAssertEqual(message, ".claude.json is not a JSON object")
    }

    /// A stale reading is still a real reading; a parse failure is not — stale
    /// wins the error slot over unexpected, same as it wins over absent.
    func testStaleBeatsUnexpectedResponseWhenBothFail() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.staleQuotaSource(
                snapshot: snapshot(.official, percent: 62, capturedAgo: 1_200),
                age: 1_200
            ))),
            cachedState: StubProvider(.failure(.unexpectedQuotaResponse("nope")))
        )

        let carried = await assertThrowsStale(age: 1_200) {
            try await provider.currentSnapshot()
        }
        XCTAssertEqual(carried?.confidence, .official)
    }

    /// A non-`ClaudeStatsError` failure carries no priority information this
    /// composition can read, so both sources failing that way collapses to
    /// "nothing available" rather than surfacing either raw error.
    func testNonClaudeStatsErrorsCollapseToNoQuotaSourceAvailable() async {
        struct OpaqueFailure: Error {}
        struct OpaqueProvider: QuotaProviding {
            func currentSnapshot() async throws -> QuotaSnapshot { throw OpaqueFailure() }
            func clearCache() throws {}
        }
        let provider = FreshestQuotaProvider(statusline: OpaqueProvider(), cachedState: OpaqueProvider())

        await assertThrows(.noQuotaSourceAvailable) {
            try await provider.currentSnapshot()
        }
    }

    // MARK: - Accounts

    /// Scripted stand-in for ``ActiveAccountReader``, which would otherwise
    /// read the developer's own `~/.claude.json`.
    private struct StubActiveAccount: ActiveAccountProviding {
        let reading: ActiveAccountReading
        func readActiveAccount() -> ActiveAccountReading { reading }
    }

    private let exampleOrg = QuotaAccount(
        uuid: "0f9c1d3e-8a4b-4c2d-9e1f-6b7a8c9d0e1f", organizationName: "Example Org")

    /// The one case the primary/backup ladder can't express: there *are*
    /// readings, none of them this login's, and the backup has nothing either.
    /// "No reading" for the active account beats both an error and somebody
    /// else's numbers.
    func testActiveAccountWithNoReadingAnywhereIsNoReadingNotAnError() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.noQuotaSourceAvailable), otherAccounts: true),
            cachedState: StubProvider(.failure(.noQuotaSourceAvailable)),
            activeAccount: StubActiveAccount(reading: ActiveAccountReading(account: exampleOrg)),
            now: { self.now }
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.account, exampleOrg)
        XCTAssertNil(result.fiveHour)
        XCTAssertNil(result.sevenDay)
        // Dated now: what was observed now is the *absence*, and another
        // account's file must not put its age on this account's tag.
        XCTAssertEqual(result.capturedAt, now)
    }

    /// A statusline source that doesn't conform to
    /// ``OtherAccountReadingsReporting`` can't tell accounts apart, so it has no
    /// other account to point at: the error stands, exactly as it did when the
    /// protocol's default reported no other accounts.
    func testStatuslineThatCannotTellAccountsApartStillThrows() async {
        struct UngroupedProvider: QuotaProviding {
            func currentSnapshot() async throws -> QuotaSnapshot { throw ClaudeStatsError.noQuotaSourceAvailable }
            func clearCache() throws {}
        }
        let provider = FreshestQuotaProvider(
            statusline: UngroupedProvider(),
            cachedState: StubProvider(.failure(.noQuotaSourceAvailable)),
            activeAccount: StubActiveAccount(reading: ActiveAccountReading(account: exampleOrg))
        )

        await assertThrows(.noQuotaSourceAvailable) {
            try await provider.currentSnapshot()
        }
    }

    /// Nothing on disk for any account is still the old error — "Claude Code
    /// hasn't cached a reading on this Mac" is accurate advice there, where
    /// two empty bars say nothing.
    func testNoReadingsAtAllStillThrowsEvenWithAKnownAccount() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.noQuotaSourceAvailable)),
            cachedState: StubProvider(.failure(.noQuotaSourceAvailable)),
            activeAccount: StubActiveAccount(reading: ActiveAccountReading(account: exampleOrg))
        )

        await assertThrows(.noQuotaSourceAvailable) {
            try await provider.currentSnapshot()
        }
    }

    /// With no state file to name the active account there is nothing to report
    /// an empty reading *for*, so the error stands.
    func testUnknownActiveAccountWithOtherReadingsStillThrows() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.noQuotaSourceAvailable), otherAccounts: true),
            cachedState: StubProvider(.failure(.noQuotaSourceAvailable)),
            activeAccount: StubActiveAccount(reading: .unknown)
        )

        await assertThrows(.noQuotaSourceAvailable) {
            try await provider.currentSnapshot()
        }
    }

    /// A stale reading is a reading: it keeps winning the error slot, and is
    /// not replaced by an empty "no reading" snapshot.
    func testStaleActiveReadingIsNotReplacedByAnEmptyOne() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(
                .failure(.staleQuotaSource(
                    snapshot: snapshot(.official, percent: 62, capturedAgo: 1_200), age: 1_200)),
                otherAccounts: true
            ),
            cachedState: StubProvider(.failure(.noQuotaSourceAvailable)),
            activeAccount: StubActiveAccount(reading: ActiveAccountReading(account: exampleOrg))
        )

        let carried = await assertThrowsStale(age: 1_200) {
            try await provider.currentSnapshot()
        }
        XCTAssertEqual(carried?.fiveHour?.percentUsed, 62)
    }

    // MARK: - Clearing

    /// Only the statusline cache is this app's to delete; `~/.claude.json`
    /// belongs to Claude Code.
    func testClearCacheForwardsToTheStatuslineReaderOnly() throws {
        let statusline = StubProvider(.failure(.noQuotaSourceAvailable))
        let cachedState = StubProvider(.failure(.noQuotaSourceAvailable))
        let provider = FreshestQuotaProvider(statusline: statusline, cachedState: cachedState)

        try provider.clearCache()

        XCTAssertEqual(statusline.box.clearCacheCallCount, 1)
        XCTAssertEqual(cachedState.box.clearCacheCallCount, 0)
    }

    /// A failed delete has to reach the caller — `AppModel` shows it instead of
    /// a false "cleared" notice.
    func testClearCachePropagatesTheStatuslineReadersError() throws {
        struct ThrowingProvider: QuotaProviding {
            struct Failure: Error {}
            func currentSnapshot() async throws -> QuotaSnapshot { throw Failure() }
            func clearCache() throws { throw Failure() }
        }

        let provider = FreshestQuotaProvider(
            statusline: ThrowingProvider(),
            cachedState: StubProvider(.failure(.noQuotaSourceAvailable))
        )

        XCTAssertThrowsError(try provider.clearCache()) { error in
            XCTAssertTrue(error is ThrowingProvider.Failure, "\(error)")
        }
    }
}
