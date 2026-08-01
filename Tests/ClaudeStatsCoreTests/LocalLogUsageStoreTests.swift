import XCTest
@testable import ClaudeStatsCore

/// Coverage for the real log-parsing ``UsageStoring``.
///
/// Everything is hermetic: the JSONL comes from `Fixtures/`, "now" is a fixed
/// reference date injected into the store, and the calendar is pinned to UTC so
/// `estimatedCostToday()` doesn't depend on the machine's time zone.
final class LocalLogUsageStoreTests: XCTestCase {

    // MARK: - Fixture setup

    /// Every fixture timestamp is relative to this instant.
    static let referenceNow = SessionLogParser.parseTimestamp("2026-07-15T12:00:00.000Z")!

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func fixtureURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(
            forResource: name,
            withExtension: "jsonl",
            subdirectory: "Fixtures"
        )
        return try XCTUnwrap(url, "missing fixture \(name).jsonl")
    }

    /// Parse all three fixtures into one store, with a frozen clock.
    private func makeStore(
        fixtures: [String] = ["cli", "vscode", "sdk"]
    ) throws -> LocalLogUsageStore {
        let parser = SessionLogParser()
        var result = SessionLogParser.ParseResult()
        for name in fixtures {
            result.merge(parser.parse(fileAt: try Self.fixtureURL(name)))
        }
        let now = Self.referenceNow
        return LocalLogUsageStore(
            events: result.events,
            skippedLines: result.skippedLines,
            calendar: Self.utcCalendar,
            now: { now }
        )
    }

    /// A config-directory tree (`projects/<escaped-cwd>/<uuid>.jsonl`) built from
    /// the fixtures inside a temp directory, so directory scanning and
    /// `$CLAUDE_CONFIG_DIR` resolution can be exercised without `~/.claude`.
    private func makeFakeConfigDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-stats-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let projectA = root.appendingPathComponent("projects/-tmp-proj-a", isDirectory: true)
        let projectB = root.appendingPathComponent("projects/-tmp-proj-b", isDirectory: true)
        for dir in [projectA, projectB] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try FileManager.default.copyItem(
            at: try Self.fixtureURL("cli"),
            to: projectA.appendingPathComponent("11111111-1111-1111-1111-111111111111.jsonl")
        )
        try FileManager.default.copyItem(
            at: try Self.fixtureURL("vscode"),
            to: projectA.appendingPathComponent("22222222-2222-2222-2222-222222222222.jsonl")
        )
        try FileManager.default.copyItem(
            at: try Self.fixtureURL("sdk"),
            to: projectB.appendingPathComponent("44444444-4444-4444-4444-444444444444.jsonl")
        )
        // A non-JSONL sibling must be ignored by the scan.
        try Data("not a session log".utf8)
            .write(to: projectB.appendingPathComponent("notes.txt"))
        return root
    }

    // MARK: - Line parsing

    func testParsesAssistantLineWithFullUsage() throws {
        let parser = SessionLogParser()
        let line = """
        {"type":"assistant","entrypoint":"cli","timestamp":"2026-07-15T11:30:00.000Z",\
        "isSidechain":false,"sessionId":"abc","message":{"role":"assistant",\
        "model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":500,\
        "cache_creation_input_tokens":2000,"cache_read_input_tokens":10000,\
        "cache_creation":{"ephemeral_5m_input_tokens":1200,"ephemeral_1h_input_tokens":800}}}}
        """
        let event = try XCTUnwrap(parser.usageEvent(fromJSONLLine: line, path: "p", lineNumber: 1))

        XCTAssertEqual(event.entrypoint, .cli)
        XCTAssertEqual(event.modelID, "claude-sonnet-5")
        XCTAssertEqual(event.modelFamily, .sonnet)
        XCTAssertEqual(event.sessionID, "abc")
        XCTAssertFalse(event.isSidechain)
        XCTAssertEqual(event.usage.inputTokens, 1000)
        XCTAssertEqual(event.usage.outputTokens, 500)
        XCTAssertEqual(event.usage.cacheCreationInputTokens, 2000)
        XCTAssertEqual(event.usage.cacheReadInputTokens, 10000)
        XCTAssertEqual(event.usage.ephemeral5mInputTokens, 1200)
        XCTAssertEqual(event.usage.ephemeral1hInputTokens, 800)
        XCTAssertEqual(event.usage.totalTokens, 13500)
        XCTAssertEqual(
            event.timestamp,
            SessionLogParser.parseTimestamp("2026-07-15T11:30:00.000Z")
        )
    }

    func testSkipsNonUsageLinesWithoutError() throws {
        let parser = SessionLogParser()
        let lines = [
            #"{"type":"user","entrypoint":"cli","timestamp":"2026-07-15T11:00:00.000Z","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"summary","summary":"x","leafUuid":"y"}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-07-15T11:00:00.000Z"}"#,
            #"{"type":"attachment","entrypoint":"cli","timestamp":"2026-07-15T11:00:00.000Z"}"#,
            "",
            "   ",
        ]
        for line in lines {
            XCTAssertNil(
                try parser.usageEvent(fromJSONLLine: line, path: "p", lineNumber: 1),
                "expected no event for: \(line)"
            )
        }
    }

    func testMalformedAndTruncatedLinesThrowMalformedLogLine() throws {
        let parser = SessionLogParser()
        let truncated = #"{"type":"assistant","entrypoint":"cli","timestamp":"2026-07-15T11:5"#

        XCTAssertThrowsError(
            try parser.usageEvent(fromJSONLLine: truncated, path: "/x.jsonl", lineNumber: 7)
        ) { error in
            XCTAssertEqual(error as? ClaudeStatsError, .malformedLogLine(path: "/x.jsonl", line: 7))
        }

        // Valid JSON, assistant usage, but no timestamp to place it in a window.
        let noTimestamp = #"{"type":"assistant","entrypoint":"cli","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":5}}}"#
        XCTAssertThrowsError(
            try parser.usageEvent(fromJSONLLine: noTimestamp, path: "/x.jsonl", lineNumber: 9)
        ) { error in
            XCTAssertEqual(error as? ClaudeStatsError, .malformedLogLine(path: "/x.jsonl", line: 9))
        }
    }

    func testCorruptNonAssistantLineIsSkippedSilently() throws {
        let parser = SessionLogParser()
        // Documented trade-off of the pre-parse gate: a corrupt line that the
        // leading `type` already rules out carries no token counts, so it's
        // skipped rather than reported.
        let corrupt = #"{"type":"user","content": <<not json>>}"#
        XCTAssertNil(try parser.usageEvent(fromJSONLLine: corrupt, path: "p", lineNumber: 1))

        // A corrupt line that *does* claim usage is still reported, because a
        // token count may have been lost.
        let corruptWithUsage = #"{"type":"assistant","usage": <<not json>>}"#
        XCTAssertThrowsError(
            try parser.usageEvent(fromJSONLLine: corruptWithUsage, path: "p", lineNumber: 2)
        ) { error in
            XCTAssertEqual(error as? ClaudeStatsError, .malformedLogLine(path: "p", line: 2))
        }
    }

    func testLeadingTypeGateRejectsOnlyWhatItIsSureAbout() {
        // Rejectable without parsing.
        for line in [#"{"type":"user","x":1}"#, #"{"type":"attachment"}"#, #"{"type":"summary"}"#] {
            XCTAssertTrue(SessionLogParser.beginsWithNonAssistantType(Data(line.utf8)), line)
        }
        // Must be parsed: assistant, unknown key order, prefix mismatch, truncation.
        for line in [
            #"{"type":"assistant","message":{}}"#,
            #"{"sessionId":"a","type":"user"}"#,   // `type` not first → parse it
            #"{"type":"assistan"#,                  // unterminated value
            "{}",
            "",
        ] {
            XCTAssertFalse(SessionLogParser.beginsWithNonAssistantType(Data(line.utf8)), line)
        }
        // A value that merely starts like "assistant" is still rejected.
        XCTAssertTrue(SessionLogParser.beginsWithNonAssistantType(Data(#"{"type":"assistant-x"}"#.utf8)))
    }

    func testUnknownEntrypointDecodesToNilRatherThanFailing() throws {
        let parser = SessionLogParser()
        let line = #"{"type":"assistant","entrypoint":"future-ide","timestamp":"2026-07-15T10:30:00.000Z","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":700,"output_tokens":300}}}"#
        let event = try XCTUnwrap(parser.usageEvent(fromJSONLLine: line))

        XCTAssertNil(event.entrypoint)
        XCTAssertEqual(event.usage.totalTokens, 1000)
    }

    func testFileParseCollectsTruncatedLineInsteadOfFailing() throws {
        let result = SessionLogParser().parse(fileAt: try Self.fixtureURL("sdk"))

        // haiku + unknown-entrypoint + mystery model + synthetic = 4 usable events.
        XCTAssertEqual(result.events.count, 4)
        XCTAssertEqual(result.skippedLines.count, 1)
        if case .malformedLogLine(_, let line)? = result.skippedLines.first {
            XCTAssertEqual(line, 5, "the truncated final line should be the one reported")
        } else {
            XCTFail("expected a malformedLogLine, got \(String(describing: result.skippedLines.first))")
        }
    }

    func testTimestampParsingAcceptsBothISO8601Shapes() {
        XCTAssertNotNil(SessionLogParser.parseTimestamp("2026-07-15T11:30:00.939Z"))
        XCTAssertNotNil(SessionLogParser.parseTimestamp("2026-07-15T11:30:00Z"))
        XCTAssertNil(SessionLogParser.parseTimestamp("15 July 2026"))
    }

    // MARK: - Entrypoint breakdown

    func testEntrypointBreakdownPerWindow() throws {
        let store = try makeStore()

        let fiveHour = try store.entrypointBreakdown(for: .fiveHour)
        XCTAssertEqual(fiveHour.window, .fiveHour)
        XCTAssertEqual(fiveHour.tokens(for: .cli), 13_800)      // 13500 + 300
        XCTAssertEqual(fiveHour.tokens(for: .vscode), 150)
        XCTAssertEqual(fiveHour.tokens(for: .sdkAgent), 2_600)  // 600 + 2000
        XCTAssertEqual(fiveHour.totalTokens, 16_550)

        let day = try store.entrypointBreakdown(for: .twentyFourHour)
        XCTAssertEqual(day.tokens(for: .cli), 19_800)           // + the 18h-old 6000
        XCTAssertEqual(day.tokens(for: .vscode), 150)
        XCTAssertEqual(day.tokens(for: .sdkAgent), 2_600)

        let week = try store.entrypointBreakdown(for: .sevenDay)
        XCTAssertEqual(week.tokens(for: .cli), 22_300)          // + the 4d-old 2500
        XCTAssertEqual(week.totalTokens, 25_050)
    }

    func testUnknownEntrypointExcludedFromBreakdownButCountedInTotals() throws {
        let store = try makeStore()
        let fiveHour = try store.entrypointBreakdown(for: .fiveHour)

        // The `future-ide` event's 1000 tokens are in no breakdown row…
        XCTAssertEqual(
            fiveHour.totalTokens,
            Entrypoint.displayOrder.reduce(0) { $0 + fiveHour.tokens(for: $1) }
        )
        XCTAssertEqual(fiveHour.totalTokens, 16_550)

        // …but they are part of the model rows, so spend isn't lost.
        let sonnet = try XCTUnwrap(try store.modelUsage(last24h: true).first { $0.family == .sonnet })
        XCTAssertEqual(sonnet.tokens, 20_800)  // 13500 + 300 + 6000 + 1000
    }

    func testEmptyStoreYieldsZeroedBreakdown() throws {
        let now = Self.referenceNow
        let store = LocalLogUsageStore(events: [], calendar: Self.utcCalendar, now: { now })

        for window in TimeWindow.allCases {
            let breakdown = try store.entrypointBreakdown(for: window)
            XCTAssertEqual(breakdown.totalTokens, 0)
            XCTAssertEqual(breakdown.orderedRows.count, Entrypoint.displayOrder.count)
        }
        XCTAssertEqual(try store.burnRatePerHour(), 0)
        XCTAssertEqual(try store.estimatedCostToday(), 0)
        XCTAssertTrue(try store.modelUsage(last24h: false).isEmpty)
        XCTAssertEqual(try store.detectedPlanTier(), .custom(tokens: 0))
    }

    // MARK: - Model usage and cost

    func testModelUsageLast24hGroupsByFamilyInDisplayOrder() throws {
        let rows = try makeStore().modelUsage(last24h: true)

        XCTAssertEqual(rows.map(\.family), [.sonnet, .opus, .haiku, nil])
        XCTAssertEqual(rows.map(\.tokens), [20_800, 150, 600, 2_000])
        XCTAssertEqual(rows.last?.modelID, "claude-mystery-9")
        XCTAssertEqual(rows.last?.displayName, "claude-mystery-9")
        XCTAssertEqual(rows.last?.estimatedCostUSD, 0, "unpriced model must not invent a cost")
        // `<synthetic>` reports all-zero usage and must not add a row.
        XCTAssertFalse(rows.contains { $0.modelID == "<synthetic>" })
    }

    func testModelUsageAllTimeIncludesEventsOutsideEveryWindow() throws {
        let rows = try makeStore().modelUsage(last24h: false)

        let sonnet = try XCTUnwrap(rows.first { $0.family == .sonnet })
        let opus = try XCTUnwrap(rows.first { $0.family == .opus })
        XCTAssertEqual(sonnet.tokens, 23_300)      // + the 4d-old 2500
        XCTAssertEqual(opus.tokens, 1_000_150)     // + the 8d-old 1M
    }

    func testModelUsageCostsUsePerFamilyPricing() throws {
        let rows = try makeStore().modelUsage(last24h: true)
        let sonnet = try XCTUnwrap(rows.first { $0.family == .sonnet })
        let opus = try XCTUnwrap(rows.first { $0.family == .opus })
        let haiku = try XCTUnwrap(rows.first { $0.family == .haiku })

        // Sonnet $3/$15 per MTok, cache write 1.25x input, cache read 0.1x input.
        XCTAssertEqual(sonnet.estimatedCostUSD, 0.0597, accuracy: 1e-9)
        XCTAssertEqual(opus.estimatedCostUSD, 0.00175, accuracy: 1e-9)   // $5/$25
        XCTAssertEqual(haiku.estimatedCostUSD, 0.0014, accuracy: 1e-9)   // $1/$5
    }

    func testPricingTableCoversEveryModelFamily() {
        for family in ModelFamily.allCases {
            XCTAssertNotNil(ModelPricing.forFamily(family), "no price for \(family.rawValue)")
        }
        XCTAssertNil(ModelPricing.forModelID("claude-mystery-9"))
        XCTAssertNil(ModelPricing.forModelID("<synthetic>"))
    }

    func testCacheWriteTTLChangesCost() throws {
        let pricing = try XCTUnwrap(ModelPricing.forFamily(.sonnet))
        let write5m = TokenUsage(cacheCreationInputTokens: 1_000_000, ephemeral5mInputTokens: 1_000_000)
        let write1h = TokenUsage(cacheCreationInputTokens: 1_000_000, ephemeral1hInputTokens: 1_000_000)
        let unattributed = TokenUsage(cacheCreationInputTokens: 1_000_000)

        XCTAssertEqual(pricing.costUSD(for: write5m), 3.75, accuracy: 1e-9)
        XCTAssertEqual(pricing.costUSD(for: write1h), 6.0, accuracy: 1e-9)
        // No `cache_creation` breakdown on the line → charged at the 5m default.
        XCTAssertEqual(pricing.costUSD(for: unattributed), 3.75, accuracy: 1e-9)
    }

    // MARK: - Burn rate and cost today

    func testBurnRateCountsOnlyTheTrailingHour() throws {
        // 11:30 (13500) + 11:45 (150) + 11:50 (2000) + 11:55 synthetic (0).
        XCTAssertEqual(try makeStore().burnRatePerHour(), 15_650, accuracy: 1e-9)
    }

    func testEstimatedCostTodayUsesLocalMidnight() throws {
        // UTC calendar → midnight is 2026-07-15T00:00Z, so the 07-14 and older
        // events are excluded while every 07-15 event counts.
        XCTAssertEqual(try makeStore().estimatedCostToday(), 0.03285, accuracy: 1e-9)
    }

    func testEstimatedCostTodayHonoursTheInjectedCalendar() throws {
        let parsed = SessionLogParser().parse(fileAt: try Self.fixtureURL("cli"))
        let now = Self.referenceNow

        func costToday(secondsFromGMT: Int) throws -> Double {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
            return try LocalLogUsageStore(
                events: parsed.events,
                calendar: calendar,
                now: { now }
            ).estimatedCostToday()
        }

        // UTC: midnight is 07-15T00:00Z, so both of today's cli events count
        // (09:00 → $0.0021 and 11:30 → $0.0210).
        XCTAssertEqual(try costToday(secondsFromGMT: 0), 0.0231, accuracy: 1e-9)

        // UTC+14: "now" is already 07-16T02:00 local, so midnight is 07-15T10:00Z
        // and only the 11:30 event is inside today.
        XCTAssertEqual(try costToday(secondsFromGMT: 14 * 3600), 0.021, accuracy: 1e-9)

        // UTC-11: midnight is 07-15T11:00Z — later still, same single event.
        XCTAssertEqual(try costToday(secondsFromGMT: -11 * 3600), 0.021, accuracy: 1e-9)
    }

    // MARK: - Plan tier detection

    /// One 5-hour window per day for 8 days, `tokens` of plain input each.
    private func planDetectionStore(windowTokens: [Int]) -> LocalLogUsageStore {
        let now = Self.referenceNow
        let events = windowTokens.enumerated().map { index, tokens in
            UsageEvent(
                // Day `index` back, offset inside the bucket so no two share one.
                timestamp: now.addingTimeInterval(-Double(index) * 86_400 - 60),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: tokens)
            )
        }
        return LocalLogUsageStore(events: events, calendar: Self.utcCalendar, now: { now })
    }

    func testDetectedPlanTierSnapsP90ToNearestKnownTier() throws {
        // P90 of these eight windows is 88_000 → Max5.
        let store = planDetectionStore(
            windowTokens: [20_000, 30_000, 40_000, 50_000, 60_000, 70_000, 80_000, 88_000]
        )
        XCTAssertEqual(store.fiveHourWindowP90(), 88_000)
        XCTAssertEqual(try store.detectedPlanTier(), .max5)

        let pro = planDetectionStore(windowTokens: Array(repeating: 19_000, count: 8))
        XCTAssertEqual(try pro.detectedPlanTier(), .pro)

        let max20 = planDetectionStore(windowTokens: Array(repeating: 215_000, count: 8))
        XCTAssertEqual(try max20.detectedPlanTier(), .max20)
    }

    func testDetectedPlanTierFallsBackToCustomWhenNowhereNearAThreshold() throws {
        let store = planDetectionStore(windowTokens: Array(repeating: 600_000, count: 8))
        XCTAssertEqual(store.fiveHourWindowP90(), 600_000)
        XCTAssertEqual(try store.detectedPlanTier(), .custom(tokens: 600_000))
        XCTAssertFalse(try store.detectedPlanTier().isKnownTier)
    }

    func testPlanDetectionIgnoresHistoryOlderThanEightDays() throws {
        let now = Self.referenceNow
        let events = [
            // Inside the window: one busy 5-hour bucket.
            UsageEvent(
                timestamp: now.addingTimeInterval(-3600),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 88_000)
            ),
            // 10 days old — must not influence the percentile.
            UsageEvent(
                timestamp: now.addingTimeInterval(-10 * 86_400),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 5_000_000)
            ),
        ]
        let store = LocalLogUsageStore(events: events, calendar: Self.utcCalendar, now: { now })

        XCTAssertEqual(store.fiveHourWindowP90(), 88_000)
        XCTAssertEqual(try store.detectedPlanTier(), .max5)
    }

    func testPlanDetectionWeightsCacheTokensBelowFreshInput() throws {
        let now = Self.referenceNow
        // 1M cache reads weigh 0.1x → 100k, not 1M.
        let event = UsageEvent(
            timestamp: now.addingTimeInterval(-600),
            entrypoint: .cli,
            modelID: "claude-sonnet-5",
            usage: TokenUsage(cacheReadInputTokens: 1_000_000)
        )
        let store = LocalLogUsageStore(events: [event], calendar: Self.utcCalendar, now: { now })

        XCTAssertEqual(event.usage.totalTokens, 1_000_000)
        XCTAssertEqual(event.usage.quotaWeightedTokens, 100_000)
        XCTAssertEqual(store.fiveHourWindowP90(), 100_000)
    }

    func testFiveHourWindowP90ExcludesThePartialCurrentBucketWhenOlderHistoryExists() throws {
        let now = Self.referenceNow
        // A big burst 60s ago (partial "current" bucket) plus 7 fully-populated
        // older-day buckets at a much lower, consistent level. Including the
        // burst in the percentile would skew P90 toward it; excluding it (the
        // fix here) keeps P90 anchored to the representative older buckets.
        var events = [
            UsageEvent(
                timestamp: now.addingTimeInterval(-60),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 5_000_000)
            ),
        ]
        events += (1...7).map { day in
            UsageEvent(
                timestamp: now.addingTimeInterval(-Double(day) * 86_400 - 60),
                entrypoint: .cli,
                modelID: "claude-sonnet-5",
                usage: TokenUsage(inputTokens: 19_000)
            )
        }
        let store = LocalLogUsageStore(events: events, calendar: Self.utcCalendar, now: { now })

        XCTAssertEqual(store.fiveHourWindowP90(), 19_000)
    }

    // MARK: - Config directory resolution

    func testResolveHonoursCLAUDE_CONFIG_DIR() throws {
        let root = try makeFakeConfigDirectory()
        let resolved = try ClaudeConfigDirectory.resolve(
            environment: [ClaudeConfigDirectory.environmentVariable: root.path]
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, root.standardizedFileURL.path)
    }

    func testResolveFallsBackToDotClaudeInHome() throws {
        let home = try makeFakeConfigDirectory()  // any existing dir works as a fake $HOME
        let dotClaude = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dotClaude, withIntermediateDirectories: true)

        let resolved = try ClaudeConfigDirectory.resolve(environment: [:], homeDirectory: home)
        XCTAssertEqual(resolved.lastPathComponent, ".claude")
        XCTAssertEqual(resolved.standardizedFileURL.path, dotClaude.standardizedFileURL.path)
    }

    func testResolveIgnoresBlankOverride() throws {
        let home = try makeFakeConfigDirectory()
        let dotClaude = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dotClaude, withIntermediateDirectories: true)

        let resolved = try ClaudeConfigDirectory.resolve(
            environment: [ClaudeConfigDirectory.environmentVariable: "   "],
            homeDirectory: home
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, dotClaude.standardizedFileURL.path)
    }

    func testResolveThrowsConfigDirectoryNotFoundForMissingPath() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString)")

        XCTAssertThrowsError(
            try ClaudeConfigDirectory.resolve(
                environment: [ClaudeConfigDirectory.environmentVariable: missing.path]
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeStatsError, .configDirectoryNotFound)
        }
    }

    func testResolveThrowsWhenOverridePointsAtAFile() throws {
        let root = try makeFakeConfigDirectory()
        let file = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)

        XCTAssertThrowsError(
            try ClaudeConfigDirectory.resolve(
                environment: [ClaudeConfigDirectory.environmentVariable: file.path]
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeStatsError, .configDirectoryNotFound)
        }
    }

    // MARK: - Directory scanning

    func testInitFromConfigDirectoryScansEveryProjectSubdirectory() throws {
        let root = try makeFakeConfigDirectory()
        let now = Self.referenceNow
        let store = try LocalLogUsageStore(
            configDirectory: root,
            calendar: Self.utcCalendar,
            now: { now }
        )

        // Same numbers as the direct-fixture store: the scan found all three files.
        XCTAssertEqual(try store.entrypointBreakdown(for: .fiveHour).totalTokens, 16_550)
        XCTAssertEqual(try store.modelUsage(last24h: true).count, 4)
        XCTAssertEqual(store.skippedLines.count, 1, "only the truncated fixture line")
    }

    func testInitFromEnvironmentUsesTheOverride() throws {
        let root = try makeFakeConfigDirectory()
        let now = Self.referenceNow
        let store = try LocalLogUsageStore(
            environment: [ClaudeConfigDirectory.environmentVariable: root.path],
            calendar: Self.utcCalendar,
            now: { now }
        )
        XCTAssertEqual(try store.burnRatePerHour(), 15_650, accuracy: 1e-9)
    }

    func testSessionFileURLsIgnoresNonJSONLAndMissingProjectsDirectory() throws {
        let root = try makeFakeConfigDirectory()
        let urls = SessionLogParser.sessionFileURLs(inConfigDirectory: root)

        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls.allSatisfy { $0.pathExtension == "jsonl" })
        XCTAssertEqual(urls, urls.sorted { $0.path < $1.path }, "scan order must be deterministic")

        let empty = root.appendingPathComponent("no-projects-here", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertTrue(SessionLogParser.sessionFileURLs(inConfigDirectory: empty).isEmpty)
    }

    func testInitFromConfigDirectoryThrowsWhenDirectoryIsMissing() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try LocalLogUsageStore(configDirectory: missing)) { error in
            XCTAssertEqual(error as? ClaudeStatsError, .configDirectoryNotFound)
        }
    }

    func testConfigDirectoryWithoutProjectsTreeYieldsEmptyStore() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-stats-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let store = try LocalLogUsageStore(configDirectory: root)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.skippedLines.isEmpty)
    }

    // MARK: - Incremental refresh

    func testAddingEventsKeepsTheStoreSortedAndPreservesTheClock() throws {
        let store = try makeStore(fixtures: ["cli"])
        let extra = SessionLogParser().parse(fileAt: try Self.fixtureURL("vscode"))
        let merged = store.adding(events: extra.events, skippedLines: extra.skippedLines)

        XCTAssertEqual(merged.events.count, store.events.count + extra.events.count)
        XCTAssertEqual(merged.events.map(\.timestamp), merged.events.map(\.timestamp).sorted())
        XCTAssertEqual(try merged.entrypointBreakdown(for: .fiveHour).tokens(for: .vscode), 150)
        XCTAssertEqual(try merged.entrypointBreakdown(for: .fiveHour).tokens(for: .cli), 13_800)
    }

    func testAddingOutOfOrderEventsStillSortsTheResult() {
        // Synthetic, deliberately out-of-order data — the fixture-based test
        // above happens to already be chronological end-to-end, which would
        // pass whether or not the merge actually sorted anything.
        let now = Self.referenceNow
        let store = LocalLogUsageStore(
            events: [
                UsageEvent(timestamp: now, entrypoint: .cli, modelID: "claude-sonnet-5", usage: TokenUsage(inputTokens: 1)),
            ],
            calendar: Self.utcCalendar,
            now: { now }
        )
        let outOfOrder = [
            UsageEvent(timestamp: now.addingTimeInterval(-3600), entrypoint: .cli, modelID: "claude-sonnet-5", usage: TokenUsage(inputTokens: 2)),
            UsageEvent(timestamp: now.addingTimeInterval(-7200), entrypoint: .cli, modelID: "claude-sonnet-5", usage: TokenUsage(inputTokens: 3)),
        ]
        let merged = store.adding(events: outOfOrder)

        let naiveConcatenation = store.events + outOfOrder
        XCTAssertNotEqual(naiveConcatenation.map(\.timestamp), merged.events.map(\.timestamp))
        XCTAssertEqual(merged.events.map(\.timestamp), merged.events.map(\.timestamp).sorted())
    }

    func testEventsInRangeIsInclusiveAtBothEnds() throws {
        let store = try makeStore(fixtures: ["cli"])
        let start = SessionLogParser.parseTimestamp("2026-07-15T09:00:00.000Z")!
        let end = SessionLogParser.parseTimestamp("2026-07-15T11:30:00.000Z")!

        let slice = store.events(in: start, to: end)
        XCTAssertEqual(slice.count, 2)
        XCTAssertEqual(slice.first?.timestamp, start)
        XCTAssertEqual(slice.last?.timestamp, end)
        XCTAssertTrue(store.events(in: end, to: start).isEmpty, "inverted range yields nothing")
    }

    // MARK: - Protocol conformance

    func testConformsToUsageStoringAndIsUsableThroughTheProtocol() throws {
        let store: any UsageStoring = try makeStore()

        XCTAssertEqual(try store.entrypointBreakdown(for: .fiveHour).totalTokens, 16_550)
        XCTAssertFalse(try store.modelUsage(last24h: true).isEmpty)
        XCTAssertGreaterThan(try store.burnRatePerHour(), 0)
        XCTAssertGreaterThan(try store.estimatedCostToday(), 0)
        _ = try store.detectedPlanTier()
    }
}
