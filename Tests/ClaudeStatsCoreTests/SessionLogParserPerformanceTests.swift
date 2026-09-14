import XCTest
@testable import ClaudeStatsCore

/// Line-splitting fidelity and throughput for ``SessionLogParser``.
///
/// The corpus is generated in memory at run time — a real `~/.claude` is
/// gigabytes and must never be touched by the suite, and a fixture that large
/// has no business in git.
final class SessionLogParserPerformanceTests: XCTestCase {

    // MARK: - Corpus

    /// One repeatable block of realistically-shaped lines: mostly bulky `user`
    /// and `attachment` records (they embed file contents and dominate a real
    /// log), a couple of `assistant` records that actually carry usage, and a
    /// blank line, because real files have those too.
    private static func makeBlock(index: Int) -> String {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 300)  // ~8 KB
        return """
        {"type":"user","entrypoint":"cli","timestamp":"2026-07-15T10:00:00.000Z","sessionId":"s-\(index)","message":{"role":"user","content":"\(filler)"}}
        {"type":"attachment","entrypoint":"cli","timestamp":"2026-07-15T10:00:01.000Z","content":"\(filler)"}
        {"type":"assistant","entrypoint":"cli","timestamp":"2026-07-15T10:00:02.000Z","isSidechain":false,"sessionId":"s-\(index)","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,"cache_read_input_tokens":20}}}
        {"type":"system","timestamp":"2026-07-15T10:00:03.000Z","content":"hook ran"}

        {"type":"assistant","entrypoint":"cli","timestamp":"2026-07-15T10:00:04.000Z","isSidechain":true,"sessionId":"s-\(index)","message":{"role":"assistant","model":"claude-haiku-5","usage":{"input_tokens":7,"output_tokens":3}}}

        """
    }

    /// `targetBytes` of synthetic JSONL plus the per-block event count.
    private static func makeCorpus(targetBytes: Int) -> (data: Data, blocks: Int) {
        var text = ""
        var blocks = 0
        // Rough sizing first, then top up: block size is stable, so one estimate
        // is enough to avoid re-measuring a growing string on every iteration.
        let sample = makeBlock(index: 0)
        let estimated = max(1, targetBytes / sample.utf8.count)
        text.reserveCapacity(targetBytes + sample.utf8.count)
        while blocks < estimated {
            text += makeBlock(index: blocks)
            blocks += 1
        }
        return (Data(text.utf8), blocks)
    }

    // MARK: - Throughput

    func testParsesLargeCorpusWellUnderInteractiveBudget() {
        let (data, blocks) = Self.makeCorpus(targetBytes: 64 * 1024 * 1024)
        XCTAssertGreaterThan(data.count, 60 * 1024 * 1024, "corpus should really be ~64 MB")

        let parser = SessionLogParser()
        let start = ContinuousClock.now
        let result = parser.parse(jsonlData: data, path: "/synthetic.jsonl")
        let elapsed = ContinuousClock.now - start

        // Reported on every run, not just failures: the assertion below only
        // catches an order-of-magnitude regression, so the actual number is
        // what makes a gradual drift — or a real speed-up — visible in the log.
        let seconds = Double(elapsed.components.attoseconds) / 1e18
            + Double(elapsed.components.seconds)
        let megabytesPerSecond = Double(data.count) / 1_048_576 / seconds
        print(
            String(
                format: "[perf] parsed %.1f MB in %.3f s (%.0f MB/s), %d events",
                Double(data.count) / 1_048_576, seconds, megabytesPerSecond, result.events.count
            )
        )

        // Prove the work actually happened: two usage-bearing lines per block,
        // and nothing in the corpus is malformed.
        XCTAssertEqual(result.events.count, blocks * 2)
        XCTAssertTrue(result.skippedLines.isEmpty)

        // Budget rationale: measured on this 64 MB corpus, the memchr line scan
        // takes ~0.10 s in an unoptimised debug test build and ~0.06 s in
        // release; the previous `Data.split` implementation took ~0.69 s debug /
        // ~0.29 s release on the same bytes. 8 s is ~80x the observed debug
        // time, so no amount of CI slowness or parallel-test contention can
        // flake it, while a regression to per-byte `Data` iteration — which
        // scales to seconds of pure CPU over a real multi-GB ~/.claude — still
        // trips it well before it becomes user-visible lag.
        XCTAssertLessThan(
            elapsed, .seconds(8),
            "parsing \(data.count) bytes took \(elapsed); line splitting has regressed"
        )
    }

    // MARK: - Corpus scan

    /// `sessionFileURLs` runs on every coalesced watcher batch, so its cost is
    /// paid every couple of seconds while a session is active — and it is
    /// O(files), independent of how much was actually written.
    ///
    /// The regression this guards is specifically a comparator that reads
    /// `URL.path`: that property re-materialises a CFURL→String bridge on every
    /// access, so `sorted { $0.path < $1.path }` pays two bridges per comparison
    /// — `n log n` bridges instead of `n`. It is invisible at fixture scale and
    /// dominant at real scale, which is why this test builds a corpus big enough
    /// for `log n` to bite rather than asserting on a handful of files.
    func testCorpusScanStaysLinearInBridgingCost() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-perf-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Spread over project directories the way a real `~/.claude` is, and
        // name files so lexical order differs from creation order.
        let projectCount = 40
        let perProject = 100
        for project in 0..<projectCount {
            let directory = root
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent("-Users-someone-project-\(project)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<perProject {
                let name = "\(UUID().uuidString)-\(file).jsonl"
                try Data().write(to: directory.appendingPathComponent(name))
            }
        }
        let expected = projectCount * perProject

        // Best of five; the first pass also warms the directory cache, and this
        // test is about comparator cost, not cold-FS latency.
        var urls: [URL] = []
        var best: Duration = .seconds(3600)
        for _ in 0..<5 {
            let start = ContinuousClock.now
            urls = SessionLogParser.sessionFileURLs(inConfigDirectory: root)
            best = min(best, ContinuousClock.now - start)
        }

        XCTAssertEqual(urls.count, expected)
        XCTAssertEqual(urls, urls.sorted { $0.path < $1.path }, "scan order must be sorted by path")

        // The yardstick is a `URL.path` comparator over the same corpus, timed
        // here rather than hard-coded: an absolute millisecond budget cannot
        // work for this regression. Enumeration is a fixed floor under both
        // implementations, so even at real corpus size the bad one is only
        // ~2.5x the good one — any budget loose enough not to flake on a busy CI
        // box is also loose enough to let the regression through. Measuring both
        // on the machine in front of us removes the machine from the comparison.
        var comparatorSortOnly: Duration = .seconds(3600)
        for _ in 0..<5 {
            let shuffled = urls.shuffled()
            let start = ContinuousClock.now
            _ = shuffled.sorted { $0.path < $1.path }
            comparatorSortOnly = min(comparatorSortOnly, ContinuousClock.now - start)
        }

        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.attoseconds) / 1e18 + Double(duration.components.seconds)
        }
        print(String(
            format: "[perf] scanned %d session files in %.3f s (path-comparator sort alone: %.3f s)",
            expected, seconds(best), seconds(comparatorSortOnly)
        ))

        // The assertion: a *whole* scan — enumeration, listing, sort — must come
        // in under what the discarded comparator costs for its sort alone. What
        // makes this stable is that both sides are timed in the same run on the
        // same machine, so the *ratio* holds even when absolute times drift.
        // Measured on a 4 000-file corpus in a debug test build: scan 0.045 s vs
        // comparator 0.090 s, a ratio of 0.50; with the comparator reintroduced,
        // 0.110 s vs 0.092 s, a ratio of 1.20, reproduced across three runs
        // without varying past the second decimal. The threshold sits at 1.0,
        // clear of both.
        XCTAssertLessThan(
            best, comparatorSortOnly,
            """
            scanning \(expected) files took \(best), no faster than a bare \
            `URL.path` comparator sort (\(comparatorSortOnly)) — the scan is \
            paying a CFURL→String bridge per comparison again
            """
        )
    }

    // MARK: - Split fidelity

    func testLineNumbersAndEmptyLinesMatchFileLayout() {
        let parser = SessionLogParser()
        // Line 1 blank, line 2 truncated, line 3 blank, line 4 valid, line 5
        // truncated with no trailing newline.
        let text = """

        {"type":"assistant","timestamp":"2026-07-15T10:00:00.000Z"

        {"type":"assistant","timestamp":"2026-07-15T10:00:02.000Z","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":5}}}
        {"type":"assistant","timesta
        """
        let result = parser.parse(jsonlText: text, path: "/x.jsonl")

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(
            result.skippedLines,
            [
                .malformedLogLine(path: "/x.jsonl", line: 2),
                .malformedLogLine(path: "/x.jsonl", line: 5),
            ]
        )
    }

    func testTrailingNewlineAndEmptyInputProduceNoSpuriousLines() {
        let parser = SessionLogParser()
        let line = #"{"type":"assistant","timestamp":"2026-07-15T10:00:00.000Z","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":5}}}"#

        for text in [line, line + "\n", line + "\n\n"] {
            let result = parser.parse(jsonlText: text, path: "/x.jsonl")
            XCTAssertEqual(result.events.count, 1, "unexpected events for \(text.debugDescription)")
            XCTAssertTrue(result.skippedLines.isEmpty, "a blank tail line is not an error")
        }

        let empty = parser.parse(jsonlData: Data(), path: "/x.jsonl")
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertTrue(empty.skippedLines.isEmpty)
    }

    func testCarriageReturnsAndPaddingAreTrimmedPerLine() {
        let parser = SessionLogParser()
        let line = #"{"type":"assistant","timestamp":"2026-07-15T10:00:00.000Z","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":5}}}"#
        // CRLF endings and indented lines still parse — the trim runs per line.
        let result = parser.parse(jsonlText: "  \(line)  \r\n\t\(line)\r\n", path: "/x.jsonl")

        XCTAssertEqual(result.events.count, 2)
        XCTAssertTrue(result.skippedLines.isEmpty)
    }
}
