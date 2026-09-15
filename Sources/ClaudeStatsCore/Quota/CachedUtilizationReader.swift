import Foundation
import os

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
/// ``QuotaScopedLimit``. `accountUuid` names the account these numbers describe
/// and becomes ``QuotaSnapshot/account``, filled out with the email and
/// organisation name from the file's sibling `oauthAccount` object when the two
/// agree on the uuid (and taken from `oauthAccount` outright on an older
/// payload that carries no `accountUuid`). A mismatch keeps the reading's own
/// uuid and nothing else: the cached numbers are the previous login's, and
/// labelling them with the current login's organisation is exactly the
/// mislabelling this app is trying to stop.
///
/// The sibling `spend` object (cross-checked against `extra_usage`) becomes
/// ``QuotaSnapshot/usageCredits`` — money, not a percentage, and on its own
/// parse path rather than through `limits[]`, which never carries it. It is
/// absent far more often than not, and that is not a failure — see
/// ``UsageCredits`` and ``QuotaJSON/usageCredits(in:)``.
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
/// ## Reading cost
///
/// Same fingerprint gate as ``ActiveAccountReader`` and
/// ``RateLimitPromoNoticeReader``: the file is ~170 KB, and
/// ``FreshestQuotaProvider`` asks this reader for usage credits on every poll
/// whose hook reading carries none (the common case — `spend.enabled` is
/// usually `false`). An unchanged file costs one `open` and one `fstat`, and the
/// values extracted from the last parse are served from memory. Staleness is
/// still judged against the clock on every call, so a reading that stops
/// changing still ages out.
///
/// ## Undocumented private state
///
/// This key is another program's internals and can be renamed or dropped by any
/// Claude Code release — a `spend` object appeared inside this very payload
/// between 2026-08-27 and 2026-08-28. That is why the statusline path is kept
/// alongside it rather than deleted; see ``FreshestQuotaProvider``.
public struct CachedUtilizationReader: QuotaProviding {
    /// Top-level key in `~/.claude.json`. Shared with ``ActiveAccountReader``,
    /// which reads the same blob for the mislabel guard's reference.
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
    /// The last parse and the fingerprint of the bytes it read — see
    /// ``loadUtilization()``. Shared by every copy of this value, like
    /// ``ActiveAccountReader``'s.
    private let cache = OSAllocatedUnfairLock<Cached?>(initialState: nil)

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
        let parsed = try loadUtilization()

        // Each window can be independently absent — Claude Code stops reporting
        // one once it has rolled over — and an absent one stays absent on the
        // snapshot rather than becoming 0%. Only *both* missing means this
        // source has nothing to say.
        guard parsed.fiveHour != nil || parsed.sevenDay != nil else {
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        // No fallback to the file's mtime, let alone to `now()`: Claude Code
        // rewrites `~/.claude.json` constantly for unrelated keys, so its mtime
        // would report a months-old reading as seconds fresh. `fetchedAtMs` is
        // the only honest age signal here, and without it the age is unknown.
        guard let capturedAt = parsed.capturedAt else {
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        let snapshot = QuotaSnapshot(
            fiveHour: parsed.fiveHour,
            sevenDay: parsed.sevenDay,
            confidence: .cachedOfficial,
            capturedAt: capturedAt,
            scopedWeekly: parsed.scopedWeekly,
            usageCredits: parsed.credits.credits,
            usageCreditsDisabledReason: parsed.credits.disabledReason,
            account: parsed.account
        )

        // Judged against the clock on every call, cached parse or not: an
        // unchanged file is exactly how a reading goes stale.
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
    /// current. Bypassing staleness does not mean bypassing whose numbers
    /// these are, though — see ``matchesActiveAccount(root:cached:)``.
    public func currentScopedWeekly() async throws -> [QuotaScopedLimit] {
        let parsed = try loadUtilization()
        guard parsed.matchesActiveAccount else { return [] }
        return parsed.scopedWeekly
    }

    /// Same payload as ``currentSnapshot()``, never gated on staleness — the
    /// usage-credits half of ``currentScopedWeekly()``, and for the same
    /// reason: `spend` is this source's alone (the statusline payload has no
    /// such object), so a stale blob must not take the credits row down while
    /// the hook keeps the account-wide numbers current. A month-long spend
    /// total an hour behind is still the right number to show — as long as
    /// it's this account's total; see ``matchesActiveAccount(root:cached:)``.
    public func currentUsageCredits() async throws -> UsageCreditsReading {
        let parsed = try loadUtilization()
        guard parsed.matchesActiveAccount else { return .unavailable }
        return parsed.credits
    }

    /// Which account the cached numbers describe — see the type's note on
    /// `accountUuid`.
    static func account(root: [String: Any], cached: [String: Any]) -> QuotaAccount? {
        let loggedIn = QuotaJSON.object(root[ActiveAccountReader.oauthAccountKey])
            .flatMap(QuotaAccount.init(json:))
        // The reading's own uuid wins: it says whose numbers these are, where
        // `oauthAccount` only says who is logged in *now*.
        guard let readingUuid = QuotaAccount(json: cached)?.uuid else { return loggedIn }
        if let loggedIn, loggedIn.uuid == readingUuid { return loggedIn }
        return QuotaAccount(uuid: readingUuid)
    }

    /// Whether the cached blob's own account agrees with who is logged in
    /// now. ``currentScopedWeekly()`` and ``currentUsageCredits()`` bypass
    /// staleness on purpose, but must not also bypass whose numbers these
    /// are: a blob left over from the previous login would otherwise graft
    /// its scoped rows or spend onto the current login's bars. With nothing
    /// to compare (either side missing a uuid) there is no known mismatch to
    /// block on.
    private static func matchesActiveAccount(root: [String: Any], cached: [String: Any]) -> Bool {
        guard let loggedInUuid = QuotaJSON.object(root[ActiveAccountReader.oauthAccountKey])
            .flatMap(QuotaAccount.init(json:))?.uuid,
            let readingUuid = QuotaAccount(json: cached)?.uuid
        else { return true }
        return loggedInUuid == readingUuid
    }

    // MARK: - Reading the file

    /// Everything the three public reads want out of one parse of the state
    /// file, extracted into typed values so it can outlive the parse behind
    /// the fingerprint gate. Nothing here depends on the clock — staleness is
    /// applied by ``currentSnapshot()`` on every call.
    private struct Parsed: Sendable {
        let fiveHour: QuotaWindow?
        let sevenDay: QuotaWindow?
        /// `fetchedAtMs`; `nil` when the blob carries no usable stamp.
        let capturedAt: Date?
        let scopedWeekly: [QuotaScopedLimit]
        let credits: UsageCreditsReading
        let account: QuotaAccount?
        let matchesActiveAccount: Bool
    }

    /// What one parse of the file concluded, cached against the fingerprint of
    /// the bytes it parsed.
    private enum Outcome: Sendable {
        case parsed(Parsed)
        /// The file is valid JSON but has no `cachedUsageUtilization.utilization`
        /// — cached too, so a machine that has never had a rate-limited response
        /// doesn't re-parse 170 KB on every poll to find that out again.
        case missingUtilization
    }

    private struct Cached: Sendable {
        var fingerprint: ClaudeStateFileFingerprint
        var outcome: Outcome
    }

    /// Loads and unwraps `cachedUsageUtilization.utilization`, common to
    /// ``currentSnapshot()``, ``currentScopedWeekly()`` and
    /// ``currentUsageCredits()``. Neither the windows nor `fetchedAtMs` are
    /// required here — callers that need them check separately, since the two
    /// staleness-bypassing readers don't.
    ///
    /// Behind ``ClaudeStateFile``'s fingerprint gate, like
    /// ``ActiveAccountReader``: ``FreshestQuotaProvider`` asks for the credits
    /// on every poll whose hook reading has none, and without the gate each of
    /// those was a full parse of an unchanged file.
    private func loadUtilization() throws -> Parsed {
        let previous = cache.withLock { $0 }
        let outcome: Outcome
        switch ClaudeStateFile.load(candidates: candidateURLs, unchangedSince: previous?.fingerprint) {
        case .unchanged:
            // Only ever returned against `previous`'s fingerprint, so it is set.
            guard let previous else { throw ClaudeStatsError.noQuotaSourceAvailable }
            outcome = previous.outcome
        case .loaded(let root, let fingerprint):
            outcome = Self.outcome(in: root)
            cache.withLock { $0 = Cached(fingerprint: fingerprint, outcome: outcome) }
        case .malformed:
            // Present but corrupt — distinct from "Claude Code has never
            // cached a reading", and the only shape of this the user could
            // plausibly act on. The fingerprint is dropped with it, as for
            // `.unavailable`, so the next poll looks again.
            cache.withLock { $0 = nil }
            throw ClaudeStatsError.unexpectedQuotaResponse(
                "\(ClaudeConfigDirectory.stateFileName) is not a JSON object"
            )
        case .unavailable:
            cache.withLock { $0 = nil }
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        switch outcome {
        case .parsed(let parsed):
            return parsed
        case .missingUtilization:
            // Every one of these is "Claude Code hasn't cached usage for this
            // account yet" (a fresh install, or a plan with no rate-limit
            // windows), not a fault: the key is absent on machines that have
            // never had a rate-limited response.
            throw ClaudeStatsError.noQuotaSourceAvailable
        }
    }

    private static func outcome(in root: [String: Any]) -> Outcome {
        guard let cached = QuotaJSON.object(root[cachedUtilizationKey]),
            let utilization = QuotaJSON.object(cached[utilizationKey])
        else {
            return .missingUtilization
        }
        let windows = QuotaJSON.optionalWindows(in: utilization)
        return .parsed(
            Parsed(
                fiveHour: windows.fiveHour,
                sevenDay: windows.sevenDay,
                capturedAt: QuotaJSON.capturedAtKeys.lazy.compactMap({ QuotaJSON.date(cached[$0]) }).first,
                scopedWeekly: QuotaJSON.scopedLimits(in: utilization),
                credits: QuotaJSON.usageCredits(in: utilization),
                account: account(root: root, cached: cached),
                matchesActiveAccount: matchesActiveAccount(root: root, cached: cached)
            )
        )
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
