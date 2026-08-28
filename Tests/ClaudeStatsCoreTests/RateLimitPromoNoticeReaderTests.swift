import XCTest

@testable import ClaudeStatsCore

/// Every test writes its fixture into a per-test temp directory and injects the
/// candidate paths — the developer's real `~/.claude.json` is never read.
final class RateLimitPromoNoticeReaderTests: XCTestCase {
    private var directory: URL!
    private var primaryURL: URL!
    private var fallbackURL: URL!

    /// Fixed clock, roughly a day after ``realCachedAtMilliseconds``.
    private let now = Date(timeIntervalSince1970: 1_787_900_000)
    /// The `cachedGrowthBookFeaturesAt` value observed on a real machine —
    /// 13-digit epoch milliseconds.
    private let realCachedAtMilliseconds = 1_787_814_106_669

    /// The exact promo text cached on a real machine.
    private let realText = "+50% weekly limits promo through Aug 31 · clau.de/cc-50-promo"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RateLimitPromoNoticeReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        primaryURL = directory.appendingPathComponent("primary-.claude.json")
        fallbackURL = directory.appendingPathComponent("fallback-.claude.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func write(_ json: String, to url: URL? = nil) throws {
        try Data(json.utf8).write(to: url ?? primaryURL)
    }

    private func makeReader(
        candidates: [URL]? = nil,
        maximumAge: TimeInterval = RateLimitPromoNoticeReader.defaultMaximumAge
    ) -> RateLimitPromoNoticeReader {
        let fixedNow = now
        return RateLimitPromoNoticeReader(
            candidateURLs: candidates ?? [primaryURL, fallbackURL],
            maximumAge: maximumAge,
            now: { fixedNow }
        )
    }

    /// The real-machine shape, trimmed to the keys that matter.
    private func realFixture() -> String {
        """
        {
          "userID": "not-read-by-anything-here",
          "cachedGrowthBookFeatures": {
            "tengu_startup_announcements": [{ "id": "x", "maxImpressions": 3 }],
            "tengu_rate_limit_promo_notices": [
              { "bar": "seven_day",
                "text": "\(realText)",
                "variant": "claude" }
            ]
          },
          "cachedGrowthBookFeaturesAt": \(realCachedAtMilliseconds)
        }
        """
    }

    /// Wraps `entries` (raw JSON array body) with a fresh timestamp.
    private func fixture(entries: String, cachedAt: Date? = nil) -> String {
        let milliseconds = Int(((cachedAt ?? now).timeIntervalSince1970 * 1000).rounded())
        return """
            {
              "cachedGrowthBookFeatures": {
                "tengu_rate_limit_promo_notices": [\(entries)]
              },
              "cachedGrowthBookFeaturesAt": \(milliseconds)
            }
            """
    }

    private func entry(bar: String = "seven_day", text: String, variant: String? = nil) -> String {
        let variantField = variant.map { ", \"variant\": \"\($0)\"" } ?? ""
        return "{ \"bar\": \"\(bar)\", \"text\": \"\(text)\"\(variantField) }"
    }

    // MARK: - Assertions

    private func read(
        _ reader: RateLimitPromoNoticeReader,
        unchangedSince previous: ClaudeStateFileFingerprint? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (notices: [RateLimitPromoNotice], fingerprint: ClaudeStateFileFingerprint?) {
        switch reader.read(unchangedSince: previous) {
        case .unchanged:
            XCTFail("expected a completed read, got .unchanged", file: file, line: line)
            throw XCTSkip("unreachable")
        case .read(let notices, let fingerprint):
            return (notices, fingerprint)
        }
    }

    // MARK: - Missing / unreadable

    func testMissingFileReadsAsNoPromoWithNoFingerprint() throws {
        let result = try read(makeReader())

        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertNil(result.fingerprint)
    }

    func testMalformedJSONReadsAsNoPromoWithoutThrowing() throws {
        try write("{ \"cachedGrowthBookFeatures\": { \"tengu_rate_l")

        let result = try read(makeReader())

        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertNil(result.fingerprint)
    }

    func testJSONArrayAtTheRootReadsAsNoPromo() throws {
        try write("[1, 2, 3]")

        let result = try read(makeReader())

        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertNil(result.fingerprint)
    }

    // MARK: - The real fixture

    func testRealMachineFixtureYieldsOneSevenDayNotice() throws {
        try write(realFixture())

        let result = try read(makeReader())

        XCTAssertEqual(result.notices.count, 1)
        let notice = try XCTUnwrap(result.notices.first)
        XCTAssertEqual(notice.bar, .sevenDay)
        XCTAssertEqual(notice.variant, "claude")
        XCTAssertEqual(notice.text, realText)
        XCTAssertEqual(notice.body.linkLabel, "clau.de/cc-50-promo")
        XCTAssertEqual(notice.body.linkURL?.absoluteString, "https://clau.de/cc-50-promo")
        XCTAssertEqual(result.fingerprint?.url, primaryURL)
    }

    // MARK: - Candidate ordering

    func testFirstCandidateThatOpensWins() throws {
        try write(fixture(entries: entry(text: "first candidate clau.de/a")))
        try write(fixture(entries: entry(text: "second candidate clau.de/b")), to: fallbackURL)

        let result = try read(makeReader())

        XCTAssertEqual(result.notices.first?.body.linkLabel, "clau.de/a")
        XCTAssertEqual(result.fingerprint?.url, primaryURL)
    }

    func testFallbackCandidateIsUsedWhenTheFirstDoesNotExist() throws {
        try write(fixture(entries: entry(text: "second candidate clau.de/b")), to: fallbackURL)

        let result = try read(makeReader())

        XCTAssertEqual(result.notices.first?.body.linkLabel, "clau.de/b")
        XCTAssertEqual(result.fingerprint?.url, fallbackURL)
    }

    // MARK: - Shape of the promo key

    func testMissingPromoKeyReadsAsNoPromoButStillAdvancesTheFingerprint() throws {
        try write(
            """
            { "cachedGrowthBookFeatures": { "tengu_startup_announcements": [] },
              "cachedGrowthBookFeaturesAt": \(Int(now.timeIntervalSince1970 * 1000)) }
            """
        )

        let result = try read(makeReader())

        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertNotNil(result.fingerprint)
    }

    func testNonArrayPromoKeyReadsAsNoPromo() throws {
        try write(
            """
            { "cachedGrowthBookFeatures": { "tengu_rate_limit_promo_notices": { "bar": "seven_day" } },
              "cachedGrowthBookFeaturesAt": \(Int(now.timeIntervalSince1970 * 1000)) }
            """
        )

        XCTAssertTrue(try read(makeReader()).notices.isEmpty)
    }

    func testEmptyPromoArrayReadsAsNoPromo() throws {
        try write(fixture(entries: ""))

        XCTAssertTrue(try read(makeReader()).notices.isEmpty)
    }

    func testMissingFeaturesBlobReadsAsNoPromo() throws {
        try write("{ \"cachedGrowthBookFeaturesAt\": \(Int(now.timeIntervalSince1970 * 1000)) }")

        XCTAssertTrue(try read(makeReader()).notices.isEmpty)
    }

    // MARK: - Per-entry skips

    /// Each bad entry is dropped on its own — a sibling valid entry must still
    /// come back, or one upstream typo would take out the whole feature.
    func testBadEntriesAreSkippedIndividually() throws {
        let valid = entry(bar: "five_hour", text: "still here clau.de/ok")
        let cases: [(name: String, bad: String)] = [
            ("unknown bar", entry(bar: "opus_weekly", text: "dropped clau.de/x")),
            ("missing bar", "{ \"text\": \"dropped clau.de/x\" }"),
            ("non-string bar", "{ \"bar\": 7, \"text\": \"dropped clau.de/x\" }"),
            ("empty text", entry(text: "")),
            ("whitespace-only text", entry(text: "   ")),
            ("missing text", "{ \"bar\": \"seven_day\" }"),
            ("over-long text", entry(text: String(repeating: "a", count: 201))),
            ("not an object", "\"just a string\""),
        ]

        for (name, bad) in cases {
            try write(fixture(entries: "\(bad), \(valid)"))
            let notices = try read(makeReader()).notices

            XCTAssertEqual(notices.count, 1, "\(name): expected only the sibling to survive")
            XCTAssertEqual(notices.first?.bar, .fiveHour, "\(name)")
            XCTAssertEqual(notices.first?.body.linkLabel, "clau.de/ok", "\(name)")
        }
    }

    func testCamelCaseBarSpellingIsAccepted() throws {
        try write(fixture(entries: entry(bar: "sevenDay", text: "promo clau.de/x")))

        XCTAssertEqual(try read(makeReader()).notices.first?.bar, .sevenDay)
    }

    /// Non-linkable text is a plain notice, not a dropped one.
    func testEntryWithoutAURLIsKeptAsPlainText() throws {
        try write(fixture(entries: entry(text: "+50% weekly limits promo through Aug 31")))

        let notice = try XCTUnwrap(try read(makeReader()).notices.first)
        XCTAssertNil(notice.body.linkLabel)
        XCTAssertEqual(notice.text, "+50% weekly limits promo through Aug 31")
    }

    // MARK: - Age gate

    func testMissingTimestampMeansUnknownAgeAndIsNotShown() throws {
        try write(
            """
            { "cachedGrowthBookFeatures": { "tengu_rate_limit_promo_notices": [
                \(entry(text: "promo clau.de/x")) ] } }
            """
        )

        XCTAssertTrue(try read(makeReader()).notices.isEmpty)
    }

    func testStaleFlagCacheIsNotShown() throws {
        let cachedAt = now.addingTimeInterval(-(RateLimitPromoNoticeReader.defaultMaximumAge + 3600))
        try write(fixture(entries: entry(text: "promo clau.de/x"), cachedAt: cachedAt))

        XCTAssertTrue(try read(makeReader()).notices.isEmpty)
    }

    func testFlagCacheJustInsideTheWindowIsShown() throws {
        let cachedAt = now.addingTimeInterval(-(RateLimitPromoNoticeReader.defaultMaximumAge - 60))
        try write(fixture(entries: entry(text: "promo clau.de/x"), cachedAt: cachedAt))

        XCTAssertEqual(try read(makeReader()).notices.count, 1)
    }

    /// Clock skew shouldn't silently hide a live promo.
    func testFutureDatedFlagCacheIsTreatedAsFresh() throws {
        try write(
            fixture(entries: entry(text: "promo clau.de/x"), cachedAt: now.addingTimeInterval(86_400))
        )

        XCTAssertEqual(try read(makeReader()).notices.count, 1)
    }

    /// `QuotaJSON.date`'s magnitude heuristic has to cover an upstream switch
    /// from milliseconds to seconds.
    func testTimestampInSecondsRatherThanMillisecondsIsAccepted() throws {
        try write(
            """
            { "cachedGrowthBookFeatures": { "tengu_rate_limit_promo_notices": [
                \(entry(text: "promo clau.de/x")) ] },
              "cachedGrowthBookFeaturesAt": \(Int(now.timeIntervalSince1970)) }
            """
        )

        XCTAssertEqual(try read(makeReader()).notices.count, 1)
    }

    // MARK: - The unchanged-since gate

    func testUnchangedFileSkipsTheParse() throws {
        try write(realFixture())
        let reader = makeReader()
        let fingerprint = try XCTUnwrap(try read(reader).fingerprint)

        guard case .unchanged = reader.read(unchangedSince: fingerprint) else {
            return XCTFail("expected .unchanged for an untouched file")
        }
    }

    func testRewriteProducesANewFingerprintAndNewNotices() throws {
        try write(realFixture())
        let reader = makeReader()
        let first = try read(reader)
        let firstFingerprint = try XCTUnwrap(first.fingerprint)

        try write(fixture(entries: entry(bar: "five_hour", text: "rewritten clau.de/new")))
        let second = try read(reader, unchangedSince: firstFingerprint)

        XCTAssertNotEqual(second.fingerprint, firstFingerprint)
        XCTAssertEqual(second.notices.first?.bar, .fiveHour)
        XCTAssertEqual(second.notices.first?.body.linkLabel, "clau.de/new")
    }

    /// An atomic same-mtime replacement of a different size must not pass the
    /// gate — this stands in for it by handing over a fingerprint that agrees on
    /// everything but the size.
    func testFingerprintDisagreeingOnSizeForcesAReread() throws {
        try write(realFixture())
        let reader = makeReader()
        let actual = try XCTUnwrap(try read(reader).fingerprint)

        let wrongSize = ClaudeStateFileFingerprint(
            url: actual.url,
            modifiedAt: actual.modifiedAt,
            size: actual.size + 1,
            inode: actual.inode
        )

        XCTAssertEqual(try read(reader, unchangedSince: wrongSize).notices.count, 1)
    }

    /// A fingerprint from the other candidate path must never suppress a read.
    func testFingerprintFromADifferentPathForcesAReread() throws {
        try write(realFixture())
        let reader = makeReader()
        let actual = try XCTUnwrap(try read(reader).fingerprint)

        let otherPath = ClaudeStateFileFingerprint(
            url: fallbackURL,
            modifiedAt: actual.modifiedAt,
            size: actual.size,
            inode: actual.inode
        )

        XCTAssertEqual(try read(reader, unchangedSince: otherPath).notices.count, 1)
    }

    // MARK: - Directory at the path

    func testDirectoryAtACandidatePathIsSkipped() throws {
        let asDirectory = directory.appendingPathComponent("directory-.claude.json", isDirectory: true)
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
        try write(fixture(entries: entry(text: "promo clau.de/x")), to: fallbackURL)

        let result = try read(makeReader(candidates: [asDirectory, fallbackURL]))

        XCTAssertEqual(result.notices.count, 1)
        XCTAssertEqual(result.fingerprint?.url, fallbackURL)
    }
}
