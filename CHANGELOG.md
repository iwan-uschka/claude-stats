# Changelog

## [Unreleased]

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
