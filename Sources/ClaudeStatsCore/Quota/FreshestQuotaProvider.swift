import Foundation

/// Serves whichever of the two account-wide quota sources has the newer
/// reading, so neither one being unavailable can take the bars down.
///
/// ## The two sources are the same numbers at different ages
///
/// ``CachedUtilizationReader`` is the primary: it needs no setup, because
/// Claude Code writes `cachedUsageUtilization` into its own state file whether
/// or not this app exists. ``StatuslineCacheReader`` is the freshness booster:
/// it requires installing a hook, and in exchange reports the payload seconds
/// after Claude Code itself saw it, rather than on Claude Code's own
/// several-minute cache cadence.
///
/// Keeping both is not redundancy for its own sake. The cached key is
/// undocumented private state that can be renamed or removed by any Claude Code
/// release; the statusline payload has a much longer track record. Whichever
/// one survives an upstream change keeps the bars lit.
///
/// ## Failure handling
///
/// One source failing is invisible — that is the entire point. An error only
/// reaches the caller when *both* fail, and then the most actionable one wins:
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
public struct FreshestQuotaProvider: QuotaProviding {
    private let statusline: any QuotaProviding
    private let cachedState: any QuotaProviding

    public init(
        statusline: any QuotaProviding = StatuslineCacheReader(),
        cachedState: any QuotaProviding = CachedUtilizationReader()
    ) {
        self.statusline = statusline
        self.cachedState = cachedState
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        // Sequential, not concurrent: both are a couple of local file reads,
        // and running them in order keeps the outcome deterministic for the
        // tie-break below.
        let fromStatusline = await outcome(of: statusline)
        let fromCachedState = await outcome(of: cachedState)

        switch (fromStatusline, fromCachedState) {
        case (.success(let hook), .success(let cached)):
            // Ties go to the statusline capture: equal `capturedAt` means the
            // same underlying reading reached us both ways, and the hook's is
            // the one that was observed directly.
            var winner = hook.capturedAt >= cached.capturedAt ? hook : cached
            // Scoped limits exist only in `cachedState`'s payload — the
            // statusline hook's schema has no `limits[]` at all, not merely an
            // empty one. So this is the one field that isn't "pick a snapshot
            // and use it whole": grafting it on top of whichever snapshot wins
            // the freshness compare is what lets the two features compose,
            // rather than the scoped bars going dark on any account where the
            // hook is installed and (as usual) fresher.
            winner.scopedWeekly = cached.scopedWeekly
            return winner
        case (.success(let hook), .failure):
            // The whole `cachedState` snapshot failed — commonly because its
            // windows are stale, which says nothing about whether its scoped
            // rows are worth showing (they carry no separate freshness gate
            // of their own either way — see ``QuotaScopedLimit``). Best
            // effort, via the one method that bypasses that staleness gate:
            // a hook this fresh with no scoped data of its own is exactly the
            // case ``currentScopedWeekly()`` exists for.
            var winner = hook
            winner.scopedWeekly = (try? await cachedState.currentScopedWeekly()) ?? []
            return winner
        case (.failure, .success(let cached)):
            return cached
        case (.failure(let hookError), .failure(let cachedError)):
            throw Self.combined(hookError, cachedError)
        }
    }

    /// Clears the statusline cache only.
    ///
    /// That file is this app's own; the other source is Claude Code's live
    /// state file, which is not ours to delete — see
    /// ``CachedUtilizationReader/clearCache()``. So this stays the escape hatch
    /// for a stuck statusline reading, and after it runs the bars fall back to
    /// the cached-state numbers instead of going empty.
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
