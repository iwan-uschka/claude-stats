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
2. **Live account-wide quota % (secondary, `official` confidence, no
   fallback).** Register as (or piggyback on) Claude Code's `statusLine`
   hook — receives `rate_limits.{five_hour,seven_day}.{used_percentage,
   resets_at}` via stdin, but only fires while Claude Code is actively
   rendering a status line in a terminal. Cache to disk, treat as stale after
   ~10 min. This is the only quota source: no live source installed surfaces
   as an error in the popover rather than falling back to an estimate; an
   installed-but-quiet source (stale cache) keeps the last reading on screen
   with an orange staleness warning — see
   `Sources/ClaudeStatsCore/Quota/StatuslineCacheReader.swift`.
   **This tier is account-wide, not machine-wide** — it already reflects AFK
   docker-loop usage automatically, *because* those containers reauthenticate
   as the same Anthropic account (confirmed: no separate API keys). No extra
   plumbing needed for that case.
   - A prior version of this app additionally polled the undocumented
     `oauth/usage` endpoint (`experimental` confidence) and, failing that,
     estimated usage from local token counts against the detected plan's
     budget (`local_estimate` confidence). Both were removed: the app is
     meant to show the account's real rate-limit window, not a guess, so a
     source that can't do that shouldn't silently stand in for one that can.
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
- 2 thin vertical bars, monochrome fixed fill (no color-shift-to-red), no
  text labels — 5-hour window % and 7-day window %. Minimal total width,
  matching Stats' CPU/GPU/RAM glyph but thinner.

Click opens a popover:

```
5-hour window     ▓▓▓▓▓▓░░ 62%     resets in 2h 14m
7-day window       ▓▓▓░░░░░ 31%     resets in 4d 6h
source: official · 40s ago                      ← confidence tag + freshness
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

Freshness tag shows `official` (fresh statusline capture) — the only tier.
No fallback: nothing installed shows as an error; an installed-but-quiet
source (stale cache) keeps the last reading with an orange staleness warning.
After "Clear Quota Cache" the bars go empty and a gray notice (not an error)
explains that the next number comes from Claude Code's own next statusline
render.

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
