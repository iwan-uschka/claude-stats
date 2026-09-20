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
  rebuild perf triage; `SessionCorpusIndex` emits `StatPass`, `ScopedScan`,
  `Reparse`, `Fold` and `SnapshotAssembly` intervals under subsystem
  `de.bitgrip.claude-stats`, category `RebuildPerf`. `StatPass` (full corpus)
  and `ScopedScan` (just the watcher batch's paths) are alternatives — a
  healthy steady state is one `StatPass` at launch and one `ScopedScan` per
  coalesced write.

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
     - **An account switch clears the statusline cache on its own.** Every
       poll asks `QuotaProviding.currentAccount()` (on `FreshestQuotaProvider`,
       the same fingerprint-cached `ActiveAccountReader` the statusline reader
       groups by — so no second parse) *before* reading the snapshot, which is
       why a switch is seen even when that poll would throw — the usual
       outcome right after one. Not `snapshot.account`: a failed poll has no
       snapshot and an unstamped one names nobody. `AppModel` keeps the last
       *known* uuid in memory only; known → different known runs the same body
       as "Clear Quota Cache" (delete, retry ladder, a failed delete surfaces as
       `quotaError`) with its own notice, "Account switched to <name> — …".
       Nothing clears on the first poll after launch, on unknown → known or on
       known → unknown; known → unknown → *different* known does clear, because
       the unknown poll doesn't overwrite the remembered uuid. Two limits, both
       accepted: detection waits for the next quota poll — the state file is in
       `$HOME`, which isn't watched, and polls are triggered by opening the
       popover, by session activity, or by `AppModel`'s background timer (all
       throttled to `quotaPollInterval`) — so a switch is noticed no later than
       one poll interval after it happens, even in an idle app; and an idle
       session can still re-render the old account's numbers into a
       fresh, new-account-stamped file *after* the clear — so the clear does not
       replace the mislabel guard above, which stays the defence against exactly
       that.
     - **Only the active account is shown — the inactive-account rows were
       removed, don't re-add them.** The popover used to list every other
       account group below the active one, collapsed, with ✓/✕ markers. It went
       for two reasons. An inactive account's numbers are a **frozen copy**:
       its cache files are only written while that account is logged in on
       this Mac, so the rows can never update, and a reading that looks live
       can be days behind. And those groups are **not covered by the mislabel
       guard**, which only checks readings stamped with the account
       `cachedUsageUtilization` describes — a mislabelled file under another
       account's stamp would be shown unchallenged. Per-account grouping and
       the guard stay: they are what keeps the *active* bars honest. The one
       question still asked of the other groups is whether any exist with a
       live window (`StatuslineCacheReader.hasReadingsForOtherAccounts()`,
       behind the internal `OtherAccountReadingsReporting` protocol): the
       state file naming an account that has *no* readings anywhere while
       other accounts do is "no reading" for that account (both windows
       `nil`), not an error and not somebody else's numbers; with nothing on
       disk for any account the old `noQuotaSourceAvailable` still stands,
       because "Claude Code hasn't cached a reading on this Mac" is then
       accurate advice.
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
     - **Read behind the same fingerprint gate as the promo reader.**
       `FreshestQuotaProvider` asks this source for usage credits on nearly
       every poll (the hook's copy usually has `spend.enabled: false`, so no
       credits), and that used to be a full ~170 KB parse of an unchanged file
       — about half a poll. The values one parse extracts are cached against
       the fingerprint; staleness is still judged against the clock per call.
     - **A window past its `resets_at` is dropped on read, against the clock
       on every call** — `QuotaWindow.isLive(asOf:)`, the statusline merge's
       own rule 1, shared so the two readers can't drift. The blob is a
       snapshot nothing rewrites when a window rolls over, and this reader used
       to pass it through untouched: whenever it beat the hook reading (fresher
       `fetchedAtMs`, or the hook stale), the 5-hour bar kept its old
       percentage for a window that no longer existed — through the 60-minute
       gate and, as the freshest stale snapshot, beyond it. Dropped before the
       stale error is built, so that snapshot loses it too; both expired is
       `noQuotaSourceAvailable`. Expired, never 0% — see below.
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
         tooltip.
       - **Money is formatted from the payload's own `currency` and
         `exponent`** via `DisplayFormat.money(_:locale:)` — never a hardcoded
         symbol, never a hardcoded `/100`, since a zero-decimal currency reports
         `exponent: 0` and would otherwise render 100× too small. The row shows
         the percentage of the cap used, in the same percent column every
         quota row shares, plus an `of <limit>` caption in the trailing
         column; the amount actually spent is stated in full only in the
         row's tooltip.
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
           `no data` and the glyph bar draws empty with VoiceOver saying
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
       - **Each file's parse is cached, keyed by path, behind a `stat`.** Every
         poll lists the directory and walks every file, so per-file cost is what
         scales — and on a Mac running endpoint-security tools `open` costs
         ~33 µs against ~1.3 µs for `stat`. A file whose (inode, ns mtime, size) still
         matches is not opened; a changed one is read and fingerprinted from
         one descriptor as before. Retention and the merge are re-applied every
         poll; files that leave the listing leave the cache, and
         `clearCache()` empties it. Listing works on path strings, not `URL`s:
         `lastPathComponent` in the sort comparator alone was ~23 µs per file.
         Measured 2026-09-15 (release, state file unchanged, whole poll): 19
         files 4.0 → 0.4 ms, 250 files 24.7 → 2.3 ms.
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
       inode + size fingerprint so an unchanged 170 KB file costs one `open`
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
   - **Neither split drops anything.** `DailyUsageHistory.bySource` and
     `.byModelFamily` are both keyed by an *optional* — `nil` for an
     `entrypoint` or a model ID this version doesn't recognise — so either set
     of series sums to `total` and a stack of them may be drawn against it.
     `bySource` is additionally dense over `Entrypoint.allCases` (a silent
     source is a `0` row the popover shows), while the `nil` key of either is
     present **only** when such usage exists, so the chart's "Other" band never
     appears over nothing. `bySource` used to drop unrecognised entrypoints, the
     rule `EntrypointBreakdown` still follows; that is why the source stack once
     fell short of the total beside it. Nothing in the UI reads that breakdown
     any more — see the popover mock — so the rule now survives only inside the
     data layer's own query.
   - `[DailyUsagePoint].summed()` folds a series back into one
     `DailyUsageTotals` — the whole-window reading a table under a chart shows,
     tokens split and cost, without a second pass over the corpus.
   - A cell carries **tokens and cost**, which is why the popover can stack
     spend and why both of its tables show tokens *and* money without a second
     accumulation: it was already in the buckets. Keep it that way — a second
     pass over the corpus is what this shape exists to avoid. It is also what
     let one `dailyUsage(days:)` replace the three windowed queries the popover
     used to make per reload (`entrypointBreakdown`, `modelUsage(last24h:)`,
     `estimatedCostToday()`), each of which walked tens of thousands of
     `UsageEvent`s on the main actor. All three are still on `UsageStoring`; no
     view calls them.
   - **That one query is cached per store and local day, and read off the main
     actor.** It still costs ~11 ms on the real corpus. `AppModel` keeps the day
     its `dailyHistory` was read on and reads again only for a new store or a
     new day — so popover opens, the rebuild path's follow-up refresh and the
     account-switch retry ladder cost nothing. The rebuild queue reads it
     (`LocalStatsLoad.load(from:)`) beside the store it just built and hands
     both over; the main actor only assigns. A load's day is taken before the
     read, so one straddling midnight is re-read rather than kept.

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

### Type

**A number is set in monospaced digits; a word is not.** Every figure on the
card sits in a right-aligned column of fixed width — the quota percentages, the
reset countdowns, both chart axes, both table columns, the money on the
usage-credits row — and a proportional `1` is narrower than a proportional `8`,
so a column of proportional figures doesn't line up on its digits and a ticking
countdown visibly reflows under a stationary pointer. The fonts are
`PopoverMetrics.valueFont` (body size) and `captionValueFont` (caption size),
each the `.monospacedDigit()` variant of the label font beside it, so a numeric
caption still reads as a caption. The tables' window caption counts as a number:
it is a date whenever a single day is shown.

Labels, section titles and the column headings stay proportional — only digits
gain from a fixed advance, and widening the letters of `Estimated cost` would
cost the column the width it was measured for. The chart's y-label column is
*measured* in `captionValueNSFont`, the same font the axis draws in: measuring
proportionally would reserve a column narrower than the labels on screen.
`PopoverFontTests` measures both halves of the rule.

### Colour

**One colour, and it is Claude's terracotta.** Everything else is ink —
primary, secondary, the system's own control colours. The brand colour is
`PopoverMetrics.brandColor`, a per-appearance `NSColor` built from `#A85E3E`
light and `#E88A5C` dark (one literal for both measured 3.17:1 on a light card,
under the 4.5:1 AA floor for caption-size text) and **muted by
`PopoverMetrics.saturationReduction`**, so what actually paints is `#9B634B`
light (≈4.90:1 on white) and `#D6906E` dark (≈6.05:1 on the card). It is what
paints the promo link, the
Claude mark in the popover header, **the filled part of every quota bar**, the
staleness warning, the sample-data line, the error lines, and the menu bar's
dev-build dot. There is no second alert hue: `.orange` for a warning, `.red` for
an error and terracotta for a link put three colours on a card whose vocabulary
is "Claude" versus "ink", and the words already say which of the three a line
is.

**The quota bars are terracotta at rest, and that is their only state.** They
are the card's headline reading, so they take the app's colour rather than the
grey their labels are set in; the unfilled track stays `Color.primary` at 0.12,
because the unused part of a bar is absence and not a second reading. There is
deliberately **no over-budget or stale tint**: the resting fill is already the
ink a warning line is set in, so a bar that turned terracotta to raise an alarm
would be indistinguishable from every other bar on the card. Staleness is
carried by `AppModel.quotaWarning`'s own line of text and over-budget by the
percentage reading past 100%. The usage-credits bar keeps its hatch — the
geometry is what marks it as a different kind of measurement — and took the same
ink as the rest, since a grey hatched bar under three terracotta ones reads as
disabled rather than as different in kind.

**Only the chart bands and the table dots that point at them may use a
*shade*** — `PopoverMetrics.chartBandColor(index, of: count)`, shades of the one
hue, strongest first, position 0 being the brand colour itself.

**Shade by position, not a fixed palette.** The ramp used to be five literals a
chart took the first `count` of, so a three-band block sat on three adjacent
steps of five and its bands were ≈1.28 apart whatever the block. It now spreads
`count` bands across the *whole* bounded range, so the fewer the bands the
further apart they sit. The ends are the old ramp's first and last steps, muted
like everything else — measured against white and the ≈`#232323` dark card,
4.90 → 1.79 in light and 6.05 → 2.26 in dark:

| bands | light, on white | dark, on `#232323` |
| --- | --- | --- |
| 2 | 4.90 / 1.79 | 6.05 / 2.26 |
| 3 | 4.90 / 2.87 / 1.79 | 6.05 / 3.89 / 2.26 |
| 4 | 4.90 / 3.41 / 2.44 / 1.79 | 6.05 / 4.54 / 3.26 / 2.26 |
| 5 | 4.90 / 3.72 / 2.87 / 2.25 / 1.79 | 6.05 / 4.89 / 3.89 / 2.98 / 2.26 |

Five is the most the popover can ask for (four model families plus "Other"); the
smallest step in that table is 1.24, and a sixth band would fall below the 1.2
floor, which is the honest cost of spreading. **Saturation moves with
lightness**, so two neighbours differ in two dimensions rather than one:
interpolated in HSL between the two muted end literals, the ramp runs
35% → 31% saturation as it lightens in light and 56% → 35% as it darkens in
dark. (HSB, which is what `NSColor` reports and what the "not a grey" test
measures, reads 0.51 → 0.17 in light; in dark it barely moves, 0.49 → 0.52,
because both the chroma and the maximum it divides by fall together.) Held at
the brand value instead, the darker dark-mode steps came out a vivid orange
rather than terracotta.

**The whole hue is muted 25%, at one place.** `PopoverMetrics.saturationReduction`
multiplies the HSL saturation of the four literals above by 0.75 — hue and
lightness untouched — and it is applied where `BandRamp` reads them, which is
the only place they are read: the brand colour is the ramp's own strong end, so
every bar, band, dot, link and warning line is muted by construction and no call
site is tuned by hand. It costs the ramp its distance from grey rather than its
contrast: the brand ink *gains* a little on the light card (4.84 → 4.90) and
loses a little on the dark one (6.15 → 6.05), both still clear of the 4.5:1 AA
floor, while the palest light band drops from 0.22 to 0.17 HSB saturation —
which is why `PopoverColorTests` measures that end at a 0.15 floor instead of
the 0.2 it held before.
`PopoverColorTests` measures all of it, at every stack height the popover can
draw; the literals are not to be nudged by eye in one appearance. The same call
returns the same `NSColor` *instance*, which is not an optimisation: a dynamic
colour compares by identity, and `DailyUsageSeries` is `Equatable` off its
colour, so a freshly built shade would make every band read as changed on every
render.

The hover rule and the hover dots stay on `Color.primary`, since they have to
read against every band. `MenuBarGlyph` is a **template image** — the system
tints it, so it takes no colour of its own.

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
me@example.com                  cached
                                  ← the quota block's section title, the same
                                    shape as "By source" and "By model" below:
                                    title left, tag right. The title names the
                                    account the rows describe, from
                                    `~/.claude.json`'s `oauthAccount` (login
                                    email, else organisation name, else a
                                    short uuid) — only when something on disk
                                    says; an unstamped reading (or no reading at
                                    all) titles the section `Quota` rather than
                                    guessing a name. No other account is ever
                                    listed (see "Only the active account is
                                    shown"). Tooltip distinguishes a named
                                    account from the unstamped fallback.
                                    The trailing tag is `cached` while Claude
                                    Code's own cached reading serves, and
                                    absent once the statusline hook is
                                    installed and has fired — "official" is
                                    never printed, both sources are. No age
                                    and no `· stale` suffix: freshness is not
                                    displayed; an over-threshold reading shows
                                    the terracotta warning line instead. The title
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
                                    gave up went to the bar, now 123 pt wide.
                                    Tooltips and VoiceOver still say "5-hour
                                    window" — nothing competes for width there.
                                    **The bar, the percentage and the trailing
                                    reading all sit flush against each other**
                                    in one zero-spacing stack, so the row's
                                    only real `rowSpacing` is the gap before
                                    the bar: both trailing columns are
                                    right-aligned in columns wider than
                                    anything they hold, so a frame gap on top
                                    of that would only have pushed the
                                    percentage back against the bar.
                                    **The percentage's right edge sits 253 pt
                                    from the row's leading edge**, which is the
                                    number the column widths are fitted to
                                    rather than a consequence of them — it was
                                    242, and moving it right is what the bar's
                                    123 pt (from 104) is made of. The trailing
                                    column is `rowSpacing + countdownColumnWidth`
                                    = 59 pt, wider than any countdown string
                                    needs — the slack is there for the
                                    usage-credits row's `of <limit>` caption,
                                    which shares this same column. Paying for
                                    the bar's growth took **both countdown
                                    placeholders**: `reset pending` → `pending`
                                    (66.5 → 39.0 pt, it was what sized the
                                    column) and `no reading` → `no data`
                                    (51.2 → 36.2), the latter because it shares
                                    its row with the em dash and would have
                                    been left 0.8 pt clear of it. What is left
                                    is genuinely pinned: the label column by
                                    `Sonnet weekly` (76.2 of 80), the percent
                                    column by `99.9%` (34.6 of 42), the
                                    trailing column by the longest countdown
                                    the formatter can make, `11d 11h` (40.9 of
                                    59).
5-hour      ░░░░░░░░░░  —      no data
                                  ← how either of the two rows above renders
                                    while no quota source reports that window
                                    (`QuotaSnapshot.fiveHour == nil`) — after
                                    it rolled over and before the next API
                                    call, and for the no-snapshot-at-all state.
                                    Empty track, em dash, "no data": never
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
Usage credits ▨▨░░░░░░ 0%  of €33.00
                                  ← org usage credits, from `utilization.spend`
                                    cross-checked against `extra_usage`. Only
                                    when credits are actually on — no credits
                                    means no row at all, no placeholder, no
                                    error. Hatched fill, because it measures
                                    money against a monthly cap rather than a
                                    rate-limit window. The row shares the same
                                    percent and trailing-value columns every
                                    quota row does: the percentage lands in
                                    `percentColumnWidth`, and the trailing
                                    column carries `of <limit>`
                                    (`creditsLimitCaption`) instead of a
                                    countdown — the monthly cap has no reported
                                    reset. That trailing column is sized to
                                    `of 999,00 €` (57.2 pt at
                                    ``captionValueFont``), the widest
                                    three-digit, two-decimal limit in the
                                    widest locale this formats; a four-digit
                                    limit truncates. The bar's own accessibility
                                    reading is hidden, since the percent `Text`
                                    beside it already states it. The tooltip
                                    states the amount actually spent in full —
                                    it is nowhere on the row itself — and names
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
<staleness warning, terracotta>   ← and after those, the staleness warning or,
                                    with no snapshot at all, the "no source yet"
                                    / just-cleared-cache line.

By source
3M ┤
2M ┤ ▁▂▅▃▂▆█▅▃▂▄▆█▃▂▄▅█▃▂▁▂▄▅█▆▃▂▁▃
1M ┤
   ┼──┬───────┬───────┬───────┬────
   16. Aug. 23. Aug. 30. Aug. 6. Sept.
Last 30 days    Estimated cost          Tokens
● CLI                   $24.51           14.9M
● VS Code                $5.77            3.5M
● SDK/agents            $41.82           25.3M
  Total                 $72.10           43.7M
      hovered: the caption reads `6. Sept.` and every number in the table is
      that day's; the chart draws a rule and a dot per band edge
                                  ← the first of two **symmetric blocks**: a
                                    stacked daily area chart of the last 30
                                    days, one band per entrypoint, and a table
                                    of the same window's numbers under it.

                                    **One window, one hover rule, for every
                                    local number in the popover.** That is the
                                    whole reorganisation. This section used to
                                    caption a 30-day chart with five-hour
                                    counts, "Costs by model" was tagged
                                    `fixed 24h`, and "Estimated cost" ended in a
                                    `Today` row — four windows on one card, three
                                    of which had to be labelled to be readable
                                    at all. Now every figure below the quota
                                    bars is the same thirty days, or the one day
                                    under the pointer (or the one day the
                                    `Latest day` preference rests on — see
                                    "Settings"), and the caption row says which.

                                    **Two blocks answer two questions**: where
                                    do the tokens come from, and where does the
                                    money go. Same shape twice on purpose — same
                                    chart type, same columns in the same places,
                                    same row order, same stack order, same
                                    hover — so the second costs no reading
                                    effort once the first is
                                    understood, and the two `Total` rows can be
                                    compared straight down the card. They are
                                    two splits of one ``DailyUsageHistory``, so
                                    those totals are the same number by
                                    construction, and a test says so.

                                    The bands are ``DailyUsageSeries``:
                                    `sources(from:)` here, `models(from:)`
                                    below, both taking
                                    ``PopoverMetrics.chartBandColor(_:of:)`` by
                                    row position *and* row count. One hue,
                                    shades of it spread across the whole ramp —
                                    never several colours: see "Colour". Bands
                                    are `.monotone`, never `.catmullRom`: a
                                    spline through spiky daily counts
                                    overshoots, and on a stack an overshoot dips
                                    below the band underneath, drawing usage
                                    that never happened.

                                    **The stack is the table upside down.** Row
                                    one is the *top* band, the last row the
                                    bottom one. A table reads downwards from its
                                    first row and a stack reads downwards from
                                    its top band; with the first band at the
                                    bottom the two sequences were mirror images
                                    and row one pointed at the band furthest
                                    from it. The tables kept display order (CLI
                                    first, `Total` last) and the *stack* flipped
                                    — Swift Charts stacks in series order, so
                                    ``DailyUsageChart/stackOrder`` reverses what
                                    it feeds the marks and the
                                    `chartForegroundStyleScale` domain, and
                                    `stackTops(at:)` climbs in that same order
                                    or every hover dot but the topmost lands on
                                    a boundary that isn't there.

                                    **Each band also strokes its own cumulative
                                    top edge**, 1 pt of its own ink at the same
                                    opacity as the fill. Fills alone leave a
                                    seam: two stacked `AreaMark`s are two
                                    anti-aliased paths, and at a shared boundary
                                    the lower covers the edge pixel by some
                                    fraction *a* and the upper by the rest, so
                                    compositing them in that order leaves
                                    *a(1-a)* of the card visible — a quarter of
                                    it at a half-covered pixel, which on the
                                    dark popover is a dark, ragged hairline
                                    along every edge. ``PopoverChartAlignmentTests``
                                    renders the whole card and asserts no pixel
                                    *between* two bands is darker than the
                                    palest shade the ramp can paint; without the
                                    stroke, 341 of them are. It has to be the
                                    whole popover: an isolated chart at these
                                    sizes composites cleanly and shows no seam
                                    at all.

                                    **Every entrypoint is always listed**, at 0
                                    if need be — a silent source keeps a band and
                                    a row rather than vanishing, because "VS
                                    Code: 0" is a reading about a tool the user
                                    either uses or doesn't. The model split
                                    below does the opposite and lists only the
                                    families the window holds; the asymmetry
                                    follows the data (``bySource`` is dense over
                                    `Entrypoint.allCases`, ``byModelFamily``
                                    is not), and a zero row for a model this
                                    account never touched would say nothing.

                                    A window holding usage this version doesn't
                                    recognise — an unknown `entrypoint` here, an
                                    unknown model ID below — grows an extra band,
                                    **"Other", last, i.e. the bottom of the
                                    stack**, so the bands sum to the day's
                                    total. Only when there is such usage: a
                                    bucket that can appear between two polls
                                    goes at the end so it never shuffles the
                                    named bands beside it. It is a real row
                                    now, with a real number in both columns —
                                    the `—` it used to read at rest was an
                                    artefact of the five-hour breakdown dropping
                                    those events, and that breakdown is gone.

                                    **The table.** A caption row, one row per
                                    band in display order — first row, top band
                                    — and a `Total`.

                                    - The **caption** is `Last 30 days` at rest
                                      (counted off the history — a Mac with
                                      younger logs charts fewer days and the
                                      caption says so) and the hovered day's
                                      date while the pointer is in *this
                                      block's* chart. Swapping it is the whole
                                      hover disclosure: the caption already
                                      claimed which window the numbers are for,
                                      so changing it says they changed meaning.
                                      No floating tooltip over a 72 pt plot, and
                                      no second styling vocabulary. With the
                                      `Latest day` preference set (see
                                      "Settings") the resting caption is a date
                                      too — the table is then showing one day,
                                      and `Last 30 days` over one day's figures
                                      would simply be wrong.
                                    - **Cost first, tokens second.** The two
                                      value columns used to run the other way.
                                      Money is what a reader of this card comes
                                      for and the wider column of the two, so
                                      ending the rows on the narrow one leaves
                                      the slack beside the labels, which is
                                      where a sparkline at the head of a table
                                      would have to go. One order for the
                                      caption row, the value rows and VoiceOver
                                      — `DailyUsageTable.columnOrder`, which is
                                      also what carries each column's heading,
                                      width and ink, so the three can't drift.
                                    - The **column headings**, `Estimated cost`
                                      and `Tokens`, sit over the two value
                                      columns. They are what let the token
                                      column drop the `tok` suffix every cell
                                      used to carry: said once instead of once
                                      per row, which is 50 pt back
                                      (98 → 48 pt, measured against `298.5M` at
                                      41.0 pt). **"Estimated" is spelled out**,
                                      not `Est.` — it is the word doing the
                                      qualifying, a stacked area invites reading
                                      what is under it as a bill, and this is a
                                      local estimate from published per-token
                                      prices: on a subscription, spend that was
                                      never charged. It didn't fit the old
                                      76 pt column, so the column widened to 74
                                      pt against the heading's own 71.7 pt
                                      rather than the word shrinking. There was
                                      room: dot, widest label (`SDK/agents`,
                                      61.4 pt) and both columns come to 209 of
                                      the 312 pt content width.
                                    - A **dot in the band's own shade** ties each
                                      row to its area in the plot, at full
                                      strength where the plot paints the band at
                                      85% to let the gridlines through — a 6 pt
                                      circle has nothing behind it to show. The
                                      `Total` row has none — it is the stack's
                                      outline, not a band in it — but keeps the
                                      dot's width, so every label starts at the
                                      same x.
                                    - The **`Total` is summed from
                                      ``DailyUsageHistory.total``**, not from the
                                      rows above it. Adding the rows up would
                                      make the total agree with itself no matter
                                      what the split dropped; summing the
                                      history's own total means a dropped band
                                      shows as a mismatch. That is exactly the
                                      bug the "Other" band was added to fix.
                                    - Values are ``[DailyUsagePoint].summed()``
                                      over the window at rest, the hovered day's
                                      point while hovering — or the newest day's
                                      at rest under the `Latest day` preference,
                                      which is the same code path with the index
                                      coming from the setting instead of the
                                      pointer. No second pass over the corpus
                                      any of those ways: the points the chart is
                                      already drawing are what gets folded.

                                    **Hovering one block changes only that
                                    block.** Two `@State` days in `PopoverView`,
                                    not one — the charts share an x-axis, but a
                                    table rewriting itself while the pointer is
                                    in the *other* block's chart is a surprise.

By model
$6 ┤
$4 ┤ ▁▂▅▃▂▆█▅▃▂▄▆█▃▂▄▅█▃▂▁▂▄▅█▆▃▂▁▃
$2 ┤
   ┼──┬───────┬───────┬───────┬────
   16. Aug. 23. Aug. 30. Aug. 6. Sept.
Last 30 days    Estimated cost          Tokens
● Sonnet                $33.17           20.1M
● Opus                  $24.51           14.9M
● Haiku                  $7.93            4.8M
● Fable                  $6.49            3.9M
  Total                 $72.10           43.7M
78% cache reads — billed at 1/10 the input rate
                                  ← the second block: the same chart over the
                                    same days, stacking **estimated cost** per
                                    model family instead of tokens per source.

                                    **The top edge of this stack is the old
                                    "Estimated cost" line.** Literally: that
                                    section drew one series of
                                    `total[i].estimatedCostUSD`, which is what
                                    these bands sum to. So the section and its
                                    `LineMark` chart are gone rather than kept
                                    alongside — the same curve now also says
                                    which models are under it, at the price of
                                    nothing. The band ramp's first shade was
                                    that line's ink, and since the stack was
                                    flipped that shade is the *top* band — so
                                    the curve the eye follows is drawn in
                                    exactly the old line's colour, right down to
                                    the 1 pt stroke closing its edge.

                                    **Deliberately a per-model chart**, which an
                                    earlier round recorded as settled the other
                                    way. It lost then on two counts: five bands
                                    against a palette that had three shades, and
                                    sitting above rows tagged `fixed 24h`, which
                                    would have sharpened a window ambiguity the
                                    tag only papered over. Both are gone — the
                                    ramp spreads however many bands there are
                                    across its whole range (see "Colour"), and
                                    there is no second window left to be
                                    ambiguous about.

                                    **Today's spend is hover-only now**, by
                                    decision. The `Today` row was the popover's
                                    last fixed reading, and keeping it would have
                                    meant keeping a second window and a second
                                    rule for one figure that the rightmost day of
                                    the chart already draws — hover it and the
                                    caption says `today's date` with the split
                                    across models beside it, which is strictly
                                    more than the row gave. `AppModel`'s
                                    `estimatedCostToday` went with it.

                                    The **cache-read note** is the one thing only
                                    this block carries, and the one asymmetry
                                    between the two. It qualifies a token total
                                    that replayed context dominates, and this is
                                    the block a reader is most likely to take for
                                    "what the real work cost". It is computed
                                    from whatever the table is currently showing,
                                    so hovering restates the share for that day
                                    rather than leaving a thirty-day percentage
                                    under one day's numbers. Only above
                                    ``DisplayFormat.cacheReadNoteThreshold``.

Both blocks, mechanically
                                  ← everything below is true of either chart;
                                    one implementation
                                    (``DailyUsageChart`` + ``DailyUsageMetric``)
                                    draws both, so it is one description rather
                                    than two that drift. The metric decides
                                    exactly three things: which field of a
                                    ``DailyUsagePoint`` is read, which axis
                                    formatter spells it, and what VoiceOver
                                    calls it.

                                    **No window tag** opposite either title,
                                    unlike the quota block: the x-axis is dated,
                                    so it already says how far back the chart
                                    reaches and that it ends today, and the
                                    table's caption says the same in words for
                                    the numbers. A Mac with no local history at
                                    all gets `No local usage yet` instead of a
                                    flat line through zero.

                                    **Both axes are drawn, sparsely.** Without a
                                    y-axis the bands show shape but no magnitude,
                                    and without dated x-ticks a spike can't be
                                    tied to a day — but thirty dated labels
                                    across a 340 pt popover would be mush, so it
                                    is one label a week and three or four round
                                    values up the y. The y-axis draws
                                    **horizontal lines but no ticks** — the line
                                    already reaches the label, and a stub in
                                    front of it only thickens the left margin.
                                    The lines are `RuleMark`s spanning the first
                                    day to the last, not `AxisGridLine`s: a
                                    gridline spans the whole plot, gutter
                                    included, so it overhangs the data it is
                                    there to be read against.

                                    **They are drawn behind the bands**, which
                                    is why the bands are painted at
                                    ``PopoverMetrics.chartBandOpacity`` (0.85)
                                    rather than opaque: a gridline the stack
                                    cuts off can only be followed in the empty
                                    region above the tallest day, and a reader
                                    taking a value off a spike is reading
                                    exactly where the stack is. At 0.85 the line
                                    reads faintly through a band without
                                    competing with it, and the ramp's steps —
                                    every one of them measured against an opaque
                                    card — still hold. The hover rule and dots
                                    stay in *front* and stay `Color.primary`.
                                    **X-ticks stop four
                                    days short of the right edge**: a label
                                    starts at its tick, runs to the right of it,
                                    and is truncated at the chart's trailing
                                    bound, so a tick any closer renders as `1…`
                                    no matter how the plot is inset (tried:
                                    padding the chart, then padding the plot area
                                    — neither helps, the label has nowhere to
                                    sit). Nothing is lost by it, since the right
                                    edge of a trailing window is always today.

                                    Y labels come from
                                    ``DisplayFormat.tokenAxisLabels`` and
                                    ``costAxisLabels``, which give a column **one
                                    unit and one decimal count**: `$1.5k / $1.0k
                                    / $0.5k`, never `$1.5k / $1k / $500`, which
                                    makes the eye convert a label before the
                                    steps look even. Money keeps two decimals or
                                    none (`$2.50`, never `$2.5`); `k` keeps one,
                                    the way `compactCost` does. **Zero goes
                                    unlabelled** on both: they scale from zero, so
                                    the bottom line is zero by construction and
                                    the label only restates it in the narrowest
                                    column the popover has.

                                    **Both plots start at the same x**, because
                                    the y-labels of both are set in one column,
                                    as wide as the widest label either chart is
                                    about to draw (`chartYLabelWidth`, measured
                                    per render from `naturalYLabelWidth`). Left
                                    to itself a chart starts its plot where its
                                    own widest label ends, and `2G` is not `$2.50`
                                    wide — so two stacked plots taking the same
                                    x-ticks disagreed about where `16. Aug.` was.
                                    Measured, not reserved: a constant wide
                                    enough for every label the formatters can
                                    produce (`$12.5k`) cost a measured 19 pt of
                                    plot on an ordinary `$6` day, and what the
                                    axis shows is decided by data.

                                    Measuring means knowing the strings, which is
                                    why **both charts pick their own y-values**
                                    (``PopoverChartAxis.yValues``) instead of
                                    leaving them `.automatic`: the first of
                                    1, 2, 2.5, 5 × 10ⁿ that is at least
                                    `max / chartYAxisTickCount`, with the domain
                                    rounded up to a multiple of it. That is what
                                    Swift Charts was choosing anyway for spend
                                    (`$0`…`$6` in twos over a $5.20 day); the
                                    token axis lands one step finer than it did.
                                    The other two routes were tried and don't
                                    work: `ChartProxy` answers for the scale but
                                    not for the labels, and a `PreferenceKey` set
                                    inside `AxisValueLabel` never leaves the
                                    `Chart` — measured, it arrives as zero.

                                    The plot carries a small margin above and
                                    below — it is the only element in the popover
                                    that is a picture rather than a row of text,
                                    and flush against the title and the table it
                                    reads as part of them. Vertical only: it
                                    spans the full content width like every other
                                    row, so a sideways inset would pull its axis
                                    out of that alignment.

                                    **Hovering** draws a rule on the nearest day
                                    and a dot on each band's top edge —
                                    cumulative sums taken in ``stackOrder``,
                                    i.e. up from the last table row, since that
                                    is the order the areas are stacked in, and
                                    none for a band that did nothing that day,
                                    whose edge is its neighbour's. Every dot is
                                    plain primary ink rather than its own band's:
                                    a dot has to read against whichever band it
                                    lands on, and the palest shade sits at about
                                    1.8:1 against the card. They are markers, not
                                    more data — which is also why they are the
                                    one thing in these charts that is not
                                    terracotta. Two dots still merge where a band
                                    is thin — about 330k tokens of a 4M axis —
                                    which is the cost of asking a stacked chart
                                    for a per-band readout.

                                    Both charts share ``PopoverChartHover``: a
                                    `.chartOverlay` converts the pointer's x
                                    through the chart proxy and snaps to the
                                    nearest plotted midnight. Snapping is the
                                    mechanism, not a refinement — 30 days over a
                                    ~250 pt plot is about 8 pt a day, so pointing
                                    at a day exactly is not available. Not
                                    `.chartXSelection`, which answers to click and
                                    drag on macOS rather than to hover.

                                    **Marks, rule and ticks share one x.** Every
                                    mark is plotted on a plain `Date`, never
                                    `unit: .day`: binning a date draws the mark at
                                    the *centre* of its bin, so the bands, the
                                    rule and the dots all sat half a day — a
                                    measured 4 pt — right of the tick naming the
                                    day they were on.
                                    ``PopoverChartAlignmentTests`` renders both
                                    charts and measures the rule against the tick,
                                    which is the only way to see this at all:
                                    `ChartProxy` answers for the scale, not for
                                    where a mark landed, and every other test
                                    passed throughout.

                                    Midnights on a plain scale land on the plot's
                                    own edges, so the scale keeps a 3 pt gutter at
                                    each end (`chartXScale(range: .plotDimension(…))`,
                                    not chart padding, which would pull the axis
                                    out of the popover's alignment). Without it
                                    half the hover dot on *today* — the day most
                                    likely to be hovered — falls outside the plot.

                                    **Hover moves nothing but the highlight.**
                                    Both marks carry values already plotted, so no
                                    scale widens, and the hovered day is never
                                    added to the x-axis — it belongs in the
                                    caption. This is not cosmetic: a y-scale that
                                    grew under a stationary pointer would redraw
                                    the bands beneath it and drag the plot's
                                    leading edge with it, changing the day the
                                    pointer was on under the user's own hand. The
                                    hovered day is also re-resolved against the
                                    *current* history on every render, so a poll —
                                    or midnight sliding the window — drops the
                                    readout back to resting instead of stranding a
                                    number from a window that has moved.

                                    Drawn axes still don't make a chart legible to
                                    VoiceOver, so each carries a real
                                    `AXChartDescriptor` — one series per band, one
                                    point per day, y-axis reaching the tallest
                                    *stacked* day, titled from the metric
                                    (`Estimated cost by model, last 30 days`).
                                    Hover is mouse-only and is not the only path
                                    to a per-day number; these are the accessible
                                    route. Both value formatters guard the
                                    framework's own probe values: the token one
                                    clamps to 2^53, not to `Double(Int.max)` (which
                                    rounds up to 2^63 and traps), and the cost one
                                    returns `unknown` past a trillion dollars
                                    rather than a 300-digit `%f` label that
                                    renders. Both were live failures.

                                    **Cost of the restructure: 48 pt.** The
                                    rendered showcase popover went from 675 to
                                    723 pt tall (340 wide). A whole chart and its
                                    row came out; two tables went in. Roughly
                                    height-neutral was the aim and 7% is what it
                                    came to — worth it for one window instead of
                                    four.

Refresh   Clear Quota Cache   Settings        Quit
                                  ← "Clear Quota Cache" deletes the statusline
                                    cache and re-polls. It lives in the footer
                                    with the other actions rather than under the
                                    quota rows it acts on, where it floated
                                    at the end of the quota block and read as
                                    though it belonged to its last row.
```

The source tag names the source only when it is the backup: `cached` (Claude
Code's own cached reading, the zero-setup default) versus nothing at all (a
statusline capture, once that hook is installed). Both are Anthropic's own
numbers, so the word "official" is not printed, and neither the reading's age
nor a "stale" marker is shown — staleness surfaces only as the terracotta
warning line. Settings still spells out the full `QuotaConfidence.displayLabel`. No
estimate fallback: with neither
source reporting, the popover shows an error instead of a number; a
real-but-old reading keeps the last numbers with a terracotta staleness warning.
"Clear Quota Cache" deletes the statusline cache only — the whole per-session
directory plus the legacy single file; `~/.claude.json` is Claude Code's, not
ours — so the bars fall back to the cached-state numbers rather than going
empty. The same clear runs without the button when a poll sees Claude Code
logged in as a different account (see "An account switch clears the
statusline cache on its own" above).

### Settings

Panes: General (launch at login), Display, Refresh (poll interval), Quota source
(the statusline hook), About. Every preference is written through the moment it
changes — there is no Apply button — and read back on the next launch from
`UserDefaults` under a `de.bitgrip.claude-stats.` key. `AppModel` takes the
defaults object as an init parameter, so a test exercises persistence in its own
suite rather than in whatever domain the process happens to have.

- **Display → Default range** (`AppModel.defaultDisplayRange`, a
  `DefaultDisplayRange`): whether the two usage tables rest on `Last 30 days` —
  the window summed, which is how the popover has always opened — or on
  `Latest day`, the newest day the charts plot.
  - **It moves the resting *reading*, not the window that is queried.** Both
    charts still draw all thirty days: a one-day plot is a single point with no
    shape to read, and the hover rule would have nothing left to move over. What
    changes is which index the tables fold their points at, which is the same
    code path hovering already used.
  - **Hover still wins wherever it lands**, so this is a different default and
    not a second mode with its own rules. "Latest" is resolved by position on
    every render, never stored as a date, so midnight sliding the window moves
    the reading along instead of stranding the table on a day that has dropped
    out.
  - An unrecognised stored value — an absent key, or one written by a version
    that spelled the cases differently — falls back to `Last 30 days` rather
    than leaving the popover with no setting at all.

## Tech / release

- Native Swift/SwiftUI, Swift Package Manager. No Electron, no Tauri.
- Release process (`make_app.sh` + `make_release.sh`): hand-rolled
  `Info.plist`, `actool` for the asset catalog, ad-hoc `codesign --sign -`
  (unsigned, no notarization — users click through Gatekeeper once), zip +
  sha256, `gh release create`. Direct-download distribution, not the Mac App
  Store (App Sandbox would need security-scoped bookmarks just to read
  `~/.claude`, real friction for no benefit here).
- Self-update-check polls the GitHub releases API (`UpdateChecker.swift`).
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

The same file renders one thing the README doesn't ship: the popover with a day
hovered, under its own gate, for looking at rather than committing.

    CLAUDE_STATS_RENDER_HOVER=/tmp/hover swift test --filter testRenderHoverPreviews

It earns its keep because hover is unreachable offscreen and the tables
*change content* under it — every number and the caption swap together — so a
column that truncates in that state alone is invisible to a unit test. That is
how the truncated `CLI 842.…` row of the legend this replaced was caught.
`PopoverView` takes its two hovered days as init parameters purely so this (and
a SwiftUI preview) can seed them.

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
  what is now the "By source" block had a `.pickerStyle(.segmented)` `Picker`, i.e. an
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
  `PopoverMetrics.brandColor` and every shade of `chartBandColor(_:of:)` are
  dynamic `NSColor(name:)`s resolved against the *AppKit* appearance, not SwiftUI's
  `colorScheme`: without it the promo link and the chart bands paint one
  theme's terracotta onto the other theme's card. Any other `NSColor`-backed
  value in the tree has the same dependency.

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
