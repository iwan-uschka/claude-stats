import XCTest
@testable import ClaudeStatsCore

final class FreshestQuotaProviderTests: XCTestCase {
    // MARK: - Fixtures

    /// A ``QuotaProviding`` whose every call is scripted, and which records
    /// whether ``clearCache()`` reached it.
    private struct StubProvider: QuotaProviding {
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
        let box = Box()

        init(
            _ result: Result<QuotaSnapshot, ClaudeStatsError>,
            scopedWeekly scopedWeeklyResult: Result<[QuotaScopedLimit], ClaudeStatsError>? = nil,
            usageCredits usageCreditsResult: Result<UsageCreditsReading, ClaudeStatsError>? = nil
        ) {
            self.result = result
            self.scopedWeeklyResult = scopedWeeklyResult
            self.usageCreditsResult = usageCreditsResult
        }

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

    // MARK: - Freshest wins

    func testNewerStatuslineCaptureWins() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 11, capturedAgo: 900)))
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.fiveHour.percentUsed, 62)
    }

    func testNewerCachedStateReadingWins() async throws {
        // The hook is installed but has been quiet since the user closed their
        // terminal, while Claude Code kept updating its own cache elsewhere.
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 540))),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 97, capturedAgo: 120)))
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .cachedOfficial)
        XCTAssertEqual(result.fiveHour.percentUsed, 97)
    }

    /// Only the cached-state source's payload has `limits[]` at all — the
    /// statusline hook's schema carries no such field, not merely an empty
    /// one. So scoped rows always come from `cachedState` regardless of which
    /// snapshot wins the freshness compare for everything else: an account
    /// with the hook installed (the common case, and almost always fresher)
    /// must not lose the scoped bars just because the hook's own reading won.
    func testScopedWeeklyLimitsAlwaysComeFromCachedState() async throws {
        let scoped = [QuotaScopedLimit(label: "Fable", percentUsed: 0)]

        let statuslineWins = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(
                .success(snapshot(.cachedOfficial, percent: 11, capturedAgo: 900, scopedWeekly: scoped))
            )
        )
        let fromStatusline = try await statuslineWins.currentSnapshot()
        XCTAssertEqual(fromStatusline.confidence, .official)
        XCTAssertEqual(fromStatusline.scopedWeekly, scoped)

        let cachedWins = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 900))),
            cachedState: StubProvider(
                .success(snapshot(.cachedOfficial, percent: 11, capturedAgo: 30, scopedWeekly: scoped))
            )
        )
        let fromCachedState = try await cachedWins.currentSnapshot()
        XCTAssertEqual(fromCachedState.confidence, .cachedOfficial)
        XCTAssertEqual(fromCachedState.scopedWeekly, scoped)

        // And when `cachedState` itself has none to report, none appear —
        // this isn't a second independent source of scoped data, just the
        // one source's field surviving the freshness pick.
        let noScopedAtAll = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 11, capturedAgo: 900)))
        )
        let result = try await noScopedAtAll.currentSnapshot()
        XCTAssertEqual(result.scopedWeekly, [])
    }

    /// The real-world case the graft above didn't cover: the hook is fresh
    /// and succeeding, but `cachedState`'s *snapshot* has crossed its own
    /// staleness threshold (``CachedUtilizationReader``'s 60 minutes) and so
    /// fails outright — `(.success, .failure)`. Its scoped rows must not
    /// disappear just because its account-wide windows are too old to win.
    func testScopedWeeklyLimitsSurviveACachedStateSnapshotThatFailsOnStaleness() async throws {
        let scoped = [QuotaScopedLimit(label: "Fable", percentUsed: 0)]

        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(
                .failure(.staleQuotaSource(
                    snapshot: snapshot(.cachedOfficial, percent: 11, capturedAgo: 13_400),
                    age: 13_400
                )),
                scopedWeekly: .success(scoped)
            )
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.scopedWeekly, scoped)
    }

    /// The best-effort fetch is genuinely best-effort: if `cachedState` can't
    /// produce scoped rows at all (e.g. no `limits[]` in the payload), the
    /// hook's snapshot still wins with none, not an error.
    func testMissingScopedWeeklyDoesNotFailTheGraftAttempt() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(
                .failure(.noQuotaSourceAvailable),
                scopedWeekly: .failure(.noQuotaSourceAvailable)
            )
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.scopedWeekly, [])
    }

    /// `spend` lives only in `cachedState`'s payload, exactly like `limits[]`,
    /// so the credits row has to survive the statusline hook winning the
    /// freshness compare.
    func testUsageCreditsAlwaysComeFromCachedState() async throws {
        let statuslineWins = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(
                .success(snapshot(.cachedOfficial, percent: 11, capturedAgo: 900, usageCredits: credits))
            )
        )

        let result = try await statuslineWins.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.usageCredits, credits)

        // And nothing is invented when `cachedState` reports none.
        let noCredits = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 11, capturedAgo: 900)))
        )
        let withoutCredits = try await noCredits.currentSnapshot()
        XCTAssertNil(withoutCredits.usageCredits)
    }

    /// The credits half of the staleness bypass: a month-to-date spend total
    /// doesn't stop being right because the account-wide windows next to it are
    /// an hour old.
    func testUsageCreditsSurviveACachedStateSnapshotThatFailsOnStaleness() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(
                .failure(.staleQuotaSource(
                    snapshot: snapshot(.cachedOfficial, percent: 11, capturedAgo: 13_400),
                    age: 13_400
                )),
                usageCredits: .success(UsageCreditsReading(credits: credits))
            )
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertEqual(result.usageCredits, credits)
    }

    /// Best-effort, like the scoped graft: a `cachedState` that can't report
    /// credits at all leaves the row out rather than failing the poll.
    func testMissingUsageCreditsDoesNotFailTheGraftAttempt() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 30))),
            cachedState: StubProvider(
                .failure(.noQuotaSourceAvailable),
                usageCredits: .failure(.noQuotaSourceAvailable)
            )
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .official)
        XCTAssertNil(result.usageCredits)
    }

    /// Same underlying reading reaching us both ways: prefer the one that was
    /// observed directly.
    func testIdenticalCaptureTimesPreferTheStatuslineCapture() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.success(snapshot(.official, percent: 62, capturedAgo: 60))),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 62, capturedAgo: 60)))
        )

        let result = try await provider.currentSnapshot()
        XCTAssertEqual(result.confidence, .official)
    }

    // MARK: - One source down

    func testMissingStatuslineHookIsInvisible() async throws {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.noQuotaSourceAvailable)),
            cachedState: StubProvider(.success(snapshot(.cachedOfficial, percent: 97, capturedAgo: 600)))
        )

        let result = try await provider.currentSnapshot()

        XCTAssertEqual(result.confidence, .cachedOfficial)
        XCTAssertEqual(result.fiveHour.percentUsed, 97)
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
        XCTAssertEqual(carried?.fiveHour.percentUsed, 97)
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
