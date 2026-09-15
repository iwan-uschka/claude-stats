import Foundation

/// Serves the statusline hook's reading, falling back to Claude Code's own
/// cached blob whenever the hook has nothing to say — so neither source being
/// unavailable can take the bars down.
///
/// ## Primary and backup, not a freshness race
///
/// ``StatuslineCacheReader`` is the primary. It is the only source this app
/// actually writes: the hook fires within seconds of a status line render, and
/// — since the helper script learned to copy `cachedUsageUtilization.utilization`
/// across as it goes — carries all four bars' worth of data. Each running
/// Claude Code session writes its own cache file, stamped with the time *that
/// file* was written, and the reader merges them per window: a session that
/// has been idle for hours can no longer restamp its own stale numbers as
/// captured "now" and overwrite a busy session's. What reaches this type is
/// the merged result, dated by the newest file that contributed to it.
///
/// ``CachedUtilizationReader`` is the backup, and it stays a full-fidelity one:
/// it reads the same account-wide windows plus the scoped rows and `spend`
/// natively, needs no setup at all, and covers every machine where the hook was
/// never installed, has never fired, or has gone quiet. Whichever of the two
/// survives an upstream change keeps the bars lit — the cached key is
/// undocumented private state that any Claude Code release can rename (a
/// `spend` object appeared inside it between 2026-08-27 and 2026-08-28), while
/// the statusline payload has a much longer track record.
///
/// This used to be a freshness compare — newer `capturedAt` wins, ties to the
/// hook — which was the right rule while the hook could only report two of the
/// four bars and the rest had to be grafted on unconditionally. Now that a hook
/// reading is complete on its own, comparing ages would only ever pick the
/// less-trustworthy source's numbers on the strength of a timestamp neither
/// source is obliged to keep moving. So the hook wins outright when it
/// succeeds, and `cachedState` is consulted only when it doesn't.
///
/// ## Backfilling a partial hook reading
///
/// One exception to "wins outright": a hook reading can still arrive without
/// its `utilization` half — a cache file written before the script copied it,
/// a machine with no `jq`, or a run where `~/.claude.json` wasn't readable. So
/// an *empty* `scopedWeekly`, or credits that are `nil` with no disabled reason
/// either, are backfilled from `cachedState` (best-effort, through the
/// staleness-bypassing ``QuotaProviding/currentScopedWeekly()`` and
/// ``QuotaProviding/currentUsageCredits()``, since a blob too old for its
/// windows still has the right scoped rows and the right month-to-date spend).
/// Fields the hook did supply are never overwritten — it is the fresher source
/// by construction, and a backfill that clobbered them would hand the UI a
/// snapshot mixing two capture times.
///
/// ## Failure handling
///
/// The primary failing is invisible — that is the entire point. An error only
/// reaches the caller when *both* sources fail, and then the most actionable
/// one wins:
///
/// 1. A stale reading beats none, so if either source has a real-but-old
///    capture, that surfaces as
///    ``ClaudeStatsError/staleQuotaSource(snapshot:age:)`` carrying the
///    **freshest** of the two ages, along with that same source's own
///    snapshot. `AppModel` renders that as a warning next to the last numbers,
///    not as a red error.
/// 2. Otherwise a parse failure wins over an absence:
///    ``ClaudeStatsError/unexpectedQuotaResponse(_:)`` names something the user
///    could actually look at, where "nothing installed" does not.
/// 3. Otherwise ``ClaudeStatsError/noQuotaSourceAvailable``.
///
/// That ordering is untouched by the priority flip: it ranks *errors*, and only
/// runs once neither source produced a reading to rank them against.
///
/// ## Accounts
///
/// Both sources are per-account now (see ``QuotaAccount``), and both resolve
/// "the account" the same way: whichever one `oauthAccount` in Claude Code's own
/// state file names. ``StatuslineCacheReader`` serves that account's group of
/// cache files, and ``CachedUtilizationReader``'s blob belongs to the current
/// login by construction — so primary and backup describe the same account, or
/// the backup says which other one it describes and the popover labels it.
///
/// One case the primary/backup ladder can't express on its own: the state file
/// names an account, the cache holds files for *other* accounts only, and the
/// backup has nothing either. Throwing "no quota source" there would be wrong —
/// there are readings, they just aren't this account's — and serving another
/// account's group would be the very bug this is all for. So the answer is an
/// empty reading for the active account: both windows `nil`, which the popover
/// renders as "no reading". With nothing on disk for *any* account the old
/// ``ClaudeStatsError/noQuotaSourceAvailable`` still stands, because then
/// "Claude Code has never cached a reading on this Mac" is the accurate advice.
///
/// No third-party account switcher is consulted anywhere in this path — see
/// ``ActiveAccountReader``.
public struct FreshestQuotaProvider: QuotaProviding {
    private let statusline: any QuotaProviding
    private let cachedState: any QuotaProviding
    private let activeAccount: any ActiveAccountProviding
    private let now: @Sendable () -> Date

    /// `statusline` is built here rather than defaulted in the signature so it
    /// can share the one ``ActiveAccountProviding`` instance: two readers would
    /// mean two fingerprint caches and two parses of the same 145 KB file per
    /// change.
    public init(
        statusline: (any QuotaProviding)? = nil,
        cachedState: any QuotaProviding = CachedUtilizationReader(),
        activeAccount: any ActiveAccountProviding = ActiveAccountReader(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.statusline = statusline ?? StatuslineCacheReader(activeAccount: activeAccount)
        self.cachedState = cachedState
        self.activeAccount = activeAccount
        self.now = now
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        // `cachedState` is read only when it is actually needed. On the common
        // path — hook installed, fired recently, carrying its own `utilization`
        // — that is never, and this poll touches one file instead of two.
        switch await outcome(of: statusline) {
        case .success(let hook):
            return await backfilled(hook)
        case .failure(let hookError):
            switch await outcome(of: cachedState) {
            case .success(let cached):
                // Full-fidelity backup: this source parses the scoped rows and
                // `spend` natively, so there is nothing to graft onto it.
                return cached
            case .failure(let cachedError):
                var error = Self.combined(hookError, cachedError)
                // Best effort, same rationale as ``backfilled(_:)``: a stale
                // reading missing its scoped rows or credits can still take
                // `cachedState`'s, which carry no freshness gate of their own.
                // Whichever snapshot won `combined` may already have both (a
                // stale `cachedState` reading always does), in which case this
                // is skipped entirely.
                if case .staleQuotaSource(var snapshot, let age) = error,
                    snapshot.scopedWeekly.isEmpty
                        || (snapshot.usageCredits == nil && snapshot.usageCreditsDisabledReason == nil) {
                    if snapshot.scopedWeekly.isEmpty {
                        snapshot.scopedWeekly = (try? await cachedState.currentScopedWeekly()) ?? []
                    }
                    // Only overwrite on a successful re-read: unlike the
                    // scoped-rows fallback above (`[]` is a no-op when there's
                    // nothing already), `.unavailable` would actively clear a
                    // disabled-reason this snapshot already carried if the live
                    // re-read merely failed.
                    if snapshot.usageCredits == nil, snapshot.usageCreditsDisabledReason == nil,
                        let fetched = try? await cachedState.currentUsageCredits() {
                        snapshot.apply(fetched)
                    }
                    error = .staleQuotaSource(snapshot: snapshot, age: age)
                }
                if case .noQuotaSourceAvailable = error,
                    let empty = await emptyActiveAccountReading() {
                    // Readings exist, none of them this account's — see the
                    // type's "Accounts" note. "No reading" beats both an error
                    // and somebody else's numbers.
                    return empty
                }
                throw error
            }
        }
    }

    /// The active account's "nothing to report" snapshot, or `nil` when that
    /// isn't the situation — no other account has a reading either, or the
    /// state file doesn't name an account to report nothing *for*.
    ///
    /// `capturedAt` is now: what was observed now is the *absence*, and dating
    /// it from another account's file would put that file's age on this
    /// account's freshness tag.
    private func emptyActiveAccountReading() async -> QuotaSnapshot? {
        // Account check first: it is a mostly-cached read of the state file,
        // while `hasReadingsForOtherAccounts()` re-lists and re-parses every
        // session cache file. With no account named there is nothing to report
        // the absence *for*, so the expensive scan is never worth paying for.
        // A statusline source that can't tell accounts apart has no other
        // accounts to point at — see `OtherAccountReadingsReporting`.
        guard let account = activeAccount.readActiveAccount().account else { return nil }
        guard let grouped = statusline as? any OtherAccountReadingsReporting,
            grouped.hasReadingsForOtherAccounts()
        else { return nil }
        return QuotaSnapshot(
            fiveHour: nil,
            sevenDay: nil,
            confidence: .official,
            capturedAt: now(),
            account: account
        )
    }

    /// Fills the two fields a hook reading can legitimately arrive without —
    /// see the type's "Backfilling a partial hook reading" note.
    ///
    /// Both fetches bypass `cachedState`'s staleness gate on purpose, and both
    /// are `try?`: a backup that can't answer leaves the row out, it never
    /// fails the poll. Nothing the hook already supplied is touched.
    private func backfilled(_ hook: QuotaSnapshot) async -> QuotaSnapshot {
        var snapshot = hook
        if snapshot.scopedWeekly.isEmpty {
            snapshot.scopedWeekly = (try? await cachedState.currentScopedWeekly()) ?? []
        }
        // Credits and reason move together — see ``QuotaSnapshot/apply(_:)`` —
        // so a hook reading carrying only a `disabled_reason` counts as having
        // answered, and is left alone rather than re-asked and overwritten.
        if snapshot.usageCredits == nil, snapshot.usageCreditsDisabledReason == nil,
            let fetched = try? await cachedState.currentUsageCredits() {
            snapshot.apply(fetched)
        }
        return snapshot
    }

    /// The logged-in account, from the same ``ActiveAccountProviding`` instance
    /// the statusline reader groups by.
    ///
    /// Sharing it is what keeps this cheap: the reader is fingerprint-cached,
    /// so asking here right beside a ``currentSnapshot()`` costs one `open` and
    /// one `fstat`, not a second parse of the state file. And it is answered
    /// whatever the two quota sources are doing — a poll that throws still
    /// knows who is logged in, which is what `AppModel`'s account-switch
    /// detection needs (see ``QuotaProviding/currentAccount()``).
    public func currentAccount() async -> QuotaAccount? {
        activeAccount.readActiveAccount().account
    }

    /// Clears the statusline cache only — the per-session directory plus the
    /// legacy single file.
    ///
    /// Those files are this app's own; the other source is Claude Code's live
    /// state file, which is not ours to delete — see
    /// ``CachedUtilizationReader/clearCache()``. So this stays the escape hatch
    /// for a stuck statusline reading (and the cleanup `AppModel` runs after an
    /// account switch), and after it runs the bars fall back to the
    /// cached-state numbers instead of going empty.
    public func clearCache() throws {
        try statusline.clearCache()
    }

    private func outcome(of provider: any QuotaProviding) async -> Result<QuotaSnapshot, Error> {
        do {
            return .success(try await provider.currentSnapshot())
        } catch {
            return .failure(error)
        }
    }

    /// Picks the single error to surface when neither source produced a
    /// reading — see the type's "Failure handling" note for the ordering.
    private static func combined(_ first: Error, _ second: Error) -> ClaudeStatsError {
        let errors = [first, second].compactMap { $0 as? ClaudeStatsError }

        // Pair, not two parallel lists: the winning age has to travel with its
        // own snapshot, or the caller would render one source's numbers under
        // the other source's age (and remediation text).
        let stale = errors.compactMap { error -> (snapshot: QuotaSnapshot, age: TimeInterval)? in
            guard case .staleQuotaSource(let snapshot, let age) = error else { return nil }
            return (snapshot, age)
        }
        if let freshest = stale.min(by: { $0.age < $1.age }) {
            return .staleQuotaSource(snapshot: freshest.snapshot, age: freshest.age)
        }

        let messages = errors.compactMap { error -> String? in
            guard case .unexpectedQuotaResponse(let message) = error else { return nil }
            return message
        }
        if let message = messages.first { return .unexpectedQuotaResponse(message) }

        return .noQuotaSourceAvailable
    }
}
