import Foundation
import os

/// Reads which Anthropic account Claude Code is logged in as, out of its own
/// state file (`~/.claude.json`).
///
/// ## Why this exists
///
/// The user can swap the global login between two accounts (personal and
/// business) — `~/.claude.json` plus the keychain entry are rewritten, and from
/// then on every new payload describes the other account's quota. Neither quota
/// payload names an account (see ``QuotaAccount``), so without this reader the
/// app cannot tell which of the readings lying in its cache belong to the
/// account the bars are supposed to describe, and the per-window merge picks
/// whichever window resets latest — the other account's, half the time.
///
/// Two facts come back, both out of the one file so they can never describe
/// different moments:
///
/// - `oauthAccount` — the active account itself, which is what the popover
///   labels the bars with and what ``StatuslineCacheReader`` groups by.
/// - `cachedUsageUtilization.accountUuid` plus that blob's
///   `seven_day.resets_at` — the ``ActiveAccountReference`` the mislabel guard
///   compares stamped statusline readings against.
///
/// **No third-party switcher is consulted**, deliberately: `~/.claude.json` is
/// Claude Code's own file and is right on every machine, where a switcher's
/// backup directory only exists if the user happens to run that tool.
///
/// ## Reading cost
///
/// Same treatment as ``RateLimitPromoNoticeReader``: the file is ~145 KB and
/// Claude Code rewrites it constantly for unrelated keys, so reads ride the
/// throttled quota refresh behind ``ClaudeStateFile``'s nanosecond-mtime +
/// inode + size fingerprint — an unchanged file costs one `open` and one
/// `fstat`, and the previous answer is served from memory. No FSEvents: the
/// file sits directly in `$HOME`, and watching `$HOME` recursively is not an
/// acceptable cost for this.
public struct ActiveAccountReader: ActiveAccountProviding {
    /// Key holding the logged-in account.
    static let oauthAccountKey = "oauthAccount"

    /// What the last parse found, kept so an unchanged file can skip the parse.
    private struct Cached: Sendable {
        var fingerprint: ClaudeStateFileFingerprint?
        var reading: ActiveAccountReading
    }

    /// Probed in order; the first that opens wins.
    public let candidateURLs: [URL]
    private let cache = OSAllocatedUnfairLock(
        initialState: Cached(fingerprint: nil, reading: .unknown))

    public init(candidateURLs: [URL] = ClaudeConfigDirectory.stateFileCandidates()) {
        self.candidateURLs = candidateURLs
    }

    public func readActiveAccount() -> ActiveAccountReading {
        let previous = cache.withLock { $0.fingerprint }
        switch ClaudeStateFile.load(candidates: candidateURLs, unchangedSince: previous) {
        case .unchanged:
            return cache.withLock { $0.reading }
        case .unavailable, .malformed:
            // No file, not a regular file, or not JSON at all. All "we don't
            // know", and the fingerprint is dropped so the next poll looks
            // again rather than latching onto a state that never existed.
            cache.withLock { $0 = Cached(fingerprint: nil, reading: .unknown) }
            return .unknown
        case .loaded(let root, let fingerprint):
            let reading = Self.reading(in: root)
            // Stored even when nothing was found, so a state file that simply
            // has no `oauthAccount` isn't re-parsed on every refresh.
            cache.withLock { $0 = Cached(fingerprint: fingerprint, reading: reading) }
            return reading
        }
    }

    /// Pulls both facts out of one parsed state file.
    static func reading(in root: [String: Any]) -> ActiveAccountReading {
        let account = QuotaJSON.object(root[Self.oauthAccountKey]).flatMap(QuotaAccount.init(json:))
        return ActiveAccountReading(account: account, reference: reference(in: root, account: account))
    }

    /// The guard's reference: the account of the *cached reading* and the 7-day
    /// reset that reading reported.
    ///
    /// `cachedUsageUtilization` carries its own `accountUuid`, which is the
    /// account the numbers beside it describe — that, not `oauthAccount`, is
    /// what a statusline reading has to agree with. It is only missing on older
    /// payloads, and then the logged-in account is the best available stand-in.
    private static func reference(
        in root: [String: Any], account: QuotaAccount?
    ) -> ActiveAccountReference? {
        guard let cached = QuotaJSON.object(root[CachedUtilizationReader.cachedUtilizationKey]),
            let utilization = QuotaJSON.object(cached[CachedUtilizationReader.utilizationKey])
        else { return nil }

        let uuid = QuotaAccount(json: cached)?.uuid ?? account?.uuid
        guard let uuid else { return nil }
        guard let resetsAt = QuotaJSON.optionalWindows(in: utilization).sevenDay?.resetsAt else {
            // No cached 7-day reading to compare against: the guard has no
            // reference and accepts everything, which is the pre-guard
            // behaviour rather than a reason to drop readings.
            return nil
        }
        return ActiveAccountReference(accountUuid: uuid, sevenDayResetsAt: resetsAt)
    }
}
