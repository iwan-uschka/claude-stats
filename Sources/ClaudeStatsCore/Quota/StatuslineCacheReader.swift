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
/// a cache file; this type reads that file. Installing that script into the
/// user's real `~/.claude/settings.json` is deliberately **not** done
/// automatically — see `Sources/ClaudeStats/Resources/claude-stats-statusline-cache.sh`
/// for the script (bundled into the app; revealed from Settings) and the wiring
/// instructions in its header comment.
///
/// ## Cache file
///
/// Default location: `~/Library/Application Support/ClaudeStats/statusline-cache.json`.
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
/// reading complete: all four bars at one known age, out of one file this app
/// wrote, instead of three from here and one from a private key that refreshes
/// on somebody else's schedule.
///
/// `utilization` is **optional in every direction**. A cache written before this
/// key existed, one written with no `jq` installed, and one written while
/// `~/.claude.json` was unreadable are all indistinguishable and all fine: the
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
public struct StatuslineCacheReader: QuotaProviding {
    /// Directory name used under Application Support.
    public static let cacheDirectoryName = "ClaudeStats"
    /// File name of the cache within that directory.
    public static let cacheFileName = "statusline-cache.json"
    /// Top-level key holding the copy of `cachedUsageUtilization.utilization`.
    /// Same spelling as ``CachedUtilizationReader/utilizationKey`` on purpose:
    /// the object under it is the same object, so the same parsers read it.
    static let utilizationKey = "utilization"

    /// `~/Library/Application Support/ClaudeStats/statusline-cache.json`.
    ///
    /// Falls back to an explicit path construction if Application Support can't
    /// be resolved, so this is never optional at the call site.
    public static var defaultCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(cacheFileName, isDirectory: false)
    }

    public let cacheURL: URL
    public let stalenessThreshold: TimeInterval
    /// `FileManager` isn't marked `Sendable`, but `.default` and other instances
    /// are documented thread-safe (Apple: "the methods of the shared FileManager
    /// object can be called from multiple threads safely").
    nonisolated(unsafe) private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        cacheURL: URL = StatuslineCacheReader.defaultCacheURL,
        stalenessThreshold: TimeInterval = QuotaSnapshot.defaultStalenessThreshold,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cacheURL = cacheURL
        self.stalenessThreshold = stalenessThreshold
        self.fileManager = fileManager
        self.now = now
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        let (root, mtime) = try loadRoot()

        // A payload captured before the account's first API response has no
        // `rate_limits` at all (and Pro/Max only). That's "no data", not
        // "broken" — fall through quietly.
        guard let windows = QuotaJSON.windows(in: root) else {
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        // No fallback to `now()`: if neither the payload nor the file itself
        // can tell us when this was captured, treat the age as unknown rather
        // than silently trusting it as freshly captured.
        guard let capturedAt = QuotaJSON.capturedAtKeys.lazy.compactMap({ QuotaJSON.date(root[$0]) }).first ?? mtime
        else {
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        // Absent on every cache the helper script wrote before it learned to
        // copy this across, and on every one written without `jq` — hence
        // empty/`nil` rather than a throw. See the type's "Cache file" note.
        let utilization = QuotaJSON.object(root[Self.utilizationKey])
        let credits = utilization.map(QuotaJSON.usageCredits(in:)) ?? .unavailable

        let snapshot = QuotaSnapshot(
            fiveHour: windows.fiveHour,
            sevenDay: windows.sevenDay,
            confidence: .official,
            capturedAt: capturedAt,
            scopedWeekly: utilization.map(QuotaJSON.scopedLimits(in:)) ?? [],
            usageCredits: credits.credits,
            usageCreditsDisabledReason: credits.disabledReason
        )

        guard !snapshot.isStale(asOf: now(), threshold: stalenessThreshold) else {
            throw ClaudeStatsError.staleQuotaSource(snapshot: snapshot, age: snapshot.age(asOf: now()))
        }
        return snapshot
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
        guard let utilization = try loadUtilization() else { return [] }
        return QuotaJSON.scopedLimits(in: utilization)
    }

    /// Same payload as ``currentSnapshot()``, never gated on staleness — the
    /// money half of ``currentScopedWeekly()``, for the same reason. A
    /// month-to-date spend total does not stop being right because the rate
    /// limits captured beside it have aged out.
    public func currentUsageCredits() async throws -> UsageCreditsReading {
        guard let utilization = try loadUtilization() else { return .unavailable }
        return QuotaJSON.usageCredits(in: utilization)
    }

    /// Deletes the cache file, so the next hook write starts from nothing.
    ///
    /// The escape hatch for a reading that looks stuck or wrong: the cache is a
    /// single global path shared by every concurrently-running Claude Code
    /// session, so any one of them can overwrite it with its own last-known
    /// numbers. Removing the file makes the next statusline render the sole
    /// source of what's on screen. Until one happens, ``currentSnapshot()``
    /// throws ``ClaudeStatsError/noQuotaSourceAvailable`` — expected, not a
    /// failure. Best-effort: a missing file is not an error.
    public func clearCache() throws {
        do {
            try fileManager.removeItem(at: cacheURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // already gone — nothing to do
        }
    }

    /// Parses the cache file into its root object, common to
    /// ``currentSnapshot()`` and ``loadUtilization()``.
    ///
    /// Only the two file-level faults throw here — nothing on disk at all, and
    /// something on disk that isn't JSON — because those are the two the
    /// staleness-bypassing readers care about just as much as
    /// ``currentSnapshot()`` does. Everything the root does or doesn't contain
    /// is each caller's own business.
    private func loadRoot() throws -> (root: [String: Any], mtime: Date?) {
        guard let (data, mtime) = readCacheFileWithModificationDate() else {
            // No hook installed, or it has never fired.
            throw ClaudeStatsError.noQuotaSourceAvailable
        }
        guard let root = QuotaJSON.object(try? JSONSerialization.jsonObject(with: data)) else {
            throw ClaudeStatsError.unexpectedQuotaResponse(
                "statusline cache at \(cacheURL.lastPathComponent) is not a JSON object"
            )
        }
        return (root, mtime)
    }

    /// The `utilization` object, or `nil` when this cache carries none — which
    /// is a normal state, not a fault, so it is `nil` rather than a throw. The
    /// file itself being absent or unparseable still throws, via ``loadRoot()``.
    private func loadUtilization() throws -> [String: Any]? {
        QuotaJSON.object(try loadRoot().root[Self.utilizationKey])
    }

    /// Reads the cache file's bytes and modification time from a single open
    /// descriptor, so they always describe the same file state — two separate
    /// syscalls (as `FileManager.contents(atPath:)` followed by
    /// `attributesOfItem(atPath:)`) could otherwise straddle the helper
    /// script's atomic `mktemp` + `mv` rewrite and pair old bytes with a new
    /// mtime (or vice versa).
    private func readCacheFileWithModificationDate() -> (data: Data, mtime: Date?)? {
        let fd = open(cacheURL.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }

        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        let mtime = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
        return (data, mtime)
    }
}
