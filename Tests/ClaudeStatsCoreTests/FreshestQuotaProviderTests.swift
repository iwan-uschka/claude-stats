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
        let box = Box()

        init(_ result: Result<QuotaSnapshot, ClaudeStatsError>) {
            self.result = result
        }

        func currentSnapshot() async throws -> QuotaSnapshot {
            try result.get()
        }

        func clearCache() throws {
            box.clearCacheCallCount += 1
        }
    }

    private let now = Date(timeIntervalSince1970: 1_787_935_500)

    private func snapshot(
        _ confidence: QuotaConfidence,
        percent: Double,
        capturedAgo: TimeInterval
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(percentUsed: percent),
            sevenDay: QuotaWindow(percentUsed: percent),
            confidence: confidence,
            capturedAt: now.addingTimeInterval(-capturedAgo)
        )
    }

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
            statusline: StubProvider(.failure(.staleQuotaSource(age: 3_600))),
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
    /// since that is how long ago the app last saw a number.
    func testBothStaleReportsTheFreshestAge() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.staleQuotaSource(age: 4_200))),
            cachedState: StubProvider(.failure(.staleQuotaSource(age: 1_900)))
        )

        await assertThrows(.staleQuotaSource(age: 1_900)) {
            try await provider.currentSnapshot()
        }
    }

    /// A stale reading is more informative than "nothing installed", so it wins
    /// the error slot.
    func testStaleBeatsAbsentWhenBothFail() async {
        let provider = FreshestQuotaProvider(
            statusline: StubProvider(.failure(.noQuotaSourceAvailable)),
            cachedState: StubProvider(.failure(.staleQuotaSource(age: 2_500)))
        )

        await assertThrows(.staleQuotaSource(age: 2_500)) {
            try await provider.currentSnapshot()
        }
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
            statusline: StubProvider(.failure(.staleQuotaSource(age: 1_200))),
            cachedState: StubProvider(.failure(.unexpectedQuotaResponse("nope")))
        )

        await assertThrows(.staleQuotaSource(age: 1_200)) {
            try await provider.currentSnapshot()
        }
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
