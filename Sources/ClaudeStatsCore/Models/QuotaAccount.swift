import Foundation

/// Which Anthropic account a quota reading belongs to.
///
/// ## Why a reading needs an identity at all
///
/// The rate-limit windows this app draws are **account-wide**, and the user can
/// swap the account Claude Code is logged in as — `~/.claude.json` plus the
/// keychain entry — at any time. Nothing in either quota payload says which
/// account it describes: the statusline hook's stdin carries `session_id`,
/// `model`, `workspace`, `cost`, `context_window` and `rate_limits`, and not one
/// field naming a user, an account or an organisation. So a reading captured
/// before a switch is indistinguishable from one captured after it, and the
/// per-window merge in ``StatuslineCacheReader`` cheerfully picked the *other*
/// account's 7-day window because its reset happened to be later.
///
/// The identity therefore comes from the only local file that has one: the
/// `oauthAccount` object in Claude Code's own state file, copied into each
/// statusline cache file by the helper script as it writes it (see
/// ``StatuslineCacheReader`` and `claude-stats-statusline-cache.sh`).
///
/// Deliberately **not** taken from any third-party account switcher. The
/// readings have to come from Claude Code's own files, or the app would be
/// correct only on machines running whatever tool we picked.
///
/// Every field but ``uuid`` is optional: this is another program's private
/// state, and a reading whose account is only half-described is still a reading
/// that must not be merged with a different account's.
public struct QuotaAccount: Sendable, Hashable, Codable, Identifiable {
    /// `oauthAccount.accountUuid` — the grouping key, and the only required
    /// field. Two readings belong together exactly when these match.
    public let uuid: String
    /// `oauthAccount.emailAddress`, when the state file carries one.
    public let email: String?
    /// `oauthAccount.organizationName`. Carried for fidelity and used as
    /// ``displayName``'s fallback, not as its first choice — see there.
    public let organizationName: String?
    /// `oauthAccount.organizationUuid`; carried for fidelity, not displayed.
    public let organizationUuid: String?

    /// Stores the four fields as given — no trimming, no blank check.
    ///
    /// The non-blank guarantee ``displayName`` relies on belongs to
    /// ``init(json:)``, which is how every reading off disk is built; this
    /// initialiser is for callers that already hold known-good values (fixtures,
    /// and readings being re-wrapped). A blank `uuid` passed here produces a
    /// blank ``displayName``.
    public init(
        uuid: String,
        email: String? = nil,
        organizationName: String? = nil,
        organizationUuid: String? = nil
    ) {
        self.uuid = uuid
        self.email = email
        self.organizationName = organizationName
        self.organizationUuid = organizationUuid
    }

    /// The uuid is the identity — see ``uuid``.
    public var id: String { uuid }

    /// How many leading characters of the uuid stand in for a name.
    static let shortUUIDLength = 8

    /// What the popover calls this account.
    ///
    /// The **login email first**, then the organisation name, then a short
    /// prefix of the uuid.
    ///
    /// Email leads because for a personal account Anthropic auto-names the
    /// organisation `"<email>'s Organization"` — the same string the user
    /// already knows, with noise appended — while the email is exactly what
    /// they typed to log in and what tells two accounts apart at a glance. An
    /// account with a real, chosen organisation name but no email still shows
    /// that name.
    ///
    /// Never the full uuid, which is 36 characters of noise in a 312 pt
    /// popover, and never an empty label for an account parsed by
    /// ``init(json:)``, which drops blank fields and rejects a blank uuid
    /// outright.
    public var displayName: String {
        email ?? organizationName ?? String(uuid.prefix(Self.shortUUIDLength))
    }

    /// Parses either spelling of the account object.
    ///
    /// Two shapes reach this, and they are the same four fields under different
    /// names, so one lenient initialiser reads both rather than two that can
    /// drift:
    ///
    /// - `oauthAccount` in `~/.claude.json` —
    ///   `{ accountUuid, emailAddress, organizationName, organizationUuid }`;
    /// - the `account` stamp the helper script copies into each statusline
    ///   cache file — `{ uuid, email, organization_name, organization_uuid }`.
    ///
    /// `nil` when no non-blank uuid is present: without one there is nothing to
    /// group by, and an account known only by its email would silently form a
    /// group of its own next to the same account's uuid-keyed readings.
    public init?(json: [String: Any]) {
        guard let uuid = Self.string(json, ["uuid", "accountUuid"]) else {
            return nil
        }
        self.init(
            uuid: uuid,
            email: Self.string(json, ["email", "emailAddress"]),
            organizationName: Self.string(json, ["organization_name", "organizationName"]),
            organizationUuid: Self.string(json, ["organization_uuid", "organizationUuid"])
        )
    }

    /// First non-blank string among `keys`. Blank is treated as absent: an
    /// empty `emailAddress` would otherwise win ``displayName`` and render a
    /// nameless row.
    private static func string(_ json: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            guard let value = json[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
