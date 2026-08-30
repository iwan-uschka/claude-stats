# claude-stats

Menu bar app for macOS showing live Claude token usage. Sibling to
[exelban/stats](https://github.com/exelban/stats). Built with Swift +
SwiftUI, no external dependencies.

![Popover showing 5-hour/7-day quota, plan tier, burn rate, per-entrypoint and per-model breakdown](assets/screenshot-popover.png)

## Download

Pre-built releases (macOS app bundle, zipped) are available on the
[Releases page](https://github.com/iwan-uschka/claude-stats/releases).

> **Note:** the app is unsigned — right-click → Open on first launch to bypass Gatekeeper.

> **Note:** move the app to `/Applications` before enabling **Settings → General →
> Launch at login** — the login item records the bundle's location, so
> enabling it from `~/Downloads` and moving it afterwards breaks the entry.

## Features

- Menu bar glyph showing 5-hour and 7-day quota usage as two thin bars, tinted for light/dark mode automatically — plus a third bar when Claude Code reports a per-model weekly limit
- Popover with per-window usage and reset countdowns, a row per per-model weekly limit Claude Code reports, auto-detected plan tier (Pro / Max5 / Max20 / custom), and current burn rate
- Per-source breakdown (CLI / VS Code / SDK-agents) across 5h/24h/7d windows, and per-model token/cost totals
- Local session-log parsing (`~/.claude/projects/*/*.jsonl`) — token counts, cost, burn rate always available, no network or credentials needed
- Live 5-hour/7-day quota percentage straight from Claude Code's own cached reading — no setup, no hook to install; the `statusLine` hook is optional and just makes it fresher — see [Quota source](#quota-source)
- Claude Code's own rate-limit promo notices, shown under the bar they apply to, with any link in them clickable
- FSEvents-driven refresh — updates on write, not on a poll timer

Full architecture and data-source design: see [AGENTS.md](AGENTS.md).

## Quota source

**No setup required.** The popover's 5-hour/7-day percentage bars read Claude
Code's own cached rate-limit numbers out of `~/.claude.json`, which it writes
for itself — tagged `official (cached)` in the freshness line. Run Claude Code
once and the bars fill in. Claude Code refreshes that cache on its own
schedule, so a reading can be several minutes old; anything older than 30
minutes is treated as stale.

**Optional: sharper freshness.** Claude Code's `statusLine` feature emits the
same rate-limit data the moment it renders a status line, which is seconds old
rather than minutes — but only if something is registered to receive it, and
this app is a menu bar app, not a shell hook, so a small script bridges the
two. Open **Settings → Quota source** and click **Set Up Automatically**: the
app shows the exact before/after change to `~/.claude/settings.json`, backs the
file up, and only edits the `statusLine` key (an existing statusline is
wrapped, not replaced). **Remove** reverts it. Prefer doing it yourself?
**Reveal Script in Finder** and follow the header comment. With the hook
installed and freshly fired, the tag reads `official`.

Whichever source has the newer reading wins, so one of them being quiet is
invisible. There is no estimate fallback: with neither reporting, the popover
shows an error rather than a guessed number, and a real-but-old reading stays
on screen with an orange staleness warning. Token counts, cost, and burn rate
(from local log parsing) work regardless.

This tier is account-wide — it reflects usage from other machines/containers
on the same Anthropic account automatically.

## Building a release app

```bash
bash make_app.sh 0.1.0
```

This produces `ClaudeStats.app` in the project root — a release binary assembled into a proper macOS app bundle, compiled asset catalog (icon), and ad-hoc signed. Omit the version to take the latest `[x.y.z]` entry from `CHANGELOG.md`.

## Publishing a release

```bash
bash make_release.sh 0.1.0
```

Stamps `CHANGELOG.md`, builds the app, zips it as `ClaudeStats-vX.Y.Z.zip` with a SHA-256 checksum, and prints the `gh release create` command to run.

## Development

```bash
swift build && .build/debug/ClaudeStats
```

Runs straight from the build directory — no bundle, no icon, fastest loop for iterating on code. `swift test` runs the test suite (no UI).

## Status

Early development — [v0.1.0](https://github.com/iwan-uschka/claude-stats/releases/tag/v0.1.0) is out, but settings UI and live quota-source setup are still manual/incomplete.
