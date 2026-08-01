import XCTest
@testable import ClaudeStatsCore

/// Coalescing/debounce behaviour, driven entirely by a virtual clock — no
/// file system, no sleeps, no wall-clock dependence.
final class ChangeCoalescerTests: XCTestCase {
    private let interval: TimeInterval = 0.35

    // MARK: Debounce window

    func testBurstCollapsesIntoOneBatchAfterQuietPeriod() {
        let (coalescer, scheduler, recorder) = makeCoalescer()

        coalescer.record(FileChange(path: "/a.jsonl", flags: .modified))
        coalescer.record(FileChange(path: "/b.jsonl", flags: .modified))
        coalescer.record(FileChange(path: "/c.jsonl", flags: .created))

        // Still inside the window: nothing delivered yet.
        scheduler.advance(by: interval - 0.01)
        XCTAssertEqual(recorder.batches.count, 0)
        XCTAssertEqual(coalescer.pendingCount, 3)

        scheduler.advance(by: 0.02)
        XCTAssertEqual(recorder.batches.count, 1)
        // First-seen order, one entry per path.
        XCTAssertEqual(recorder.batches[0].paths, ["/a.jsonl", "/b.jsonl", "/c.jsonl"])
        XCTAssertFalse(coalescer.hasPendingChanges)
    }

    func testEveryEventRestartsTheWindow() {
        let (coalescer, scheduler, recorder) = makeCoalescer()

        // Six events, each 0.3s apart with a 0.35s debounce: never quiet, so a
        // trailing debounce alone must not deliver.
        for index in 0..<6 {
            coalescer.record(FileChange(path: "/f\(index).jsonl", flags: .modified))
            scheduler.advance(by: 0.3)
        }
        XCTAssertEqual(recorder.batches.count, 0, "window should keep being pushed out")

        scheduler.advance(by: 0.05)
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.batches[0].count, 6)
    }

    func testSubsequentBatchGetsAFreshWindow() {
        let (coalescer, scheduler, recorder) = makeCoalescer()

        coalescer.record(FileChange(path: "/a.jsonl", flags: .modified))
        scheduler.advance(by: interval)
        XCTAssertEqual(recorder.batches.count, 1)

        coalescer.record(FileChange(path: "/b.jsonl", flags: .modified))
        scheduler.advance(by: interval - 0.01)
        XCTAssertEqual(recorder.batches.count, 1, "second window shouldn't inherit the first's elapsed time")

        scheduler.advance(by: 0.02)
        XCTAssertEqual(recorder.batches.count, 2)
        XCTAssertEqual(recorder.batches[1].paths, ["/b.jsonl"])
    }

    func testIdleCoalescerDeliversNothing() {
        let (_, scheduler, recorder) = makeCoalescer()
        scheduler.advance(by: 10)
        XCTAssertEqual(recorder.batches.count, 0)
    }

    func testRecordingNothingIsANoOp() {
        let (coalescer, scheduler, recorder) = makeCoalescer()

        coalescer.record([FileChange]())
        XCTAssertFalse(coalescer.hasPendingChanges)
        scheduler.advance(by: 10)
        XCTAssertEqual(recorder.batches.count, 0, "an empty arrival must not schedule an empty delivery")
    }

    // MARK: Deduplication

    func testRepeatedPathsDeduplicateAndMergeFlags() {
        let (coalescer, scheduler, recorder) = makeCoalescer()

        coalescer.record(FileChange(path: "/s.jsonl", flags: .created))
        coalescer.record(FileChange(path: "/s.jsonl", flags: .modified))
        coalescer.record(FileChange(path: "/s.jsonl", flags: .modified))
        XCTAssertEqual(coalescer.pendingCount, 1)

        scheduler.advance(by: interval)

        XCTAssertEqual(recorder.batches.count, 1)
        let batch = recorder.batches[0]
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.changes[0].flags, [.created, .modified])
    }

    func testFirstSeenOrderSurvivesInterleavedRepeats() {
        let (coalescer, scheduler, recorder) = makeCoalescer()

        coalescer.record(FileChange(path: "/b.jsonl", flags: .modified))
        coalescer.record(FileChange(path: "/a.jsonl", flags: .modified))
        coalescer.record(FileChange(path: "/b.jsonl", flags: .modified))
        coalescer.record(FileChange(path: "/c.jsonl", flags: .modified))
        coalescer.record(FileChange(path: "/a.jsonl", flags: .removed))

        scheduler.advance(by: interval)

        XCTAssertEqual(recorder.batches[0].paths, ["/b.jsonl", "/a.jsonl", "/c.jsonl"])
    }

    // MARK: Maximum-delay ceiling

    func testMaximumDelayDeliversDuringSustainedActivity() {
        // The realistic case: Claude Code appends to its JSONL faster than the
        // debounce interval for minutes on end. Without the ceiling the UI
        // would never update.
        let (coalescer, scheduler, recorder) = makeCoalescer(maximumDelay: 1.0)

        for index in 0..<10 {
            coalescer.record(FileChange(path: "/f\(index).jsonl", flags: .modified))
            scheduler.advance(by: 0.2)
        }

        XCTAssertEqual(recorder.batches.count, 2, "should have fired at the 1.0s and 2.0s ceilings")
        XCTAssertEqual(recorder.batches[0].count, 5, "first ceiling covers the first 1.0s of events")
        XCTAssertEqual(recorder.batches[0].paths.first, "/f0.jsonl")
        XCTAssertEqual(recorder.batches[1].paths.first, "/f5.jsonl", "second batch starts where the first ended")
    }

    func testMaximumDelayIsMeasuredFromTheFirstChangeInTheBatch() {
        let (coalescer, scheduler, recorder) = makeCoalescer(maximumDelay: 1.0)

        // Events every 0.2s — always inside the 0.35s debounce, so only the
        // ceiling can end this batch.
        for index in 0..<5 {
            coalescer.record(FileChange(path: "/f\(index).jsonl", flags: .modified))
            if index < 4 { scheduler.advance(by: 0.2) }
        }

        // 0.8s of events so far; the ceiling must still sit at 1.0s after the
        // *first* change, not have been pushed out by the later four.
        scheduler.advance(by: 0.19)
        XCTAssertEqual(recorder.batches.count, 0)
        XCTAssertEqual(scheduler.currentTime, 0.99, accuracy: 0.0001)

        scheduler.advance(by: 0.02) // crosses 1.0s since /f0.jsonl
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.batches[0].count, 5)
    }

    func testQuietBurstStillUsesTheShorterDebounce() {
        let (coalescer, scheduler, recorder) = makeCoalescer(maximumDelay: 1.0)

        coalescer.record(FileChange(path: "/a.jsonl", flags: .modified))
        scheduler.advance(by: interval)

        XCTAssertEqual(recorder.batches.count, 1, "debounce wins when activity stops")
        XCTAssertLessThan(scheduler.currentTime, 1.0)

        // Both timers must be invalidated by a delivery — a surviving ceiling
        // timer would later fire on an empty batch (or leak).
        XCTAssertEqual(scheduler.pendingCount, 0)

        scheduler.advance(by: 5)
        XCTAssertEqual(recorder.batches.count, 1)
    }

    func testMaximumDelayShorterThanDebounceBecomesTheEffectiveInterval() {
        let (coalescer, scheduler, recorder) = makeCoalescer(maximumDelay: 0.1) // < interval (0.35)
        coalescer.record(FileChange(path: "/a.jsonl", flags: .modified))
        scheduler.advance(by: 0.1)
        XCTAssertEqual(recorder.batches.count, 1, "cap should win when it's shorter than the debounce window")
    }

    // MARK: Manual flush / cancel

    func testFlushNowDeliversImmediatelyAndOnlyOnce() {
        let (coalescer, scheduler, recorder) = makeCoalescer(maximumDelay: 1.0)

        coalescer.record(FileChange(path: "/a.jsonl", flags: .modified))
        coalescer.flushNow()

        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.batches[0].paths, ["/a.jsonl"])
        XCTAssertFalse(coalescer.hasPendingChanges)

        // Neither the debounce nor the ceiling timer may re-deliver.
        scheduler.advance(by: 10)
        XCTAssertEqual(recorder.batches.count, 1)
    }

    func testFlushNowWithNothingPendingDoesNotDeliverAnEmptyBatch() {
        let (coalescer, _, recorder) = makeCoalescer()
        coalescer.flushNow()
        XCTAssertEqual(recorder.batches.count, 0)
    }

    func testCancelPendingDropsChangesWithoutDelivering() {
        let (coalescer, scheduler, recorder) = makeCoalescer(maximumDelay: 1.0)

        coalescer.record(FileChange(path: "/a.jsonl", flags: .modified))
        coalescer.cancelPending()
        XCTAssertFalse(coalescer.hasPendingChanges)

        scheduler.advance(by: 10)
        XCTAssertEqual(recorder.batches.count, 0)
    }

    func testRecordingAfterCancelStartsCleanly() {
        let (coalescer, scheduler, recorder) = makeCoalescer(maximumDelay: 1.0)

        coalescer.record(FileChange(path: "/a.jsonl", flags: .modified))
        coalescer.cancelPending()

        coalescer.record(FileChange(path: "/b.jsonl", flags: .modified))
        scheduler.advance(by: interval)

        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.batches[0].paths, ["/b.jsonl"], "cancelled changes must not resurface")
    }

    func testDeallocatingTheCoalescerReleasesTimersWithoutDelivering() {
        let scheduler = ManualScheduler()
        let recorder = BatchRecorder()
        var coalescer: ChangeCoalescer? = ChangeCoalescer(
            debounceInterval: interval,
            maximumDelay: 1.0,
            scheduler: scheduler,
            onFlush: { [recorder] batch in recorder.append(batch) }
        )
        coalescer?.record(FileChange(path: "/a.jsonl", flags: .modified))
        coalescer = nil

        scheduler.advance(by: 10)
        XCTAssertEqual(recorder.batches.count, 0)
    }

    // MARK: Batch conveniences (what callers actually act on)

    func testBatchSeparatesContentChangesFromNoise() {
        let batch = FileChangeBatch(changes: [
            FileChange(path: "/p/session.jsonl", flags: .modified),
            FileChange(path: "/p/notes.txt", flags: .created),
            FileChange(path: "/p", flags: [.modified, .isDirectory]),
            FileChange(path: "/p/touched.jsonl", flags: .metadata),
        ])

        XCTAssertEqual(batch.contentChanges.map(\.path), ["/p/session.jsonl", "/p/notes.txt"])
        XCTAssertEqual(batch.contentChanges(withExtension: "jsonl").map(\.path), ["/p/session.jsonl"])
        XCTAssertFalse(batch.requiresFullRescan)
    }

    func testBatchFlagsAFullRescanWhenEventsWereDropped() {
        let batch = FileChangeBatch(changes: [
            FileChange(path: "/p/session.jsonl", flags: .modified),
            FileChange(path: "/p", flags: [.requiresRescan, .isDirectory]),
        ])
        XCTAssertTrue(batch.requiresFullRescan)
    }

    // MARK: Helpers

    private func makeCoalescer(
        maximumDelay: TimeInterval? = nil
    ) -> (ChangeCoalescer, ManualScheduler, BatchRecorder) {
        let scheduler = ManualScheduler()
        let recorder = BatchRecorder()
        let coalescer = ChangeCoalescer(
            debounceInterval: interval,
            maximumDelay: maximumDelay,
            scheduler: scheduler,
            onFlush: { [recorder] batch in recorder.append(batch) }
        )
        return (coalescer, scheduler, recorder)
    }
}

// MARK: - Test doubles

/// ``DelayScheduler`` on a virtual clock: work runs only when a test calls
/// ``advance(by:)``, in deadline order, with the clock set to each item's
/// deadline as it runs (so work scheduled from within work gets the right base).
final class ManualScheduler: DelayScheduler {
    private let state = State()

    /// Virtual seconds elapsed since creation.
    var currentTime: TimeInterval { state.now }

    /// Scheduled, not-yet-fired, not-cancelled work items.
    var pendingCount: Int { state.pendingCount }

    @discardableResult
    func schedule(
        after delay: TimeInterval,
        _ work: @escaping @Sendable () -> Void
    ) -> ScheduledWork {
        state.insert(deadline: state.now + max(0, delay), work: work)
    }

    /// Move the clock forward, firing everything that comes due.
    func advance(by delta: TimeInterval) {
        state.advance(by: delta)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: TimeInterval = 0
        private var items: [Item] = []

        var now: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return _now
        }

        var pendingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return items.filter { !$0.isCancelled }.count
        }

        func insert(deadline: TimeInterval, work: @escaping @Sendable () -> Void) -> Item {
            let item = Item(deadline: deadline, work: work)
            lock.lock()
            items.append(item)
            lock.unlock()
            return item
        }

        func advance(by delta: TimeInterval) {
            let target = now + delta
            while let next = takeNextDue(upTo: target) {
                next.work()
            }
            lock.lock()
            _now = target
            lock.unlock()
        }

        /// Repeated `advance(by:)` calls accumulate binary-floating-point error
        /// (ten 0.2s steps land on 1.9999999999999998, not 2.0), which would
        /// otherwise make a deadline sitting exactly on a step boundary look
        /// un-due. A nanosecond of slack keeps tests expressing intent instead
        /// of encoding float drift; it's far smaller than any interval under
        /// test, and a real dispatch timer wouldn't miss by 2e-16 either.
        private static let epsilon: TimeInterval = 1e-9

        /// Earliest live item due at or before `target`, removing it and moving
        /// the clock to its deadline. Cancelled items are dropped silently.
        private func takeNextDue(upTo target: TimeInterval) -> Item? {
            lock.lock()
            defer { lock.unlock() }
            let cutoff = target + State.epsilon
            while true {
                guard
                    let index = items.indices
                        .filter({ items[$0].deadline <= cutoff })
                        .min(by: { items[$0].deadline < items[$1].deadline })
                else { return nil }
                let item = items.remove(at: index)
                guard item.isCancelled else {
                    _now = item.deadline
                    return item
                }
            }
        }
    }

    /// All stored properties are immutable and `Sendable`, so this satisfies
    /// ``ScheduledWork``'s `Sendable` requirement without an unchecked escape;
    /// the mutable cancellation bit lives in ``Flag``.
    final class Item: ScheduledWork {
        let deadline: TimeInterval
        let work: @Sendable () -> Void
        private let cancelled = Flag()

        var isCancelled: Bool { cancelled.isSet }

        init(deadline: TimeInterval, work: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.work = work
        }

        func cancel() { cancelled.set() }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }
}

/// Thread-safe collector for delivered batches. Also used by the integration
/// test, where deliveries arrive on the watcher's queue.
final class BatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FileChangeBatch] = []

    var batches: [FileChangeBatch] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ batch: FileChangeBatch) {
        lock.lock()
        storage.append(batch)
        lock.unlock()
    }
}
