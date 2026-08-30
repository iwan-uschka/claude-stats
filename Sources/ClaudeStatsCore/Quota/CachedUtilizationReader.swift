import Foundation

/// Reads `cachedUsageUtilization` out of Claude Code's private state file
/// (`~/.claude.json`) — the same account-wide rate-limit numbers the statusline
/// hook carries, but written by Claude Code for its own use
/// (``QuotaConfidence/cachedOfficial``).
///
/// ## Why this exists
///
/// ``StatuslineCacheReader`` can only see what a status line render hands it,
/// which means it works at all only after the user has edited
/// `~/.claude/settings.json` to install our helper script. That install step
/// gated the entire quota tier: no hook, no bars. This source needs no setup —
/// Claude Code writes the blob itself, on every machine it has ever run on.
///
/// ## Shape
///
/// ```json
/// "cachedUsageUtilization": {
///   "fetchedAtMs": 1787813888696,
///   "accountUuid": "…",
///   "utilization": {
///     "five_hour": { "utilization": 11, "resets_at": "2026-08-28T16:50:00.401807+00:00" },
///     "seven_day": { "utilization": 97, "resets_at": "2026-08-28T23:00:00.401826+00:00" },
///     "seven_day_opus": null, "seven_day_sonnet": null, "limits": [ … ]
///   }
/// }
/// ```
///
/// The two typed windows are the source for the two main bars. `limits[]`
/// restates those same numbers in a flat form (`session` == `five_hour`,
/// `weekly_all` == `seven_day`) — both kinds are deliberately skipped here, so
/// they can't duplicate or shadow the typed fields. Only its `weekly_scoped`
/// entries are read, each becoming a ``QuotaScopedLimit`` labelled from
/// `scope.model.display_name`:
///
/// ```json
/// { "kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
///   "resets_at": null, "is_active": false,
///   "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null } }
/// ```
///
/// What that `percent` is a share of is **not** documented — see
/// ``QuotaScopedLimit``. `accountUuid` is carried by the payload but unused —
/// there is nothing on this side to compare it against.
///
/// ## Staleness: 60 minutes, not the statusline's 10
///
/// This blob refreshes on Claude Code's own schedule, not ours: it was measured
/// 15 minutes old during an active session, and did not move across five
/// rewrites of `~/.claude.json` spanning 13 minutes — the file's churn is not a
/// usage refresh. A 10-minute threshold would therefore reject perfectly good
/// readings. A later observation put the gap much wider still: `fetchedAtMs`
/// sat unmoved for 3.7+ hours while three Claude Code sessions were actively
/// running, so the real cadence appears to be hours rather than minutes, at
/// least sometimes. 60 minutes remains a judgement call from those two
/// measurements, not a documented cadence — chosen to cut down on
/// false-positive staleness warnings during normal active use without
/// switching staleness detection off entirely.
///
/// ## Undocumented private state
///
/// This key is another program's internals and can be renamed or dropped by any
/// Claude Code release — a `spend` object appeared inside this very payload
/// between 2026-08-27 and 2026-08-28. That is why the statusline path is kept
/// alongside it rather than deleted; see ``FreshestQuotaProvider``.
public struct CachedUtilizationReader: QuotaProviding {
    /// Top-level key in `~/.claude.json`.
    static let cachedUtilizationKey = "cachedUsageUtilization"
    /// The nested object holding the per-window numbers.
    static let utilizationKey = "utilization"

    /// How old a `fetchedAtMs` may be before the reading is refused — see the
    /// type's "Staleness" note for why this is six times the statusline's.
    public static let defaultStalenessThreshold: TimeInterval = 60 * 60

    /// Probed in order; the first that opens wins.
    public let candidateURLs: [URL]
    public let stalenessThreshold: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        candidateURLs: [URL] = ClaudeConfigDirectory.stateFileCandidates(),
        stalenessThreshold: TimeInterval = CachedUtilizationReader.defaultStalenessThreshold,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.candidateURLs = candidateURLs
        self.stalenessThreshold = stalenessThreshold
        self.now = now
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        let (cached, utilization) = try loadUtilization()

        guard let windows = QuotaJSON.windows(in: utilization) else {
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        // No fallback to the file's mtime, let alone to `now()`: Claude Code
        // rewrites `~/.claude.json` constantly for unrelated keys, so its mtime
        // would report a months-old reading as seconds fresh. `fetchedAtMs` is
        // the only honest age signal here, and without it the age is unknown.
        guard let capturedAt = QuotaJSON.capturedAtKeys.lazy
            .compactMap({ QuotaJSON.date(cached[$0]) }).first
        else {
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        let snapshot = QuotaSnapshot(
            fiveHour: windows.fiveHour,
            sevenDay: windows.sevenDay,
            confidence: .cachedOfficial,
            capturedAt: capturedAt,
            scopedWeekly: QuotaJSON.scopedLimits(in: utilization)
        )

        guard !snapshot.isStale(asOf: now(), threshold: stalenessThreshold) else {
            throw ClaudeStatsError.staleQuotaSource(snapshot: snapshot, age: snapshot.age(asOf: now()))
        }
        return snapshot
    }

    /// Same payload as ``currentSnapshot()``, but never gated on staleness.
    ///
    /// See the protocol doc on ``QuotaProviding/currentScopedWeekly()`` for
    /// why: ``FreshestQuotaProvider`` wants this source's scoped rows even
    /// when its windows are too old to win the freshness compare, so a stale
    /// `cachedUsageUtilization` blob doesn't have to take the scoped bars down
    /// along with it while the statusline hook keeps the account-wide numbers
    /// current.
    public func currentScopedWeekly() async throws -> [QuotaScopedLimit] {
        let (_, utilization) = try loadUtilization()
        return QuotaJSON.scopedLimits(in: utilization)
    }

    /// Loads and unwraps `cachedUsageUtilization.utilization`, common to both
    /// ``currentSnapshot()`` and ``currentScopedWeekly()``. Neither the
    /// windows nor `fetchedAtMs` are required here — callers that need them
    /// check separately, since ``currentScopedWeekly()`` doesn't.
    private func loadUtilization() throws -> (cached: [String: Any], utilization: [String: Any]) {
        let root: [String: Any]
        // No fingerprint: a quota poll always wants the current numbers, and
        // the unchanged-since gate has nothing to hand back if it fires.
        switch ClaudeStateFile.load(candidates: candidateURLs, unchangedSince: nil) {
        case .loaded(let loaded, _):
            root = loaded
        case .malformed:
            // Present but corrupt — distinct from "Claude Code has never
            // cached a reading", and the only shape of this the user could
            // plausibly act on.
            throw ClaudeStatsError.unexpectedQuotaResponse(
                "\(ClaudeConfigDirectory.stateFileName) is not a JSON object"
            )
        case .unavailable, .unchanged:
            // `.unchanged` is unreachable — it is only ever returned against a
            // previous fingerprint, and this call passes none.
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        // Every one of these is "Claude Code hasn't cached usage for this
        // account yet" (a fresh install, or a plan with no rate-limit windows),
        // not a fault: the key is absent on machines that have never had a
        // rate-limited response.
        guard let cached = QuotaJSON.object(root[Self.cachedUtilizationKey]),
            let utilization = QuotaJSON.object(cached[Self.utilizationKey])
        else {
            throw ClaudeStatsError.noQuotaSourceAvailable
        }
        return (cached, utilization)
    }

    /// Deliberately does nothing.
    ///
    /// ``QuotaProviding/clearCache()`` is defined as discarding whatever state
    /// backs the source — but the state here is `~/.claude.json`, which belongs
    /// to Claude Code. Deleting or rewriting another program's live state file
    /// to refresh a percentage would take out its project map, command history
    /// and onboarding flags with it. The statusline cache, which this app does
    /// own, is still cleared — see ``FreshestQuotaProvider/clearCache()``.
    public func clearCache() throws {}
}
