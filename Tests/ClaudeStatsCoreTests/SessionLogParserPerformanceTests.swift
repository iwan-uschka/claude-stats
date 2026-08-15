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
