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
    private func assistantLine(hoursAgo: Double, model: String = "claude-sonnet-5", inputTokens: Int = 100, outputTokens: Int = 50) -> String {
        let timestamp = Self.referenceNow.addingTimeInterval(-hoursAgo * 3600)
        let iso = timestamp.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return #"{"type":"assistant","entrypoint":"cli","timestamp":"\#(iso)","isSidechain":false,"sessionId":"s1","message":{"role":"assistant","model":"\#(model)","usage":{"input_tokens":\#(inputTokens),"output_tokens":\#(outputTokens),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    }

    private func writeSession(_ name: String, lines: [String]) throws -> URL {
        let url = projectDirectory.appendingPathComponent("\(name).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
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
