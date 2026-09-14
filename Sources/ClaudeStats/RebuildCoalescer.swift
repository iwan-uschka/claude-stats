import ClaudeStatsCore
import Foundation

/// Tracks whether a rebuild is queued and merges watcher batches that arrive
/// while one is, so a burst of batches — the normal case while a session is
/// active, arriving every couple of seconds — collapses into a single
/// follow-up rebuild instead of each queueing its own.
///
/// Split out of `AppDelegate` so this accumulate/merge/drain behaviour can be
/// tested without touching AppKit — mirrors why `ChangeCoalescer` is split
/// out of `ConfigDirectoryWatcher`, though this one has no timers: "queued"
/// here means "a rebuild is in flight or about to be", not a debounce window.
///
/// Thread-safe: `enqueue` and `drain` are called from different contexts (the
/// watcher's callback and the rebuild queue respectively).
final class RebuildCoalescer: @unchecked Sendable {
    private var queued = false
    private var pending: FileChangeBatch?
    private let lock = NSLock()

    /// Record `batch` as wanting a rebuild. Returns `true` when the caller
    /// should start one now (nothing was already queued); `false` means a
    /// rebuild is already in flight or queued, and `batch` has been folded
    /// into what that rebuild will see via `drain()`.
    func enqueue(_ batch: FileChangeBatch) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let alreadyQueued = queued
        queued = true
        pending = pending.map { $0.merging(batch) } ?? batch
        return !alreadyQueued
    }

    /// Called when a rebuild is about to run. Clears the queued flag and
    /// returns whatever batches accumulated since the triggering `enqueue`,
    /// for the caller to rebuild with.
    func drain() -> FileChangeBatch? {
        lock.lock()
        defer { lock.unlock() }
        queued = false
        let changes = pending
        pending = nil
        return changes
    }
}
