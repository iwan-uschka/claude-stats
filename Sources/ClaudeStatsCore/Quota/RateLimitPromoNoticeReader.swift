import Foundation
import os

/// Reads `cachedGrowthBookFeatures.tengu_rate_limit_promo_notices` out of
/// Claude Code's private state file.
///
/// These keys are undocumented internals of another program. Everything here is
/// best-effort by construction: this type has no failure path at all (see
/// ``PromoNoticeProviding``), because every way it can come up empty — the file
/// is missing, it belongs to a Claude Code version that never wrote the key, it
/// was half-written when we looked, the flag cache went cold — is a state the
/// user can neither see nor fix, and an error banner for any of them would be
/// noise.
///
/// ## Why the notice has its own age, separate from the file's
///
/// The state file's mtime says nothing about how old the *flags* are: Claude
/// Code rewrites the file on every startup for `numStartups`,
/// `seenNotifications` and similar, so its mtime is minutes old even when the
/// GrowthBook cache underneath it is months stale. The age gate therefore reads
/// `cachedGrowthBookFeaturesAt` — the timestamp GrowthBook's own cache carries —
/// and a missing one means "unknown age", which is treated as too old to show.
/// The file's mtime is only ever used for the unchanged-since gate.
///
/// A future-dated timestamp (clock skew) counts as fresh: a notice shown a
/// little too eagerly is a far smaller problem than a promo silently vanishing
/// because a laptop's clock is off.
public struct RateLimitPromoNoticeReader: PromoNoticeProviding {
    /// Key holding the whole GrowthBook feature blob.
    static let featuresKey = "cachedGrowthBookFeatures"
    /// Key holding when that blob was fetched (epoch **milliseconds** on this
    /// machine — `QuotaJSON.date`'s magnitude heuristic already handles that).
    static let cachedAtKey = "cachedGrowthBookFeaturesAt"
    /// The flag itself.
    static let promoNoticesKey = "tengu_rate_limit_promo_notices"

    /// How old the GrowthBook cache may be before its notices are ignored.
    /// Matches the 7-day bar the notice describes.
    public static let defaultMaximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// Probed in order; the first that opens wins.
    public let candidateURLs: [URL]
    public let maximumAge: TimeInterval
    private let now: @Sendable () -> Date

    /// `cachedGrowthBookFeaturesAt` from the last parse, so the age gate can be
    /// re-applied when the file itself hasn't changed — its mtime says nothing
    /// about the flag cache's age, and a promo must not outlive its window just
    /// because Claude Code stopped running.
    private let lastCachedAt = OSAllocatedUnfairLock<Date?>(initialState: nil)

    public init(
        candidateURLs: [URL] = ClaudeConfigDirectory.stateFileCandidates(),
        maximumAge: TimeInterval = RateLimitPromoNoticeReader.defaultMaximumAge,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.candidateURLs = candidateURLs
        self.maximumAge = maximumAge
        self.now = now
    }

    public func read(unchangedSince previous: ClaudeStateFileFingerprint?) -> PromoNoticeReadResult {
        switch ClaudeStateFile.load(candidates: candidateURLs, unchangedSince: previous) {
        case .unchanged:
            guard let cachedAt = lastCachedAt.withLock({ $0 }),
                now().timeIntervalSince(cachedAt) > maximumAge
            else { return .unchanged }
            // Aged out since the last parse: drop the notices but keep the
            // fingerprint, so this stays a one-shot transition, not a re-parse
            // loop on every later poll.
            return .read(notices: [], fingerprint: previous)
        case .unavailable, .malformed:
            // Covers both "no candidate opened" and "one opened but wasn't
            // usable" (directory, or contents that aren't a JSON object).
            // This reader has no failure path, so the two are the same
            // outcome here — see ``PromoNoticeProviding``.
            // `ClaudeStateFile` doesn't hand back a fingerprint for either, so
            // the next call looks again rather than treating "no data" as a
            // known state.
            lastCachedAt.withLock { $0 = nil }
            return .read(notices: [], fingerprint: nil)
        case .loaded(let root, let fingerprint):
            // Returned even when empty, so the fingerprint advances and the
            // next refresh takes the cheap gated path.
            lastCachedAt.withLock { $0 = QuotaJSON.date(root[Self.cachedAtKey]) }
            return .read(notices: notices(in: root), fingerprint: fingerprint)
        }
    }

    private func notices(in root: [String: Any]) -> [RateLimitPromoNotice] {
        guard let cachedAt = QuotaJSON.date(root[Self.cachedAtKey]) else { return [] }
        guard now().timeIntervalSince(cachedAt) <= maximumAge else { return [] }

        guard let features = QuotaJSON.object(root[Self.featuresKey]),
            let entries = features[Self.promoNoticesKey] as? [Any]
        else { return [] }

        return entries.compactMap {
            QuotaJSON.object($0).flatMap(RateLimitPromoNotice.init(json:))
        }
    }
}
