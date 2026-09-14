import XCTest
@testable import ClaudeStatsCore

final class QuotaAccountTests: XCTestCase {
    private let uuid = "0f9c1d3e-8a4b-4c2d-9e1f-6b7a8c9d0e1f"

    // MARK: - Display name

    /// The login email leads: for a personal account the organisation is
    /// auto-named "<email>'s Organization", so the org name is the email plus
    /// noise, and the email is what the user recognises. Nothing inspects the
    /// org string's shape — an email present wins whatever it says — so one
    /// case covers both.
    func testDisplayNamePrefersTheEmail() {
        let account = QuotaAccount(
            uuid: uuid, email: "me@example.com", organizationName: "Other Org")
        XCTAssertEqual(account.displayName, "me@example.com")
    }

    /// A real, chosen organisation name still shows when there is no email to
    /// prefer over it.
    func testDisplayNameFallsBackToTheOrganisationName() {
        let account = QuotaAccount(uuid: uuid, organizationName: "Other Org")
        XCTAssertEqual(account.displayName, "Other Org")
    }

    /// Last resort: a short prefix, never the full 36-character uuid — that is
    /// noise in a 312 pt popover — and never an empty label.
    func testDisplayNameFallsBackToAShortUUID() {
        XCTAssertEqual(QuotaAccount(uuid: uuid).displayName, "0f9c1d3e")
    }

    func testDisplayNameOfAShortUUIDIsTheWholeThing() {
        XCTAssertEqual(QuotaAccount(uuid: "abc").displayName, "abc")
    }

    // MARK: - Parsing

    /// The `oauthAccount` object as `~/.claude.json` spells it.
    func testParsesTheStateFileSpelling() throws {
        let account = try XCTUnwrap(QuotaAccount(json: [
            "accountUuid": uuid,
            "emailAddress": "me@example.com",
            "organizationName": "Other Org",
            "organizationUuid": "a1b2c3d4",
        ]))

        XCTAssertEqual(account.uuid, uuid)
        XCTAssertEqual(account.email, "me@example.com")
        XCTAssertEqual(account.organizationName, "Other Org")
        XCTAssertEqual(account.organizationUuid, "a1b2c3d4")
        XCTAssertEqual(account.id, uuid)
    }

    /// The `account` stamp as the helper script writes it into a cache file —
    /// the same four fields, snake_cased, read by the same initialiser so the
    /// two spellings can't drift.
    func testParsesTheCacheStampSpelling() throws {
        let account = try XCTUnwrap(QuotaAccount(json: [
            "uuid": uuid,
            "email": "me@example.com",
            "organization_name": "Other Org",
            "organization_uuid": "a1b2c3d4",
        ]))

        XCTAssertEqual(account, QuotaAccount(
            uuid: uuid,
            email: "me@example.com",
            organizationName: "Other Org",
            organizationUuid: "a1b2c3d4"
        ))
    }

    /// A partial stamp is normal — the script omits keys the state file didn't
    /// have — and is still a usable identity.
    func testParsesAStampWithOnlyAUUID() throws {
        let account = try XCTUnwrap(QuotaAccount(json: ["uuid": uuid]))

        XCTAssertEqual(account.uuid, uuid)
        XCTAssertNil(account.email)
        XCTAssertNil(account.organizationName)
        XCTAssertNil(account.organizationUuid)
    }

    /// Without a uuid there is nothing to group by, so this is not an account —
    /// it must not form a group of its own beside the same account's readings.
    func testRejectsAnObjectWithNoUUID() {
        XCTAssertNil(QuotaAccount(json: ["email": "me@example.com"]))
        XCTAssertNil(QuotaAccount(json: [:]))
    }

    func testRejectsABlankOrNonStringUUID() {
        XCTAssertNil(QuotaAccount(json: ["uuid": "   "]))
        XCTAssertNil(QuotaAccount(json: ["uuid": 42]))
    }

    /// A blank email — or a blank organisation name — would otherwise win
    /// `displayName` and render a nameless row. Both fields, so a regression
    /// that blanked only one of them can't hide behind the other.
    func testBlankFieldsAreTreatedAsAbsent() throws {
        let account = try XCTUnwrap(QuotaAccount(json: [
            "uuid": uuid, "organization_name": "  ", "email": "  ",
        ]))

        XCTAssertNil(account.organizationName)
        XCTAssertNil(account.email)
        XCTAssertEqual(account.displayName, "0f9c1d3e")
    }

    func testFieldsAreTrimmed() throws {
        let account = try XCTUnwrap(QuotaAccount(json: [
            "uuid": " \(uuid) ", "organization_name": " Other Org\n",
        ]))

        XCTAssertEqual(account.uuid, uuid)
        XCTAssertEqual(account.organizationName, "Other Org")
    }

    // MARK: - Coding

    /// ``QuotaSnapshot`` is `Codable` and its account rides along; a snapshot
    /// encoded before the field existed still decodes, with no account.
    func testSnapshotWithoutAnAccountKeyStillDecodes() throws {
        let json = """
        { "confidence": "official", "capturedAt": 0 }
        """
        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(json.utf8))

        XCTAssertNil(snapshot.account)
    }

    func testSnapshotAccountSurvivesARoundTrip() throws {
        var snapshot = MockQuotaProvider.sampleSnapshot()
        snapshot.account = QuotaAccount(uuid: uuid, organizationName: "Other Org")

        let decoded = try JSONDecoder().decode(
            QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))

        XCTAssertEqual(decoded.account, snapshot.account)
    }
}
