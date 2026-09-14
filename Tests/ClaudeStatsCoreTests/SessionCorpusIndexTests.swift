import XCTest
@testable import ClaudeStatsCore

/// Coverage for the incremental rebuild path: stat-based change detection,
/// deletion handling, and retention folding. Hermetic — a temp config
/// directory, a frozen (mutable) clock, and a parse-counting seam.
final class SessionCorpusIndexTests: XCTestCase {

    /// Every timestamp below is relative to this instant.
    static let referenceNow = SessionLogParser.parseTimestamp("2026-07-15T12:00:00.000Z")!

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Mutable clock, safe to hand to the index's `@Sendable` now-provider.
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// Counts which files the index actually reparses.
    private final class ParseCounter {
        private(set) var parsedPaths: [String] = []
        func reset() { parsedPaths = [] }
        func parse(_ url: URL) -> SessionLogParser.ParseResult {
            parsedPaths.append(url.lastPathComponent)
            return SessionLogParser().parse(fileAt: url)
        }
    }

    // MARK: - Fixture helpers

    private var configDirectory: URL!
    private var projectDirectory: URL!

    override func setUpWithError() throws {
        configDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corpus-index-tests-\(UUID().uuidString)", isDirectory: true)
        projectDirectory = configDirectory.appendingPathComponent("projects/-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        addTeardownBlock { [configDirectory] in
            if let configDirectory { try? FileManager.default.removeItem(at: configDirectory) }
        }
    }

    /// One `assistant` JSONL line carrying usage, `hoursAgo` before `referenceNow`.
    private func assistantLine(hoursAgo: Double, model: String = "claude-sonnet-5", entrypoint: String = "cli", inputTokens: Int = 100, outputTokens: Int = 50) -> String {
        let timestamp = Self.referenceNow.addingTimeInterval(-hoursAgo * 3600)
        let iso = timestamp.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return #"{"type":"assistant","entrypoint":"\#(entrypoint)","timestamp":"\#(iso)","isSidechain":false,"sessionId":"s1","message":{"role":"assistant","model":"\#(model)","usage":{"input_tokens":\#(inputTokens),"output_tokens":\#(outputTokens),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    }

    private func writeSession(_ name: String, lines: [String]) throws -> URL {
        let url = projectDirectory.appendingPathComponent("\(name).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    /// Rewrite a session file with `lines`, so both its size and its mtime move.
    private func rewrite(_ url: URL, lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    /// A watcher change for one session file, in the path space the index scans
    /// (see `testBothSpellingsOfABatchPathReachTheSameFile` for the other one).
    private func change(_ name: String, flags: FileChange.Flags) -> FileChange {
        FileChange(path: projectDirectory.appendingPathComponent("\(name).jsonl").path, flags: flags)
    }

    private func batch(_ changes: FileChange...) -> FileChangeBatch {
        FileChangeBatch(changes: changes)
    }

    private func makeIndex(clock: Clock, counter: ParseCounter, retention: TimeInterval = SessionCorpusIndex.defaultRetention) -> SessionCorpusIndex {
        SessionCorpusIndex(
            configDirectory: configDirectory,
            retention: retention,
            calendar: Self.utcCalendar,
            now: { clock.now },
            parseFile: { counter.parse($0) }
        )
    }

    // MARK: - Incremental reparse

    func testSecondRebuildWithoutChangesParsesNothing() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1)])
        _ = try writeSession("b", lines: [assistantLine(hoursAgo: 2)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)

        let first = index.rebuild()
        XCTAssertEqual(counter.parsedPaths.sorted(), ["a.jsonl", "b.jsonl"])
        XCTAssertEqual(first.events.count, 2)

        counter.reset()
        let second = index.rebuild()
        XCTAssertEqual(counter.parsedPaths, [], "unchanged corpus must not reparse anything")
        XCTAssertEqual(second.events.count, 2)
    }

    func testOnlyChangedFileIsReparsed() throws {
        let urlA = try writeSession("a", lines: [assistantLine(hoursAgo: 1)])
        _ = try writeSession("b", lines: [assistantLine(hoursAgo: 2)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        _ = index.rebuild()

        // Append a line — size (and mtime) change.
        let appended = [assistantLine(hoursAgo: 1), assistantLine(hoursAgo: 0.5)]
        try Data((appended.joined(separator: "\n") + "\n").utf8).write(to: urlA)

        counter.reset()
        let store = index.rebuild()
        XCTAssertEqual(counter.parsedPaths, ["a.jsonl"], "only the touched file gets reparsed")
        XCTAssertEqual(store.events.count, 3)
    }

    /// The snapshot is assembled in scan order rather than by re-sorting
    /// `files.keys`, so this pins the ordering guarantee that swap relies on.
    ///
    /// Every line carries the *same* timestamp: `LocalLogUsageStore.init` leaves
    /// an already-ordered event array untouched, so with all timestamps tied the
    /// stored order is exactly the assembly order, and a Dictionary-iteration
    /// regression would show up here as a shuffled `inputTokens` sequence.
    func testSnapshotAssemblyFollowsSortedPathOrderWhenTimestampsTie() throws {
        // Written back-to-front so creation order and path order disagree.
        _ = try writeSession("c", lines: [assistantLine(hoursAgo: 1, inputTokens: 300)])
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        _ = try writeSession("b", lines: [assistantLine(hoursAgo: 1, inputTokens: 200)])
        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())

        XCTAssertEqual(
            index.rebuild().events.map(\.usage.inputTokens), [100, 200, 300],
            "events must be assembled in sorted-path order"
        )

        // And stably across rebuilds — the second pass takes the all-cached
        // branch, which is where a scan-order bug would diverge from a key sort.
        XCTAssertEqual(
            index.rebuild().events.map(\.usage.inputTokens), [100, 200, 300],
            "a no-reparse rebuild must assemble in the same order"
        )
    }

    /// A file that disappears between the scan and the assembly must be skipped,
    /// not crash the rebuild — the assembly loop walks scanned paths and looks
    /// each entry up, so a missing one has to be tolerated.
    func testFileDeletedBetweenRebuildsLeavesAssemblyIntact() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let urlB = try writeSession("b", lines: [assistantLine(hoursAgo: 1, inputTokens: 200)])
        _ = try writeSession("c", lines: [assistantLine(hoursAgo: 1, inputTokens: 300)])
        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())
        XCTAssertEqual(index.rebuild().events.count, 3)

        try FileManager.default.removeItem(at: urlB)
        XCTAssertEqual(
            index.rebuild().events.map(\.usage.inputTokens), [100, 300],
            "the surviving files keep their order with the deleted one gone"
        )
    }

    func testDeletedFileDropsItsEvents() throws {
        let urlA = try writeSession("a", lines: [assistantLine(hoursAgo: 1)])
        _ = try writeSession("b", lines: [assistantLine(hoursAgo: 2)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 2)

        try FileManager.default.removeItem(at: urlA)
        let store = index.rebuild()
        XCTAssertEqual(store.events.count, 1)
    }

    func testNewFileIsPickedUp() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 1)

        _ = try writeSession("c", lines: [assistantLine(hoursAgo: 0.25)])
        counter.reset()
        let store = index.rebuild()
        XCTAssertEqual(counter.parsedPaths, ["c.jsonl"])
        XCTAssertEqual(store.events.count, 2)
    }

    // MARK: - Retention folding

    func testOldEventsFoldIntoHistoricalTotals() throws {
        // One event well inside retention, one far outside (30 days).
        _ = try writeSession("a", lines: [
            assistantLine(hoursAgo: 1, inputTokens: 100, outputTokens: 50),
            assistantLine(hoursAgo: 30 * 24, inputTokens: 1000, outputTokens: 500),
        ])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)

        let store = index.rebuild()
        XCTAssertEqual(store.events.count, 1, "pre-cutoff event must not stay in the event array")
        let folded = try XCTUnwrap(store.historicalByModel["claude-sonnet-5"])
        XCTAssertEqual(folded.usage.totalTokens, 1500)

        // All-time model usage still sees both events' tokens.
        let allTime = try store.modelUsage(last24h: false)
        XCTAssertEqual(allTime.count, 1)
        XCTAssertEqual(allTime[0].tokens, 1650)
        // Rolling windows only see the retained event.
        let last24h = try store.modelUsage(last24h: true)
        XCTAssertEqual(last24h.count, 1)
        XCTAssertEqual(last24h[0].tokens, 150)
    }

    func testEventsAgingPastCutoffFoldWithoutReparse() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100, outputTokens: 50)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)

        var store = index.rebuild()
        XCTAssertEqual(store.events.count, 1)
        XCTAssertTrue(store.historicalByModel.isEmpty)

        // 10 days later, the file untouched: the event is past the 8-day
        // retention and must fold — without the file being reparsed.
        clock.now = Self.referenceNow.addingTimeInterval(10 * 86_400)
        counter.reset()
        store = index.rebuild()
        XCTAssertEqual(counter.parsedPaths, [])
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.historicalByModel["claude-sonnet-5"]?.usage.totalTokens, 150)

        // And it must not be counted twice across further rebuilds.
        store = index.rebuild()
        XCTAssertEqual(store.historicalByModel["claude-sonnet-5"]?.usage.totalTokens, 150)
        XCTAssertEqual(try store.modelUsage(last24h: false).first?.tokens, 150)
    }

    func testReparseAfterFoldDoesNotDoubleCount() throws {
        // Old event already folded; then the file changes (append) and gets
        // fully reparsed — the fold must be rebuilt from scratch, not added on top.
        let url = try writeSession("a", lines: [assistantLine(hoursAgo: 30 * 24, inputTokens: 1000, outputTokens: 500)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        var store = index.rebuild()
        XCTAssertEqual(store.historicalByModel["claude-sonnet-5"]?.usage.totalTokens, 1500)

        let lines = [
            assistantLine(hoursAgo: 30 * 24, inputTokens: 1000, outputTokens: 500),
            assistantLine(hoursAgo: 1, inputTokens: 100, outputTokens: 50),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)

        store = index.rebuild()
        XCTAssertEqual(store.historicalByModel["claude-sonnet-5"]?.usage.totalTokens, 1500)
        XCTAssertEqual(try store.modelUsage(last24h: false).first?.tokens, 1650)
    }

    // MARK: - Daily history

    func testDailyHistorySpansTheFoldBoundary() throws {
        // One event on each side of the 8-day retention cutoff: the old one can
        // only reach the chart through the folded daily cells, the recent one
        // only through the retained events. Both have to land on their own day.
        _ = try writeSession("a", lines: [
            assistantLine(hoursAgo: 20 * 24, inputTokens: 1000, outputTokens: 500),
            assistantLine(hoursAgo: 1, inputTokens: 100, outputTokens: 50),
        ])
        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())

        let history = try index.rebuild().dailyUsage(days: 30)

        XCTAssertEqual(history.days.count, 21)  // 20 days back … today
        XCTAssertEqual(history.total.first?.totalTokens, 1500)
        XCTAssertEqual(history.total.last?.totalTokens, 150)
        XCTAssertEqual(history.total.reduce(0) { $0 + $1.totalTokens }, 1650)
    }

    func testAnAgedZeroUsageEventOpensNoDailyCell() throws {
        // Claude Code's `<synthetic>` assistant lines carry an all-zero usage
        // block. Aged past retention they still fold, and a cell for one would
        // stretch the chart's axis back over a stretch of nothing — the axis
        // starts at the oldest day that *has* a cell.
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 20 * 24, inputTokens: 0, outputTokens: 0)])
        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())

        let history = try index.rebuild().dailyUsage(days: 30)

        XCTAssertTrue(history.days.isEmpty, "an all-zero-usage day should not stretch the axis")
    }

    func testDailyHistoryMatchesFullParse() throws {
        _ = try writeSession("a", lines: [
            assistantLine(hoursAgo: 25 * 24, model: "claude-opus-5", inputTokens: 10, outputTokens: 5),
            assistantLine(hoursAgo: 12 * 24, model: "claude-sonnet-5", inputTokens: 100, outputTokens: 50),
            assistantLine(hoursAgo: 1, model: "claude-sonnet-5", inputTokens: 1, outputTokens: 1),
        ])
        let clock = Clock(Self.referenceNow)
        let incremental = try makeIndex(clock: clock, counter: ParseCounter())
            .rebuild()
            .dailyUsage(days: 30)

        // The full-parse path keeps every event whole, so it is the reference
        // for what the fold must reproduce.
        let full = try LocalLogUsageStore(
            configDirectory: configDirectory,
            calendar: Self.utcCalendar,
            now: { Self.referenceNow }
        ).dailyUsage(days: 30)

        XCTAssertEqual(incremental, full)
    }

    func testDailyHistoryDoesNotDoubleCountWhenEventsAgeOrFilesReparse() throws {
        let url = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100, outputTokens: 50)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        _ = index.rebuild()

        // 10 days on, untouched: the event folds into a daily cell without a
        // reparse, and its day must still hold exactly its own tokens.
        clock.now = Self.referenceNow.addingTimeInterval(10 * 86_400)
        counter.reset()
        var history = try index.rebuild().dailyUsage(days: 30)
        XCTAssertEqual(counter.parsedPaths, [])
        XCTAssertEqual(history.total.reduce(0) { $0 + $1.totalTokens }, 150)

        // A further rebuild must not fold it a second time…
        history = try index.rebuild().dailyUsage(days: 30)
        XCTAssertEqual(history.total.reduce(0) { $0 + $1.totalTokens }, 150)

        // …and neither must a full reparse after the file changes.
        let lines = [
            assistantLine(hoursAgo: 1, inputTokens: 100, outputTokens: 50),
            assistantLine(hoursAgo: 2, inputTokens: 10, outputTokens: 5),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        history = try index.rebuild().dailyUsage(days: 30)
        XCTAssertEqual(history.total.reduce(0) { $0 + $1.totalTokens }, 165)
    }

    func testDailyCellsMergeAcrossFiles() throws {
        // Two files, same day, same model, different sources — one cell each,
        // merged into one day with both sources represented.
        _ = try writeSession("a", lines: [
            assistantLine(hoursAgo: 30 * 24, entrypoint: "cli", inputTokens: 1000, outputTokens: 500)
        ])
        _ = try writeSession("b", lines: [
            assistantLine(hoursAgo: 30 * 24, entrypoint: "claude-vscode", inputTokens: 2000, outputTokens: 1000)
        ])
        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())

        let history = try index.rebuild().dailyUsage(days: 40)

        XCTAssertEqual(history.total.first?.totalTokens, 4500)
        XCTAssertEqual(history.bySource[.cli]?.first?.totalTokens, 1500)
        XCTAssertEqual(history.bySource[.vscode]?.first?.totalTokens, 3000)
    }

    func testHistoricalTotalsMatchFullParseAcrossModels() throws {
        _ = try writeSession("a", lines: [
            assistantLine(hoursAgo: 30 * 24, model: "claude-opus-5", inputTokens: 10, outputTokens: 5),
            assistantLine(hoursAgo: 20 * 24, model: "claude-sonnet-5", inputTokens: 100, outputTokens: 50),
            assistantLine(hoursAgo: 1, model: "claude-sonnet-5", inputTokens: 1, outputTokens: 1),
        ])
        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())
        let incremental = try index.rebuild().modelUsage(last24h: false)

        // Reference: the pre-existing full-parse path with the same clock.
        let full = try LocalLogUsageStore(
            configDirectory: configDirectory,
            calendar: Self.utcCalendar,
            now: { Self.referenceNow }
        ).modelUsage(last24h: false)

        XCTAssertEqual(incremental, full)
    }

    func testHistoricalTotalsMergeAcrossMultipleFiles() throws {
        // Both events are past retention and share a model ID, so their folds
        // must merge across files — including taking the max latestTimestamp.
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 30 * 24, inputTokens: 1000, outputTokens: 500)])
        _ = try writeSession("b", lines: [assistantLine(hoursAgo: 40 * 24, inputTokens: 2000, outputTokens: 1000)])
        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())

        let store = index.rebuild()
        XCTAssertTrue(store.events.isEmpty)
        let merged = try XCTUnwrap(store.historicalByModel["claude-sonnet-5"])
        XCTAssertEqual(merged.usage.totalTokens, 4500)
        XCTAssertEqual(merged.latestTimestamp, Self.referenceNow.addingTimeInterval(-30 * 24 * 3600))
    }

    func testRetentionCoversEveryPerEventQueryWindow() {
        // Folded events only survive in per-model totals; every per-event
        // query (rolling windows, plan-tier heuristic) must fit inside the
        // retention window or it silently under-reports.
        let longestWindow = TimeWindow.allCases.map(\.duration).max()!
        XCTAssertGreaterThanOrEqual(SessionCorpusIndex.defaultRetention, longestWindow)
        XCTAssertGreaterThanOrEqual(
            SessionCorpusIndex.defaultRetention,
            TimeInterval(LocalLogUsageStore.localHistoryDays) * 86_400
        )
    }

    func testSameSizeContentChangeIsStillReparsed() throws {
        // Rewrite with identical byte count but different token digits: size
        // matches, only mtime differs — must still count as changed.
        let url = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.first?.usage.inputTokens, 100)

        let sizeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        try Data((assistantLine(hoursAgo: 1, inputTokens: 900) + "\n").utf8).write(to: url)
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        XCTAssertEqual(sizeBefore, sizeAfter, "fixture must keep the byte count identical")
        // Filesystem mtime granularity could make back-to-back writes look
        // identical — force a distinct timestamp instead of sleeping.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: url.path
        )

        counter.reset()
        let store = index.rebuild()
        XCTAssertEqual(counter.parsedPaths, ["a.jsonl"])
        XCTAssertEqual(store.events.first?.usage.inputTokens, 900)
    }

    func testNonJSONLFilesAreIgnored() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1)])
        try Data("not a session log".utf8)
            .write(to: projectDirectory.appendingPathComponent("notes.txt"))
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)

        let store = index.rebuild()
        XCTAssertEqual(counter.parsedPaths, ["a.jsonl"])
        XCTAssertEqual(store.events.count, 1)
    }

    // MARK: - Scoped rebuild

    /// The lane's core differential guard: a rebuild handed a batch must stat
    /// only what the batch named. A full-scan implementation finds `b`'s change
    /// too and fails the middle assertion.
    func testScopedRebuildIgnoresAChangeTheBatchDidNotName() throws {
        let urlA = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let urlB = try writeSession("b", lines: [assistantLine(hoursAgo: 1, inputTokens: 200)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 2)

        // Both files grow on disk; only `a` is reported.
        try rewrite(urlA, lines: [assistantLine(hoursAgo: 1, inputTokens: 100), assistantLine(hoursAgo: 0.5, inputTokens: 101)])
        try rewrite(urlB, lines: [assistantLine(hoursAgo: 1, inputTokens: 200), assistantLine(hoursAgo: 0.5, inputTokens: 201)])

        counter.reset()
        let scoped = index.rebuild(changed: batch(change("a", flags: .modified)))
        XCTAssertEqual(counter.parsedPaths, ["a.jsonl"], "only the named file may be stat-ed and reparsed")
        XCTAssertEqual(scoped.events.count, 3, "b's unreported change must not be picked up by a scoped rebuild")

        // A batchless rebuild falls back to the full scan and catches up.
        counter.reset()
        let full = index.rebuild()
        XCTAssertEqual(counter.parsedPaths, ["b.jsonl"])
        XCTAssertEqual(full.events.count, 4)
    }

    func testScopedRemovalDropsTheFilesEvents() throws {
        let urlA = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        _ = try writeSession("b", lines: [assistantLine(hoursAgo: 1, inputTokens: 200)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 2)

        try FileManager.default.removeItem(at: urlA)
        counter.reset()
        let store = index.rebuild(changed: batch(change("a", flags: .removed)))
        XCTAssertEqual(counter.parsedPaths, [], "a gone file is dropped, never parsed")
        XCTAssertEqual(store.events.map(\.usage.inputTokens), [200])
    }

    /// A rename fires for both paths. The old one no longer stats, so it drops
    /// out exactly like a removal; the new one stats fine and is inserted.
    func testRenameAwayIsTreatedAsARemovalAndTheNewPathIsPickedUp() throws {
        let urlA = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 1)

        let urlC = projectDirectory.appendingPathComponent("c.jsonl")
        try FileManager.default.moveItem(at: urlA, to: urlC)

        counter.reset()
        let store = index.rebuild(changed: batch(
            change("a", flags: .renamed),
            change("c", flags: .renamed)
        ))
        XCTAssertEqual(counter.parsedPaths, ["c.jsonl"])
        XCTAssertEqual(store.events.map(\.usage.inputTokens), [100], "the events moved with the file, they didn't double")
    }

    /// New paths are spliced into the scan order by binary search, so the
    /// snapshot stays sorted-by-path. An append-at-end regression shuffles this.
    func testNewFilesLandInSortedScanOrder() throws {
        _ = try writeSession("b", lines: [assistantLine(hoursAgo: 1, inputTokens: 200)])
        _ = try writeSession("d", lines: [assistantLine(hoursAgo: 1, inputTokens: 400)])
        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())
        XCTAssertEqual(index.rebuild().events.map(\.usage.inputTokens), [200, 400])

        // One sorts before everything known, one into the middle — and the
        // batch names them in the reverse of their sorted order.
        _ = try writeSession("c", lines: [assistantLine(hoursAgo: 1, inputTokens: 300)])
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])

        let store = index.rebuild(changed: batch(
            change("c", flags: .created),
            change("a", flags: .created)
        ))
        XCTAssertEqual(store.events.map(\.usage.inputTokens), [100, 200, 300, 400])
    }

    func testRequiresFullRescanBatchForcesAFullScan() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let urlB = try writeSession("b", lines: [assistantLine(hoursAgo: 1, inputTokens: 200)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 2)

        try rewrite(urlB, lines: [assistantLine(hoursAgo: 1, inputTokens: 200), assistantLine(hoursAgo: 0.5, inputTokens: 201)])

        // The batch names only `a`, but the OS says its list is incomplete.
        counter.reset()
        let store = index.rebuild(changed: batch(
            change("a", flags: .modified),
            FileChange(path: projectDirectory.path, flags: [.requiresRescan, .isDirectory])
        ))
        XCTAssertEqual(counter.parsedPaths, ["b.jsonl"], "the full scan finds the change no batch named")
        XCTAssertEqual(store.events.count, 3)
    }

    func testFirstRebuildIsFullEvenWhenGivenABatch() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        _ = try writeSession("b", lines: [assistantLine(hoursAgo: 1, inputTokens: 200)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)

        let store = index.rebuild(changed: batch(change("a", flags: .created)))
        XCTAssertEqual(counter.parsedPaths.sorted(), ["a.jsonl", "b.jsonl"], "no baseline yet — scope nothing")
        XCTAssertEqual(store.events.count, 2)
    }

    /// FSEvents reports a removed or renamed directory by its own path and never
    /// names the `.jsonl` children that went with it, so scoping to the batch
    /// would keep serving a project that is gone.
    func testRemovedProjectDirectoryForcesAFullScan() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let otherProject = configDirectory.appendingPathComponent("projects/-tmp-other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: true)
        try Data((assistantLine(hoursAgo: 1, inputTokens: 300) + "\n").utf8)
            .write(to: otherProject.appendingPathComponent("c.jsonl"))

        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())
        XCTAssertEqual(index.rebuild().events.count, 2)

        try FileManager.default.removeItem(at: otherProject)
        // The batch names the directory alone — no `.jsonl` content change in
        // it at all, so a scoped rebuild would do precisely nothing.
        let store = index.rebuild(changed: batch(
            FileChange(path: otherProject.path, flags: [.removed, .isDirectory])
        ))
        XCTAssertEqual(store.events.map(\.usage.inputTokens), [100], "the vanished project's events must go with it")
    }

    /// The renamed half of the same fallback: `.renamed` alone (no `.removed`)
    /// must also force a full scan, and the moved directory's files must still
    /// turn up at their new path — a scoped rebuild given only the old path
    /// would find nothing there to reparse and silently drop them.
    func testRenamedProjectDirectoryForcesAFullScan() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let otherProject = configDirectory.appendingPathComponent("projects/-tmp-other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: true)
        try Data((assistantLine(hoursAgo: 1, inputTokens: 300) + "\n").utf8)
            .write(to: otherProject.appendingPathComponent("c.jsonl"))

        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())
        XCTAssertEqual(index.rebuild().events.count, 2)

        let renamedProject = configDirectory.appendingPathComponent("projects/-tmp-renamed", isDirectory: true)
        try FileManager.default.moveItem(at: otherProject, to: renamedProject)
        // The batch names only the old path, flagged `.renamed` rather than
        // `.removed` — a scoped rebuild would find nothing there to reparse.
        let store = index.rebuild(changed: batch(
            FileChange(path: otherProject.path, flags: [.renamed, .isDirectory])
        ))
        XCTAssertEqual(
            store.events.map(\.usage.inputTokens).sorted(), [100, 300],
            "the full scan must find the moved project's files at their new path"
        )
    }

    func testMetadataOnlyBatchReparsesNothing() throws {
        let urlA = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 1)

        // The bytes did change, but the batch only reports a metadata touch —
        // which carries no promise that contents moved, so it is not acted on.
        try rewrite(urlA, lines: [assistantLine(hoursAgo: 1, inputTokens: 100), assistantLine(hoursAgo: 0.5, inputTokens: 101)])

        counter.reset()
        let store = index.rebuild(changed: batch(change("a", flags: .metadata)))
        XCTAssertEqual(counter.parsedPaths, [])
        XCTAssertEqual(store.events.count, 1)
    }

    /// Retention is a property of the clock, not of the batch: events age out of
    /// files nobody wrote to, so the sweep has to cover the whole index.
    func testScopedRebuildStillFoldsRetentionOnUnnamedFiles() throws {
        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100, outputTokens: 50)])
        _ = try writeSession("b", lines: [assistantLine(hoursAgo: 1, inputTokens: 200, outputTokens: 100)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 2)

        // 10 days on, past the 8-day retention, with only `a` reported and
        // neither file actually touched.
        clock.now = Self.referenceNow.addingTimeInterval(10 * 86_400)
        counter.reset()
        let store = index.rebuild(changed: batch(change("a", flags: .modified)))
        XCTAssertEqual(counter.parsedPaths, [])
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.historicalByModel["claude-sonnet-5"]?.usage.totalTokens, 450)

        // And not a second time on the next rebuild.
        XCTAssertEqual(
            index.rebuild(changed: batch(change("a", flags: .modified)))
                .historicalByModel["claude-sonnet-5"]?.usage.totalTokens,
            450
        )
    }

    /// FSEvents reports fully symlink-resolved paths (`/private/var/…`), which
    /// need not be the spelling the index keys by — the config directory is only
    /// standardized (`/var/…`). Both spellings have to land on the same cache
    /// entry; otherwise a scoped rebuild silently reparses into a second,
    /// parallel key and double-counts the file, or matches nothing at all.
    func testBothSpellingsOfABatchPathReachTheSameFile() throws {
        let resolvedProject = ConfigDirectoryWatcher.resolvedPath(projectDirectory.path)
        try XCTSkipIf(
            resolvedProject == projectDirectory.path,
            "temp directory is not behind a symlink on this machine — nothing to bridge"
        )

        let urlA = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 1)

        // Symlink-resolved, the way the watcher would report it.
        try rewrite(urlA, lines: [assistantLine(hoursAgo: 1, inputTokens: 100), assistantLine(hoursAgo: 0.5, inputTokens: 101)])
        counter.reset()
        let resolved = index.rebuild(changed: batch(
            FileChange(path: resolvedProject + "/a.jsonl", flags: .modified)
        ))
        XCTAssertEqual(counter.parsedPaths, ["a.jsonl"], "the watcher's path space must map onto the index's")
        XCTAssertEqual(resolved.events.count, 2, "one entry for the file, not two under two keys")

        // The unresolved spelling of the very same file.
        try rewrite(urlA, lines: [
            assistantLine(hoursAgo: 1, inputTokens: 100),
            assistantLine(hoursAgo: 0.5, inputTokens: 101),
            assistantLine(hoursAgo: 0.25, inputTokens: 102),
        ])
        counter.reset()
        let declared = index.rebuild(changed: batch(change("a", flags: .modified)))
        XCTAssertEqual(counter.parsedPaths, ["a.jsonl"])
        XCTAssertEqual(declared.events.count, 3)
    }

    /// The one case `projectsPrefixes()` cannot read off an existing cache key:
    /// an empty corpus (nothing scanned yet) behind a symlinked config
    /// directory. It falls back to the enumerator's measured behaviour rather
    /// than a confirmed key — this pins that the very first scoped rebuild
    /// after an empty full scan still reaches a brand-new file instead of
    /// silently dropping it.
    func testFirstScopedRebuildAfterAnEmptyCorpusStillFindsANewFile() throws {
        let resolvedProject = ConfigDirectoryWatcher.resolvedPath(projectDirectory.path)
        try XCTSkipIf(
            resolvedProject == projectDirectory.path,
            "temp directory is not behind a symlink on this machine — nothing to bridge"
        )

        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        // Nothing written yet, so `orderedPaths.first` is nil and
        // `projectsPrefixes()` must use its fallback guess.
        XCTAssertEqual(index.rebuild().events.count, 0)

        _ = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        counter.reset()
        let store = index.rebuild(changed: batch(
            FileChange(path: resolvedProject + "/a.jsonl", flags: .created)
        ))
        XCTAssertEqual(counter.parsedPaths, ["a.jsonl"], "the empty-corpus fallback must still map the watcher's resolved path onto the corpus")
        XCTAssertEqual(store.events.count, 1)
    }

    func testBatchPathsOutsideTheCorpusAreIgnored() throws {
        let urlA = try writeSession("a", lines: [assistantLine(hoursAgo: 1, inputTokens: 100)])
        let clock = Clock(Self.referenceNow)
        let counter = ParseCounter()
        let index = makeIndex(clock: clock, counter: counter)
        XCTAssertEqual(index.rebuild().events.count, 1)

        try rewrite(urlA, lines: [assistantLine(hoursAgo: 1, inputTokens: 100), assistantLine(hoursAgo: 0.5, inputTokens: 101)])

        // A sibling directory whose name merely starts the same, and an
        // unrelated root: neither is this corpus.
        counter.reset()
        let store = index.rebuild(changed: batch(
            FileChange(path: configDirectory.path + "/projects-backup/-tmp-proj/a.jsonl", flags: .modified),
            FileChange(path: "/tmp/somewhere-else/b.jsonl", flags: .created)
        ))
        XCTAssertEqual(counter.parsedPaths, [])
        XCTAssertEqual(store.events.count, 1, "a foreign path must not disturb the index")
    }

    // MARK: - Skipped lines

    func testSkippedLinesAreCappedPerFile() throws {
        let malformed = Array(repeating: #"{"type":"assistant","message":{"usage":{"input_tokens":1}}}"#, count: 20)
        _ = try writeSession("a", lines: malformed + [assistantLine(hoursAgo: 1)])
        let clock = Clock(Self.referenceNow)
        let index = makeIndex(clock: clock, counter: ParseCounter())

        let store = index.rebuild()
        XCTAssertEqual(store.events.count, 1)
        XCTAssertLessThanOrEqual(store.skippedLines.count, SessionCorpusIndex.skippedSampleLimit)
        XCTAssertEqual(index.skippedLineCount, 20)
    }
}
