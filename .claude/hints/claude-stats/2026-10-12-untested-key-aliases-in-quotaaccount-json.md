# Untested key aliases in QuotaAccount json

- **Pattern:** Flagging a missing test for a specific key alias in `QuotaAccount.init?(json:)` based on an earlier view of the file.
- **Why that was wrong:** The alias lists in this initializer have been trimmed, so a named alias may no longer exist. A coverage finding for a removed alias is a false positive.
- **Before raising this again, verify:** I read `Sources/ClaudeStatsCore/Models/QuotaAccount.swift` lines 101-108. The `Self.string(json, [...])` calls list only `uuid`/`accountUuid`, `email`/`emailAddress`, `organization_name`/`organizationName` and `organization_uuid`/`organizationUuid`. The entry's examples `account_uuid` and `email_address` are gone.

**The legacy entry said, verbatim:**

> Before flagging a missing test for a specific key alias (e.g. `account_uuid`, `email_address`) in `QuotaAccount.init?(json:)`, re-read the current version of `Sources/ClaudeStatsCore/Models/QuotaAccount.swift` on the branch under review rather than relying on a cached or earlier view of the file. This codebase has had alias lists actively trimmed as part of the same change, so a finding about an untested alias can go stale mid-review if that alias was removed. Confirm the exact string literal still appears in the `Self.string(json, [...])` call before writing up a coverage gap.
> _Source: per-account-quota, finding [23:973c4a48], 2026-09-13_

_migrated from legacy hints file 2026-10-12; original finding not retained_
