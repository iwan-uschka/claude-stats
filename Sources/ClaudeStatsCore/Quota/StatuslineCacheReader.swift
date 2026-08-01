import Foundation

/// Reads the on-disk cache of Claude Code's `statusLine` rate-limit payload
/// (`.official` confidence — the strongest source we have).
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
/// automatically — see `scripts/claude-stats-statusline-cache.sh` for the script
/// and the wiring instructions the app should surface in Settings.
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
///   }
/// }
/// ```
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
/// ``ClaudeStatsError/noQuotaSourceAvailable`` so ``CompositeQuotaProvider``
/// falls through to the next tier instead of showing a confidently wrong number.
public struct StatuslineCacheReader: QuotaProviding {
    /// Directory name used under Application Support.
    public static let cacheDirectoryName = "ClaudeStats"
    /// File name of the cache within that directory.
    public static let cacheFileName = "statusline-cache.json"

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
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        cacheURL: URL = StatuslineCacheReader.defaultCacheURL,
        stalenessThreshold: TimeInterval = QuotaSnapshot.defaultStalenessThreshold,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cacheURL = cacheURL
        self.stalenessThreshold = stalenessThreshold
        self.fileManager = fileManager
        self.now = now
    }

    public func currentSnapshot() async throws -> QuotaSnapshot {
        guard let (data, mtime) = readCacheFileWithModificationDate() else {
            // No hook installed, or it has never fired.
            throw ClaudeStatsError.noQuotaSourceAvailable
        }

        guard let root = QuotaJSON.object(try? JSONSerialization.jsonObject(with: data)) else {
            throw ClaudeStatsError.unexpectedQuotaResponse(
                "statusline cache at \(cacheURL.lastPathComponent) is not a JSON object"
            )
        }

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

        let snapshot = QuotaSnapshot(
            fiveHour: windows.fiveHour,
            sevenDay: windows.sevenDay,
            confidence: .official,
            capturedAt: capturedAt
        )

        guard !snapshot.isStale(asOf: now(), threshold: stalenessThreshold) else {
            throw ClaudeStatsError.noQuotaSourceAvailable
        }
        return snapshot
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
