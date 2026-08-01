import Foundation

/// Debounces a stream of individual file-system events into ``FileChangeBatch``
/// deliveries, deduplicated by path.
///
/// This is the whole timing brain of the watcher, deliberately split out from
/// ``ConfigDirectoryWatcher`` so it can be tested without touching the file
/// system: the only time-dependence is the injected ``DelayScheduler``, so a
/// test can drive a virtual clock and assert exact flush behaviour with no
/// sleeps.
///
/// ## Debounce shape
///
/// Trailing debounce with a ceiling:
///
/// - Every ``record(_:)-1eqhj`` (re)starts a ``debounceInterval`` timer, so a
///   burst of writes collapses into one delivery `debounceInterval` after the
///   *last* event.
/// - ``maximumDelay`` caps how long the oldest un-delivered change can sit
///   there. Without it, a pure trailing debounce would starve indefinitely
///   under continuous activity — which is exactly the normal case here, since
///   Claude Code appends to its session JSONL every few hundred milliseconds
///   during an active session, and the UI would never update.
///
/// The cap timer is started when a batch opens and is *not* reset by later
/// events, so it fires ``maximumDelay`` after the first change in the batch.
/// Whichever timer fires first delivers the batch and cancels the other.
///
/// ## Coalescing rules
///
/// - One entry per unique path; repeated events for the same path merge their
///   ``FileChange/Flags`` (so "created" + "modified" in one window arrives as
///   both).
/// - Changes are delivered in first-seen order, which keeps deliveries
///   deterministic for tests and stable for callers.
///
/// Thread-safe: events arrive on the watcher's queue while `stop()` may be
/// called from anywhere. `onFlush` is always invoked *outside* the internal
/// lock, so callers may re-enter (e.g. call ``flushNow()``) without deadlocking.
public final class ChangeCoalescer: @unchecked Sendable {
    /// Long enough to swallow an editor's write-then-rename dance, short enough
    /// that the menu bar still feels live.
    public static let defaultDebounceInterval: TimeInterval = 0.35

    /// Ceiling on delivery latency during sustained activity. See "Debounce
    /// shape" above for why a trailing debounce alone isn't enough.
    public static let defaultMaximumDelay: TimeInterval = 2.0

    /// Quiet period after the last event before a batch is delivered.
    public let debounceInterval: TimeInterval

    /// Upper bound on how long the first change in a batch waits, or `nil` to
    /// debounce without a ceiling.
    public let maximumDelay: TimeInterval?

    private let scheduler: DelayScheduler
    private let onFlush: @Sendable (FileChangeBatch) -> Void

    private let lock = NSLock()

    // MARK: Lock-guarded state

    /// Paths in first-seen order — the delivery order of a batch.
    private var order: [String] = []
    /// Merged change per path.
    private var pending: [String: FileChange] = [:]
    private var debounceWork: ScheduledWork?
    private var capWork: ScheduledWork?
    /// Bumped on every reschedule and on every flush. A timer callback carrying
    /// a stale token is ignored, which makes us immune to ``ScheduledWork``'s
    /// best-effort cancellation firing late anyway.
    private var debounceToken: UInt64 = 0
    /// Bumped on flush only — the cap timer is never rescheduled mid-batch.
    private var capToken: UInt64 = 0

    /// - Parameters:
    ///   - debounceInterval: Quiet period after the last event before delivery.
    ///   - maximumDelay: Ceiling on the wait for the first change in a batch.
    ///     Pass `nil` for an uncapped trailing debounce. Values below
    ///     `debounceInterval` make the cap the effective interval.
    ///   - scheduler: Injected timing. Production passes
    ///     ``DispatchQueueScheduler``; tests pass a manual virtual-clock one.
    ///   - onFlush: Called once per batch, on whatever context the scheduler
    ///     runs work on (the watcher's serial queue in production). Never
    ///     called with an empty batch.
    public init(
        debounceInterval: TimeInterval = ChangeCoalescer.defaultDebounceInterval,
        maximumDelay: TimeInterval? = ChangeCoalescer.defaultMaximumDelay,
        scheduler: DelayScheduler,
        onFlush: @escaping @Sendable (FileChangeBatch) -> Void
    ) {
        precondition(debounceInterval >= 0, "debounceInterval must be non-negative")
        precondition(maximumDelay.map { $0 >= 0 } ?? true, "maximumDelay must be non-negative")
        self.debounceInterval = debounceInterval
        self.maximumDelay = maximumDelay
        self.scheduler = scheduler
        self.onFlush = onFlush
    }

    deinit {
        // Don't deliver on the way out, just release the timers.
        lock.lock()
        debounceWork?.cancel()
        capWork?.cancel()
        lock.unlock()
    }

    // MARK: Inspection

    /// `true` while at least one change is waiting for its window to close.
    public var hasPendingChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    /// Number of unique paths currently waiting for delivery.
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    // MARK: Recording

    /// Record one change, (re)opening the debounce window.
    public func record(_ change: FileChange) {
        record([change])
    }

    /// Record several changes as one arrival — the natural shape for FSEvents,
    /// which hands over an array of paths per callback.
    ///
    /// Recording an empty sequence is a no-op and does not disturb a window
    /// that's already open.
    public func record<S: Sequence>(_ changes: S) where S.Element == FileChange {
        lock.lock()

        var recorded = false
        for change in changes {
            recorded = true
            if let existing = pending[change.path] {
                pending[change.path] = existing.merging(change)
            } else {
                pending[change.path] = change
                order.append(change.path)
            }
        }

        guard recorded else {
            lock.unlock()
            return
        }

        debounceToken &+= 1
        let debounceGeneration = debounceToken
        let previousDebounce = debounceWork
        debounceWork = nil

        // The cap timer belongs to the batch, not to the latest event, so only
        // start one when this change opened a fresh batch.
        let capGeneration = capToken
        let needsCapTimer = maximumDelay != nil && capWork == nil

        lock.unlock()

        // Scheduling happens outside the lock: a scheduler is free to run work
        // synchronously (a zero-delay test scheduler would), and re-entering
        // `record`/`fire` while holding a non-recursive lock would deadlock.
        previousDebounce?.cancel()

        let newDebounce = scheduler.schedule(after: debounceInterval) { [weak self] in
            self?.fire(.debounce(debounceGeneration))
        }

        var newCap: ScheduledWork?
        if needsCapTimer, let maximumDelay {
            newCap = scheduler.schedule(after: maximumDelay) { [weak self] in
                self?.fire(.cap(capGeneration))
            }
        }

        // Store the handles back — unless a flush happened while we were
        // scheduling, in which case these timers are already obsolete.
        lock.lock()
        if debounceToken == debounceGeneration {
            debounceWork = newDebounce
        } else {
            newDebounce.cancel()
        }
        if let newCap {
            if capToken == capGeneration, capWork == nil {
                capWork = newCap
            } else {
                newCap.cancel()
            }
        }
        lock.unlock()
    }

    // MARK: Delivery

    /// Deliver whatever is pending immediately, bypassing the debounce window
    /// and clearing both timers. No-op when nothing is pending.
    public func flushNow() {
        guard let batch = takeBatch() else { return }
        onFlush(batch)
    }

    /// Discard pending changes without delivering them, and clear the timers.
    /// Used by ``ConfigDirectoryWatcher/stop()`` so a stopped watcher can't
    /// emit a trailing batch.
    public func cancelPending() {
        _ = takeBatch()
    }

    private enum Trigger {
        case debounce(UInt64)
        case cap(UInt64)
    }

    private func fire(_ trigger: Trigger) {
        lock.lock()
        let isCurrent: Bool
        switch trigger {
        case .debounce(let generation): isCurrent = generation == debounceToken
        case .cap(let generation): isCurrent = generation == capToken
        }
        guard isCurrent, let batch = takeBatchLocked() else {
            lock.unlock()
            return
        }
        lock.unlock()
        onFlush(batch)
    }

    private func takeBatch() -> FileChangeBatch? {
        lock.lock()
        defer { lock.unlock() }
        return takeBatchLocked()
    }

    /// Invalidate both timers and drain pending state. Returns `nil` when there
    /// was nothing to deliver. The caller must hold `lock`.
    private func takeBatchLocked() -> FileChangeBatch? {
        debounceToken &+= 1
        capToken &+= 1
        debounceWork?.cancel()
        debounceWork = nil
        capWork?.cancel()
        capWork = nil

        guard !pending.isEmpty else { return nil }
        let changes = order.compactMap { pending[$0] }
        order.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        return FileChangeBatch(changes: changes)
    }
}
