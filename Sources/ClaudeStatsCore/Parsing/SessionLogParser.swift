import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Parses Claude Code's session JSONL into ``UsageEvent`` values.
///
/// One file per session lives at
/// `<config dir>/projects/<escaped-cwd>/<session-uuid>.jsonl`, one JSON object
/// per line. The parser is deliberately lenient:
///
/// - Lines that aren't valid JSON are **skipped**, not fatal — the last line of
///   a session that Claude Code is actively writing is regularly a truncated
///   fragment. Each one is reported as a
///   ``ClaudeStatsError/malformedLogLine(path:line:)`` alongside the events.
/// - Lines that are valid JSON but carry no token counts (`user`, `attachment`,
///   `system`, `summary`, `queue-operation`, `mode`, `file-history-*`, …) are
///   skipped silently — they're expected, not errors.
/// - Unknown `entrypoint` values decode to `nil` rather than failing, so a new
///   Claude Code surface can't break parsing.
public struct SessionLogParser: Sendable {
    public init() {}

    /// Events plus the non-fatal problems hit while producing them.
    public struct ParseResult: Sendable {
        /// Token-bearing events, in file order.
        public var events: [UsageEvent]
        /// One entry per line that looked like it should have parsed but didn't.
        public var skippedLines: [ClaudeStatsError]

        public init(events: [UsageEvent] = [], skippedLines: [ClaudeStatsError] = []) {
            self.events = events
            self.skippedLines = skippedLines
        }

        /// Field-wise merge, for folding many files into one result.
        public mutating func merge(_ other: ParseResult) {
            events.append(contentsOf: other.events)
            skippedLines.append(contentsOf: other.skippedLines)
        }
    }

    // MARK: - Single line

    /// Parse one JSONL line.
    ///
    /// - Returns: An event, or `nil` when the line is valid JSON that simply
    ///   carries no token counts.
    /// - Throws: ``ClaudeStatsError/malformedLogLine(path:line:)`` when the line
    ///   isn't decodable JSON, or when it *is* an assistant/usage line but has
    ///   no parseable `timestamp` (it could never be placed in a time window).
    public func usageEvent(
        fromJSONLLine line: String,
        path: String = "",
        lineNumber: Int = 0
    ) throws -> UsageEvent? {
        try usageEvent(
            fromJSONLLine: Data(line.utf8),
            decoder: JSONDecoder(),
            path: path,
            lineNumber: lineNumber
        )
    }

    /// Byte-level line parse. Working on `Data` avoids re-encoding every line
    /// back to UTF-8, and reusing one decoder across a file avoids ~700k
    /// throwaway `JSONDecoder`s on a full scan of a real `~/.claude`.
    func usageEvent(
        fromJSONLLine line: Data,
        decoder: JSONDecoder,
        path: String,
        lineNumber: Int
    ) throws -> UsageEvent? {
        try line.withUnsafeBytes { bytes in
            try usageEvent(
                fromJSONLLine: bytes,
                decoder: decoder,
                path: path,
                lineNumber: lineNumber
            )
        }
    }

    /// Pointer-level line parse — the hot path of a whole-file scan.
    ///
    /// Identical in behaviour to the `Data` overload, but nothing is allocated
    /// until a line survives the `type` gate: trimming and the gate are plain
    /// pointer arithmetic, and only a genuine `assistant` candidate is copied
    /// into a `Data` for `JSONDecoder`.
    func usageEvent(
        fromJSONLLine line: UnsafeRawBufferPointer,
        decoder: JSONDecoder,
        path: String,
        lineNumber: Int
    ) throws -> UsageEvent? {
        let range = SessionLogParser.trimmedASCIIWhitespaceRange(line)
        // Blank padding between records is not an error.
        guard !range.isEmpty else { return nil }
        let trimmed = UnsafeRawBufferPointer(rebasing: line[range])

        // Truncated lines — the normal state of the last line of a session
        // Claude Code is still writing — don't close their object. Catch that
        // before paying for a parse.
        guard trimmed[0] == UInt8(ascii: "{"), trimmed[trimmed.count - 1] == UInt8(ascii: "}") else {
            throw ClaudeStatsError.malformedLogLine(path: path, line: lineNumber)
        }

        // Only `assistant` lines carry usage; `user` and `attachment` lines are
        // both the majority and the largest (they embed file contents), so
        // rejecting them on the leading `type` field — without parsing the rest
        // of a possibly 100 KB line — is what keeps a full-tree scan fast.
        // Trade-off: a *corrupt* non-assistant line is skipped silently instead
        // of reported, which is fine — it holds no token counts either way.
        guard !SessionLogParser.beginsWithNonAssistantType(trimmed) else { return nil }

        guard let raw = try? decoder.decode(RawLogLine.self, from: Data(trimmed)) else {
            throw ClaudeStatsError.malformedLogLine(path: path, line: lineNumber)
        }

        // Same check again for lines whose `type` wasn't the first key.
        guard raw.type == "assistant", let rawUsage = raw.message?.usage else { return nil }

        guard let timestamp = raw.timestamp.flatMap(SessionLogParser.parseTimestamp) else {
            throw ClaudeStatsError.malformedLogLine(path: path, line: lineNumber)
        }

        return UsageEvent(
            timestamp: timestamp,
            entrypoint: raw.entrypoint.flatMap(Entrypoint.init(rawJSONLValue:)),
            modelID: raw.message?.model,
            usage: rawUsage.tokenUsage,
            isSidechain: raw.isSidechain ?? false,
            sessionID: raw.sessionId
        )
    }

    // MARK: - Whole files

    /// Parse the JSONL text of one session file. Never throws — malformed lines
    /// land in ``ParseResult/skippedLines``.
    public func parse(jsonlText text: String, path: String) -> ParseResult {
        parse(jsonlData: Data(text.utf8), path: path)
    }

    /// Parse the raw bytes of one session file.
    ///
    /// Splits on `\n` and hands each line to the decoder as-is: no `String`
    /// round-trip, so invalid UTF-8 from a half-written multi-byte character at
    /// EOF fails that one line rather than corrupting the whole file.
    ///
    /// The split is a raw `memchr` scan over one borrowed buffer rather than
    /// `Data.split`, which walks the file byte-by-byte through `Data`'s
    /// non-inlinable subscript and materialises a `Data` slice per line. Nothing
    /// is allocated until a line survives the `type` gate, so the bulk of a real
    /// log — the `user`/`attachment` records — costs one pointer scan each.
    /// Measured over a real 1.76 GB `~/.claude` (release, I/O excluded): 10.6 s
    /// before, 4.5 s after, for byte-identical results.
    public func parse(jsonlData data: Data, path: String) -> ParseResult {
        var result = ParseResult()
        let decoder = JSONDecoder()
        data.withUnsafeBytes { buffer in
            let count = buffer.count
            var lineNumber = 0
            var start = 0
            // Mirrors `split(separator: "\n", omittingEmptySubsequences: false)`:
            // empty lines are still counted, so line numbers match the file, and
            // a final line without a trailing `\n` is a line like any other.
            // `start <= count` (not `<`) keeps the empty trailing line that a
            // file ending in `\n` — and an empty file — both produce.
            while start <= count {
                var end = count
                if let base = buffer.baseAddress, start < count,
                   let hit = memchr(base + start, Int32(UInt8(ascii: "\n")), count - start) {
                    end = UnsafeRawPointer(hit) - base
                }
                lineNumber += 1
                do {
                    if let event = try usageEvent(
                        fromJSONLLine: UnsafeRawBufferPointer(rebasing: buffer[start..<end]),
                        decoder: decoder,
                        path: path,
                        lineNumber: lineNumber
                    ) {
                        result.events.append(event)
                    }
                } catch let error as ClaudeStatsError {
                    result.skippedLines.append(error)
                } catch {
                    result.skippedLines.append(.malformedLogLine(path: path, line: lineNumber))
                }
                if end == count { break }  // no more newlines: that was the last line
                start = end + 1
            }
        }
        return result
    }

    /// Parse one session file from disk. Unreadable bytes yield an empty result
    /// rather than throwing — a file that vanished mid-scan shouldn't take the
    /// whole refresh down.
    public func parse(fileAt url: URL) -> ParseResult {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return ParseResult()
        }
        return parse(jsonlData: data, path: url.path)
    }

    /// Parse every `*.jsonl` under `<configDirectory>/projects`, recursively.
    ///
    /// A missing or unreadable `projects` directory is not an error: a fresh
    /// install has a config directory with no sessions in it yet.
    public func parseAllSessions(inConfigDirectory configDirectory: URL) -> ParseResult {
        var result = ParseResult()
        for url in SessionLogParser.sessionFileURLs(inConfigDirectory: configDirectory) {
            result.merge(parse(fileAt: url))
        }
        return result
    }

    /// Every session JSONL under `<configDirectory>/projects`, sorted by path so
    /// scans are deterministic.
    public static func sessionFileURLs(inConfigDirectory configDirectory: URL) -> [URL] {
        let projects = configDirectory.appendingPathComponent("projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    // MARK: - Timestamps

    // Real lines look like `2026-07-23T16:15:58.939Z`; tolerate the
    // whole-second variant too rather than dropping the event.
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// Parse an ISO8601 `timestamp` field, with or without fractional seconds.
    public static func parseTimestamp(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: fractional) { return date }
        return try? Date(string, strategy: wholeSeconds)
    }

    // MARK: - Bytes

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C
    }

    /// Offsets of the same trim, applied to a borrowed buffer — no `Data`
    /// slice, so a whole-file scan trims every line without touching the heap.
    static func trimmedASCIIWhitespaceRange(_ bytes: UnsafeRawBufferPointer) -> Range<Int> {
        var start = 0
        var end = bytes.count
        while start < end, isASCIIWhitespace(bytes[start]) { start += 1 }
        while end > start, isASCIIWhitespace(bytes[end - 1]) { end -= 1 }
        return start..<end
    }

    // Hoisted out of `beginsWithNonAssistantType`: rebuilding these arrays per
    // line was two allocations for every one of ~7M lines in a full scan.
    private static let typeKeyPrefix = Array(#"{"type":""#.utf8)
    private static let assistantValue = Array("assistant".utf8)

    /// `true` when the line starts with `{"type":"<something other than
    /// assistant>"` — i.e. it can be rejected without parsing.
    ///
    /// Returns `false` (meaning "can't tell, parse it") whenever `type` isn't the
    /// first key, so correctness never depends on Claude Code's key order; only
    /// speed does. Only the first few dozen bytes of the line are touched.
    static func beginsWithNonAssistantType(_ data: Data) -> Bool {
        data.withUnsafeBytes { beginsWithNonAssistantType($0) }
    }

    static func beginsWithNonAssistantType(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let prefix = typeKeyPrefix
        let assistant = assistantValue
        let quote = UInt8(ascii: "\"")

        guard bytes.count > prefix.count else { return false }
        for index in 0..<prefix.count where bytes[index] != prefix[index] { return false }

        // Compare the value up to the closing quote against "assistant".
        var index = prefix.count
        var matched = 0
        while index < bytes.count, bytes[index] != quote {
            if matched < assistant.count, bytes[index] == assistant[matched] {
                matched += 1
            } else {
                matched = assistant.count + 1  // definitely not "assistant"
            }
            index += 1
        }
        guard index < bytes.count else { return false }  // unterminated: let the parser judge
        return matched != assistant.count
    }
}

// MARK: - On-disk shapes

/// The subset of a JSONL line this app reads. Unknown keys are ignored, so new
/// Claude Code fields are additive rather than breaking.
private struct RawLogLine: Decodable {
    var type: String?
    var entrypoint: String?
    var timestamp: String?
    var isSidechain: Bool?
    var sessionId: String?
    var message: RawMessage?

    struct RawMessage: Decodable {
        var role: String?
        var model: String?
        var usage: RawUsage?
    }

    struct RawUsage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        var cacheCreationInputTokens: Int?
        var cacheReadInputTokens: Int?
        var cacheCreation: RawCacheCreation?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreation = "cache_creation"
        }

        var tokenUsage: TokenUsage {
            TokenUsage(
                inputTokens: inputTokens ?? 0,
                outputTokens: outputTokens ?? 0,
                cacheCreationInputTokens: cacheCreationInputTokens ?? 0,
                cacheReadInputTokens: cacheReadInputTokens ?? 0,
                ephemeral5mInputTokens: cacheCreation?.ephemeral5mInputTokens ?? 0,
                ephemeral1hInputTokens: cacheCreation?.ephemeral1hInputTokens ?? 0
            )
        }
    }

    struct RawCacheCreation: Decodable {
        var ephemeral5mInputTokens: Int?
        var ephemeral1hInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
            case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
        }
    }
}
