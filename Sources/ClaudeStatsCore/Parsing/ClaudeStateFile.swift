import Foundation

/// Identifies one on-disk state of Claude Code's private state file precisely
/// enough that an atomic same-size replacement can't pass for "unchanged":
/// nanosecond mtime **and** inode, not just mtime.
///
/// Always describes the bytes that were actually read and parsed — it's taken
/// from the same descriptor the read happens on.
public struct ClaudeStateFileFingerprint: Sendable, Hashable {
    /// Which candidate path this describes — a fingerprint from
    /// `$CLAUDE_CONFIG_DIR/.claude.json` must never compare equal to one from
    /// `~/.claude.json`.
    public let url: URL
    public let modifiedAt: Date
    public let size: Int
    public let inode: UInt64

    public init(url: URL, modifiedAt: Date, size: Int, inode: UInt64) {
        self.url = url
        self.modifiedAt = modifiedAt
        self.size = size
        self.inode = inode
    }
}

/// The one place that opens Claude Code's private state file (`~/.claude.json`).
///
/// ## Why this is its own type
///
/// The file is Claude Code's own scratch state, not a documented interface: it
/// holds `userID`, the full `projects` map (every directory Claude Code has
/// ever run in) and command history, alongside the handful of undocumented keys
/// we actually want. Keeping every read behind one type means there is exactly
/// one place that has to honour the rule that **file contents never reach an
/// error, a message or a log**.
///
/// ## The fingerprint gate
///
/// The file is ~145 KB and Claude Code rewrites it constantly for reasons that
/// have nothing to do with us (`numStartups`, `seenNotifications`, …). Callers
/// pass the fingerprint of whatever they last parsed; when the file still
/// matches it, this returns ``LoadResult/unchanged`` after one `open` and one
/// `fstat` — no read, no `JSONSerialization`.
///
/// The `open` → `fstat`-on-that-descriptor → read-that-descriptor sequence is
/// the same single-descriptor trick as
/// `StatuslineCacheReader.readCacheFileWithModificationDate()`, at nanosecond
/// mtime + inode resolution: two separate syscalls could otherwise straddle an
/// atomic `mktemp` + `rename` and pair one file's bytes with another's stat.
///
/// ## No FSEvents coverage
///
/// `ConfigDirectoryWatcher` watches directory trees under the config dir.
/// `~/.claude.json` is a sibling of `~/.claude`, directly in `$HOME`, and
/// watching `$HOME` recursively is not an acceptable cost for one cached
/// feature flag. Reads ride the throttled refresh instead, behind this gate.
enum ClaudeStateFile {
    enum LoadResult {
        /// The file still matches the caller's previous fingerprint.
        case unchanged
        case loaded(root: [String: Any], fingerprint: ClaudeStateFileFingerprint)
        /// No candidate could be opened, or the first one that opened held
        /// something that isn't a JSON object. Both are "no data", never an
        /// error — see ``RateLimitPromoNoticeReader``.
        case unavailable
    }

    /// Probes `candidates` in order; the first path that *opens* wins, even if
    /// its contents turn out to be unusable — a present-but-broken state file
    /// is not a reason to silently read a different one.
    static func load(
        candidates: [URL],
        unchangedSince previous: ClaudeStateFileFingerprint?
    ) -> LoadResult {
        for url in candidates {
            // O_NONBLOCK makes the open itself non-blocking for FIFOs and
            // devices; it has no effect on reads from a regular file, which is
            // the only case that survives the S_IFREG guard below. Without it
            // a FIFO at a candidate path would block this call forever.
            let fd = open(url.path, O_RDONLY | O_NONBLOCK)
            guard fd >= 0 else { continue }
            defer { close(fd) }

            var info = stat()
            guard fstat(fd, &info) == 0 else { return .unavailable }
            // A directory at the path opens fine but can't be read as a state
            // file — the first path that opens still wins, so this is
            // terminal, not a reason to fall through to the next candidate.
            guard info.st_mode & S_IFMT == S_IFREG else { return .unavailable }

            let fingerprint = ClaudeStateFileFingerprint(
                url: url,
                modifiedAt: Date(
                    timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                        + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
                ),
                size: Int(info.st_size),
                inode: UInt64(info.st_ino)
            )
            if let previous, previous == fingerprint { return .unchanged }

            let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                // Deliberately no diagnostic: anything describing what was in
                // there risks leaking the file's contents.
                return .unavailable
            }
            return .loaded(root: root, fingerprint: fingerprint)
        }
        return .unavailable
    }
}
