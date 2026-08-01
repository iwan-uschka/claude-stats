import Foundation

/// Polls Claude Code's undocumented account usage endpoint
/// (`.experimental` confidence).
///
/// ```
/// GET https://api.anthropic.com/api/oauth/usage
/// Authorization: Bearer <token from ClaudeOAuthTokenStore>
/// anthropic-beta: oauth-2025-04-20
/// ```
///
/// Observed response shape:
///
/// ```json
/// {
///   "five_hour": { "utilization": 8.0,  "resets_at": "2026-01-22T09:00:00Z" },
///   "seven_day": { "utilization": 77.0, "resets_at": "2026-01-22T19:00:00Z" },
///   "seven_day_sonnet": { "utilization": 0.0, "resets_at": "..." },
///   "extra_usage": { "is_enabled": false }
/// }
/// ```
///
/// Note the differences from the statusline payload: `utilization` rather than
/// `used_percentage`, and an ISO-8601 `resets_at` rather than epoch seconds.
/// ``QuotaJSON`` absorbs both, and also tolerates the windows being moved under a
/// `rate_limits`/`usage`/`data` wrapper.
///
/// Unlike the statusline cache this works whether or not Claude Code is running,
/// and is account-wide (so it already includes phone, web, and AFK container
/// usage). It is also undocumented: it can break or start rejecting this client
/// without notice, and it is known to rate-limit aggressively — poll sparingly
/// and never treat a failure here as fatal.
public struct OAuthUsageClient: QuotaProviding {
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeaderName = "anthropic-beta"
    public static let betaHeaderValue = "oauth-2025-04-20"

    public let endpoint: URL
    private let tokenStore: OAuthTokenProviding
    private let session: URLSession
    private let now: @Sendable () -> Date

    /// - Parameter session: injected so tests can supply a `URLSession` backed by
    ///   a stub `URLProtocol` and never touch the network.
    public init(
        tokenStore: OAuthTokenProviding = ClaudeOAuthTokenStore.makeDefault(),
        session: URLSession = .shared,
        endpoint: URL = OAuthUsageClient.defaultEndpoint,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tokenStore = tokenStore
        self.session = session
        self.endpoint = endpoint
        self.now = now
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        // Throws .missingCredentials — never includes the token in the error.
        let token = try tokenStore.accessToken()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeaderValue, forHTTPHeaderField: Self.betaHeaderName)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Transport failures (offline, DNS, timeout) propagate as URLError.
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeStatsError.unexpectedQuotaResponse("oauth/usage: non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw ClaudeStatsError.unexpectedQuotaResponse("oauth/usage: HTTP \(http.statusCode)")
        }
        let root: [String: Any]
        do {
            guard let parsed = QuotaJSON.object(try JSONSerialization.jsonObject(with: data)) else {
                throw ClaudeStatsError.unexpectedQuotaResponse("oauth/usage: body is not a JSON object")
            }
            root = parsed
        } catch let error as ClaudeStatsError {
            throw error
        } catch {
            throw ClaudeStatsError.unexpectedQuotaResponse("oauth/usage: JSON decode failed: \(error)")
        }
        guard let windows = QuotaJSON.windows(in: root) else {
            throw ClaudeStatsError.unexpectedQuotaResponse(
                "oauth/usage: no five_hour or seven_day window in response"
            )
        }

        return QuotaSnapshot(
            fiveHour: windows.fiveHour,
            sevenDay: windows.sevenDay,
            confidence: .experimental,
            capturedAt: now()
        )
    }
}
