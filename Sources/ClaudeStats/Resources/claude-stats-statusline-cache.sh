#!/usr/bin/env bash
#
# claude-stats-statusline-cache.sh
#
# Feeds ClaudeStats' `StatuslineCacheReader` (tier-2 "official" quota source).
#
# WHY THIS EXISTS
# ---------------
# Claude Code's 5-hour / 7-day rate-limit percentages are only ever handed out
# through the `statusLine` hook: Claude Code pipes a JSON payload into the
# configured command, containing
#
#   .rate_limits.five_hour.used_percentage   0..100
#   .rate_limits.five_hour.resets_at         Unix epoch seconds
#   .rate_limits.seven_day.used_percentage
#   .rate_limits.seven_day.resets_at
#
# There is no API to request that payload — you have to *be* the status line.
# ClaudeStats is a menu bar app, not a shell command, so it can't be. This script
# is the hook; it writes the payload to a cache file that the app reads.
#
# `rate_limits` only appears for Claude.ai Pro/Max subscribers, and only after the
# session's first API response. The hook fires only while Claude Code is actively
# rendering a status line, so the cache goes cold when you stop working — the app
# treats it as stale after 10 minutes and falls back to the OAuth usage poll.
#
# INSTALL
# -------
# From the app (recommended): Settings > Quota source > "Set Up Automatically".
# It copies this script next to settings.json, points `statusLine` at it, wraps
# any existing statusline command, and shows the exact before/after first.
#
# By hand (Settings > "Reveal Script in Finder" reveals a temp copy — move it to
# ~/.claude/, it is not a stable path):
#   cp Sources/ClaudeStats/Resources/claude-stats-statusline-cache.sh ~/.claude/
#   chmod +x ~/.claude/claude-stats-statusline-cache.sh
# ... then edit ~/.claude/settings.json yourself, per Case A / Case B below.
# (The automatic install writes Case B as
# `bash "$HOME/.claude/claude-stats-statusline-cache.sh" bash -c '<your command>'`;
# both shapes are recognized on detect/uninstall.)
#
# Case A — you have no status line yet:
#
#   {
#     "statusLine": {
#       "type": "command",
#       "command": "bash \"$HOME/.claude/claude-stats-statusline-cache.sh\""
#     }
#   }
#
# Case B — you already have one, e.g.
# `bash "$HOME/.claude/statusline-command.sh"`. Wrap it: pass your existing
# command as arguments and this script caches, then delegates to it with the same
# stdin, printing its output unchanged.
#
#   {
#     "statusLine": {
#       "type": "command",
#       "command": "bash \"$HOME/.claude/claude-stats-statusline-cache.sh\" bash \"$HOME/.claude/statusline-command.sh\""
#     }
#   }
#
# Verify with:  cat "$HOME/Library/Application Support/ClaudeStats/statusline-cache.json"
#
# CACHE FORMAT
# ------------
# With `jq` installed, only the rate-limit fields are persisted:
#
#   {"captured_at":1738425600,
#    "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
#                   "seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}
#
# Without `jq`, the raw payload is written verbatim and the app uses the file's
# modification time as the capture time. Both shapes are accepted by the reader.
#
# Override the cache directory with $CLAUDE_STATS_CACHE_DIR — useful for
# manually exercising this script against a scratch directory. (No automated
# test harness exercises this script yet; that claim was previously here but
# wasn't true — the repo has no shell test runner.)

set -uo pipefail

cache_dir="${CLAUDE_STATS_CACHE_DIR:-${HOME:-/tmp}/Library/Application Support/ClaudeStats}"
cache_file="$cache_dir/statusline-cache.json"

# Claude Code hands the payload over on stdin.
input=$(cat)

# --- write the cache -------------------------------------------------------
# Never let a cache-write failure break the user's status line: everything here
# is best-effort, and the delegate runs regardless.
write_cache() {
  mkdir -p "$cache_dir" || return 1
  local tmp
  tmp=$(mktemp "${cache_file}.XXXXXX") || return 1
  trap 'rm -f "$tmp"' EXIT

  if command -v jq >/dev/null 2>&1; then
    if ! printf '%s' "$input" | jq -c \
        --argjson now "$(date +%s)" \
        'if .rate_limits then {captured_at: $now, rate_limits: .rate_limits} else empty end' \
        >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  else
    # Mirror the jq path's "null/absent .rate_limits is falsy" rule, so a
    # payload without it never clobbers a previously-good cache here either.
    if printf '%s' "$input" | grep -q '"rate_limits"' \
        && ! printf '%s' "$input" | grep -Eq '"rate_limits"[[:space:]]*:[[:space:]]*null'; then
      printf '%s' "$input" >"$tmp" || { rm -f "$tmp"; return 1; }
    else
      rm -f "$tmp"
      return 0
    fi
  fi

  # jq emits nothing when .rate_limits is absent; don't overwrite a good cache
  # with an empty file.
  if [ -s "$tmp" ]; then
    chmod 600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$cache_file"
  else
    rm -f "$tmp"
  fi
}
write_cache || true

# --- delegate --------------------------------------------------------------
# Any arguments are the user's real status line command; re-feed it the payload
# and let its stdout become the status line. With no arguments, print nothing.
if [ "$#" -gt 0 ]; then
  printf '%s' "$input" | "$@"
fi
