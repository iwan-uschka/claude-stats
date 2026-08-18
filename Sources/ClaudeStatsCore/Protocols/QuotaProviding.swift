import Foundation

/// Source of live account-wide quota percentages (tier 2 of the data layer).
///
/// The only implementation is a `statusLine`-hook reader (writes/reads a disk
/// cache; `.official` confidence) — see ``StatuslineCacheReader``.
///
/// `async` because the real implementation does file I/O.
public protocol QuotaProviding: Sendable {
    /// The most recent reading available. Implementations may return a cached
    /// snapshot — callers check ``QuotaSnapshot/isStale(asOf:threshold:)``.
    func currentSnapshot() async throws -> QuotaSnapshot

    /// Discards whatever on-disk or cached state backs this source, so the next
    /// ``currentSnapshot()`` reflects only data written after this call.
    ///
    /// A manual escape hatch, not part of the normal refresh path: it exists for
    /// a reading that looks stuck or wrong, which a plain re-read of the same
    /// cache can't fix. Callers should expect
    /// ``ClaudeStatsError/noQuotaSourceAvailable`` from the next read until the
    /// source has reported again.
    func clearCache() throws
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

    /// Current consumption in the trailing hour, split by token kind.
    func burnRateUsagePerHour() throws -> TokenUsage

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
    /// No live quota source produced a usable reading — nothing installed, or
    /// a reading with no usable data at all. See ``staleQuotaSource(age:)``
    /// for the "installed, but hasn't reported recently" case.
    case noQuotaSourceAvailable
    /// A live quota source has a reading, but it's older than its staleness
    /// threshold — the source is installed and has worked before, it just
    /// hasn't reported since. `age` is how long ago it was captured.
    case staleQuotaSource(age: TimeInterval)
    /// The quota source responded, but not with something we can parse.
    case unexpectedQuotaResponse(String)

    /// `true` for ``staleQuotaSource(age:)`` — callers that want to treat it
    /// as a warning rather than a hard failure switch on this instead of
    /// pattern-matching the case directly.
    public var isStaleQuotaSource: Bool {
        if case .staleQuotaSource = self { return true }
        return false
    }
}

/// The popover's error banner reads ``LocalizedError/errorDescription``
/// (via ``Error/localizedDescription``) rather than the raw case — a bare
/// `String(describing:)` of `.noQuotaSourceAvailable` would just print
/// "noQuotaSourceAvailable".
extension ClaudeStatsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configDirectoryNotFound:
            return "Couldn't find Claude Code's config directory (~/.claude or $CLAUDE_CONFIG_DIR)."
        case .malformedLogLine(let path, let line):
            return "Couldn't parse line \(line) of \((path as NSString).lastPathComponent)."
        case .noQuotaSourceAvailable:
            return "No live quota data. Install the statusline hook in Settings → Quota source, or wait for it to report."
        case .staleQuotaSource(let age):
            return "Quota data is stale (hasn't reported in \(DisplayFormat.duration(age))). Open a terminal running Claude Code to refresh it."
        case .unexpectedQuotaResponse(let message):
            return "Quota source returned something unexpected: \(message)"
        }
    }
}
