# Code review hints — claude-stats

## Verify current file state before flagging untested aliases

Before flagging a missing test for a specific key alias (e.g. `account_uuid`, `email_address`) in `QuotaAccount.init?(json:)`, re-read the current version of `Sources/ClaudeStatsCore/Models/QuotaAccount.swift` on the branch under review rather than relying on a cached or earlier view of the file. This codebase has had alias lists actively trimmed as part of the same change, so a finding about an untested alias can go stale mid-review if that alias was removed. Confirm the exact string literal still appears in the `Self.string(json, [...])` call before writing up a coverage gap.
_Source: per-account-quota, finding [23:973c4a48], 2026-09-13_
