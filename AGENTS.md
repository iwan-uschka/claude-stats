# claude-stats — agent context

Menu bar app for macOS showing live Claude token usage. Sibling to
[exelban/stats](https://github.com/exelban/stats) — same "thin bars in the
menu bar, popover on click" shape, but for Claude quota instead of
CPU/GPU/RAM.

Core scaffold (data layer, parsing, quota providers, UI) already implemented —
see `Sources/`. Treat the plan below as the design baseline; verify against
the code before assuming a feature is missing. Every decision below is
settled unless the user reopens it; don't re-derive or re-litigate.

## Layout

- `ClaudeStatsCore` — models, parsing, watching, quota (unit-tested)
- `ClaudeStats` — AppKit/SwiftUI menu bar app (executable; unit-tested via `Tests/ClaudeStatsTests`)

## Commands

- `swift build` / `swift test`
- `xcrun xctrace record --template 'os_signpost' --launch ClaudeStats.app` —
  rebuild perf triage; `SessionCorpusIndex` emits `StatPass`, `Reparse`,
  `Fold` and `SnapshotAssembly` intervals under subsystem
  `de.bitgrip.claude-stats`, category `RebuildPerf`.

## Data layer

Two independent tiers, deliberately decoupled:

1. **Local log parsing (primary, always-on, zero auth).** Parse Claude Code's
   session JSONL under `~/.claude` (or `$CLAUDE_CONFIG_DIR`) —
   `~/.claude/projects/*/*.jsonl`. `~/.config/claude` is NOT consulted. Gives: token counts, cost math (per-model
   pricing), and a source breakdown via the `entrypoint` field
   already present on each line — confirmed values on this machine: `cli`,
   `claude-vscode`, `sdk-cli` (Agent SDK / subagents / workflows / headless
   `-p` runs). Only sees sessions whose JSONL lives on this Mac's disk.
2. **Live account-wide quota % (secondary, no estimate fallback).** Two
   sources, both carrying Anthropic's own numbers, composed by
   `Sources/ClaudeStatsCore/Quota/FreshestQuotaProvider.swift`: the statusline
   hook is the **primary** and wins outright when it succeeds; the
   `cachedUsageUtilization` reader is the **backup**, consulted only when the
   hook has failed, is missing, or has gone stale. (It used to be a freshness
   compare — newer `capturedAt` wins — which was right while the hook could
   only report two of the four bars; it now reports all four.) One source being
   down is invisible; an error only surfaces when **both** fail.
   **This tier is account-wide, not machine-wide** — it already reflects AFK
   docker-loop usage automatically, *because* those containers reauthenticate
   as the same Anthropic account (confirmed: no separate API keys). No extra
   plumbing needed for that case.
   - **Which account, though — the readings are grouped by one.** The user
     swaps the global login (`~/.claude.json` + keychain) between two Anthropic
     accounts, and *neither* quota payload names an account: the statusline
     stdin carries `session_id`, `transcript_path`, `cwd`, `model`,
     `workspace`, `cost`, `context_window`, `rate_limits`, `version` — nothing
     about a user, account or org (checked against the statusline docs). So a
     cache file left behind by the previous login is indistinguishable from a
     current one, and "latest `resets_at` wins" happily picked the other
     account's 7-day window. Observed on this machine: after switching from
     account A (7-day resetting 23:00Z, 56% used) to account B (03:00Z, 0%),
     one idle session kept re-rendering A's payload and the 7-day bar showed
     A's 56% as this machine's usage.
     - **Identity comes from `~/.claude.json`'s `oauthAccount`**
       (`accountUuid`, `emailAddress`, `organizationName`, `organizationUuid`)
       — modelled as `Models/QuotaAccount.swift`, display name
       `email ?? organizationName ?? short uuid`. **Email leads**: for a
       personal account Anthropic auto-names the organisation
       `"<email>'s Organization"`, so the org name is the email with noise
       appended, and the email is what the user recognises and logged in with.
       A real, chosen organisation name still shows when there is no email. The helper script copies it
       into every cache file it writes as a top-level `account` object;
       `ActiveAccountReader` reads the same key for "who is logged in **now**",
       behind the same fingerprint gate as the promo reader (no FSEvents on
       `$HOME`). `CachedUtilizationReader` takes the account from its own
       payload's `accountUuid`, filled out from `oauthAccount` when the uuids
       agree.
     - **No third-party switcher is consulted — deliberately.** Not `cswap` /
       claude-swap, not `~/.claude-swap-backup`, not anything else: the
       readings have to come from Claude Code's own files, or the app would be
       correct only on machines running whichever tool we bet on. The state
       file is right on every machine, switcher or not.
     - **Merging is per account group, never across them.** Files stamped with
       the same uuid form a group; unstamped files (a script copy from before
       the stamp, a machine without `jq`, the legacy single file) form one
       "unknown" group. `currentSnapshot()` serves the group matching
       `oauthAccount`; with no group for that account it reports
       `noQuotaSourceAvailable` so the backup — which reads that same login's
       blob — takes over, rather than substituting another account's numbers or
       claiming the unstamped group is this account's. With no `oauthAccount`
       at all (state file absent, unreadable, or simply carrying no such key)
       the most recently captured group serves, which is the pre-account
       behaviour on a one-account machine. The `utilization`
       copy is scoped the same way: it is lifted out of a per-login file.
     - **One heuristic, the mislabel guard.** An idle session re-renders its
       status line from its *last* API payload, so right after a switch a hook
       run can pipe the old account's rate limits while `~/.claude.json`
       already names the new one — the file is then stamped with the new
       account and carries the old one's numbers, which grouping alone cannot
       catch. So when the active account's `cachedUsageUtilization` reports a
       `seven_day.resets_at`, a stamped reading for that same account whose
       `seven_day.resets_at` differs by more than **60 seconds** is dropped
       from the merge as foreign. The tolerance exists because the two sources
       spell the same instant differently (epoch seconds vs ISO-8601 with
       fractional seconds) and is far below the gap between two real 7-day
       windows. Readings with no `seven_day` are never dropped (nothing to
       compare), and with no cached reference everything is accepted.
     - **Every other account's readings are still carried**, through
       `QuotaProviding.otherAccountSnapshots()` — listed below the active
       account's rows, never gated on staleness, never an error, and left out
       entirely for a group whose windows have all rolled over. Each group
       **starts collapsed**: the closed row is a cross icon
       (`xmark.circle.fill`, uncoloured), the account name, and a trailing
       caret, with no summary number (a percentage there would be about an
       account the glyph and the bars above aren't describing). The whole row
       is a single plain `Button`, not a `DisclosureGroup` — clicking anywhere
       on it reveals exactly the rows below. The caret shows the **action, not
       the state**: `chevron.down` while closed (click to reveal), `chevron.up`
       while open (click to collapse), in the row's own ink. The row is set in
       `PopoverMetrics.sectionTitleFont` like the active account's title row,
       but in secondary ink — same weight, one step dimmer — so the accounts
       read as one list while the dimmer one is visibly not the account the
       bars describe. The active account's own section title takes the
       matching checkmark (`checkmark.circle.fill`, the icon Settings uses next
       to "Statusline hook installed", uncoloured here), and only while such a
       group exists (`AppModel.showsAccountStateMarkers`) — with nothing to
       contrast against, the bare account name reads better. Which groups are open lives in
       `AppModel.expandedOtherAccounts` (keyed by account uuid, `"unknown"` for
       the unstamped group), so it survives the popover closing and the rows
       being rebuilt by a poll — and is not persisted across launches, since
       the set of other accounts isn't either. The state file
       naming an account that has *no* readings anywhere is "no reading" for
       that account (both windows `nil`), not an error and not somebody else's
       numbers; with nothing on disk for any account the old
       `noQuotaSourceAvailable` still stands, because "Claude Code hasn't
       cached a reading on this Mac" is then accurate advice.
   - **`cachedUsageUtilization` (backup, `official (cached)`, zero setup).**
     Claude Code caches the same rate-limit payload into its own state file,
     `~/.claude.json`, as
     `cachedUsageUtilization.utilization.{five_hour,seven_day}.{utilization,
     resets_at}` with a `fetchedAtMs` stamp (epoch ms; `resets_at` here is
     ISO-8601 with fractional seconds, unlike the statusline payload's epoch
     seconds). Nothing to install — see
     `Sources/ClaudeStatsCore/Quota/CachedUtilizationReader.swift`.
     - **Stale after 60 min, not the statusline's 10.** Measured: `fetchedAtMs`
       sat 15 minutes old during an active session and did not move across five
       rewrites of `~/.claude.json` spanning 13 minutes — the file's churn is
       *not* a usage refresh. Later measured unmoved for 3.7+ hours with three
       Claude Code sessions actively running, so the real cadence looks like
       hours, not minutes. A 10-minute gate would reject good readings. The 60
       is a judgement call from those measurements, not a documented cadence.
     - **Undocumented private state.** It can be renamed or dropped by any
       Claude Code release — a `spend` object appeared inside this payload
       between 2026-08-27 and 2026-08-28. That is precisely why the statusline
       path below is kept rather than deleted.
     - The payload also carries a flat `limits[]`, `spend` / `extra_usage`, and
       `accountUuid`. Its `session` and `weekly_all` entries are deliberately
       *not* read — they restate the typed fields (`session` == `five_hour`,
       `weekly_all` == `seven_day`), which stay the source for the two main
       bars. Its `weekly_scoped` entries **are** read, one per scope, labelled
       from `scope.model.display_name` (falling back to `scope.surface`) and
       carried on the snapshot as `scopedWeekly` — generically, so a model that
       appears tomorrow needs no code change.
       - **What that `percent` is a share of is unverified.** Every entry
         observed so far read 0, with `resets_at: null` and
         `is_active: false`; whether a populated one measures a model-specific
         sub-cap or the account's weekly total is unknown. So the row and its
         tooltip report Claude Code's own number and name no denominator, and
         0% is shown as 0% rather than hidden. `severity` and `is_active` are
         stored for fidelity but not yet styled.
     - **Usage credits (`spend` + `extra_usage`) — transient, and absence is
       normal.** `utilization.spend` carries the org's extra-usage spend as
       money (`used` / `limit` as `{amount_minor, currency, exponent}`, plus
       `percent`, `severity`, `enabled`), and the sibling `extra_usage` object
       says whether credits are on at all. Read on its **own** parse path —
       this key is never in `limits[]`, so the generic scoped-limit parser
       doesn't see it — into `QuotaSnapshot.usageCredits` (see
       `Models/UsageCredits.swift`), and rendered as a fourth, hatched bar in
       both the popover and the glyph.
       - **Every unmet condition yields `nil`, never a partial bar and never an
         error.** `spend.enabled` must be `true`; `spend.percent` must be
         present (a missing percentage is not 0%); `used` and `limit` must both
         parse and agree on the currency. `extra_usage` **vetoes** a populated
         `spend` when `is_enabled` is false or `user_disabled` is true — the
         `spend` object can outlive the credits it describes.
       - **Absence is the normal state of this row, not a fault.** Credits can
         appear and disappear between two polls (the whole `spend` object turned
         up between 2026-08-27 and 2026-08-28, and an admin can switch credits
         off at any time). No credits means no popover row and no fourth glyph
         bar — no placeholder, nothing in `activeErrors`, no warning. The only
         thing ever surfaced about their absence is `disabled_reason`, carried
         as `usageCreditsDisabledReason` and appended to the quota title's
         tooltip (and to an inactive account's row tooltip).
       - **Money is formatted from the payload's own `currency` and
         `exponent`** via `DisplayFormat.money(_:locale:)` — never a hardcoded
         symbol, never a hardcoded `/100`, since a zero-decimal currency reports
         `exponent: 0` and would otherwise render 100× too small. The value
         column shows `€0.00 of €33.00`, not a percentage: 0% of an unstated
         budget says nothing.
       - The cap is **monthly** (`extra_usage.monthly_limit` restates
         `spend.limit`) and the payload reports no reset timestamp for it, so
         the countdown column stays empty. `extra_usage.spend_limit_reached` is
         carried on the model and named in the tooltip; `severity` is stored for
         fidelity but not yet styled.
       - Like `scopedWeekly`, this originates only in `cachedUsageUtilization`
         — the statusline *payload* has no `spend` object. It reaches the hook's
         cache anyway, because the helper script copies both across itself (see
         below), and `FreshestQuotaProvider` backfills from this source only
         when the hook's reading arrived without them, via
         `QuotaProviding.currentUsageCredits()`, which bypasses that source's
         staleness gate for the same reason `currentScopedWeekly()` does.
   - **statusline hook (`official`, opt-in, and the primary).** Register as
     (or piggyback on) Claude Code's `statusLine` hook — receives
     `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` via stdin,
     but only fires while Claude Code is actively rendering a status line in a
     terminal. Cache to disk, treat as stale after ~10 min — see
     `Sources/ClaudeStatsCore/Quota/StatuslineCacheReader.swift`.
     - **One cache file per session, merged on read.** The hook writes
       `~/Library/Application Support/ClaudeStats/statusline-cache/<session_id>.json`
       — the payload's own top-level `session_id`, stripped to `[A-Za-z0-9._-]`
       and of leading dots (a hidden file is one the reader never sees) — not
       one shared file. Every running Claude Code process runs the hook
       and pipes in the rate limits *its own* last API response carried, while
       an idle session re-renders its status line on timers alone; one shared
       file therefore meant last writer wins, with hours-old numbers stamped as
       captured "now". Observed: bars reading 0% (5h) / 25% (7d) against a real
       68% / 44%.
       - **A window missing from a payload is expired, not 0%.** Claude Code
         drops a window from `rate_limits` entirely once its `resets_at` has
         passed, so a quiet session's payload can carry `seven_day` alone.
         Mapping the absent one to an empty window is how the 0% above got on
         screen; `QuotaJSON.optionalWindows(in:)` keeps absence absent and the
         reader ranks only the readings that exist.
         - **The absence survives all the way to the UI.**
           `QuotaSnapshot.fiveHour` / `.sevenDay` are **optional**, and `nil`
           means *no source made a claim about this window* — the normal state
           between a rollover and that session's next API call, when no file
           mentions the window at all. The popover renders it as `—` /
           `no reading` and the glyph bar draws empty with VoiceOver saying
           unknown; nothing anywhere substitutes 0%. Both readers apply the
           same guard — at least one window, or `noQuotaSourceAvailable` —
           and neither grafts a window from the other source: a hook snapshot
           with a `nil` window stays `nil`. (`QuotaWindow` has no zeroed
           `.empty` placeholder any more; `nil` is the placeholder.)
       - **Merge rule, per window, independently — and within one account
         group only** (see "Which account, though" above). Ignore any reading whose
         `resets_at` has passed; take the latest `resets_at` (a later reset is
         a later window); on a tie — i.e. the same window — take the *highest*
         percentage, since utilization within one window never decreases, so a
         lower number is the older read; a reading with no `resets_at` ranks
         below every reading that has one, and among those the newest capture
         wins. The snapshot's `capturedAt` is the newest `captured_at` among
         the files that actually contributed a window, and the staleness gate
         applies to that.
       - The single `statusline-cache.json` older script copies wrote is no
         longer written but still read, as one more input — unstamped, so it
         joins the unknown-account group rather than the logged-in account's,
         and a machine whose hook hasn't been reinstalled is served by the
         backup source until its next render writes a stamped file. Session files unwritten
         for 7 days are deleted as the reader passes over them; the legacy file
         is not, since it may be that machine's only reading.
     - **The cache carries all four bars, not two — plus whose they are.** When
       `jq` is available the
       helper script also reads Claude Code's own `~/.claude.json` (located the
       way `ClaudeConfigDirectory.stateFileCandidates()` does) and merges the
       `weekly_scoped` entries of `limits[]` plus `spend` and `extra_usage`
       into the same cache file it writes the rate limits to, under a third
       top-level `utilization` key shaped exactly as those objects appear in
       `cachedUsageUtilization` — so `QuotaJSON.scopedLimits(in:)` /
       `usageCredits(in:)` read them unchanged — and `oauthAccount` as a fourth
       top-level `account` key (`uuid`, `email`, `organization_name`,
       `organization_uuid`, each omitted when the state file lacks it, the
       whole object omitted when none is usable). Both copies ride one
       fingerprint-gated read of that file, so the stamp costs nothing extra. Not merged window-style: every
       session copies the same `~/.claude.json`, so the reader simply takes
       this object from the most recently captured file that carries one.
       That is what makes a hook-only reading complete, and why the hook can be
       primary rather than a freshness booster. Strictly best-effort and
       additive: no `jq`, no state file, or a malformed one simply omits the
       key, exactly like a cache file written before the key existed, and the
       app backfills those two fields from the backup source.
     - The hook used to be the only source, which made its `settings.json`
       install step a gate on the whole tier. It is not one now — the backup
       covers a machine with no hook installed — so nothing in the UI treats
       installing it as required; the Settings pane's "freshness booster"
       framing has not been revisited since the priority flip.
   - Neither source falling back to an estimate is deliberate. A prior version
     of this app additionally polled the undocumented `oauth/usage` endpoint
     (`experimental` confidence) and, failing that, estimated usage from local
     token counts against the detected plan's budget (`local_estimate`
     confidence). Both were removed: the app is meant to show the account's
     real rate-limit window, not a guess, so a source that can't do that
     shouldn't silently stand in for one that can.
   - **Promo notices (decoration, never an error).** Alongside the config tree,
     Claude Code keeps a state file it writes for itself, `~/.claude.json`.
     Among its
     *undocumented* internal keys,
     `cachedGrowthBookFeatures.tengu_rate_limit_promo_notices` holds the promo
     line the CLI renders above its own weekly bar (`{ bar, text, variant }`), and
     `cachedGrowthBookFeaturesAt` says when GrowthBook last served it. We
     render it below the quota bars, in bar order — see
     `Sources/ClaudeStatsCore/Quota/RateLimitPromoNoticeReader.swift`.
     Everything about this path is best-effort: it is another program's private
     state, so absent / unreadable / malformed / stale all mean "no promo" and
     **never** produce a `ClaudeStatsError` or an `activeErrors` entry.
     - **Both candidate paths are probed** —
       `$CLAUDE_CONFIG_DIR/.claude.json`, then `~/.claude.json`. The docs say
       the override relocates "every `~/.claude` path", but this file is a
       *sibling* of `~/.claude`, not inside it; which one wins is undetermined
       upstream, so try both and take the first that opens.
     - **No FSEvents coverage.** The file lives directly in `$HOME`, and
       watching `$HOME` recursively is not an acceptable cost for one cached
       feature flag. Reads ride the throttled quota refresh instead (≥30s,
       ≤300s; manual Refresh always re-reads), gated on a nanosecond-mtime +
       inode + size fingerprint so an unchanged 145 KB file costs one `open`
       plus one `fstat`, not a parse.
     - **Hidden when `cachedGrowthBookFeaturesAt` is older than 7 days**, and
       when it is missing entirely (unknown age ≠ fresh). **The file's mtime is
       not an age signal** — Claude Code rewrites it constantly for unrelated
       keys (`numStartups`, `seenNotifications`), so mtime is minutes old even
       when the flag cache is months stale. mtime is only ever the
       unchanged-since gate.
     - **Any `https` URL in the text is linkified**, not restricted to a host
       allowlist. Stated risk: the file is user-writable, so any local process
       running as the user can plant clickable text in a Claude-branded
       popover. Mitigated by shape guards, not by host — `https` only, other
       explicit schemes rejected outright rather than prefixed, no userinfo/port, ASCII host
       that must equal the parser's own host — plus a tooltip disclosing the
       resolved URL. See `Support/LinkifiedText.swift`.
     - **No dismiss affordance.** `tengu_startup_announcements` in the same
       blob carries `id` + `maxImpressions`; the promo key carries neither —
       upstream gave dismissible notices an identity and deliberately did not
       give this one.
     - An unknown `bar` value **drops the notice**: "+50% weekly limits" is
       only true of one of the two bars. `variant` is stored for fidelity and
       does not drive styling.
3. Refresh via `FSEventStream` (CoreServices) watching the config dir tree —
   not polling. Kernel wakes the app only on write; debounce bursts; reparse
   only changed files, not a full rescan.
4. **Retention window.** `SessionCorpusIndex` keeps individual `UsageEvent`s
   only for the last `defaultRetention` (8 days = `localHistoryDays`);
   older events fold into per-model `HistoricalModelUsage` totals that only
   `modelUsage(last24h: false)` reads back. Any new per-event query — a new
   `TimeWindow` case, a longer heuristic — must fit inside that window, or
   raise `defaultRetention` first.
   - **The same fold also buckets by day**, into `DailyUsageCell` →
     `DailyUsageTotals` (`Models/DailyUsage.swift`) keyed by
     `(local day, raw model ID, entrypoint)`. That is what lets
     `LocalLogUsageStore.dailyUsage(days:)` chart 30 days without retention
     being raised: it is not a per-event query, so the rule above does not
     apply to it. It reads the folded cells for old days and the retained
     events for recent ones, exactly the two-halves split
     `modelUsage(last24h: false)` already uses — the halves never overlap,
     because the fold moves events rather than copying them.
   - Both accumulations are filled in one pass, so neither costs extra I/O;
     the parse already happens. `HistoricalModelUsage` stays alongside the
     cells rather than being derived from them because it carries a
     `latestTimestamp` per model for `modelUsage`'s "newest raw ID wins" rule,
     which day-resolution cells could only approximate.
   - Series come back **dense** — an idle day inside the window is a zero
     point, never a gap, or a line chart connects across it and draws usage
     that never happened — and the window is **shortened, never zero-padded**,
     when the corpus is younger than it was asked for.
   - A cell carries **tokens and cost**, which is why "Estimated cost" could be
     added as a pure UI change: the spend was already in the buckets. Keep it
     that way — a second accumulation for a second chart would mean a second
     pass over the corpus.

### Explicit non-goals (v1)

- **CI / remote agents.** Almost certainly a different quota pool (API-key
  billed, not the OAuth subscription window) on an ephemeral filesystem that
  never reaches this Mac. Not solvable by local-log parsing. Would need
  Console Admin API (org admin scope) or the CI pipeline self-reporting
  somewhere pollable. Backlog, not v1.
- **Phone / claude.ai web chat.** No local trace, no public per-source API.
  Folds invisibly into the blended account-wide % from tier 2, but never
  breaks out separately.

## UI

`NSStatusItem` with a custom SwiftUI-hosted view:

- Claude mark (see `assets/claude-mark.svg`) on the left, in place of a
  generic SF Symbol.
- 3–4 thin vertical bars, monochrome fixed fill (no color-shift-to-red), no
  text labels — 5-hour window %, 7-day window %, and the highest-percentage
  scoped weekly limit (the popover lists them all). Minimal total width,
  matching Stats' CPU/GPU/RAM glyph but thinner. Those three are always drawn:
  with no scoped-limit reading (or no snapshot at all), the third bar is simply
  empty — there is no narrower, two-bar state. A 5h/7d window no source
  currently reports draws empty the same way (there is no third rendering of an
  empty 3 pt bar to invent), but the accessibility description says
  `five-hour unknown` / `seven-day unknown` instead of `0% five-hour` — the one
  place that can tell an unknown window from a zero one.
  - A **fourth, hatched bar** is drawn *only* when the payload reports usage
    credits, so the glyph is three bars wide normally and four wide while
    credits exist (the width is a function of the bar count —
    `MenuBarGlyph.width(barCount:)` — and the status item is `variableLength`,
    so it resizes with it). Conditional, unlike the other three, because
    credits are transient: an always-drawn empty fourth bar would imply a
    monthly spend cap the account may not have. 0% of a real cap *is* a
    reading and does draw the bar. The hatch marks it as a different kind of
    measurement — money against a monthly cap, not a rate-limit window — and
    is drawn in the same template ink, so the menu bar still tints and inverts
    it for free.

Click opens a popover:

```
✓ me@example.com                cached
                                  ← the quota block's section title, the same
                                    shape as "Tokens by source" and "Costs by model" below:
                                    title left, tag right. The title names the
                                    account the rows describe, from
                                    `~/.claude.json`'s `oauthAccount` (login
                                    email, else organisation name, else a
                                    short uuid) — only when something on disk
                                    says; an unstamped reading (or no reading at
                                    all) titles the section `Quota` rather than
                                    guessing a name. The ✓ checkmark icon
                                    appears **only** when there is at least one
                                    other account listed below to contrast with
                                    (then an unstamped reading is titled
                                    "Unknown account", not "Quota");
                                    on the one-account machine the bare name
                                    stands alone. Tooltip distinguishes a named
                                    account from the unstamped fallback.
                                    The trailing tag is `cached` while Claude
                                    Code's own cached reading serves, and
                                    absent once the statusline hook is
                                    installed and has fired — "official" is
                                    never printed, both sources are. No age
                                    and no `· stale` suffix: freshness is not
                                    displayed; an over-threshold reading shows
                                    the orange warning line instead. The title
                                    also carries the `disabled_reason` tooltip
                                    when the payload
                                    said why there are no usage credits — there
                                    is no credits row to hang it on, and it is
                                    never an error line.
5-hour      ▓▓▓▓▓▓░░░░ 62%    2h 14m
7-day       ▓▓▓░░░░░░░ 31%    4d 6h
                                  ← countdown column is the bare time until
                                    the window resets; no "resets in" prefix.
                                    The labels carry no "window" suffix and the
                                    weekly rows no parentheses: the label column
                                    is 80 pt, sized to the payload-labelled rows
                                    (`Sonnet weekly`), and everything those two
                                    gave up went to the bar, now 100 pt wide.
                                    Tooltips and VoiceOver still say "5-hour
                                    window" — nothing competes for width there.
5-hour      ░░░░░░░░░░  —      no reading
                                  ← how either of the two rows above renders
                                    while no quota source reports that window
                                    (`QuotaSnapshot.fiveHour == nil`) — after
                                    it rolled over and before the next API
                                    call, and for the no-snapshot-at-all state.
                                    Empty track, em dash, "no reading": never
                                    0%, which would be a number nobody
                                    reported.
Fable weekly ░░░░░░░░░  0%
                                  ← one row per `weekly_scoped` entry in the
                                    payload's `limits[]`, labelled from
                                    `scope.model.display_name`. Only when the
                                    payload reports any. 0% shows as 0%; the
                                    countdown column is empty when the entry
                                    has no `resets_at`. The tooltip says it is
                                    Claude Code's own scoped weekly limit and
                                    deliberately claims no denominator for the
                                    percentage.
Usage credits ▨▨░░░░░░   €0.00 of €33.00
                                  ← org usage credits, from `utilization.spend`
                                    cross-checked against `extra_usage`. Only
                                    when credits are actually on — no credits
                                    means no row at all, no placeholder, no
                                    error. Hatched fill, because it measures
                                    money against a monthly cap rather than a
                                    rate-limit window. The value column is
                                    money (formatted from the payload's own
                                    `currency`/`exponent`), not a percentage,
                                    and spans the percent + countdown columns:
                                    the monthly cap has no reported reset, so
                                    there is no countdown. The tooltip names
                                    the monthly framing and says when
                                    `spend_limit_reached` is set.
+50% weekly limits promo through Aug 31 · clau.de/cc-50-promo
                                  ← Claude Code's own promo notices, read from
                                    `~/.claude.json`; the bare URL is clickable.
                                    Only when one is cached and fresh. All of
                                    them sit here, below the active account's
                                    last row and in bar order — not under the
                                    bar each one names: the line wraps to the
                                    full content width, so one between two bars
                                    split the column of rows in half.
<staleness warning, orange>       ← and after those, the staleness warning or,
                                    with no snapshot at all, the "no source yet"
                                    / just-cleared-cache line.

✕ other@example.com            ⌄  ← one collapsed group per *other* account
                                    this Mac has readings for — what is left
                                    behind after switching the global login.
                                    Closed by default, showing the ✕ cross icon
                                    and the account name, nothing else; no
                                    summary percentage. Set in the same
                                    semibold section-title font as the active
                                    account's title above but in secondary
                                    ink (one step dimmer), so the two read as one list of
                                    accounts rather than as a section with a
                                    footnote under it. The whole row is one
                                    button, not a disclosure: clicking anywhere
                                    on it toggles the group. The caret is
                                    trailing and names the *action*, not the
                                    state — `⌄` on a closed row because
                                    clicking reveals the rows below, `⌃` on an
                                    open one because clicking folds them away.
                                    Pairs with the ✓ checkmark above. Separated
                                    from the bars and from each other by
                                    whitespace only — no divider (that line
                                    marks a top-level section) and no indent.
✕ other@example.com            ⌃  ← expanded: the same rows as above, same `—` /
5-hour      ░░░░░░░░░░  —           "no reading" for an expired window, a
7-day       ▓▓▓▓▓░░░░░ 56%          `cached` tag at the foot only if that group
                                    came from the backup source (it never does:
                                    statusline files are the only per-account
                                    readings), no usage-credits row
                                    (that data only ever exists for the active
                                    account). Labelled "✕ Unknown
                                    account" for the unstamped group, which is
                                    shown only when it isn't the one driving the
                                    bars above and still has a live window.
                                    Absent entirely on a one-account machine.

Tokens by source
4M ┤
2M ┤ ▁▂▅▃▂▆█▅▃▂▄▆█▃▂▄▅█▃▂▁▂▄▅█▆▃▂▁▃
 0 ┼──┬───────┬───────┬───────┬────
   16. Aug. 23. Aug. 30. Aug. 6. Sept.
● CLI 18k   ● VS Code 0   ● SDK 40.6k   5h
                                  ← a stacked daily area chart of the last 30
                                    days, one band per entrypoint, plus one
                                    legend chip per band carrying that source's
                                    **five-hour** token count.

                                    This replaced a 3×3 table (one row per
                                    entrypoint, one column per `TimeWindow`).
                                    The `24h` and `7d` columns were integrals
                                    over ranges the x-axis now covers — the
                                    last point and the last seven — so they
                                    went. `5h` did not: a daily chart has no
                                    intra-day resolution, it is the only
                                    sub-day reading in the popover, and it is
                                    the machine-local counterpart to the
                                    account-wide five-hour quota bar above. So
                                    it survives as the legend's value rather
                                    than as a column. (The table in turn had
                                    replaced a segmented picker with
                                    peak-relative bars, which compared rows
                                    inside one window and said nothing across
                                    windows.)

                                    Monochrome — three opacities of the primary
                                    ink, never three hues: colour in this
                                    popover means a warning or the one brand
                                    link. Bands are `.monotone`, never
                                    `.catmullRom`: a spline through spiky daily
                                    counts overshoots, and on a stack an
                                    overshoot dips below the band underneath,
                                    drawing usage that never happened.

                                    Every entrypoint is always listed, at 0 if
                                    need be — a silent source keeps a band and a
                                    chip rather than vanishing. Hovering a chip
                                    shows that source's full five-hour token
                                    split, which is where the table's per-cell
                                    tooltip went.

                                    Both axes are drawn, sparsely: without a
                                    y-axis the bands show shape but no
                                    magnitude, and without dated x-ticks a spike
                                    can't be tied to a day — but thirty dated
                                    labels across a 340 pt popover would be
                                    mush, so it is one label a week and three
                                    values up the y. **Ticks stop four days
                                    short of the right edge**: a label is centred
                                    on its tick and truncated at the chart's
                                    trailing bound, so a tick any closer renders
                                    as `1…` no matter how the plot is inset
                                    (tried: padding the chart, then padding the
                                    plot area — neither helps, the label has
                                    nowhere to sit). Nothing is lost by it, since
                                    the right edge of a trailing window is always
                                    today.

                                    Drawn axes still don't make a chart legible
                                    to VoiceOver, so it carries a real
                                    `AXChartDescriptor` — one series per source,
                                    one point per day, y-axis reaching the
                                    tallest *stacked* day — rather than being an
                                    unlabelled image. Its value formatter guards
                                    non-finite input and clamps to 2^53, not to
                                    `Double(Int.max)` (which rounds up to 2^63
                                    and traps): the framework calls it with
                                    probe values of its own choosing, and both
                                    traps were live crashes.

                                    **No window tag** opposite the title,
                                    unlike every other section: the dated
                                    x-axis already says how far back the chart
                                    reaches and that it ends today, so a
                                    `30 days` caption would only repeat it. A
                                    Mac whose logs don't reach back that far
                                    simply charts fewer days; one with no local
                                    history at all gets `No local usage yet`
                                    instead of a flat line through zero.

                                    The plot carries a small margin above and
                                    below — it is the only element in the
                                    popover that is a picture rather than a row
                                    of text, and flush against the title and
                                    legend it reads as part of them. Vertical
                                    only: it spans the full content width like
                                    every other row, so a sideways inset would
                                    pull its axis out of that alignment.

                                    No cache-read note here: the
                                    chart's numbers are a single window's
                                    per-source split, and "Costs by model" (fixed 24h)
                                    keeps that explanation on screen.

Costs by model (fixed 24h window)
  Sonnet   2.1M tok   $3.15
  Opus      180k tok   $2.70
  Haiku     640k tok   $0.19
  Fable      90k tok   $0.08
81% cache reads — billed at 1/10 the input rate  ← only when cache reads are
                                    >50% of the model rows' total, as a
                                    whole-percent share of it. The one place
                                    that explanation still appears.

Estimated cost
$6 ┤
$4 ┤  ╱╲  ╱╲╱╲  ╱╲  ╱╲╱╲  ╱╲  ╱╲╱╲
$0 ┼──┬───────┬───────┬───────┬────
   16. Aug. 23. Aug. 30. Aug. 6. Sept.
Today                              $3.05
                                  ← a single line of estimated daily spend over
                                    the same 30 days and the same x-ticks as
                                    "Tokens by source" (both take them from
                                    `PopoverChartAxis`, so a given x position
                                    means one day in both plots).

                                    A line, not a stacked area: one series with
                                    nothing under it, and a filled band would
                                    read as a fourth source rather than as a
                                    different question. Same ink as the source
                                    chart's top band — one visual weight for the
                                    popover's own data, not a second palette.

                                    `.monotone` for the reason the stacked chart
                                    uses it, only sharper here: an overshoot
                                    below the baseline draws **negative
                                    dollars**. `chartYScale(includesZero:)` pins
                                    zero into the domain so a quiet stretch
                                    still sits visibly above the axis.

                                    Y labels are `DisplayFormat.compactCost`,
                                    not `cost` — axis ticks land on round
                                    numbers and `$50.00` spends a third of the
                                    popover's narrowest label on zeroes.
                                    Decimals survive below `$10`, where `$2` and
                                    `$2.50` are different readings.

                                    "Estimated" moved from the row to the
                                    section title, where it qualifies the chart
                                    too, and is spelled out rather than `Est.`
                                    because it is the word doing the work: a
                                    curve invites reading the area under it as a
                                    monthly bill, and this is a local estimate
                                    from published per-token prices — on a
                                    subscription, spend that was never charged.

                                    The curve's last point *is* the `Today` row:
                                    both count from the same local midnight on
                                    the same calendar, and today is always
                                    inside the retention window. Pinned by
                                    `testTodaysPointMatchesEstimatedCostToday`,
                                    and on the mock too, since the README
                                    screenshots render from it.

                                    Deliberately not a per-model chart. That was
                                    the original plan and it lost: five bands
                                    (four families plus unrecognised IDs)
                                    against a three-shade monochrome palette,
                                    and placing it above the `fixed 24h` rows
                                    would have sharpened the window ambiguity
                                    the tag only papers over.

Refresh   Clear Quota Cache   Settings        Quit
                                  ← "Clear Quota Cache" deletes the statusline
                                    cache and re-polls. It lives in the footer
                                    with the other actions rather than under the
                                    quota rows it acts on, where it floated
                                    after the other accounts' groups and read as
                                    though it belonged to the last one.
```

The source tag names the source only when it is the backup: `cached` (Claude
Code's own cached reading, the zero-setup default) versus nothing at all (a
statusline capture, once that hook is installed). Both are Anthropic's own
numbers, so the word "official" is not printed, and neither the reading's age
nor a "stale" marker is shown — staleness surfaces only as the orange warning
line. Settings still spells out the full `QuotaConfidence.displayLabel`. No
estimate fallback: with neither
source reporting, the popover shows an error instead of a number; a
real-but-old reading keeps the last numbers with an orange staleness warning.
"Clear Quota Cache" deletes the statusline cache only — the whole per-session
directory plus the legacy single file; `~/.claude.json` is Claude Code's, not
ours — so the bars fall back to the cached-state numbers rather than going
empty.

## Tech / release

- Native Swift/SwiftUI, Swift Package Manager. No Electron, no Tauri.
- Release process cloned from `qrski` (sibling repo,
  `../qrski/make_app.sh` + `../qrski/make_release.sh`): hand-rolled
  `Info.plist`, `actool` for the asset catalog, ad-hoc `codesign --sign -`
  (unsigned, no notarization — users click through Gatekeeper once), zip +
  sha256, `gh release create`. Direct-download distribution, not the Mac App
  Store (App Sandbox would need security-scoped bookmarks just to read
  `~/.claude`, real friction for no benefit here).
- Reuse `qrski`'s `UpdateChecker.swift` pattern (poll GitHub releases API)
  for self-update-check.
- `assets/claude-mark.svg` is the source for both the status-item glyph and
  the generated `AppIcon.appiconset` — regenerate PNG sizes from it rather
  than hand-drawing a new mark.

### Release commands

- `bash make_app.sh <x.y.z>` — builds `.build/release/ClaudeStats`, assembles
  `ClaudeStats.app`, runs `actool` over
  `Sources/ClaudeStats/Assets.xcassets`, writes `Info.plist`, ad-hoc-signs.
  Omit the version to take the newest released one from `CHANGELOG.md`.
- `bash make_release.sh <x.y.z>` — stamps `[Unreleased]` in `CHANGELOG.md`,
  calls `make_app.sh`, zips with a SHA-256 sidecar, prints the
  `gh release create` command. Refuses to run on a dirty tree, an existing
  tag, a non-semver version, or an empty `[Unreleased]`.
- `bash scripts/make_icon.sh` — regenerates the `AppIcon.appiconset` PNGs
  (16/32/64/128/256/512/1024) from `scripts/make_icon.swift`'s own drawing
  code (three generic rounded bars, no Claude branding — deliberate, a
  third-party app can't use Anthropic's logo as its own icon). Only needed
  after that file changes; the PNGs are committed. Self-contained CoreGraphics,
  no rsvg/cairo toolchain required. Unrelated to `assets/claude-mark.svg` /
  `ClaudeMark.swift`, which is still the menu-bar glyph's own mark.
- `Sources/ClaudeStats/Assets.xcassets` is `exclude`d in `Package.swift`:
  the SwiftPM CLI has no asset-catalog build rule, and declaring it as a
  resource would ship a bundle nothing reads.
- `Info.plist` sets `LSUIElement` even though `ClaudeStatsApp.swift` already
  calls `setActivationPolicy(.accessory)` — launchd reads the key before any
  of our code runs, so there is no Dock-tile flash on launch. The runtime call
  stays authoritative for bundle-less `swift run` builds.

### CHANGELOG / release note style

Keep entries short — 1-3 lines each, like `0.9.2` and earlier ("Menu bar
glyph: mark size 14 → 11.9 (15% smaller)..."). Entries from `0.9.3` onward
drifted into paragraph-length rationale (every "why", every measurement, every
edge case) — that belongs in commit messages / AGENTS.md, not the changelog a
user reads to decide whether to update. State what changed and, if truly
needed, why in a clause — not the full investigation.

### README images

Two PNGs, `assets/screenshot-popover-{light,dark}.png` — menu bar strip, the
status item glyph sitting in it, and the popover hanging below with its tail
pointing back up at the glyph — **rendered from the app's own views** rather
than screenshotted, a light and a dark variant because GitHub serves READMEs
in both themes and a single image is wrong in one of them.

Regenerate with:

    bash scripts/render-readme-assets.sh

Run it by hand after a popover layout change. Deliberately not wired into
`make_app.sh` or `make_release.sh` — `make_release.sh` refuses a dirty tree, so
regenerating committed PNGs mid-release would break the release.

The renderer is `Tests/ClaudeStatsTests/ReadmeAssetRenderTests.swift`, skipped
unless `CLAUDE_STATS_RENDER_ASSETS` names an output directory, so a plain
`swift test` neither writes files nor pays for the render.

**Why it lives in the test target.** `ClaudeStats` is an `executableTarget`, so
no second executable can depend on it. The test target already can, and
`@testable import ClaudeStats` reaches `PopoverView`, `MenuBarGlyph` and the
`#if DEBUG` `AppModel.previewShowcase(now:)` fixture without a `public` sweep
over the whole UI. Test targets are never bundled into the `.app`, so none of
it ships.

Four things it has to get right, each of which will silently produce a wrong
image if dropped:

- **Mock data.** One fixture, `AppModel.previewShowcase(now:)`, also driven by
  a `#Preview` in `PopoverView.swift` — so the canvas and the committed PNG
  cannot drift. It composes the promo notice, the scoped weekly row and a
  part-spent `MockQuotaProvider.sampleShowcaseSnapshot(now:)`; the glyph is
  drawn from that *same* snapshot via `MenuBarGlyph.image(for:)`, so its bars
  can never disagree with the popover's rows.
- **A pinned clock.** The PNGs are committed, so `renderDate` is a fixed
  `Date` fed to both the snapshot and `PopoverClock(now:)` (never resumed, so
  it never ticks). Without it every run rewrites the countdowns and dirties
  the tree. Rendering twice must leave `git status` clean.
- **`NSHostingView`, not `ImageRenderer`.** Originally forced: what is now
  the "Tokens by source" section had a `.pickerStyle(.segmented)` `Picker`, i.e. an
  `NSSegmentedControl` behind an `NSViewRepresentable`, and `ImageRenderer`
  rasterizes SwiftUI's own drawing only, painting that control as its yellow
  "unsupported view" placeholder. The picker is gone (that section is a chart
  now), and the hosting view is kept rather than re-litigated: it is the
  same AppKit draw path the shipping popover uses, and it is what carries the
  `NSAppearance` the next point needs — `ImageRenderer` offers a SwiftUI
  environment, not an AppKit appearance. So the
  card is hosted in a borderless `NSWindow` and captured with
  `cacheDisplay(in:to:)` into an `NSBitmapImageRep` whose `pixelsWide/High` are
  4× its `size` — that ratio is where the 4× scale comes from.
- **The AppKit appearance**, set on both the hosting view and its window.
  `PopoverMetrics.brandLinkColor` is a dynamic `NSColor(name:)` resolved against
  the *AppKit* appearance, not SwiftUI's `colorScheme`: without it the promo
  link paints one theme's terracotta onto the other theme's card. Any other
  `NSColor`-backed value in the tree has the same dependency.

Three things the renderer draws itself, all confined to that file:

- **The popover chrome** — rounded body, the tail on the top edge, the hairline
  border. `NSPopover` owns all of it at runtime; `PopoverView` is only the
  content. It is one closed `Shape` (`PopoverCardShape`) so the border strokes
  the tail's sides rather than cutting across its base. It must not move into
  app code: the real popover needs AppKit's own chrome, with the tail aligned
  to the actual status item.
- **The drop shadow**, as a Core Graphics pass in the composite —
  `cacheDisplay(in:to:)` captures the view's drawing and does not reliably
  composite the layer-level shadow a SwiftUI `.shadow` installs. Drawn after
  the strip, so the popover casts onto the menu bar the way the real one does.
- **The menu bar strip** — a three-stop *horizontal* gradient
  (`#7E78A7 → #4885BA → #286AA7`), the desktop tint measured off the real menu
  bar. Horizontal because that is the wallpaper showing through and a wallpaper
  sweeps across the screen; over 24 pt of height a vertical fade would not read.
  The light variant blends every stop 40% toward white, which is what macOS's
  light wash over the menu bar looks like. Glyph and tail are both centred on
  the canvas, so they line up with each other by construction.

The glyph PNGs are the status item's template image (black ink + alpha)
recolored with a `.sourceIn` fill, which repaints only where the glyph already
put ink and so preserves the anti-aliased mark edges and the bars' faint unused
tracks. The dev-build dot never appears — it is a separate `NSView` overlay
`StatusItemController` adds to the status button, never part of
`MenuBarGlyph`'s image.
