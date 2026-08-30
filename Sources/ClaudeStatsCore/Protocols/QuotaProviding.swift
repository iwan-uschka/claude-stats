import Foundation

/// Source of live account-wide quota percentages (tier 2 of the data layer).
///
/// Two real implementations, both reporting Anthropic's own numbers:
/// ``CachedUtilizationReader`` (Claude Code's own cached blob in
/// `~/.claude.json`; `.cachedOfficial`, needs no setup) and
/// ``StatuslineCacheReader`` (our `statusLine` hook's disk cache; `.official`,
/// fresher but opt-in). ``FreshestQuotaProvider`` composes them and is what the
/// app actually wires up.
///
/// `async` because the real implementations do file I/O.
public protocol QuotaProviding: Sendable {
    /// The most recent reading available. Implementations may return a cached
    /// snapshot — callers check ``QuotaSnapshot/isStale(asOf:threshold:)``.
    func currentSnapshot() async throws -> QuotaSnapshot

    /// Best-effort per-model scoped limits, bypassing this source's own
    /// staleness gate.
    ///
    /// ``currentSnapshot()`` throws ``ClaudeStatsError/staleQuotaSource(snapshot:age:)``
    /// whole — a stale account-wide window and a stale scoped row are thrown
    /// out together, which is right for the two main bars (a wrong percentage
    /// is worse than none) but wrong for ``FreshestQuotaProvider``'s graft: it
    /// wants ``CachedUtilizationReader``'s scoped rows even when that source's
    /// windows are too old to serve as the winning snapshot, so long as the
    /// *other* source (the statusline hook) is covering the account-wide
    /// numbers. Default implementation just reads them off ``currentSnapshot()``,
    /// which is correct for a source with no separate staleness gate to bypass
    /// (``StatuslineCacheReader`` never populates ``QuotaSnapshot/scopedWeekly``
    /// at all, so this is `[]` there either way).
    func currentScopedWeekly() async throws -> [QuotaScopedLimit]

    /// Discards whatever on-disk or cached state backs this source, so the next
    /// ``currentSnapshot()`` reflects only data written after this call.
    ///
    /// A manual escape hatch, not part of the normal refresh path: it exists for
    /// a reading that looks stuck or wrong, which a plain re-read of the same
    /// cache can't fix. For a source that composes multiple readers (see
    /// ``FreshestQuotaProvider``), this only guarantees *this* source's own
    /// state is discarded — another composed source may still produce a
    /// reading on the next call.
    func clearCache() throws
}

extension QuotaProviding {
    public func currentScopedWeekly() async throws -> [QuotaScopedLimit] {
        try await currentSnapshot().scopedWeekly
    }
}

/// Outcome of one promo-notice read.
///
/// There is no failure case on purpose — see ``PromoNoticeProviding``.
public enum PromoNoticeReadResult: Sendable, Hashable {
    /// The state file is byte-for-byte what the caller last parsed; it should
    /// keep whatever notices it already has.
    case unchanged
    /// A completed read. `notices` is empty when there is nothing to show —
    /// no file, unreadable file, no promo key, or a flag cache too old to
    /// trust. `fingerprint` is `nil` when nothing could be read at all, so the
    /// next call retries rather than latching onto a state that never existed.
    case read(notices: [RateLimitPromoNotice], fingerprint: ClaudeStateFileFingerprint?)
}

/// Source of the promo notices Claude Code caches in its own state file.
///
/// **Never throws.** Absent, unreadable, malformed or stale all mean "no
/// promo", which is the overwhelmingly common case and not something the user
/// could act on. A deliberate divergence from ``QuotaProviding``, whose errors
/// *are* the point: a missing quota source is the difference between a number
/// and no number, whereas a missing promo line is the normal state of the app.
///
/// Synchronous: the gated path is one `open` plus one `fstat`, and the ungated
/// path is a low-single-digit-millisecond parse.
public protocol PromoNoticeProviding: Sendable {
    /// Reads the notices, skipping the parse when the backing file still
    /// matches `previous`.
    func read(unchangedSince previous: ClaudeStateFileFingerprint?) -> PromoNoticeReadResult
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
    /// No live quota source produced a usable reading — Claude Code has never
    /// cached one on this Mac, or every source returned data with no usable
    /// windows in it. See ``staleQuotaSource(snapshot:age:)`` for the "has
    /// reported before, but not recently" case.
    case noQuotaSourceAvailable
    /// A live quota source has a reading, but it's older than its staleness
    /// threshold — the source is installed and has worked before, it just
    /// hasn't reported since. `age` is how long ago it was captured.
    ///
    /// `snapshot` is the reading that was rejected, carried along rather than
    /// discarded: a caller with nothing else on screen (a cold start, where no
    /// earlier poll ever succeeded) can show these old numbers instead of empty
    /// bars, and ``errorDescription`` reads its
    /// ``QuotaSnapshot/confidence`` to pick the right remediation text.
    case staleQuotaSource(snapshot: QuotaSnapshot, age: TimeInterval)
    /// The quota source responded, but not with something we can parse.
    case unexpectedQuotaResponse(String)

    /// `true` for ``staleQuotaSource(snapshot:age:)`` — callers that want to treat it
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
            return "No live quota data yet. Claude Code hasn't cached a rate-limit reading on this Mac — run it once, and the percentages appear on the next refresh."
        case .staleQuotaSource(let snapshot, let age):
            // The remediation differs by source: the statusline hook really is
            // driven by a terminal rendering a status line, but Claude Code's
            // own cache refreshes on its own schedule and having a terminal
            // open does nothing for it.
            let ageText = DisplayFormat.duration(age)
            switch snapshot.confidence {
            case .official:
                return "Quota data is stale (hasn't reported in \(ageText)). Open a terminal running Claude Code to refresh it."
            case .cachedOfficial:
                return "Quota data is stale (hasn't reported in \(ageText)). Claude Code hasn't refreshed its own usage cache yet — this isn't triggered by having a terminal open, and can take a while."
            }
        case .unexpectedQuotaResponse(let message):
            return "Quota source returned something unexpected: \(message)"
        }
    }
}
