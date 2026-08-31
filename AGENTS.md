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
   pricing), burn rate, and a source breakdown via the `entrypoint` field
   already present on each line — confirmed values on this machine: `cli`,
   `claude-vscode`, `sdk-cli` (Agent SDK / subagents / workflows / headless
   `-p` runs). Only sees sessions whose JSONL lives on this Mac's disk.
2. **Live account-wide quota % (secondary, no estimate fallback).** Two
   sources, both carrying Anthropic's own numbers, composed by
   `Sources/ClaudeStatsCore/Quota/FreshestQuotaProvider.swift`: it queries both
   and serves whichever snapshot has the newer `capturedAt`. One source being
   down is invisible; an error only surfaces when **both** fail.
   **This tier is account-wide, not machine-wide** — it already reflects AFK
   docker-loop usage automatically, *because* those containers reauthenticate
   as the same Anthropic account (confirmed: no separate API keys). No extra
   plumbing needed for that case.
   - **`cachedUsageUtilization` (primary, `official (cached)`, zero setup).**
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
         as `usageCreditsDisabledReason` and shown as a tooltip on the freshness
         tag.
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
       - Like `scopedWeekly`, this is `cachedUsageUtilization`-only — the
         statusline payload has no `spend` object — so `FreshestQuotaProvider`
         grafts it onto whichever snapshot wins the freshness compare, via
         `QuotaProviding.currentUsageCredits()`, which bypasses that source's
         staleness gate for the same reason `currentScopedWeekly()` does.
   - **statusline hook (`official`, opt-in, sharper freshness).** Register as
     (or piggyback on) Claude Code's `statusLine` hook — receives
     `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` via stdin,
     but only fires while Claude Code is actively rendering a status line in a
     terminal. Cache to disk, treat as stale after ~10 min — see
     `Sources/ClaudeStatsCore/Quota/StatuslineCacheReader.swift`. This used to
     be the only source, which made its `settings.json` install step a gate on
     the whole tier; it is now a freshness booster (seconds old instead of
     minutes), and the Settings pane says so.
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
     render it under the matching bar — see
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
4. Plan tier (Pro / Max5 / Max20) auto-detected: known thresholds
   (~19k / ~88k / ~220k tokens per 5h window) plus P90 of the last 8 days of
   local history as a fallback for custom/unclear tiers.
5. **Retention window.** `SessionCorpusIndex` keeps individual `UsageEvent`s
   only for the last `defaultRetention` (8 days = `planDetectionHistoryDays`);
   older events fold into per-model `HistoricalModelUsage` totals that only
   `modelUsage(last24h: false)` reads back. Any new per-event query — a new
   `TimeWindow` case, a longer heuristic — must fit inside that window, or
   raise `defaultRetention` first.

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
  empty — there is no narrower, two-bar state.
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
5-hour window     ▓▓▓▓▓▓░░ 62%     resets in 2h 14m
7-day window       ▓▓▓░░░░░ 31%     resets in 4d 6h
+50% weekly limits promo through Aug 31 · clau.de/cc-50-promo
                                  ← Claude Code's own promo notice for this
                                    bar, read from `~/.claude.json`; the bare
                                    URL is clickable. Only when one is cached
                                    and fresh.
Fable (weekly)     ░░░░░░░░  0%
                                  ← one row per `weekly_scoped` entry in the
                                    payload's `limits[]`, labelled from
                                    `scope.model.display_name`. Only when the
                                    payload reports any. 0% shows as 0%; the
                                    countdown column is empty when the entry
                                    has no `resets_at`. The tooltip says it is
                                    Claude Code's own scoped weekly limit and
                                    deliberately claims no denominator for the
                                    percentage.
Usage credits      ▨▨░░░░░░   €0.00 of €33.00
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
source: official (cached) · 4m ago              ← confidence tag + freshness;
                                    `official` (no suffix) once the statusline
                                    hook is installed and has just fired.
                                    Also carries the `disabled_reason` tooltip
                                    when the payload said why there are no
                                    usage credits — there is no credits row to
                                    hang it on, and it is never an error line.
                                  [ Clear Quota Cache ]   ← deletes the
                                    statusline cache and re-polls

Plan: Max20 (auto-detected)
Burn rate: 12.4k tok/hr
10k of 12.4k is cache reads — billed at 1/10 the input rate  ← only when cache
                                    reads are >50% of the total; same line
                                    under the model rows. Hovering a model row
                                    or the burn rate shows the full split.

This Mac               5h   24h   7d
  CLI                   ▓░   ▓▓   ▓▓▓
  VS Code                ░    ▓    ▓▓
  SDK/agents            ▓▓   ▓▓▓  ▓▓▓▓

By model (fixed 24h window, not tied to the 5h/24h/7d toggle above)
  Sonnet   2.1M tok   $3.15
  Opus      180k tok   $2.70
  Haiku     640k tok   $0.19
  Fable      90k tok   $0.08

Est. cost today: $4.82

Refresh   Settings   Quit
```

Freshness tag names the source that won: `official (cached)` (Claude Code's own
cached reading, the zero-setup default) or `official` (a fresh statusline
capture, once that hook is installed). No estimate fallback: with neither
source reporting, the popover shows an error instead of a number; a
real-but-old reading keeps the last numbers with an orange staleness warning.
"Clear Quota Cache" deletes the statusline cache only — `~/.claude.json` is
Claude Code's, not ours — so the bars fall back to the cached-state numbers
rather than going empty.

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

### README screenshot

`assets/screenshot-popover.png` is composited from four same-canvas-size
layers in `assets/source/screenshot-popover/`, not hand-screenshotted as one
image:

- `menu-bar.png` — the blue menu-bar strip, opaque top rows, transparent
  below.
- `icon.png` — the status-item glyph, captured as a rectangular patch
  (own background + glyph) roughly positioned over the menu bar.
- `icon-mask.png` — an alpha mask (opaque = glyph silhouette, transparent
  elsewhere) that replaces `icon.png`'s own alpha at composite time, so
  `icon.png`'s rectangular capture bounds never show as a seam — only the
  glyph shape actually gets drawn onto `menu-bar.png`.
- `popup.png` — the popover body (rows, captions, buttons), transparent
  above where the menu bar shows through.

`bash scripts/build-screenshot.sh` composites them (`menu-bar` → masked
`icon` → `popup`, in that order) and writes `assets/screenshot-popover.png`.
Canvas size is taken from `popup.png`; `menu-bar.png` and `icon.png` are
extended or cropped to match (anchored top-left) — so a taller or shorter
popup capture is a drop-in replacement, no manual resizing needed.

**Not** a drop-in: a new *icon*. A raw icon screenshot (its own background,
no alpha mask, arbitrary size, not positioned on the shared canvas) has to be
trimmed, scaled to match the glyph's existing on-canvas height, positioned,
and turned into an `icon.png` + `icon-mask.png` pair *before* the script can
use it — that conversion needs eyes on the pixels (crop bounds, scale
factor, paste offset), not just a script run.
