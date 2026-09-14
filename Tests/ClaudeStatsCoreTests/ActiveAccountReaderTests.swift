import XCTest
@testable import ClaudeStatsCore

/// Every test here writes its fixture into a per-test temp directory and injects
/// that path — the real `~/.claude.json` is never touched, read or written.
final class ActiveAccountReaderTests: XCTestCase {
    private var directory: URL!
    private var stateFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActiveAccountReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateFileURL = directory.appendingPathComponent(".claude.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private let uuid = "0f9c1d3e-8a4b-4c2d-9e1f-6b7a8c9d0e1f"
    /// `2026-08-28T23:00:00.401826+00:00`, the `seven_day` reset in the fixture.
    private let sevenDayResetEpoch: TimeInterval = 1_787_958_000.401826

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: stateFileURL)
    }

    private func makeReader() -> ActiveAccountReader {
        ActiveAccountReader(candidateURLs: [stateFileURL])
    }

    /// The shape on a real machine, trimmed to the two keys this reads.
    private func stateFile(
        oauthAccount: String? = nil,
        cachedAccountUuid: String? = nil,
        sevenDay: String? = #""seven_day": { "utilization": 56, "resets_at": "2026-08-28T23:00:00.401826+00:00" }"#
    ) -> String {
        let oauth = oauthAccount.map { "\"oauthAccount\": \($0)," } ?? ""
        let cachedUuid = cachedAccountUuid.map { "\"accountUuid\": \"\($0)\"," } ?? ""
        return """
        {
          "numStartups": 412,
          \(oauth)
          "cachedUsageUtilization": {
            "fetchedAtMs": 1787935500000,
            \(cachedUuid)
            "utilization": { \(sevenDay ?? "\"member_dashboard_available\": false") }
          }
        }
        """
    }

    private func oauthAccount(uuid: String, organization: String = "Other Org") -> String {
        """
        { "accountUuid": "\(uuid)", "emailAddress": "me@example.com",
          "organizationName": "\(organization)", "organizationUuid": "a1b2c3d4" }
        """
    }

    // MARK: - The logged-in account

    func testReadsTheLoggedInAccountFromOAuthAccount() throws {
        try write(stateFile(oauthAccount: oauthAccount(uuid: uuid)))

        let reading = makeReader().readActiveAccount()

        XCTAssertEqual(reading.account?.uuid, uuid)
        XCTAssertEqual(reading.account?.organizationName, "Other Org")
        XCTAssertEqual(reading.account?.email, "me@example.com")
    }

    /// A state file that names no account is "we don't know" — the pre-account
    /// behaviour — and never an error. Same for one that isn't there at all.
    func testMissingOAuthAccountIsUnknownNotAFailure() throws {
        try write(stateFile())

        XCTAssertEqual(makeReader().readActiveAccount(), .unknown)
    }

    func testAbsentStateFileIsUnknown() {
        XCTAssertEqual(makeReader().readActiveAccount(), .unknown)
    }

    func testMalformedStateFileIsUnknown() throws {
        try write("{ this is not json")

        XCTAssertEqual(makeReader().readActiveAccount(), .unknown)
    }

    /// Both candidate paths are probed, first that opens wins — the same rule
    /// the other state-file readers follow.
    func testFirstCandidateThatOpensWins() throws {
        let override = directory.appendingPathComponent("override.json")
        try Data(stateFile(oauthAccount: oauthAccount(uuid: "override-uuid")).utf8).write(to: override)
        try write(stateFile(oauthAccount: oauthAccount(uuid: uuid)))

        let reader = ActiveAccountReader(candidateURLs: [override, stateFileURL])

        XCTAssertEqual(reader.readActiveAccount().account?.uuid, "override-uuid")
    }

    // MARK: - The mislabel guard's reference

    /// The reference is the *cached reading's* account and its 7-day reset —
    /// the pair a statusline reading has to agree with.
    func testReferenceUsesTheCachedReadingsOwnAccountUuid() throws {
        try write(stateFile(
            oauthAccount: oauthAccount(uuid: uuid),
            cachedAccountUuid: "cached-account"
        ))

        let reference = try XCTUnwrap(makeReader().readActiveAccount().reference)

        XCTAssertEqual(reference.accountUuid, "cached-account")
        XCTAssertEqual(reference.sevenDayResetsAt.timeIntervalSince1970,
                       sevenDayResetEpoch, accuracy: 0.001)
    }

    /// An older payload with no `accountUuid` inside `cachedUsageUtilization`:
    /// the logged-in account is the best stand-in there is.
    func testReferenceFallsBackToTheLoggedInAccountUuid() throws {
        try write(stateFile(oauthAccount: oauthAccount(uuid: uuid)))

        XCTAssertEqual(makeReader().readActiveAccount().reference?.accountUuid, uuid)
    }

    /// No cached 7-day reading means no reference, which disables the guard —
    /// accepting everything, rather than dropping readings against nothing.
    func testNoCachedSevenDayWindowYieldsNoReference() throws {
        try write(stateFile(oauthAccount: oauthAccount(uuid: uuid), sevenDay: nil))

        let reading = makeReader().readActiveAccount()

        XCTAssertEqual(reading.account?.uuid, uuid)
        XCTAssertNil(reading.reference)
    }

    /// A `seven_day` with no `resets_at` is nothing to compare against either.
    func testCachedSevenDayWithoutResetYieldsNoReference() throws {
        try write(stateFile(
            oauthAccount: oauthAccount(uuid: uuid),
            sevenDay: #""seven_day": { "utilization": 56 }"#
        ))

        XCTAssertNil(makeReader().readActiveAccount().reference)
    }

    func testNoCachedUtilizationAtAllYieldsNoReference() throws {
        try write("""
        { "oauthAccount": \(oauthAccount(uuid: uuid)) }
        """)

        let reading = makeReader().readActiveAccount()

        XCTAssertEqual(reading.account?.uuid, uuid)
        XCTAssertNil(reading.reference)
    }

    // MARK: - The fingerprint gate

    /// An unchanged file is not parsed again — the previous answer is served
    /// from memory. Proved by making the *contents* lie while leaving the
    /// fingerprint (mtime, size, inode) untouched: a re-parse would see the new
    /// uuid, the gate does not.
    func testUnchangedFileIsServedWithoutReparsing() throws {
        // A whole-second stamp, so restoring it below reproduces the same
        // nanosecond mtime the fingerprint actually compares.
        let pinned = Date(timeIntervalSince1970: 1_800_000_000)
        try write(stateFile(oauthAccount: oauthAccount(uuid: uuid)))
        try setModificationDate(pinned)
        let reader = makeReader()
        XCTAssertEqual(reader.readActiveAccount().account?.uuid, uuid)

        // Same length, so the size half of the fingerprint doesn't move either,
        // and an in-place rewrite keeps the inode.
        try write(stateFile(oauthAccount: oauthAccount(uuid: String(uuid.reversed()))))
        try setModificationDate(pinned)

        XCTAssertEqual(reader.readActiveAccount().account?.uuid, uuid)
    }

    private func setModificationDate(_ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: stateFileURL.path)
    }

    /// A changed file is re-read: switching the login is exactly the event this
    /// whole path exists for, and it rewrites the file.
    func testChangedFileIsReparsed() throws {
        try write(stateFile(oauthAccount: oauthAccount(uuid: uuid)))
        let reader = makeReader()
        XCTAssertEqual(reader.readActiveAccount().account?.uuid, uuid)

        try write(stateFile(oauthAccount: oauthAccount(uuid: "second-account", organization: "Example Org")))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: stateFileURL.path)

        let reading = reader.readActiveAccount()
        XCTAssertEqual(reading.account?.uuid, "second-account")
        XCTAssertEqual(reading.account?.organizationName, "Example Org")
    }

    /// The file disappearing drops the remembered fingerprint too, so the next
    /// call looks again rather than latching onto a state that no longer exists.
    func testDeletedFileForgetsThePreviousReading() throws {
        try write(stateFile(oauthAccount: oauthAccount(uuid: uuid)))
        let reader = makeReader()
        XCTAssertEqual(reader.readActiveAccount().account?.uuid, uuid)

        try FileManager.default.removeItem(at: stateFileURL)
        XCTAssertEqual(reader.readActiveAccount(), .unknown)

        try write(stateFile(oauthAccount: oauthAccount(uuid: uuid)))
        XCTAssertEqual(reader.readActiveAccount().account?.uuid, uuid)
    }

    // MARK: - The no-op reader

    /// `UnknownAccountReader` is what every construction that doesn't wire the
    /// real reader gets — it must touch nothing and answer "unknown".
    func testUnknownAccountReaderReadsNothing() {
        XCTAssertEqual(UnknownAccountReader().readActiveAccount(), .unknown)
    }
}
