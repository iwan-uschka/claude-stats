import Foundation

/// Source of live account-wide quota percentages (tier 2 of the data layer).
///
/// Implementations are expected to be one of:
/// - a `statusLine`-hook reader (writes/reads a disk cache; `.official`),
/// - a poller for the undocumented `oauth/usage` endpoint (`.experimental`),
/// - a local-logs estimator (`.localEstimate`),
/// - or a composite that picks the highest-confidence non-stale source.
///
/// `async` because the real implementations do network or file I/O.
public protocol QuotaProviding: Sendable {
    /// The most recent reading available. Implementations may return a cached
    /// snapshot — callers check ``QuotaSnapshot/isStale(asOf:threshold:)``.
    func currentSnapshot() async throws -> QuotaSnapshot
}

/// Aggregated local-log statistics (tier 1 of the data layer).
///
/// All members are synchronous: implementations are expected to serve from an
/// in-memory index that the FSEvents watcher keeps up to date, so no call here
/// should block on I/O.
public protocol UsageStoring: Sendable {
    /// Per-entrypoint token counts for the given rolling window.
    func entrypointBreakdown(for window: TimeWindow) throws -> EntrypointBreakdown

    /// Per-model tokens and cost.
    /// - Parameter last24h: `true` for the popover's fixed 24-hour "By model"
    ///   section; `false` for all locally-known history.
    func modelUsage(last24h: Bool) throws -> [ModelUsage]

    /// Current consumption rate in tokens per hour.
    func burnRatePerHour() throws -> Double

    /// Estimated spend in USD since local midnight.
    func estimatedCostToday() throws -> Double

    /// Plan tier inferred from local history.
    func detectedPlanTier() throws -> PlanTier
}

/// Errors surfaced by the data layer.
public enum ClaudeStatsError: Error, Sendable, Equatable {
    /// No Claude config directory found (`$CLAUDE_CONFIG_DIR`, `~/.config/claude`, `~/.claude`).
    case configDirectoryNotFound
    /// A JSONL line could not be decoded.
    case malformedLogLine(path: String, line: Int)
    /// No live quota source produced a usable reading.
    case noQuotaSourceAvailable
    /// Credentials for the OAuth usage endpoint are missing or unreadable.
    case missingCredentials
    /// The quota source responded, but not with something we can parse.
    case unexpectedQuotaResponse(String)
}
