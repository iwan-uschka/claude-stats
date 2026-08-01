import Foundation

/// Cancellable handle for work scheduled via ``DelayScheduler``.
public protocol ScheduledWork: AnyObject, Sendable {
    /// Best-effort cancellation. May be a no-op if the work already started —
    /// callers must therefore tolerate a late firing (``ChangeCoalescer`` does
    /// so with a generation counter).
    func cancel()
}

/// The one piece of time-dependence in the coalescing logic, factored out so
/// tests can drive it deterministically instead of sleeping.
///
/// Production uses ``DispatchQueueScheduler``; tests use a manual scheduler
/// with a virtual clock.
public protocol DelayScheduler: Sendable {
    /// Run `work` after `delay` seconds. Implementations must invoke `work`
    /// serially with respect to each other, so callers don't need their own
    /// queue hopping.
    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> ScheduledWork
}

/// ``DelayScheduler`` backed by `DispatchQueue.asyncAfter`.
public final class DispatchQueueScheduler: DelayScheduler {
    private let queue: DispatchQueue

    /// - Parameter queue: should be serial; the coalescer relies on its timer
    ///   callbacks not overlapping.
    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    @discardableResult
    public func schedule(
        after delay: TimeInterval,
        _ work: @escaping @Sendable () -> Void
    ) -> ScheduledWork {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return Handle(item: item)
    }

    private final class Handle: ScheduledWork {
        /// `DispatchWorkItem` predates `Sendable` but `cancel()` is documented
        /// as thread-safe, which is all this handle exposes.
        private nonisolated(unsafe) let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
}
