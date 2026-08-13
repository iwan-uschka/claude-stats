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

- Menu bar glyph showing 5-hour and 7-day quota usage as two thin bars, tinted for light/dark mode automatically
- Popover with per-window usage and reset countdowns, auto-detected plan tier (Pro / Max5 / Max20 / custom), and current burn rate
- Per-source breakdown (CLI / VS Code / SDK-agents) across 5h/24h/7d windows, and per-model token/cost totals
- Local session-log parsing (`~/.claude/projects/*/*.jsonl`) — token counts, cost, burn rate always available, no network or credentials needed
- Live 5-hour/7-day quota percentage from Claude Code's `statusLine` hook — see [Quota source](#quota-source)
- FSEvents-driven refresh — updates on write, not on a poll timer

Full architecture and data-source design: see [AGENTS.md](AGENTS.md).

## Quota source

The popover's 5-hour/7-day percentage bars come from a single source, tagged
`official` in the freshness line: Claude Code's `statusLine` hook, cached to
disk (stale after ~10 min). There is no fallback — until the hook is
installed and has fired at least once, the popover shows an error instead of
a quota number. Token counts, cost, and burn rate (from local log parsing)
work regardless.

**Setup.** Claude Code's `statusLine` feature can emit live rate-limit data,
but only while a terminal is actively rendering a status line, and only if
something is registered to receive it. This app is a menu bar app, not a
shell hook, so a small script bridges the two. Open **Settings → Quota
source** and click **Set Up Automatically**: the app shows the exact
before/after change to `~/.claude/settings.json`, backs the file up, and only
edits the `statusLine` key (an existing statusline is wrapped, not replaced).
**Remove** reverts it. Prefer doing it yourself? **Reveal Script in Finder**
and follow the header comment.

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
