import XCTest
@testable import ClaudeStats
@testable import ClaudeStatsCore

/// Accumulate/merge/drain behaviour, with no AppKit dependency and no
/// wall-clock timing involved.
final class RebuildCoalescerTests: XCTestCase {
    func testFirstEnqueueReturnsTrue() {
        let coalescer = RebuildCoalescer()
        let batch = FileChangeBatch(changes: [FileChange(path: "/a.jsonl", flags: .modified)])

        XCTAssertTrue(coalescer.enqueue(batch), "nothing queued yet, so the caller should start a rebuild")
    }

    func testSecondEnqueueWhileQueuedReturnsFalseAndMerges() {
        let coalescer = RebuildCoalescer()
        let first = FileChangeBatch(changes: [FileChange(path: "/a.jsonl", flags: .modified)])
        let second = FileChangeBatch(changes: [FileChange(path: "/b.jsonl", flags: .created)])

        XCTAssertTrue(coalescer.enqueue(first))
        XCTAssertFalse(coalescer.enqueue(second), "a rebuild is already queued; this batch should fold in instead")

        let drained = coalescer.drain()
        XCTAssertEqual(drained?.paths, ["/a.jsonl", "/b.jsonl"])
    }

    func testDrainClearsQueuedFlagSoTheNextEnqueueStartsAFreshRebuild() {
        let coalescer = RebuildCoalescer()
        let batch = FileChangeBatch(changes: [FileChange(path: "/a.jsonl", flags: .modified)])

        _ = coalescer.enqueue(batch)
        _ = coalescer.drain()

        XCTAssertTrue(coalescer.enqueue(batch), "draining should have cleared the queued flag")
    }

    func testDrainWithNothingPendingReturnsNil() {
        let coalescer = RebuildCoalescer()

        XCTAssertNil(coalescer.drain())
    }
}
