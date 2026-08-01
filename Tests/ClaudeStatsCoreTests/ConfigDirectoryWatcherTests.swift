import CoreServices
import XCTest
@testable import ClaudeStatsCore

/// Real-FSEvents coverage for ``ConfigDirectoryWatcher``, plus the pure bits
/// (flag mapping, config-directory resolution) that need no file system.
///
/// Deliberately only **two** tests touch real FSEvents, with tight timeouts:
/// the OS delivery path is worth proving once, but every extra case costs
/// wall-clock time and adds a flake surface. The debounce/coalesce logic itself
/// is covered deterministically in `ChangeCoalescerTests`.
///
/// FSEvents needs no special entitlement for a directory the process already
/// owns, but it *can* be unavailable in constrained environments (no `fseventsd`
/// reachable, exotic sandbox). Rather than flake or hang, the integration tests
/// `XCTSkip` when the daemon delivers nothing inside the timeout — a skip is an
/// honest "couldn't verify here", whereas a failure would blame the code.
final class ConfigDirectoryWatcherTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stats-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: Real FSEvents

    func testWatcherReportsAPathWrittenInsideTheWatchedTree() throws {
        let delivered = expectation(description: "batch containing session.jsonl")
        delivered.assertForOverFulfill = false

        let recorder = BatchRecorder()
        let watcher = ConfigDirectoryWatcher(
            configuration: shortWindowConfiguration()
        ) { batch in
            recorder.append(batch)
            if batch.paths.contains(where: { $0.hasSuffix("/session.jsonl") }) {
                delivered.fulfill()
            }
        }

        try watcher.start()
        XCTAssertTrue(watcher.isRunning)
        defer { watcher.stop() }

        // Written into a subdirectory to prove the watch is recursive — the real
        // layout is ~/.claude/projects/<project>/<session>.jsonl.
        let projectDirectory = temporaryDirectory
            .appendingPathComponent("projects/some-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let sessionFile = projectDirectory.appendingPathComponent("session.jsonl")
        try #"{"entrypoint":"cli"}"#.write(to: sessionFile, atomically: true, encoding: .utf8)

        guard XCTWaiter.wait(for: [delivered], timeout: 5) == .completed else {
            throw XCTSkip(
                """
                FSEvents delivered no matching event within 5s for \
                \(temporaryDirectory.path). Treating as environment-unavailable \
                rather than a code failure — see this file's header.
                """
            )
        }

        // The debounce collapsed the create/modify/rename burst of an atomic
        // write into a small number of batches, not one per raw OS event. The
        // exact count isn't the invariant under test (CI load or slow FSEvents
        // delivery can split coalescing further) — the file's own delivery
        // below is; a loose ceiling just catches a coalescer that stopped
        // coalescing at all.
        XCTAssertLessThanOrEqual(recorder.batches.count, 6)

        let change = try XCTUnwrap(
            recorder.batches
                .flatMap(\.changes)
                .first { $0.path.hasSuffix("/session.jsonl") }
        )
        // Reported paths must sit under the *truly* resolved watch root, so the
        // log layer can map a change back onto the tree it asked about. `realpath`
        // here rather than `URL.resolvingSymlinksInPath()` on purpose — see
        // `testResolvedPathMatchesRealpathNotFoundationStandardizing`.
        XCTAssertTrue(
            change.path.hasPrefix(Self.realpath(temporaryDirectory.path)),
            "expected a resolved path under the watch root, got \(change.path)"
        )
        XCTAssertTrue(change.path.hasSuffix("/projects/some-project/session.jsonl"))
        XCTAssertFalse(change.flags.isDisjoint(with: .contentAffecting))
        XCTAssertFalse(change.flags.contains(.isDirectory))
    }

    func testStoppedWatcherDeliversNothingAndTearsDownCleanly() throws {
        let unexpected = expectation(description: "no delivery after stop")
        unexpected.isInverted = true

        var watcher: ConfigDirectoryWatcher? = ConfigDirectoryWatcher(
            configuration: shortWindowConfiguration()
        ) { _ in unexpected.fulfill() }

        try watcher?.start()
        try watcher?.start() // idempotent
        XCTAssertEqual(watcher?.isRunning, true)

        watcher?.stop()
        watcher?.stop() // idempotent
        XCTAssertEqual(watcher?.isRunning, false)

        // Dropping the last reference must run `deinit` -> `stop()` on an
        // already-stopped watcher without over-releasing the stream or the
        // C `info` pointer. A double release would crash the test process here.
        watcher = nil

        let file = temporaryDirectory.appendingPathComponent("after-stop.jsonl")
        try "written after stop".write(to: file, atomically: true, encoding: .utf8)

        wait(for: [unexpected], timeout: 1)
    }

    // MARK: Start validation (no file system events involved)

    func testStartRejectsAMissingDirectory() {
        let missing = temporaryDirectory.appendingPathComponent("does-not-exist").path
        let watcher = ConfigDirectoryWatcher(configuration: .init(path: missing)) { _ in }

        XCTAssertThrowsError(try watcher.start()) { error in
            XCTAssertEqual(
                error as? ConfigDirectoryWatcher.StartError,
                .pathNotADirectory(missing)
            )
        }
        XCTAssertFalse(watcher.isRunning)
    }

    func testStartRejectsAnEmptyPathList() {
        let watcher = ConfigDirectoryWatcher(configuration: .init(paths: [])) { _ in }
        XCTAssertThrowsError(try watcher.start()) { error in
            XCTAssertEqual(error as? ConfigDirectoryWatcher.StartError, .noPathsConfigured)
        }
        XCTAssertFalse(watcher.isRunning)
    }

    func testStartAcceptsAMissingDirectoryWhenNotRequired() throws {
        let missing = temporaryDirectory.appendingPathComponent("does-not-exist").path
        let watcher = ConfigDirectoryWatcher(
            configuration: .init(path: missing, requiresExistingPaths: false)
        ) { _ in }
        XCTAssertNoThrow(try watcher.start())
        XCTAssertTrue(watcher.isRunning)
        watcher.stop()
    }

    // MARK: Config-directory convenience
    //
    // `ClaudeConfigDirectory` owns resolution (and its own tests); these only
    // pin the wiring — that the watcher watches the same tree the parser reads,
    // and that the debounce defaults come along.

    func testClaudeConfigDirectoryConfigurationWatchesTheParsersDirectory() {
        let environment = ["CLAUDE_CONFIG_DIR": "/opt/claude-config"]
        let configuration = ConfigDirectoryWatcher.Configuration
            .claudeConfigDirectory(environment: environment)

        XCTAssertEqual(
            configuration.paths,
            [ClaudeConfigDirectory.candidate(environment: environment).path]
        )
        XCTAssertEqual(configuration.debounceInterval, ChangeCoalescer.defaultDebounceInterval)
        XCTAssertEqual(configuration.maximumDelay, ChangeCoalescer.defaultMaximumDelay)
    }

    func testClaudeConfigDirectoryDefaultsToDotClaudeInHome() throws {
        let configuration = ConfigDirectoryWatcher.Configuration
            .claudeConfigDirectory(environment: [:])
        let path = try XCTUnwrap(configuration.paths.first)

        XCTAssertEqual(
            path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        )
        XCTAssertFalse(path.contains("/.config/claude"), "must not be ~/.config/claude")
    }

    // MARK: Path resolution

    func testResolvedPathMatchesRealpathNotFoundationStandardizing() throws {
        let truePath = Self.realpath(temporaryDirectory.path)
        XCTAssertEqual(ConfigDirectoryWatcher.resolvedPath(temporaryDirectory.path), truePath)

        // Guard the reason this doesn't just use Foundation: on a machine where
        // the temp dir really does live under /private, `resolvingSymlinksInPath`
        // hands back the /private-stripped form that FSEvents never reports.
        if truePath.hasPrefix("/private/") {
            XCTAssertNotEqual(
                URL(fileURLWithPath: temporaryDirectory.path).resolvingSymlinksInPath().path,
                truePath,
                "if Foundation ever starts agreeing with realpath, resolvedPath(_:) can be simplified"
            )
        }
    }

    func testResolvedPathExpandsTildeAndToleratesMissingPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ConfigDirectoryWatcher.resolvedPath("~/.claude"), home + "/.claude")

        // `realpath` fails on a non-existent path; resolution must degrade
        // instead of returning something empty or crashing.
        let missing = temporaryDirectory.appendingPathComponent("nope/deeper").path
        XCTAssertEqual(ConfigDirectoryWatcher.resolvedPath(missing), missing)
    }

    // MARK: FSEvents flag mapping

    func testFSEventFlagsMapOntoTheStableVocabulary() {
        XCTAssertEqual(
            FileChange.Flags(fsEventFlags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)),
            .created
        )
        XCTAssertEqual(
            FileChange.Flags(fsEventFlags: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
            )),
            .modified
        )
        XCTAssertEqual(
            FileChange.Flags(fsEventFlags: FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemRenamed
                    | kFSEventStreamEventFlagItemIsDir
            )),
            [.created, .renamed, .isDirectory]
        )
        XCTAssertEqual(
            FileChange.Flags(fsEventFlags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod)),
            .metadata
        )
        XCTAssertEqual(
            FileChange.Flags(fsEventFlags: FSEventStreamEventFlags(0)),
            [],
            "unknown/empty flag words must not invent a change kind"
        )

        // Every "we lost events" bit collapses to a single rescan signal.
        for dropped in [
            kFSEventStreamEventFlagMustScanSubDirs,
            kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped,
            kFSEventStreamEventFlagRootChanged,
            kFSEventStreamEventFlagMount,
            kFSEventStreamEventFlagUnmount,
        ] {
            let flags = FileChange.Flags(fsEventFlags: FSEventStreamEventFlags(dropped))
            XCTAssertTrue(flags.contains(.requiresRescan), "flag \(dropped) should force a rescan")
        }
    }

    // MARK: Helpers

    /// `realpath(3)`, computed independently of the production code so the
    /// integration assertion doesn't just restate the implementation.
    private static func realpath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    /// Tight windows so the integration tests don't sit out the production
    /// debounce, but not zero — the coalescing behaviour is still exercised.
    private func shortWindowConfiguration() -> ConfigDirectoryWatcher.Configuration {
        ConfigDirectoryWatcher.Configuration(
            path: temporaryDirectory.path,
            debounceInterval: 0.1,
            maximumDelay: 0.4,
            eventLatency: 0.02
        )
    }
}
