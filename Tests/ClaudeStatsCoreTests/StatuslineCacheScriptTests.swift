import XCTest
@testable import ClaudeStatsCore

/// Runs the real hook script — `Sources/ClaudeStats/Resources/claude-stats-statusline-cache.sh`
/// — against a scratch cache directory, because `StatuslineCacheReaderTests`
/// can only prove the app reads what it expects, not that the script writes it.
/// The file layout is the contract between the two, and it is the half that
/// used to be wrong: one shared file that any session could overwrite.
///
/// `$HOME` is pointed at the scratch directory too, so the script's best-effort
/// read of `~/.claude.json` finds nothing — or the fixture a test planted there
/// — and this suite never touches the real one.
final class StatuslineCacheScriptTests: XCTestCase {
    private var directory: URL!
    private var cacheDirectory: URL!
    private var sessionDirectory: URL!

    private static let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ClaudeStatsCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Sources/ClaudeStats/Resources/claude-stats-statusline-cache.sh")

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatuslineCacheScriptTests-\(UUID().uuidString)", isDirectory: true)
        cacheDirectory = directory.appendingPathComponent("ClaudeStats", isDirectory: true)
        sessionDirectory = cacheDirectory.appendingPathComponent(
            StatuslineCacheReader.sessionCacheDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Running the script

    /// Feeds `payload` to the script on stdin and returns whatever it printed.
    /// `path` is `$PATH`, so a test can take `jq` away from it.
    @discardableResult
    private func run(
        _ payload: String,
        arguments: [String] = [],
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.scriptURL.path] + arguments
        process.environment = [
            "HOME": directory.path,
            "CLAUDE_STATS_CACHE_DIR": cacheDirectory.path,
            "PATH": path,
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: printed, as: UTF8.self)
    }

    /// A `$PATH` with everything the script's no-`jq` path needs and nothing
    /// else — macOS ships `jq` in `/usr/bin`, so hiding it means building a
    /// directory rather than trimming a path.
    private func pathWithoutJq() throws -> String {
        let bin = directory.appendingPathComponent("bin-without-jq", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["cat", "mkdir", "mktemp", "grep", "rm", "mv", "chmod"] {
            // `/bin` and `/usr/bin` split these between them (`mktemp` and
            // `grep` live in the latter), and a symlink to the wrong one is a
            // dangling link the script would report as a missing command.
            let source = try XCTUnwrap(["/bin/\(tool)", "/usr/bin/\(tool)"]
                .first { FileManager.default.isExecutableFile(atPath: $0) })
            try FileManager.default.createSymbolicLink(
                at: bin.appendingPathComponent(tool),
                withDestinationURL: URL(fileURLWithPath: source))
        }
        return bin.path
    }

    /// The `jq` branch is the one most tests assert on (`captured_at`,
    /// session-id file names, non-clobbering). Without `jq` on `$PATH` they
    /// would exercise the `tee` fallback instead and fail on confusing
    /// mismatches, so make the missing tool the stated reason.
    private func skipUnlessJqOnPath() throws {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        try XCTSkipUnless(
            path.split(separator: ":").contains {
                FileManager.default.isExecutableFile(atPath: "\($0)/jq")
            },
            "jq not on PATH; this test asserts the script's jq branch")
    }

    private func payload(session: String?, fiveHourPercent: Double = 68) -> String {
        let id = session.map { "\"session_id\": \"\($0)\"," } ?? ""
        return """
        { \(id) "rate_limits": { "five_hour": { "used_percentage": \(fiveHourPercent),
                                                "resets_at": 2000000000 } } }
        """
    }

    private func sessionFiles() throws -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path)) ?? []
        return contents.sorted()
    }

    private func json(of fileName: String) throws -> [String: Any] {
        let data = try Data(contentsOf: sessionDirectory.appendingPathComponent(fileName))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Where the script looks for Claude Code's own state file: `$HOME` is the
    /// scratch directory, so this is the only `.claude.json` it can find.
    private var stateFileURL: URL { directory.appendingPathComponent(".claude.json") }

    /// The script's machine-wide fingerprint sidecar, beside the session directory.
    private var utilizationSidecarURL: URL {
        cacheDirectory.appendingPathComponent("statusline-utilization-cache.json")
    }

    /// A `~/.claude.json` with one `weekly_scoped` limit, one the filter must
    /// drop, and a `spend` — no `extra_usage`, so its absence is asserted too.
    private func writeStateFile() throws {
        try Data("""
        { "cachedUsageUtilization": { "utilization": {
            "limits": [
              { "kind": "weekly_scoped", "name": "Opus", "utilization": 0.44 },
              { "kind": "session", "name": "ignored", "utilization": 0.9 }
            ],
            "spend": { "amount": 12.5, "currency": "USD" },
            "other": true
        } } }
        """.utf8).write(to: stateFileURL)
    }

    // MARK: - Tests

    /// The fix itself: the payload's own `session_id` names the file, so two
    /// sessions can't overwrite each other.
    func testEachSessionWritesItsOwnFile() throws {
        try skipUnlessJqOnPath()
        try run(payload(session: "aaaa-1111", fiveHourPercent: 68))
        try run(payload(session: "bbbb-2222", fiveHourPercent: 25))

        XCTAssertEqual(try sessionFiles(), ["aaaa-1111.json", "bbbb-2222.json"])
        let root = try json(of: "aaaa-1111.json")
        XCTAssertNotNil(root["captured_at"])
        let rateLimits = try XCTUnwrap(root["rate_limits"] as? [String: Any])
        let fiveHour = try XCTUnwrap(rateLimits["five_hour"] as? [String: Any])
        XCTAssertEqual(fiveHour["used_percentage"] as? Double, 68)
        // The single file the old script wrote is not written any more.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent(
                StatuslineCacheReader.legacyCacheFileName).path))
    }

    /// The id reaches the file system, so it is stripped to `[A-Za-z0-9._-]` and
    /// of leading dots — no separator survives, the name can only land inside
    /// the directory, and it isn't a hidden file the reader would skip.
    func testSessionIdIsSanitizedIntoAFileNameInsideTheDirectory() throws {
        try skipUnlessJqOnPath()
        try run(payload(session: "../../escape me/now"))

        XCTAssertEqual(try sessionFiles(), ["escapemenow.json"])
        // Nothing appeared outside the session directory.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).sorted(),
            [StatuslineCacheReader.sessionCacheDirectoryName])
    }

    /// A payload that names no session still gets cached — under the shared
    /// name, which is worse than one file per session and better than nothing.
    func testMissingSessionIdFallsBackToTheSharedName() throws {
        try skipUnlessJqOnPath()
        try run(payload(session: nil))

        XCTAssertEqual(try sessionFiles(), ["unknown-session.json"])
    }

    /// A `session_id` made entirely of characters the sanitizer strips collapses
    /// to nothing — the other route to the shared name, with `id` starting
    /// non-empty and emptying only after sanitization.
    func testSessionIdThatSanitizesToEmptyFallsBackToTheSharedName() throws {
        try skipUnlessJqOnPath()
        try run(payload(session: "!!! ..."))

        XCTAssertEqual(try sessionFiles(), ["unknown-session.json"])
    }

    /// A payload from before the session's first API response carries no
    /// `rate_limits`; it must not blank out what that session cached earlier.
    func testPayloadWithoutRateLimitsDoesNotClobberTheSessionsCache() throws {
        try skipUnlessJqOnPath()
        try run(payload(session: "aaaa-1111"))
        try run(#"{ "session_id": "aaaa-1111", "model": { "display_name": "Opus 5" } }"#)

        let rateLimits = try XCTUnwrap(try json(of: "aaaa-1111.json")["rate_limits"] as? [String: Any])
        XCTAssertNotNil(rateLimits["five_hour"])
    }

    /// The third and fourth bars: with a readable `~/.claude.json`, the script
    /// copies `cachedUsageUtilization.utilization` into the session file — only
    /// the `weekly_scoped` limits, plus `spend` and `extra_usage` when present.
    func testUtilizationIsCopiedOutOfTheStateFileWithOnlyWeeklyScopedLimits() throws {
        try skipUnlessJqOnPath()
        try writeStateFile()

        try run(payload(session: "aaaa-1111"))

        let utilization = try XCTUnwrap(try json(of: "aaaa-1111.json")["utilization"] as? [String: Any])
        let limits = try XCTUnwrap(utilization["limits"] as? [[String: Any]])
        XCTAssertEqual(limits.map { $0["kind"] as? String }, ["weekly_scoped"])
        let spend = try XCTUnwrap(utilization["spend"] as? [String: Any])
        XCTAssertEqual(spend["amount"] as? Double, 12.5)
        XCTAssertNil(utilization["extra_usage"])
        XCTAssertNil(utilization["other"])
    }

    /// The fingerprint gate: an unchanged state file is not parsed again — the
    /// sidecar's stored payload is what lands in the next session file. Proved
    /// by planting a sentinel in the sidecar and watching it come back out.
    func testUnchangedStateFileIsServedFromTheFingerprintSidecar() throws {
        try skipUnlessJqOnPath()
        try writeStateFile()
        try run(payload(session: "aaaa-1111"))

        var sidecar = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: utilizationSidecarURL)) as? [String: Any])
        XCTAssertNotNil(sidecar["source_fingerprint"])
        sidecar["utilization"] = ["limits": [], "spend": ["amount": 99]]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: utilizationSidecarURL)

        try run(payload(session: "bbbb-2222"))

        let utilization = try XCTUnwrap(try json(of: "bbbb-2222.json")["utilization"] as? [String: Any])
        let spend = try XCTUnwrap(utilization["spend"] as? [String: Any])
        XCTAssertEqual(spend["amount"] as? Double, 99)
    }

    /// Without `jq` the script can't read the id out of the payload, so every
    /// session on that machine shares one file — the raw payload, verbatim,
    /// which the reader dates from the file's mtime.
    func testWithoutJqTheRawPayloadGoesToTheSharedFile() throws {
        try run(payload(session: "aaaa-1111"), path: try pathWithoutJq())

        XCTAssertEqual(try sessionFiles(), ["unknown-session.json"])
        let root = try json(of: "unknown-session.json")
        XCTAssertNil(root["captured_at"])
        XCTAssertEqual(root["session_id"] as? String, "aaaa-1111")
    }

    /// Case B in the script's header: an existing status line passed as
    /// arguments still runs, on the same stdin, with its output passed through.
    func testWrappedCommandStillReceivesThePayloadAndItsOutputIsPassedThrough() throws {
        try skipUnlessJqOnPath()
        let printed = try run(payload(session: "aaaa-1111"), arguments: ["/bin/cat"])

        XCTAssertEqual(printed, payload(session: "aaaa-1111"))
        XCTAssertEqual(try sessionFiles(), ["aaaa-1111.json"])
    }
}
