import Foundation

/// Adapts a closure to ``QuotaProviding``.
///
/// Exists so ``CompositeQuotaProvider`` can take a local-estimate source without
/// anyone having to declare a type for it — the tier-1 log parser can hand over a
/// closure over its in-memory index.
public struct ClosureQuotaProvider: QuotaProviding {
    private let body: @Sendable () async throws -> QuotaSnapshot

    public init(_ body: @escaping @Sendable () async throws -> QuotaSnapshot) {
        self.body = body
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        try await body()
    }
}

/// Layers the quota sources by confidence, highest first.
///
/// Order is fixed: fresh statusline cache (`.official`) → `oauth/usage` poll
/// (`.experimental`) → local-log estimate (`.localEstimate`). The first source
/// that returns a usable snapshot wins; a tier not being configured is expected
/// and silent, but any other failure is logged before moving to the next tier.
///
/// "Usable" means non-stale for the two live tiers: a snapshot older than
/// ``stalenessThreshold`` is discarded even if the source handed it over, because
/// a cold reading of the account-wide window is worse than a current local
/// estimate. The local-estimate tier is exempt — it is the last resort, and it
/// timestamps itself from local logs that may legitimately have no recent
/// activity.
///
/// Every tier is optional, and the local-estimate tier is injected as a plain
/// ``QuotaProviding`` (or a closure via ``ClosureQuotaProvider``) so this type
/// has no dependency on the log-parsing implementation.
public struct CompositeQuotaProvider: QuotaProviding {
    /// Tier 1: fresh `statusLine` hook capture. See ``StatuslineCacheReader``.
    public let statuslineSource: QuotaProviding?
    /// Tier 2: undocumented usage endpoint. See ``OAuthUsageClient``.
    public let oauthSource: QuotaProviding?
    /// Tier 3: math over local JSONL. Supplied by the caller; never stale-checked.
    public let localEstimateSource: QuotaProviding?
    /// Maximum accepted age for a live-tier snapshot.
    public let stalenessThreshold: TimeInterval

    private let now: @Sendable () -> Date

    public init(
        statuslineSource: QuotaProviding? = nil,
        oauthSource: QuotaProviding? = nil,
        localEstimateSource: QuotaProviding? = nil,
        stalenessThreshold: TimeInterval = QuotaSnapshot.defaultStalenessThreshold,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.statuslineSource = statuslineSource
        self.oauthSource = oauthSource
        self.localEstimateSource = localEstimateSource
        self.stalenessThreshold = stalenessThreshold
        self.now = now
    }

    /// Convenience init taking the local estimate as a closure.
    public init(
        statuslineSource: QuotaProviding? = nil,
        oauthSource: QuotaProviding? = nil,
        stalenessThreshold: TimeInterval = QuotaSnapshot.defaultStalenessThreshold,
        now: @escaping @Sendable () -> Date = { Date() },
        localEstimate: @escaping @Sendable () async throws -> QuotaSnapshot
    ) {
        self.init(
            statuslineSource: statuslineSource,
            oauthSource: oauthSource,
            localEstimateSource: ClosureQuotaProvider(localEstimate),
            stalenessThreshold: stalenessThreshold,
            now: now
        )
    }

    /// The standard production wiring: real statusline cache, real OAuth poll,
    /// plus whatever local estimator tier 1 provides.
    public static func makeDefault(
        localEstimateSource: QuotaProviding? = nil,
        session: URLSession = .shared
    ) -> CompositeQuotaProvider {
        CompositeQuotaProvider(
            statuslineSource: StatuslineCacheReader(),
            oauthSource: OAuthUsageClient(session: session),
            localEstimateSource: localEstimateSource
        )
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        for source in [statuslineSource, oauthSource] {
            guard let source else { continue }
            let snapshot: QuotaSnapshot
            do {
                snapshot = try await source.currentSnapshot()
            } catch {
                if !Self.isExpectedTierAbsence(error) {
                    print("[ClaudeStats] quota source \(type(of: source)) unavailable: \(error)")
                }
                continue
            }
            guard !snapshot.isStale(asOf: now(), threshold: stalenessThreshold) else {
                print("[ClaudeStats] quota source \(type(of: source)) returned a stale snapshot (captured \(snapshot.capturedAt))")
                continue
            }
            return snapshot
        }

        if let localEstimateSource {
            do {
                return try await localEstimateSource.currentSnapshot()
            } catch {
                print("[ClaudeStats] local-estimate quota source unavailable: \(error)")
            }
        }

        throw ClaudeStatsError.noQuotaSourceAvailable
    }

    /// `.noQuotaSourceAvailable` / `.missingCredentials` are the documented
    /// "tier not configured" sentinels — expected, not diagnostic.
    private static func isExpectedTierAbsence(_ error: Error) -> Bool {
        switch error {
        case ClaudeStatsError.noQuotaSourceAvailable, ClaudeStatsError.missingCredentials:
            return true
        default:
            return false
        }
    }
}
