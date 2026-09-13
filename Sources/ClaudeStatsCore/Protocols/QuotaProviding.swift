import Foundation

/// Source of live account-wide quota percentages (tier 2 of the data layer).
///
/// Two real implementations, both reporting Anthropic's own numbers:
/// ``StatuslineCacheReader`` (our `statusLine` hook's disk cache; `.official`,
/// opt-in, and the primary) and ``CachedUtilizationReader`` (Claude Code's own
/// cached blob in `~/.claude.json`; `.cachedOfficial`, needs no setup, and the
/// backup for machines where the hook isn't installed or has gone quiet).
/// ``FreshestQuotaProvider`` composes them and is what the app actually wires
/// up.
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
    /// is worse than none) but wrong for ``FreshestQuotaProvider``'s backfill:
    /// it wants a source's scoped rows even when that source's windows are too
    /// old to serve as the snapshot, so long as the *other* source is covering
    /// the account-wide numbers. A scoped row carries no freshness claim of its
    /// own to invalidate — see ``QuotaScopedLimit``.
    ///
    /// Both real implementations override this, because both can now report
    /// `weekly_scoped`: ``CachedUtilizationReader`` reads it out of
    /// `cachedUsageUtilization`, and ``StatuslineCacheReader`` reads the copy
    /// the helper script snapshots into its cache file. The default
    /// implementation just reads them off ``currentSnapshot()``, which stays
    /// correct for a source with no separate staleness gate to bypass.
    func currentScopedWeekly() async throws -> [QuotaScopedLimit]

    /// Best-effort usage credits, bypassing this source's own staleness gate —
    /// the money counterpart of ``currentScopedWeekly()``, existing for exactly
    /// the same reason: a month-to-date spend total an hour behind is still the
    /// right number to show, whatever the windows captured beside it are doing.
    ///
    /// Also overridden by both real implementations, and for the same reason —
    /// `spend` reaches ``StatuslineCacheReader`` through the same copy that
    /// brings it `weekly_scoped`. The default implementation reads it off
    /// ``currentSnapshot()``, which is right for a source with no separate gate
    /// to bypass.
    func currentUsageCredits() async throws -> UsageCreditsReading

    /// Latest reading for every account this source can see **other** than the
    /// active one, one merged snapshot each, newest capture first.
    ///
    /// Decoration, so unlike ``currentSnapshot()`` it never throws and is never
    /// gated on staleness: the popover renders each of these with its own
    /// freshness tag, and an account whose readings went cold is exactly the
    /// thing the user wants to see. An empty array is the normal answer — one
    /// account, or a source that cannot tell accounts apart at all, which is
    /// why the default implementation returns one.
    ///
    /// A group whose windows have all rolled over contributes nothing and is
    /// left out entirely: with no live window there is no row to draw, only a
    /// label over two "no reading" lines.
    func otherAccountSnapshots() async -> [QuotaSnapshot]

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

    public func currentUsageCredits() async throws -> UsageCreditsReading {
        let snapshot = try await currentSnapshot()
        return UsageCreditsReading(
            credits: snapshot.usageCredits,
            disabledReason: snapshot.usageCreditsDisabledReason
        )
    }

    public func otherAccountSnapshots() async -> [QuotaSnapshot] { [] }
}

/// The reference the mislabel guard compares a statusline reading against — see
/// ``StatuslineCacheReader`` for what it is guarding against and why.
///
/// Both fields come from the same `cachedUsageUtilization` blob, so they always
/// describe one account's one reading: the account Claude Code last fetched
/// usage for, and when that fetch said the 7-day window rolls over.
public struct ActiveAccountReference: Sendable, Hashable {
    /// `cachedUsageUtilization.accountUuid`, falling back to
    /// `oauthAccount.accountUuid` when the cached blob doesn't name one.
    public let accountUuid: String
    /// `cachedUsageUtilization.utilization.seven_day.resets_at`.
    public let sevenDayResetsAt: Date

    /// How far two spellings of the same instant may differ before they count
    /// as different windows.
    ///
    /// The two sources format the same timestamp differently — the statusline
    /// payload emits whole epoch seconds, `cachedUsageUtilization` an ISO-8601
    /// string with fractional seconds — so an exact compare would reject
    /// matching readings over sub-second rounding. A minute is far below the
    /// gap between two real 7-day windows (hours at the very least), so nothing
    /// foreign can hide inside it.
    public static let tolerance: TimeInterval = 60

    public init(accountUuid: String, sevenDayResetsAt: Date) {
        self.accountUuid = accountUuid
        self.sevenDayResetsAt = sevenDayResetsAt
    }
}

/// One read of "who is Claude Code logged in as right now".
public struct ActiveAccountReading: Sendable, Hashable {
    /// `oauthAccount` from the state file, or `nil` when the file is absent,
    /// unreadable, malformed, or simply carries no such object.
    public let account: QuotaAccount?
    /// The mislabel guard's reference, when the state file also holds a cached
    /// 7-day reading to compare against. `nil` disables the guard — with no
    /// reference, every reading is accepted.
    public let reference: ActiveAccountReference?

    public init(account: QuotaAccount? = nil, reference: ActiveAccountReference? = nil) {
        self.account = account
        self.reference = reference
    }

    /// Nothing known: the state file is absent, unreadable or says nothing
    /// about an account. Not an error — see ``ActiveAccountProviding``.
    public static let unknown = ActiveAccountReading()
}

/// Source of the account Claude Code is currently logged in as.
///
/// **Never throws**, for the same reason ``PromoNoticeProviding`` doesn't: the
/// answer is read out of another program's private state file, and every way it
/// can come up empty (no file, a Claude Code version that spells the key
/// differently, a half-written file) leaves the app in the state it was in
/// before accounts were modelled at all — one unknown account — rather than in
/// a failure the user could act on.
public protocol ActiveAccountProviding: Sendable {
    func readActiveAccount() -> ActiveAccountReading
}

/// The "we don't know" answer, used wherever the real reader is deliberately
/// not wired up.
///
/// This is the default for ``StatuslineCacheReader`` on purpose: a reader that
/// read `~/.claude.json` unless told otherwise would make every test that
/// constructs one touch the developer's real state file, which the suite's
/// stated rule forbids. ``FreshestQuotaProvider`` wires the real
/// ``ActiveAccountReader`` in, and that is the only path the app itself uses.
public struct UnknownAccountReader: ActiveAccountProviding {
    public init() {}
    public func readActiveAccount() -> ActiveAccountReading { .unknown }
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

    /// Per-entrypoint token counts for every window in `windows`, keyed by
    /// window. The default implementation calls ``entrypointBreakdown(for:)``
    /// once per window; ``LocalLogUsageStore`` overrides it to sum all of them
    /// in one pass over the widest window's events instead.
    func entrypointBreakdowns(for windows: [TimeWindow]) throws -> [TimeWindow: EntrypointBreakdown]

    /// Per-model tokens and cost.
    /// - Parameter last24h: `true` for the popover's fixed 24-hour "By model"
    ///   section; `false` for all locally-known history.
    func modelUsage(last24h: Bool) throws -> [ModelUsage]

    /// Estimated spend in USD since local midnight.
    func estimatedCostToday() throws -> Double
}

public extension UsageStoring {
    func entrypointBreakdowns(for windows: [TimeWindow]) throws -> [TimeWindow: EntrypointBreakdown] {
        var result: [TimeWindow: EntrypointBreakdown] = [:]
        for window in windows {
            result[window] = try entrypointBreakdown(for: window)
        }
        return result
    }
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
