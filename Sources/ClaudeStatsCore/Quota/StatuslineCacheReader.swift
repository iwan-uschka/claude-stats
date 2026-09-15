import Foundation

/// Reads the on-disk cache written by our `statusLine` hook — the app's
/// **primary** quota source (`.official` confidence; see
/// ``FreshestQuotaProvider``).
///
/// ## Why a cache and not a hook
///
/// The `rate_limits` numbers are only ever handed out by Claude Code itself: it
/// pipes a JSON payload into whatever command is configured under `statusLine`
/// in `~/.claude/settings.json`, containing
/// `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` (percentages
/// 0...100; `resets_at` is **Unix epoch seconds**). There is no way to ask for
/// that payload — you have to *be* the status line.
///
/// This app is a menu bar app, not a shell command, so it can't be the hook. The
/// split is therefore: a tiny shell script is the hook and writes the payload to
/// a cache file; this type reads those files. Installing that script into the
/// user's real `~/.claude/settings.json` is deliberately **not** done
/// automatically — see `Sources/ClaudeStats/Resources/claude-stats-statusline-cache.sh`
/// for the script (bundled into the app; revealed from Settings) and the wiring
/// instructions in its header comment.
///
/// ## One file per session, not one file
///
/// Default location: `~/Library/Application Support/ClaudeStats/statusline-cache/`,
/// holding one `<session_id>.json` per Claude Code session (the statusline
/// payload's own top-level `session_id`, sanitized into a file name).
///
/// It used to be a single `statusline-cache.json` that every session
/// overwrote, and with more than one Claude Code window open that was wrong in
/// a way that showed: each process pipes in the rate limits *its* last API
/// response carried, and an idle session re-renders its status line on
/// time-based triggers alone. So a session that last talked to the API hours
/// ago would restamp its own stale numbers as captured "now", and last writer
/// won. Worse, Claude Code drops a window from the payload entirely once its
/// `resets_at` has passed — so the stale writer's file carried only
/// `seven_day`, the missing `five_hour` was read back as a zeroed window, and
/// the bars showed a confident 0%. One file per session plus the merge below is
/// what makes a quiet session unable to overwrite a busy one.
///
/// A window no file claims stays absent: the snapshot's ``QuotaSnapshot/fiveHour``
/// / ``QuotaSnapshot/sevenDay`` is `nil`, which the UI shows as no reading. That
/// is the normal state right after a window rolls over and before the session's
/// next API call — the payload simply has nothing to say about it yet, and
/// saying "0%" on its behalf is the same wrong answer in a subtler place.
///
/// The legacy single file is still read, as one more input, so a machine whose
/// hook script hasn't been reinstalled yet keeps working.
///
/// ## One group per account
///
/// The merge runs **inside one account's files only**. The user can swap the
/// global login between two Anthropic accounts, and nothing in the statusline
/// payload says which account it describes (see ``QuotaAccount``), so a cache
/// left behind by the previous login is indistinguishable from a current one —
/// and since a merge picks the latest `resets_at`, the *other* account's 7-day
/// window won outright whenever its reset happened to be later. Observed: after
/// switching from account A (7-day reset 23:00Z, 56%) to account B (03:00Z,
/// 0%), one idle session kept re-rendering A's payload and the bar showed A's
/// 56% as the machine's 7-day usage.
///
/// So the helper script stamps each cache file with the `oauthAccount` of
/// Claude Code's own state file at the moment it writes, this reader groups the
/// files by that stamp's uuid, and the rules below apply within a group and
/// never across groups. Files with no stamp form one "unknown" group — a cache
/// written by a script copy from before the stamp existed, or one written
/// without `jq`. The legacy single `statusline-cache.json` is unstamped by
/// definition and lands there too.
///
/// ``currentSnapshot()`` serves the **active** account's group: the one whose
/// uuid matches `oauthAccount` in the state file (see ``ActiveAccountReader``).
/// With no group for that account it reports
/// ``ClaudeStatsError/noQuotaSourceAvailable`` — not another account's numbers
/// and not the unstamped group's, which is how a machine still running the old
/// script falls through to the backup source until its next render restamps.
/// When the active account itself is unknown, the most recently captured group
/// serves, which is exactly the pre-account behaviour on a one-account machine.
/// Every other group is never displayed: its numbers are a frozen copy, written
/// only while that account was logged in on this Mac, and the mislabel guard
/// below only checks files stamped with the account Claude Code's own cached
/// reading describes — the active one. The one thing still asked of
/// those groups is whether any exist — ``hasReadingsForOtherAccounts()``.
///
/// ### The mislabel guard
///
/// One heuristic, and only this one. An idle Claude Code session re-renders its
/// status line on timers alone, handing the hook the rate limits *its own* last
/// API response carried. Right after a login switch such a render pipes the old
/// account's numbers while `~/.claude.json` already names the new account — so
/// the file gets stamped with the new account and carries the old one's
/// percentages, and no amount of grouping catches it.
///
/// It is catchable against one fact the state file has already updated: the
/// 7-day reset of the cached reading for that same account. A stamped reading
/// whose `seven_day.resets_at` differs from it by more than
/// ``ActiveAccountReference/tolerance`` describes a different 7-day window than
/// the account is actually in, so the whole reading is dropped from that
/// account's merge. Readings with no `seven_day` window at all are not subject
/// to it (nothing to compare), and with no cached reference everything is
/// accepted.
///
/// ## Merging
///
/// Within one account group, each window is chosen independently across that
/// group's files, and `captured_at` is deliberately *not* the deciding field —
/// it says when we wrote the file, not how old the numbers in it are. In order:
///
/// 1. A reading whose `resets_at` has already passed is ignored: Claude Code
///    itself stops reporting such a window, so a file still carrying one is by
///    definition showing a window that has since rolled over.
/// 2. The latest `resets_at` wins — a later reset is a later window.
/// 3. Same `resets_at` (i.e. the same window) breaks toward the **highest**
///    percentage: utilization within one window never decreases, so a lower
///    reading is the older one. Identical percentages — two sessions polled
///    before either made a new API call — break toward the most recently
///    captured, which changes nothing on screen but keeps the pick stable.
/// 4. A reading with no `resets_at` at all ranks below any reading that has
///    one; among themselves, the most recently captured wins.
///
/// The snapshot's ``QuotaSnapshot/capturedAt`` is the newest `captured_at`
/// among the files that actually contributed a window, and the staleness gate
/// applies to that.
///
/// ## Cache file
///
/// Preferred shape (what the helper script writes when `jq` is available):
///
/// ```json
/// {
///   "captured_at": 1738425600,
///   "rate_limits": {
///     "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
///     "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
///   },
///   "utilization": {
///     "limits": [ { "kind": "weekly_scoped", … } ],
///     "spend": { … }, "extra_usage": { … }
///   },
///   "account": {
///     "uuid": "…", "email": "…",
///     "organization_name": "…", "organization_uuid": "…"
///   }
/// }
/// ```
///
/// Only `rate_limits` comes from the statusline payload; that schema has never
/// carried a `limits[]` or a `spend`. The `utilization` object is the script
/// copying those two out of Claude Code's own `~/.claude.json` at the moment it
/// fires, nested and named exactly as they appear there — which is why the
/// parsing below is ``CachedUtilizationReader``'s parsing, reused verbatim
/// rather than reimplemented. Carrying them here is what makes a hook-only
/// reading complete: all four bars out of files this app wrote, instead of
/// three from here and one from a private key that refreshes on somebody
/// else's schedule. They come from `~/.claude.json` and are therefore identical
/// across the sessions of one login, so they are taken from the most recently
/// captured file *in the chosen account's group* that has them, rather than
/// merged window-style — the file is per-login, so a file stamped with another
/// account describes another account's scoped rows and spend.
///
/// `account` comes from the same read of that file — `oauthAccount`, copied
/// key by key — and is what "One group per account" above groups by.
///
/// `utilization` and `account` are **optional in every direction**. A cache
/// written before those keys existed, one written with no `jq` installed, and
/// one written while `~/.claude.json` was unreadable are all indistinguishable
/// and all fine: the account is unknown (see "One group per account"), the
/// scoped rows come back empty and the credits `nil`, which is exactly what
/// this reader reported before the key existed, and ``FreshestQuotaProvider``
/// backfills both from ``CachedUtilizationReader``.
///
/// The raw, unfiltered statusline payload is *also* accepted verbatim (it
/// already nests the windows under `rate_limits`), in which case the file's
/// modification date stands in for `captured_at`. That lets the helper script
/// degrade to a plain `tee` with no JSON tooling installed.
///
/// ## Staleness
///
/// The hook only fires while Claude Code is actively rendering a status line in
/// some terminal, so this cache goes cold as soon as the user stops working.
/// Anything older than ``stalenessThreshold`` throws
/// ``ClaudeStatsError/staleQuotaSource(snapshot:age:)`` instead of showing a
/// confidently wrong number, and a missing cache (never installed, or never
/// fired) throws ``ClaudeStatsError/noQuotaSourceAvailable`` instead — a
/// distinct case, since "not installed" and "installed but quiet" call for
/// different messages. This reader still throws on either: it is
/// ``FreshestQuotaProvider`` that swallows both by falling back to
/// ``CachedUtilizationReader``, so an error only reaches the UI when neither
/// source has a reading.
public struct StatuslineCacheReader: QuotaProviding, OtherAccountReadingsReporting {
    /// Directory name used under Application Support.
    public static let cacheDirectoryName = "ClaudeStats"
    /// Sub-directory holding one cache file per Claude Code session.
    public static let sessionCacheDirectoryName = "statusline-cache"
    /// The single file older copies of the helper script wrote. No longer
    /// written, still read — see "One file per session, not one file".
    public static let legacyCacheFileName = "statusline-cache.json"
    /// Session files not written within this long are deleted as we read.
    /// A session that quiet has nothing to contribute anyway: even the 7-day
    /// window it last saw has rolled over by now.
    public static let sessionRetention: TimeInterval = 7 * 24 * 60 * 60
    /// Top-level key holding the copy of `cachedUsageUtilization.utilization`.
    /// Same spelling as ``CachedUtilizationReader/utilizationKey`` on purpose:
    /// the object under it is the same object, so the same parsers read it.
    static let utilizationKey = "utilization"
    /// Top-level key holding the copy of the state file's `oauthAccount` — the
    /// stamp everything in "One group per account" turns on.
    static let accountKey = "account"

    /// `~/Library/Application Support/ClaudeStats`.
    ///
    /// Falls back to an explicit path construction if Application Support can't
    /// be resolved, so this is never optional at the call site.
    public static var defaultCacheDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    /// The directory both cache locations are derived from — everything this
    /// type touches lives inside it, so one injected path is enough to point a
    /// test (or a `$CLAUDE_STATS_CACHE_DIR` run of the script) somewhere else.
    public let cacheDirectoryURL: URL
    /// `…/ClaudeStats/statusline-cache/`, one `<session_id>.json` per session.
    public var sessionCacheDirectoryURL: URL {
        cacheDirectoryURL.appendingPathComponent(Self.sessionCacheDirectoryName, isDirectory: true)
    }
    /// `…/ClaudeStats/statusline-cache.json`, written by older script copies.
    public var legacyCacheURL: URL {
        cacheDirectoryURL.appendingPathComponent(Self.legacyCacheFileName, isDirectory: false)
    }
    public let stalenessThreshold: TimeInterval
    /// `FileManager` isn't marked `Sendable`, but `.default` and other instances
    /// are documented thread-safe (Apple: "the methods of the shared FileManager
    /// object can be called from multiple threads safely").
    nonisolated(unsafe) private let fileManager: FileManager
    private let now: @Sendable () -> Date
    /// Who Claude Code is logged in as, so the files can be scoped to that
    /// account — see "One group per account".
    ///
    /// Defaults to ``UnknownAccountReader`` rather than the real
    /// ``ActiveAccountReader``: this type is constructed all over the test
    /// suite, and a default that read `~/.claude.json` would point every one of
    /// those constructions at the developer's own state file.
    /// ``FreshestQuotaProvider`` wires the real reader in.
    private let activeAccount: any ActiveAccountProviding

    public init(
        cacheDirectoryURL: URL = StatuslineCacheReader.defaultCacheDirectoryURL,
        stalenessThreshold: TimeInterval = QuotaSnapshot.defaultStalenessThreshold,
        fileManager: FileManager = .default,
        activeAccount: any ActiveAccountProviding = UnknownAccountReader(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.stalenessThreshold = stalenessThreshold
        self.fileManager = fileManager
        self.activeAccount = activeAccount
        self.now = now
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        let readings = try loadReadings()
        let asOf = now()

        // Nothing for the active account is "no reading from this source", not
        // an error of its own: `FreshestQuotaProvider` then falls through to
        // `cachedUsageUtilization`, which belongs to the active login by
        // construction. Another account's files are never substituted.
        guard let group = chosenGroup(in: readings),
            let snapshot = snapshot(for: group, asOf: asOf)
        else {
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        guard !snapshot.isStale(asOf: asOf, threshold: stalenessThreshold) else {
            throw ClaudeStatsError.staleQuotaSource(snapshot: snapshot, age: snapshot.age(asOf: asOf))
        }
        return snapshot
    }

    /// Whether any account group other than the one ``currentSnapshot()``
    /// serves still claims a live window — see
    /// ``OtherAccountReadingsReporting``.
    ///
    /// Counts exactly the groups that would merge into a snapshot: a group
    /// whose every window has already reset contributes nothing to
    /// ``snapshot(for:asOf:)`` and does not count here either, so a machine
    /// whose only other files are ancient still gets the plain "no quota
    /// source" advice rather than two empty bars. Checked per reading with the
    /// merge's own rule 1 (``isLive(_:asOf:)``) instead of by building the
    /// snapshots, since only the yes/no is wanted.
    ///
    /// Never gated on staleness: a cold other account is still proof that
    /// readings exist on this Mac. Never throws: a file-level fault has already
    /// been reported by the snapshot path.
    func hasReadingsForOtherAccounts() -> Bool {
        guard let readings = try? loadReadings() else { return false }
        let asOf = now()
        let active = activeAccount.readActiveAccount()
        let groups = groups(in: readings, reference: active.reference)
        let chosen = chosen(among: groups, account: active.account)
        return groups
            .filter { group in chosen.map { group.key != $0.key } ?? true }
            .contains { group in
                group.readings.contains { reading in
                    [reading.fiveHour, reading.sevenDay].contains { window in
                        window.map { Self.isLive($0, asOf: asOf) } ?? false
                    }
                }
            }
    }

    /// Same payload as ``currentSnapshot()``, but never gated on staleness —
    /// the mirror of ``CachedUtilizationReader/currentScopedWeekly()``, and see
    /// ``QuotaProviding/currentScopedWeekly()`` for the rationale.
    ///
    /// The symmetry is not decorative. Now that this source is the primary one,
    /// it is also the source the *other* one's graft can pull from: when
    /// ``CachedUtilizationReader`` is serving the account-wide windows and this
    /// cache is merely too old to win, its scoped rows are still the freshest
    /// copy of `weekly_scoped` on disk — and unlike the windows they carry no
    /// freshness claim of their own (see ``QuotaScopedLimit``).
    public func currentScopedWeekly() async throws -> [QuotaScopedLimit] {
        guard let utilization = newestUtilization(in: try chosenReadings()) else { return [] }
        return QuotaJSON.scopedLimits(in: utilization)
    }

    /// Same payload as ``currentSnapshot()``, never gated on staleness — the
    /// money half of ``currentScopedWeekly()``, for the same reason. A
    /// month-to-date spend total does not stop being right because the rate
    /// limits captured beside it have aged out.
    public func currentUsageCredits() async throws -> UsageCreditsReading {
        guard let utilization = newestUtilization(in: try chosenReadings()) else { return .unavailable }
        return QuotaJSON.usageCredits(in: utilization)
    }

    /// The chosen account group's files, for the two staleness-bypassing
    /// accessors — scoped the same way ``currentSnapshot()`` is, since the
    /// `utilization` copy is per-login too: another account's file carries
    /// another account's scoped rows and spend.
    ///
    /// Empty rather than throwing when there is no group for the active
    /// account: the file-level faults have already been raised by
    /// ``loadReadings()``, and "nothing for this account" is the same non-fault
    /// here as it is in ``currentSnapshot()``.
    private func chosenReadings() throws -> [Reading] {
        chosenGroup(in: try loadReadings())?.readings ?? []
    }

    /// Deletes the whole session cache directory and the legacy single file, so
    /// the next hook write starts from nothing.
    ///
    /// The escape hatch for a reading that looks stuck or wrong: per-session
    /// files stop one quiet session from overwriting a busy one, but they can't
    /// help if every file on disk is somehow wrong. Removing them makes the next
    /// statusline render the sole source of what's on screen. Until one happens,
    /// ``currentSnapshot()`` throws
    /// ``ClaudeStatsError/noQuotaSourceAvailable`` — expected, not a failure.
    /// Best-effort on absence: a missing directory or file is not an error,
    /// anything else is and reaches the caller.
    public func clearCache() throws {
        var failure: Swift.Error?
        for url in [sessionCacheDirectoryURL, legacyCacheURL] {
            do {
                try fileManager.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // already gone — nothing to do
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    // MARK: - Reading the files

    /// One parsed cache file: the two windows as they actually appeared (either
    /// may be absent — see the 0% pitfall in "One file per session"), when we
    /// wrote it, the account it was stamped with, and the `utilization` copy if
    /// it carried one.
    private struct Reading {
        let capturedAt: Date
        let fiveHour: QuotaWindow?
        let sevenDay: QuotaWindow?
        let utilization: [String: Any]?
        /// `nil` for an unstamped file — a script copy from before the stamp,
        /// one running without `jq`, or the legacy single file.
        let account: QuotaAccount?

        /// This file's claim about one window, ready to rank — `nil` when it
        /// made none.
        func candidate(_ window: KeyPath<Reading, QuotaWindow?>) -> Candidate? {
            self[keyPath: window].map { Candidate(window: $0, capturedAt: capturedAt) }
        }
    }

    /// One file's reading of one window, in the merge.
    private struct Candidate {
        let window: QuotaWindow
        let capturedAt: Date
    }

    /// Every readable cache file, parsed, pruning expired session files as it
    /// goes.
    ///
    /// Only the two whole-source faults throw — nothing on disk at all, and
    /// nothing on disk that is JSON — because those are the two the
    /// staleness-bypassing readers care about just as much as
    /// ``currentSnapshot()`` does. A single unparseable file among good ones is
    /// skipped: one session writing garbage must not take down the bars that
    /// every other session is still feeding.
    private func loadReadings() throws -> [Reading] {
        let cutoff = now().addingTimeInterval(-Self.sessionRetention)
        var readings: [Reading] = []
        var malformed: URL?

        for (url, isSessionFile) in cacheFileURLs() {
            guard let (data, mtime) = readFileWithModificationDate(at: url) else { continue }
            let root = QuotaJSON.object(try? JSONSerialization.jsonObject(with: data))
            // No fallback to `now()`: if neither the payload nor the file
            // itself can tell us when this was captured, treat the age as
            // unknown rather than silently trusting it as freshly captured.
            let capturedAt = root.flatMap { root in
                QuotaJSON.capturedAtKeys.lazy.compactMap { QuotaJSON.date(root[$0]) }.first
            } ?? mtime

            // Best-effort, and deliberately ahead of the parse check so a
            // session file that is both ancient and garbage still goes away.
            if isSessionFile, let capturedAt, capturedAt < cutoff {
                try? fileManager.removeItem(at: url)
                continue
            }

            guard let root else {
                malformed = malformed ?? url
                continue
            }
            guard let capturedAt else { continue }

            let windows = QuotaJSON.optionalWindows(in: root)
            readings.append(
                Reading(
                    capturedAt: capturedAt,
                    fiveHour: windows.fiveHour,
                    sevenDay: windows.sevenDay,
                    utilization: QuotaJSON.object(root[Self.utilizationKey]),
                    account: QuotaJSON.object(root[Self.accountKey])
                        .flatMap(QuotaAccount.init(json:))
                )
            )
        }

        guard readings.isEmpty else { return readings }
        if let malformed {
            throw ClaudeStatsError.unexpectedQuotaResponse(
                "statusline cache at \(malformed.lastPathComponent) is not a JSON object"
            )
        }
        // No hook installed, or it has never fired.
        throw ClaudeStatsError.noQuotaSourceAvailable
    }

    /// Every candidate cache file, flagged with whether pruning applies to it.
    /// Sorted by name so a tie the merge can't break resolves the same way on
    /// every poll rather than following directory order.
    private func cacheFileURLs() -> [(url: URL, isSessionFile: Bool)] {
        let sessionFiles = (try? fileManager.contentsOfDirectory(
            at: sessionCacheDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return sessionFiles
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0, true) }
            + [(legacyCacheURL, false)]
    }

    /// Reads one cache file's bytes and modification time from a single open
    /// descriptor, so they always describe the same file state — two separate
    /// syscalls (as `FileManager.contents(atPath:)` followed by
    /// `attributesOfItem(atPath:)`) could otherwise straddle the helper
    /// script's atomic `mktemp` + `mv` rewrite and pair old bytes with a new
    /// mtime (or vice versa).
    private func readFileWithModificationDate(at url: URL) -> (data: Data, mtime: Date?)? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }

        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        let mtime = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
        return (data, mtime)
    }

    // MARK: - Grouping by account

    /// One account's files. `key` is the grouping identity — the stamp's uuid,
    /// or `nil` for the unstamped group.
    private struct Group {
        let account: QuotaAccount?
        let readings: [Reading]

        var key: String? { account?.uuid }
        /// Newest file in the group, used only to order the groups.
        var newestCapture: Date { readings.map(\.capturedAt).max() ?? .distantPast }
    }

    /// Splits the files into one group per account, newest group first, after
    /// dropping the readings the mislabel guard rejects.
    ///
    /// ## The mislabel guard, in code
    ///
    /// A reading is dropped when it is stamped with the account the state file's
    /// cached reading describes, carries a `seven_day` window, and that window's
    /// reset is more than ``ActiveAccountReference/tolerance`` away from the
    /// cached one's. Reason: an idle session re-renders its status line from its
    /// *last* API payload, so immediately after a login switch a render can pipe
    /// the previous account's numbers while `~/.claude.json` already names the
    /// new one — the file is then stamped with the new account and carries the
    /// old account's percentages, which grouping alone cannot catch. The 7-day
    /// reset is the one field the two sources both report and that differs
    /// between accounts, and the tolerance absorbs their different spellings of
    /// the same instant (epoch seconds vs ISO-8601 with fractional seconds).
    ///
    /// Readings with no `seven_day` window are never dropped — there is nothing
    /// to compare — and with no reference at all nothing is dropped either.
    ///
    /// The reference is passed in rather than read here so that one
    /// ``ActiveAccountProviding/readActiveAccount()`` serves both this and
    /// ``chosen(among:account:)``: two reads per refresh is duplicated file
    /// I/O, and a login switch landing between them could have the guard and
    /// the group choice describing different accounts.
    private func groups(in readings: [Reading], reference: ActiveAccountReference?) -> [Group] {
        var order: [String?] = []
        var byKey: [String?: (account: QuotaAccount?, readings: [Reading])] = [:]

        for reading in readings where !isForeign(reading, reference: reference) {
            let key = reading.account?.uuid
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = (reading.account, [])
            }
            byKey[key]?.readings.append(reading)
        }

        return order
            .compactMap { key in byKey[key].map { Group(account: $0.account, readings: $0.readings) } }
            .sorted { $0.newestCapture > $1.newestCapture }
    }

    /// The mislabel guard's verdict on one file — see ``groups(in:reference:)``.
    private func isForeign(_ reading: Reading, reference: ActiveAccountReference?) -> Bool {
        guard let reference, reading.account?.uuid == reference.accountUuid,
            let resetsAt = reading.sevenDay?.resetsAt
        else { return false }
        return abs(resetsAt.timeIntervalSince(reference.sevenDayResetsAt))
            > ActiveAccountReference.tolerance
    }

    /// The group ``currentSnapshot()`` serves: the active account's, or — when
    /// the state file doesn't name one — the most recently captured.
    ///
    /// `nil` when the state file names an account no file on disk is stamped
    /// with. That is deliberately *not* a fall-through to another group: the
    /// whole point is that the bars describe the account the user is logged in
    /// as, and the backup source reads that same login's cached blob.
    private func chosen(among groups: [Group], account: QuotaAccount?) -> Group? {
        guard let uuid = account?.uuid else {
            return groups.first
        }
        return groups.first { $0.key == uuid }
    }

    private func chosenGroup(in readings: [Reading]) -> Group? {
        let active = activeAccount.readActiveAccount()
        return chosen(among: groups(in: readings, reference: active.reference), account: active.account)
    }

    /// Merges one group's files into that account's snapshot, or `nil` when
    /// none of them still claims a live window.
    private func snapshot(for group: Group, asOf now: Date) -> QuotaSnapshot? {
        let fiveHour = choose(group.readings.compactMap { $0.candidate(\.fiveHour) }, asOf: now)
        let sevenDay = choose(group.readings.compactMap { $0.candidate(\.sevenDay) }, asOf: now)

        // Each window can be independently absent; require at least one — the
        // same rule ``CachedUtilizationReader`` applies to its single payload.
        // With neither, every file in this group is either
        // pre-first-API-response or describing windows that have already rolled
        // over: no data, not a fault. One of the two surviving is a snapshot
        // with a `nil` window, not a snapshot with a zeroed one.
        guard let capturedAt = [fiveHour?.capturedAt, sevenDay?.capturedAt].compactMap({ $0 }).max() else {
            return nil
        }

        // Absent on every cache the helper script wrote before it learned to
        // copy this across, and on every one written without `jq` — hence
        // empty/`nil` rather than a throw. See the type's "Cache file" note.
        let utilization = newestUtilization(in: group.readings)
        let credits = utilization.map(QuotaJSON.usageCredits(in:)) ?? .unavailable

        return QuotaSnapshot(
            fiveHour: fiveHour?.window,
            sevenDay: sevenDay?.window,
            confidence: .official,
            capturedAt: capturedAt,
            scopedWeekly: utilization.map(QuotaJSON.scopedLimits(in:)) ?? [],
            usageCredits: credits.credits,
            usageCreditsDisabledReason: credits.disabledReason,
            account: group.account
        )
    }

    // MARK: - Merging

    /// Picks one window out of every file's claim about it, by the four rules
    /// in "Merging" above. `nil` when no file made a claim that survives them.
    private func choose(_ candidates: [Candidate], asOf now: Date) -> Candidate? {
        // Rule 1: a window whose reset has passed is one Claude Code has
        // already stopped reporting. Expired, not 0%.
        let live = candidates.filter { Self.isLive($0.window, asOf: now) }

        // Rules 2 and 3, on the readings that date themselves.
        let dated = live.compactMap { candidate in
            candidate.window.resetsAt.map { (resetsAt: $0, candidate: candidate) }
        }
        if !dated.isEmpty {
            return dated.max { lhs, rhs in
                if lhs.resetsAt != rhs.resetsAt { return lhs.resetsAt < rhs.resetsAt }
                if lhs.candidate.window.percentUsed != rhs.candidate.window.percentUsed {
                    return lhs.candidate.window.percentUsed < rhs.candidate.window.percentUsed
                }
                return lhs.candidate.capturedAt < rhs.candidate.capturedAt
            }?.candidate
        }

        // Rule 4: undated readings only ever win when nothing dated survived,
        // and then the newest capture is all there is to go on.
        return live.max { $0.capturedAt < $1.capturedAt }
    }

    /// Rule 1 of "Merging" on its own: a window is live until its reset has
    /// passed, and one with no `resets_at` at all can't be shown to have
    /// expired. Shared with ``hasReadingsForOtherAccounts()`` so "this group
    /// would merge into a snapshot" can't drift from the merge itself.
    private static func isLive(_ window: QuotaWindow, asOf now: Date) -> Bool {
        window.resetsAt.map { $0 >= now } ?? true
    }

    /// The `utilization` object from the most recently captured file that
    /// carries one, or `nil` when none does — a normal state, not a fault.
    ///
    /// Not merged window-style: this object is copied out of `~/.claude.json`,
    /// which every session of one login sees identically, so the newest copy is
    /// simply the best one. Always called with a single account group's
    /// readings — the file belongs to whichever account was logged in when it
    /// was copied.
    private func newestUtilization(in readings: [Reading]) -> [String: Any]? {
        readings
            .filter { $0.utilization != nil }
            .max { $0.capturedAt < $1.capturedAt }?
            .utilization
    }
}
