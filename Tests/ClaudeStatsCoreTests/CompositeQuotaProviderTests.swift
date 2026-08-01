import XCTest
@testable import ClaudeStatsCore

/// Pins the fallback ordering with in-memory stubs — no network, no credentials,
/// no filesystem.
final class CompositeQuotaProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fresh(_ confidence: QuotaConfidence, ageSeconds: TimeInterval = 30) -> QuotaSnapshot {
        .fixture(confidence: confidence, capturedAt: now.addingTimeInterval(-ageSeconds))
    }

    private func makeProvider(
        statusline: QuotaProviding? = nil,
        oauth: QuotaProviding? = nil,
        local: QuotaProviding? = nil,
        stalenessThreshold: TimeInterval = QuotaSnapshot.defaultStalenessThreshold
    ) -> CompositeQuotaProvider {
        let fixedNow = now
        return CompositeQuotaProvider(
            statuslineSource: statusline,
            oauthSource: oauth,
            localEstimateSource: local,
            stalenessThreshold: stalenessThreshold,
            now: { fixedNow }
        )
    }

    // MARK: - Ordering

    func testStatuslineWinsAndLowerTiersAreNeverConsulted() async throws {
        let statusline = StubQuotaProvider(snapshot: fresh(.official))
        let oauth = StubQuotaProvider(snapshot: fresh(.experimental))
        let local = StubQuotaProvider(snapshot: fresh(.localEstimate))

        let snapshot = try await makeProvider(statusline: statusline, oauth: oauth, local: local)
            .currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .official)
        XCTAssertTrue(statusline.wasCalled)
        XCTAssertFalse(oauth.wasCalled)
        XCTAssertFalse(local.wasCalled)
    }

    func testFallsBackToOAuthWhenStatuslineCacheIsAbsent() async throws {
        let statusline = StubQuotaProvider(error: ClaudeStatsError.noQuotaSourceAvailable)
        let oauth = StubQuotaProvider(snapshot: fresh(.experimental))
        let local = StubQuotaProvider(snapshot: fresh(.localEstimate))

        let snapshot = try await makeProvider(statusline: statusline, oauth: oauth, local: local)
            .currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .experimental)
        XCTAssertTrue(oauth.wasCalled)
        XCTAssertFalse(local.wasCalled)
    }

    func testFallsBackToLocalEstimateWhenBothLiveSourcesFail() async throws {
        let statusline = StubQuotaProvider(error: ClaudeStatsError.noQuotaSourceAvailable)
        let oauth = StubQuotaProvider(error: ClaudeStatsError.unexpectedQuotaResponse("oauth/usage: HTTP 429"))
        let local = StubQuotaProvider(snapshot: fresh(.localEstimate))

        let snapshot = try await makeProvider(statusline: statusline, oauth: oauth, local: local)
            .currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .localEstimate)
        XCTAssertTrue(statusline.wasCalled)
        XCTAssertTrue(oauth.wasCalled)
        XCTAssertTrue(local.wasCalled)
    }

    func testMissingCredentialsAlsoFallsThroughToLocalEstimate() async throws {
        let snapshot = try await makeProvider(
            statusline: StubQuotaProvider(error: ClaudeStatsError.noQuotaSourceAvailable),
            oauth: StubQuotaProvider(error: ClaudeStatsError.missingCredentials),
            local: StubQuotaProvider(snapshot: fresh(.localEstimate))
        ).currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .localEstimate)
    }

    /// A transport error must not escape the composite — it's just another
    /// reason to drop a tier.
    func testNetworkErrorFromOAuthTierIsSwallowed() async throws {
        let snapshot = try await makeProvider(
            statusline: StubQuotaProvider(error: ClaudeStatsError.noQuotaSourceAvailable),
            oauth: StubQuotaProvider(error: URLError(.timedOut)),
            local: StubQuotaProvider(snapshot: fresh(.localEstimate))
        ).currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .localEstimate)
    }

    // MARK: - Staleness gate on the live tiers

    func testStaleStatuslineSnapshotIsSkippedInFavourOfOAuth() async throws {
        // A source that hands over an old snapshot instead of failing.
        let statusline = StubQuotaProvider(snapshot: fresh(.official, ageSeconds: 3600))
        let oauth = StubQuotaProvider(snapshot: fresh(.experimental))

        let snapshot = try await makeProvider(statusline: statusline, oauth: oauth)
            .currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .experimental)
    }

    func testStaleLiveTiersFallThroughToLocalEstimate() async throws {
        let snapshot = try await makeProvider(
            statusline: StubQuotaProvider(snapshot: fresh(.official, ageSeconds: 3600)),
            oauth: StubQuotaProvider(snapshot: fresh(.experimental, ageSeconds: 3600)),
            local: StubQuotaProvider(snapshot: fresh(.localEstimate))
        ).currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .localEstimate)
    }

    /// The last-resort tier is exempt from the staleness gate: local logs may
    /// legitimately show no recent activity.
    func testLocalEstimateIsNotStalenessCheckedAndIsReturnedEvenWhenOld() async throws {
        let old = QuotaSnapshot.fixture(
            confidence: .localEstimate,
            capturedAt: now.addingTimeInterval(-86_400)
        )
        let snapshot = try await makeProvider(local: StubQuotaProvider(snapshot: old)).currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .localEstimate)
        XCTAssertTrue(snapshot.isStale(asOf: now))
    }

    // MARK: - Exhaustion

    func testThrowsNoQuotaSourceAvailableWhenEveryTierFails() async {
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeProvider(
                statusline: StubQuotaProvider(error: ClaudeStatsError.noQuotaSourceAvailable),
                oauth: StubQuotaProvider(error: ClaudeStatsError.missingCredentials),
                local: StubQuotaProvider(error: ClaudeStatsError.configDirectoryNotFound)
            ).currentSnapshot()
        }
    }

    func testThrowsNoQuotaSourceAvailableWhenNoTiersAreConfigured() async {
        await assertThrows(.noQuotaSourceAvailable) {
            try await self.makeProvider().currentSnapshot()
        }
    }

    // MARK: - Closure-injected local estimate

    func testClosureLocalEstimateComposesWithoutAConcreteType() async throws {
        let fixedNow = now
        let provider = CompositeQuotaProvider(
            statuslineSource: StubQuotaProvider(error: ClaudeStatsError.noQuotaSourceAvailable),
            oauthSource: StubQuotaProvider(error: ClaudeStatsError.missingCredentials),
            now: { fixedNow },
            localEstimate: {
                QuotaSnapshot.fixture(fiveHour: 44, confidence: .localEstimate, capturedAt: fixedNow)
            }
        )

        let snapshot = try await provider.currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .localEstimate)
        XCTAssertEqual(snapshot.fiveHour.percentUsed, 44)
    }

    func testClosureQuotaProviderPropagatesItsError() async {
        let provider = ClosureQuotaProvider { throw ClaudeStatsError.configDirectoryNotFound }
        await assertThrows(.configDirectoryNotFound) { try await provider.currentSnapshot() }
    }

    // MARK: - Default wiring

    func testMakeDefaultWiresRealSourcesWithoutTouchingThem() {
        let provider = CompositeQuotaProvider.makeDefault(session: StubURLProtocol.makeSession())

        XCTAssertTrue(provider.statuslineSource is StatuslineCacheReader)
        XCTAssertTrue(provider.oauthSource is OAuthUsageClient)
        XCTAssertNil(provider.localEstimateSource)
        XCTAssertEqual(provider.stalenessThreshold, QuotaSnapshot.defaultStalenessThreshold)
    }
}
