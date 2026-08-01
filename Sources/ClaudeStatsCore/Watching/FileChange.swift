import Foundation

/// One file-system change reported by the config-directory watcher.
///
/// `path` is an absolute, symlink-resolved path (FSEvents always reports
/// resolved paths, e.g. `/private/var/...` rather than `/var/...`), so callers
/// can use it as a stable identity key for incremental reparsing.
public struct FileChange: Sendable, Hashable {
    /// Absolute, symlink-resolved path of the changed item.
    public var path: String

    /// What happened to the item. An option set because a single coalesced
    /// change can be several things at once (created *and* modified within the
    /// same debounce window).
    public var flags: Flags

    public init(path: String, flags: Flags = []) {
        self.path = path
        self.flags = flags
    }

    /// `path` as a file URL, for callers that prefer URL APIs.
    public var url: URL { URL(fileURLWithPath: path) }

    /// Same path, with the union of both flag sets — used when coalescing
    /// several OS events for one path into a single change.
    public func merging(_ other: FileChange) -> FileChange {
        assert(path == other.path, "merging changes for different paths: \(path) vs \(other.path)")
        return FileChange(path: path, flags: flags.union(other.flags))
    }

    /// Kinds of change, mapped from the raw FSEvents event flags.
    ///
    /// Deliberately a small, stable vocabulary rather than a 1:1 mirror of the
    /// `kFSEventStreamEventFlag*` constants: callers only ever need to know
    /// "does this file need reparsing", "is it gone", or "did we lose events
    /// and need a full rescan".
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// The item came into existence.
        public static let created = Flags(rawValue: 1 << 0)
        /// The item's contents changed (an appended JSONL line, typically).
        public static let modified = Flags(rawValue: 1 << 1)
        /// The item was deleted.
        public static let removed = Flags(rawValue: 1 << 2)
        /// The item was renamed — fires for both the old and the new path, so
        /// callers generally treat it as "re-stat this path".
        public static let renamed = Flags(rawValue: 1 << 3)
        /// Only metadata changed (inode, owner, xattrs) — contents are
        /// unchanged, so a reparse is usually unnecessary.
        public static let metadata = Flags(rawValue: 1 << 4)
        /// The item is a directory rather than a file.
        public static let isDirectory = Flags(rawValue: 1 << 5)
        /// Events were coalesced or dropped by the kernel/daemon, or the
        /// watched root itself changed. Individual paths cannot be trusted —
        /// the caller must rescan the tree. See
        /// ``FileChangeBatch/requiresFullRescan``.
        public static let requiresRescan = Flags(rawValue: 1 << 6)

        /// Flags that imply the file's bytes may have changed, i.e. the ones
        /// worth triggering an incremental reparse for.
        public static let contentAffecting: Flags = [.created, .modified, .removed, .renamed]
    }
}

/// A debounced group of changes: everything the watcher saw within one
/// coalescing window, deduplicated by path.
public struct FileChangeBatch: Sendable, Hashable {
    /// Changed items in first-seen order (stable, so callers and tests get
    /// deterministic ordering), one entry per unique path.
    public let changes: [FileChange]

    /// Enforces the "one entry per unique path" invariant: repeated entries
    /// for the same path have their flags unioned (not just the first kept),
    /// so a caller reporting e.g. `.created` then `.removed` for one path
    /// doesn't lose either half of that information.
    public init(changes: [FileChange]) {
        var merged: [String: FileChange] = [:]
        var order: [String] = []
        for change in changes {
            if let existing = merged[change.path] {
                merged[change.path] = existing.merging(change)
            } else {
                merged[change.path] = change
                order.append(change.path)
            }
        }
        self.changes = order.map { merged[$0]! }
    }

    /// Just the paths, in the same order as ``changes``.
    public var paths: [String] { changes.map(\.path) }

    public var isEmpty: Bool { changes.isEmpty }

    public var count: Int { changes.count }

    /// `true` when the OS told us it dropped or coalesced events (or the
    /// watched root moved). The per-path list is then incomplete and the
    /// caller should rescan the whole tree instead of trusting ``paths``.
    public var requiresFullRescan: Bool {
        changes.contains { $0.flags.contains(.requiresRescan) }
    }

    /// Changes whose contents may have changed — the subset worth reparsing.
    /// Excludes metadata-only touches and directory events.
    public var contentChanges: [FileChange] {
        changes.filter {
            !$0.flags.contains(.isDirectory) && !$0.flags.intersection(.contentAffecting).isEmpty
        }
    }

    /// Convenience for the log-parsing layer: content changes whose path has
    /// the given extension (e.g. `"jsonl"`), case-insensitively.
    public func contentChanges(withExtension ext: String) -> [FileChange] {
        let suffix = "." + ext.lowercased().drop(while: { $0 == "." })
        return contentChanges.filter { $0.path.lowercased().hasSuffix(suffix) }
    }
}
