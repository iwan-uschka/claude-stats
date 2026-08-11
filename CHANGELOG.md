# Changelog

## [Unreleased]

### Added
- Update check against the GitHub releases API: silent once on launch, plus an
  on-demand "Check for Updates…" button in Settings → About. Only https
  github.com release URLs are opened.
- Settings window: quota poll interval picker (30s / 1m / 2m / 5m, persisted in UserDefaults), active quota-source tier, and "Reveal Script in Finder" for the statusline hook script
- The statusline cache script ships as a bundled app resource, so it's reachable from a downloaded release rather than a repo checkout only

### Changed
- The live-quota poll throttle is user-configurable (default 60s) instead of a fixed 60-second minimum

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
