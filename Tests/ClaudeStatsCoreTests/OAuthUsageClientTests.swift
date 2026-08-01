import XCTest
@testable import ClaudeStatsCore

/// No test here performs real network I/O (every request is served by
/// ``StubURLProtocol``) or reads the real credentials file / Keychain (the token
/// comes from ``StubTokenStore``, except in the explicitly path-injected
/// ``FileOAuthTokenStore`` tests, which use a temp directory).
final class OAuthUsageClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(tokenStore: OAuthTokenProviding = StubTokenStore()) -> OAuthUsageClient {
        let fixedNow = now
        return OAuthUsageClient(
            tokenStore: tokenStore,
            session: StubURLProtocol.makeSession(),
            endpoint: endpoint,
            now: { fixedNow }
        )
    }

    /// The shape observed from the live endpoint: `utilization` + ISO-8601
    /// `resets_at`, plus extra keys we ignore.
    private let successBody = """
    {
      "five_hour":        { "utilization": 8.0,  "resets_at": "2027-01-22T09:00:00Z" },
      "seven_day":        { "utilization": 77.0, "resets_at": "2027-01-22T19:00:00Z" },
      "seven_day_sonnet": { "utilization": 0.0,  "resets_at": "2027-01-25T00:00:00Z" },
      "extra_usage":      { "is_enabled": false }
    }
    """

    // MARK: - Success

    func testSuccessfulResponseParsesIntoExperimentalSnapshot() async throws {
        StubURLProtocol.respond(statusCode: 200, body: successBody)

        let snapshot = try await makeClient().currentSnapshot()

        XCTAssertEqual(snapshot.confidence, .experimental)
        XCTAssertEqual(snapshot.fiveHour.percentUsed, 8.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.sevenDay.percentUsed, 77.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.capturedAt, now)
        XCTAssertEqual(
            snapshot.fiveHour.resetsAt,
            ISO8601DateFormatter().date(from: "2027-01-22T09:00:00Z")
        )
        XCTAssertEqual(snapshot.fiveHour.fractionUsed, 0.08, accuracy: 0.0001)
    }

    func testRequestCarriesBearerTokenAndBetaHeader() async throws {
        StubURLProtocol.respond(statusCode: 200, body: successBody)
        _ = try await makeClient(tokenStore: StubTokenStore(token: "stub-token")).currentSnapshot()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stub-token")
    }

    /// Tolerate a future rename: windows nested under a wrapper, spelled the way
    /// the statusline payload spells them.
    func testAlternateResponseShapeIsTolerated() async throws {
        StubURLProtocol.respond(statusCode: 200, body: """
        {
          "rate_limits": {
            "five_hour": { "used_percentage": 12, "resets_at": 1900000000 },
            "seven_day": { "used_percentage": 34, "resets_at": 1900500000 }
          }
        }
        """)

        let snapshot = try await makeClient().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour.percentUsed, 12)
        XCTAssertEqual(snapshot.sevenDay.percentUsed, 34)
        XCTAssertEqual(snapshot.fiveHour.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testPartialResponseFillsMissingWindowWithEmpty() async throws {
        StubURLProtocol.respond(statusCode: 200, body: #"{ "five_hour": { "utilization": 5 } }"#)

        let snapshot = try await makeClient().currentSnapshot()

        XCTAssertEqual(snapshot.fiveHour.percentUsed, 5)
        XCTAssertEqual(snapshot.sevenDay, .empty)
    }

    // MARK: - Missing credentials

    func testMissingCredentialsThrowsBeforeAnyRequestIsMade() async throws {
        StubURLProtocol.respond(statusCode: 200, body: successBody)

        await assertThrows(.missingCredentials) {
            try await self.makeClient(tokenStore: StubTokenStore(token: nil)).currentSnapshot()
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "must not hit the network without a token")
    }

    func testFileTokenStoreThrowsMissingCredentialsWhenFileAbsent() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)/.credentials.json")
        let store = FileOAuthTokenStore(url: missing)

        XCTAssertThrowsError(try store.accessToken()) { error in
            XCTAssertEqual(error as? ClaudeStatsError, .missingCredentials)
        }
    }

    func testFileTokenStoreReadsDocumentedKeyPath() throws {
        let url = try writeTempCredentials(#"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":1900000000}}"#)
        XCTAssertEqual(try FileOAuthTokenStore(url: url).accessToken(), "tok-abc")
    }

    func testFileTokenStoreToleratesAlternateKeyPaths() throws {
        let cases: [(String, String)] = [
            (#"{"claudeAiOauth":{"access_token":"snake"}}"#, "snake"),
            (#"{"accessToken":"flat"}"#, "flat"),
            (#"{"oauth":{"accessToken":"nested"}}"#, "nested"),
            // Not in the known list — found by the recursive fallback.
            (#"{"accounts":{"default":{"access_token":"deep"}}}"#, "deep"),
        ]
        for (json, expected) in cases {
            let url = try writeTempCredentials(json)
            XCTAssertEqual(try FileOAuthTokenStore(url: url).accessToken(), expected, json)
        }
    }

    func testFileTokenStoreRejectsCredentialsWithoutAnyToken() throws {
        let url = try writeTempCredentials(#"{"claudeAiOauth":{"refreshToken":"nope","scopes":[]}}"#)
        XCTAssertThrowsError(try FileOAuthTokenStore(url: url).accessToken()) { error in
            XCTAssertEqual(error as? ClaudeStatsError, .missingCredentials)
        }
    }

    func testChainedStoreFallsThroughToTheSecondStore() throws {
        let chain = ChainedOAuthTokenStore([StubTokenStore(token: nil), StubTokenStore(token: "second")])
        XCTAssertEqual(try chain.accessToken(), "second")

        let empty = ChainedOAuthTokenStore([StubTokenStore(token: nil), StubTokenStore(token: nil)])
        XCTAssertThrowsError(try empty.accessToken()) { error in
            XCTAssertEqual(error as? ClaudeStatsError, .missingCredentials)
        }
    }

    // MARK: - Bad responses

    func testNon200StatusThrowsUnexpectedQuotaResponseIncludingTheCode() async throws {
        // 429 is the documented failure mode for this endpoint.
        StubURLProtocol.respond(statusCode: 429, body: #"{"error":"rate_limited"}"#)

        let message = await assertThrowsUnexpectedQuotaResponse {
            try await self.makeClient().currentSnapshot()
        }
        XCTAssertEqual(message, "oauth/usage: HTTP 429")
    }

    func testUnauthorizedStatusThrowsUnexpectedQuotaResponse() async throws {
        StubURLProtocol.respond(statusCode: 401, body: "")
        let message = await assertThrowsUnexpectedQuotaResponse {
            try await self.makeClient().currentSnapshot()
        }
        XCTAssertEqual(message, "oauth/usage: HTTP 401")
    }

    func testMalformedJSONThrowsUnexpectedQuotaResponse() async throws {
        StubURLProtocol.respond(statusCode: 200, body: "<html>nope</html>")
        let message = await assertThrowsUnexpectedQuotaResponse {
            try await self.makeClient().currentSnapshot()
        }
        XCTAssertEqual(message, "oauth/usage: body is not a JSON object")
    }

    func testJSONWithoutAnyWindowThrowsUnexpectedQuotaResponse() async throws {
        StubURLProtocol.respond(statusCode: 200, body: #"{"extra_usage":{"is_enabled":true}}"#)
        let message = await assertThrowsUnexpectedQuotaResponse {
            try await self.makeClient().currentSnapshot()
        }
        XCTAssertEqual(message, "oauth/usage: no five_hour or seven_day window in response")
    }

    // MARK: - Transport

    func testNetworkErrorsPropagateRatherThanBecomingQuotaErrors() async throws {
        StubURLProtocol.failTransport(with: URLError(.notConnectedToInternet))

        do {
            _ = try await makeClient().currentSnapshot()
            XCTFail("expected a URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("expected URLError, got \(error)")
        }
    }

    // MARK: - Helpers

    private func writeTempCredentials(_ json: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAuthUsageClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".credentials.json")
        try Data(json.utf8).write(to: url)
        return url
    }
}
