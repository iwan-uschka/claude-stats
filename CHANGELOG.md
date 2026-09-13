# Changelog

## [Unreleased]

### Added
- Quota readings are now grouped per Anthropic account, with other accounts'
  readings shown below the current one.

### Changed
- Quota percentages from 99% up to 100% show one decimal place (`99.4%`), so
  "almost done" no longer reads as "done".
- The popover's "Plan" and "Burn rate" lines are gone — the plan tier was
  guessed from local history, and the burn rate said little the window bars
  don't.
- The cache-read note now reads `81% cache reads` instead of restating the two
  raw token counts.
- Accounts are labelled with the login email rather than the organisation name,
  which for a personal account is just the email with `'s Organization`
  appended.
- Other accounts' readings are collapsed under one row per account, closed by
  default, marked with a cross icon — and the active account's title gets a
  checkmark while any of them are listed.
- The quota block now has a title row like "This Mac" and "By model": the
  account name on the left, the freshness tag on the right instead of on its
  own line under the bars.
- Promo notices moved below the quota bars instead of between them.
- "Clear Quota Cache" moved from the quota section into the footer, next to
  Refresh and Settings.
- Reset countdowns show the bare time (`2h 14m`), without "resets in"; the
  quota bars grew by the width that freed up.
- An inactive account's rows open from a click anywhere on its row, which now
  carries a trailing caret showing what a click will do (`⌄` reveal, `⌃`
  collapse) and is set in the active account title's font, one shade dimmer.
- The quota rows' labels lost the word "window" and the weekly rows their
  parentheses (`5-hour`, `Sonnet weekly`); the bars took the width, growing
  from 80 to 100 pt. Tooltips and VoiceOver still spell out "5-hour window".
- "This Mac" is a table now: one row per source with the 5h, 24h and 7d token
  counts side by side, instead of one window at a time behind a 5h/24h/7d
  picker with a bar per row. The counts read in the same ink as their labels,
  and hovering one still shows that window's full token split.
- The freshness tag is gone: no `official`, no age, no `stale` suffix. A bare
  `cached` marker appears next to the quota title while Claude Code's own
  cached reading serves; a stale reading still shows the orange warning line.

### Fixed
- Switching accounts no longer mixes in a stale reading from the previous
  login. Existing installs need to update the statusline script (Settings →
  Quota source → Update Script) to get per-account stamping; until then they
  fall back to Claude Code's own cached reading.

## [0.9.9] - 2026-09-13

### Changed
- The 5-hour and 7-day rows now show `—` and **no reading** instead of 0% when
  no quota source currently reports that window — the normal state just after a
  window rolls over and before the next API call, since Claude Code drops a
  window from its payloads once it has reset. The matching bar in the menu bar
  glyph is drawn empty and its accessibility text says the window is unknown
  rather than 0%, and the popover row's own bar is hidden from VoiceOver for
  the same case so it doesn't announce a "0%" nobody reported.

### Fixed
- The quota bars no longer show another session's stale numbers — or a
  confident 0% — when several Claude Code sessions are open. Every running
  session feeds the statusline hook the rate limits *its own* last API response
  carried, and an idle session re-renders its status line on timers alone, so
  the single shared cache file meant last writer wins: hours-old percentages,
  stamped as captured just now. Worse, Claude Code drops a window from the
  payload once that window has reset, and the missing one was read back as 0%
  used (observed: 0% / 25% on screen against a real 68% / 44%). The hook now
  writes one file per session, and the app merges them per window — readings
  whose reset has passed are ignored, the latest window wins, and within one
  window the highest percentage wins, since usage inside a window never goes
  down. Session files nobody has written in a week are cleaned up as the app
  reads.
  - **Existing installs keep running the old script until it is updated:**
    Settings → Quota source will offer **Update Script** (or re-run **Set Up
    Automatically**). Until then the app reads the old single file, which it
    still accepts, so nothing breaks in the meantime.

## [0.9.8] - 2026-09-11

### Fixed
- Clicking the 5h/24h/7d switcher in the popover's "This Mac" section no longer
  stalls the UI for up to a second. Selecting a window used to trigger a
  main-thread re-sum of every `UsageEvent` in the newly selected window, which
  blocked the segmented control's own selection animation. All three windows are
  now summed together whenever the underlying data can actually change (popover
  open, manual Refresh, new session activity), so switching windows is a
  dictionary lookup and recomputes nothing. All three windows are summed in one
  pass over the widest window's events, and the FSEvents rebuild path no longer
  reloads them twice per rebuild — so this costs one walk per real refresh, not
  three.

## [0.9.7] - 2026-08-31

### Added
- Organisation usage credits. Claude Code's cached usage payload grew a `spend`
  object (and a sibling `extra_usage` one) carrying the extra-usage spend as
  actual money, and accounts that have credits enabled now get a fourth row in
  the popover — `Usage credits ▨▨░░░░ €0.00 of €33.00` — plus a fourth, hatched
  bar in the menu bar glyph. The hatch marks it as a different kind of
  measurement: money against a monthly cap, not a rate-limit window. Money is
  formatted from the payload's own currency and decimal places, so an account
  billed in a zero-decimal currency reads correctly rather than 100× too small,
  and the value column shows the amounts rather than a percentage — 0% of an
  unstated budget says nothing. The cap is monthly and the payload reports no
  reset time for it, so the countdown column stays empty.
- Credits are transient, and their absence is the normal state, not an error:
  no credits means no row and no fourth bar — no placeholder, no warning,
  nothing in the error list — and the glyph goes back to three bars. Every
  unmet condition in the payload (credits switched off, a stale `spend` an
  admin has since disabled, a missing percentage, two currencies that disagree)
  produces no row rather than a half-filled one. The one thing ever said about
  their absence is the payload's own `disabled_reason`, as a tooltip on the
  freshness line.
- Per-model weekly limits. Claude Code's cached usage payload carries scoped
  weekly sub-limits alongside the two account-wide windows
  (`utilization.limits[]`), and each one now gets its own popover row —
  `Fable (weekly)`, labelled straight from the payload, so a model that turns
  up tomorrow needs no update. The menu bar glyph gets a third bar for the
  highest of them, always drawn — same as the other two, empty when there's
  nothing to show. Entirely as reported: 0% shows as 0%, no countdown appears
  when the payload gives no reset time, and neither the row nor its tooltip
  claims what the percentage is a share of — that is undocumented, and
  guessing at a denominator would be inventing a number.

### Changed
- The README's images are now rendered from the app's own views instead of
  hand-captured, in a light and a dark variant each:
  `assets/screenshot-popover-{light,dark}.png` (menu bar strip, the glyph in
  it, and the popover below with its tail pointing back up at it) and
  `assets/menu-bar-glyph-{light,dark}.png` (the glyph alone, transparent).
  `bash scripts/render-readme-assets.sh` draws all four from
  `AppModel.previewShowcase(now:)` — one mock fixture shared with a `#Preview`,
  on a pinned clock, so the output is byte-stable and a re-render on an
  unchanged UI leaves the tree clean. Replaces `scripts/build-screenshot.sh`
  and the four hand-screenshotted layers under
  `assets/source/screenshot-popover/`, whose icon layer AGENTS.md described as
  needing "eyes on the pixels" every time; also drops ImageMagick as a tooling
  dependency.
- The promo notice's link now uses Claude's own terracotta instead of the
  system accent colour, which followed the OS accent and read as an unrelated
  system affordance rather than Claude's own promo.
- Promo notices sit in a little more vertical space, and the popover's shared
  label column widened from 84 pt to 92 pt to fit per-model weekly row labels
  without wrapping.
- A stale quota source no longer means empty bars on a cold start: the old
  numbers it did have are shown with the orange staleness warning instead of
  nothing, and the warning's advice now matches the source — "open a terminal"
  applies to the statusline hook, not to Claude Code's own usage cache.
- Claude Code's cached reading is treated as stale after 60 minutes rather than
  30; `fetchedAtMs` was measured unmoved for 3.7+ hours during active sessions.

## [0.9.6] - 2026-08-30

### Changed
- The quota bars no longer need the statusline hook installed. Claude Code
  caches the same account-wide rate-limit numbers into its own state file
  (`cachedUsageUtilization` in `~/.claude.json`), and that is now the primary
  source — run Claude Code once and send a prompt and the percentages appear,
  tagged `official (cached)`. The hook stays as an opt-in freshness booster: install
  it and the tag flips to `official`, reporting seconds after Claude Code sees
  the numbers instead of on its several-minute cache cadence. Whichever source
  has the newer reading wins, so one going quiet is invisible, and an error
  only appears when neither has anything. Settings → Quota source is reworded
  accordingly, from required setup to optional.
- "Clear Quota Cache" now only deletes the statusline cache — `~/.claude.json`
  is Claude Code's own live state file, not ours to touch — so the bars fall
  back to the cached reading instead of going empty.

## [0.9.5] - 2026-08-29

### Added
- Promo notices from Claude Code's own state file (`~/.claude.json`) now render
  under the quota bar they apply to — e.g. "+50% weekly limits promo through
  Aug 31 · clau.de/cc-50-promo" under the 7-day bar — with the bare URL
  clickable and a tooltip disclosing where it actually goes. Best-effort by
  design: a missing, unreadable, malformed or stale notice is silently no
  notice, never an error line. Hidden once the cached flag is more than 7 days
  old.

## [0.9.4] - 2026-08-19

### Added
- "By model" rows, "This Mac" rows, and the burn rate now explain their token
  totals: a tooltip with the four-way split (`in · out · cache write · cache
  read`), plus a muted caption line when cache reads are more than half the
  total ("453M of 496M is cache reads — billed at 1/10 the input rate"). The
  headline number is unchanged — raw tokens — it just no longer reads as if
  it were all new work.

## [0.9.3] - 2026-08-18

### Added
- "Clear Quota Cache" button in the popover's quota section: deletes the
  statusline cache file and re-polls, so the next percentage comes from Claude
  Code's own next statusline render. Escape hatch for a number that looks stuck
  or wrong — the cache is one global file, so several concurrent Claude Code
  sessions can overwrite it with each other's older readings, and "Refresh"
  only re-reads that same file. The empty state shows a notice rather than an
  error banner until a fresh reading lands.

## [0.9.2] - 2026-08-18

### Changed
- Menu bar glyph: mark size 14 → 11.9 (15% smaller), and bars now stretch to
  the full glyph height instead of a hardcoded 13pt, matching Stats' bar
  proportions.

## [0.9.1] - 2026-08-15

### Fixed
- Release builds crashed on launch with a Swift runtime exclusivity trap in
  `SessionCorpusIndex.rebuild()` (regression introduced by 0.9.0's signpost
  instrumentation).

## [0.9.0] - 2026-08-15

### Added
- `os_signpost` instrumentation around `rebuild()`'s phases (`StatPass`,
  `Reparse`, `Fold`, `SnapshotAssembly`) for perf triage — record with
  `xcrun xctrace record --template 'os_signpost' --launch ClaudeStats.app`,
  or query the persisted unified log directly:
  `log show --predicate 'subsystem == "de.bitgrip.claude-stats" and category == "RebuildPerf"' --style compact --last 7d`.

## [0.8.0] - 2026-08-15

### Fixed
- Session-log refreshes now reparse only the files that actually changed
  (stat-based mtime/size diff) instead of the entire multi-GB corpus on every
  write, and bursts of watcher batches collapse into at most one queued
  rebuild. On a 1.9 GB corpus this drops CPU during active Claude Code
  sessions from ~100% of a core to ~17%, and to ~0% when idle.
- Events older than the longest query window (8 days) are folded into
  per-model totals instead of being kept in memory individually, shrinking the
  app's resident memory from hundreds of MB to a size proportional to the last
  8 days of activity. All-time per-model totals (`modelUsage(last24h: false)`)
  stay exact across the fold.

## [0.7.0] - 2026-08-13

### Added
- The app now checks for updates automatically every 24 hours while running, not just once at launch.

### Changed
- Automatic update checks are throttled to once per 24 hours across launches (persisted), so
  relaunching within that window no longer triggers a fresh check. An explicit
  "Check for Updates…" always runs but no longer resets the 24-hour clock.

## [0.6.0] - 2026-08-13

### Fixed
- Quota errors are shown as sentences instead of raw enum case names.
- An installed-but-quiet hook (stale cache) now keeps the last reading with an
  orange staleness warning instead of blanking the bars with a red error.
- Removing the hook deletes the statusline cache and re-polls immediately,
  instead of leaving the last reading on screen for up to 10 minutes.
- The uninstall confirmation's "Before" text shows the real current
  `statusLine` command.
- `settings.json` writes no longer fail when the file is a symlink into
  another directory (dotfile-managed / synced setups).

### Removed
- The `experimental` (OAuth `oauth/usage` poll) and `local_estimate`
  (local-log-derived approximation) quota tiers. The statusline hook
  (`official`) is now the only quota source, with no fallback — the popover
  shows an error instead of a number until the hook is installed and has
  fired at least once.

## [0.5.0] - 2026-08-13

### Added
- Settings → Quota source: "Set Up Automatically" installs (and "Remove"
  uninstalls) the `statusLine` hook in `~/.claude/settings.json`, wrapping an
  existing statusline instead of replacing it, after a before/after confirmation
  and a timestamped backup. Only the `statusLine` member's text is rewritten —
  key order, formatting and escaping of every other setting are preserved.

## [0.4.0] - 2026-08-12

### Added
- Dev builds (`swift run` / `swift build`, no `.app` bundle) mark the menu bar
  item with a small orange dot and a "Claude Stats (dev)" tooltip, so a dev
  binary is distinguishable from the installed release when both are running

## [0.3.0] - 2026-08-12

### Added
- Settings → General: "Launch at login" toggle, registering the app bundle
  itself as a login item via `SMAppService.mainApp` (macOS 13+) — no separate
  helper target

## [0.2.0] - 2026-08-11

### Added
- Update check against the GitHub releases API: silent once on launch, plus an
  on-demand "Check for Updates…" button in Settings → About. Only https
  github.com release URLs are opened.
- Settings window: quota poll interval picker (30s / 1m / 2m / 5m, persisted in UserDefaults), active quota-source tier, and "Reveal Script in Finder" for the statusline hook script
- The statusline cache script ships as a bundled app resource, so it's reachable from a downloaded release rather than a repo checkout only

### Changed
- The live-quota poll throttle is user-configurable (default 60s) instead of a fixed 60-second minimum

### Fixed
- The OAuth usage tier (`experimental` confidence) never worked on macOS: the Keychain query combined `kSecReturnData` with `kSecMatchLimitAll` and failed with `errSecParam`, so every install silently fell through to the local-log estimate and no Keychain access prompt was ever shown
- Quota-source fallthroughs are logged instead of silently swallowed, except for the expected "tier not configured" case

## [0.1.0] - 2026-08-02

### Added
- Menu bar status item drawing the Claude mark plus two thin vertical bars for the 5-hour and 7-day quota windows, as a template image so it picks up the menu bar's light/dark, highlighted and background tints automatically
- Popover with per-window usage and reset times, auto-detected plan tier, burn rate, a per-entrypoint (CLI / VS Code / SDK) breakdown across 5h/24h/7d, a per-model token and cost table, and estimated cost today
- Local session-log parsing of `~/.claude/projects/*/*.jsonl` (honouring `$CLAUDE_CONFIG_DIR`): token counts, per-model cost math, burn rate, and an entrypoint breakdown
- Live quota with a `statusline cache → OAuth usage endpoint → local estimate` fallback chain, each tier labelled with its confidence (`official`, `experimental`, `local_estimate`) and freshness in the popover
- Plan tier (Pro / Max5 / Max20) auto-detection from known thresholds with a P90-of-recent-history fallback for custom tiers
- FSEvents-based config directory watching with debouncing and change coalescing, so usage refreshes on write instead of on a poll timer
- App icon generated via `scripts/make_icon.sh`: three generic rounded bars on a neutral background, deliberately not the Claude mark, which stays reserved for the menu bar glyph only
- `make_app.sh` / `make_release.sh`: ad-hoc-signed `ClaudeStats.app` bundle, zipped with a SHA-256 checksum for direct download

### Changed
- Live-quota network polls are throttled to a 60-second minimum interval instead of firing on every refresh
- The file watcher scopes to the `projects/` session-log tree only, so writes to `history.jsonl`, `todos/` and `shell-snapshots/` no longer trigger a full-corpus reparse
- Errors are tracked per subsystem (local stats / breakdown / quota) rather than through one shared slot that could clobber a still-live failure
- Falling back to sample data because `~/.claude` is unreadable is surfaced distinctly from a genuine read error

### Fixed
- The popover no longer anchors ~64pt above the screen on first open: `NSPopover` was sizing against the SwiftUI content's fitting size before `NSHostingController` had laid it out, and never re-anchored once the real size arrived
