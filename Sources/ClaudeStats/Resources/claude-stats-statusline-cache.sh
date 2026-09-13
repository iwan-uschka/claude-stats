#!/usr/bin/env bash
#
# claude-stats-statusline-cache.sh
#
# Feeds ClaudeStats' `StatuslineCacheReader` — the app's **primary** quota
# source (tier-2 "official").
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
# ONE FILE PER SESSION
# --------------------
# Every running Claude Code process runs this script, and each pipes in the rate
# limits *its own* last API response carried — an idle session re-renders its
# status line on timers alone and hands over numbers that may be hours old.
# Writing one shared file therefore meant last writer wins, with the quiet
# session's stale numbers stamped as captured "now". Worse, Claude Code drops a
# window from the payload entirely once its `resets_at` has passed, so the quiet
# writer's payload can carry `seven_day` alone and the app read the missing
# `five_hour` back as 0%.
#
# So the payload's own top-level `session_id` names the file: one file per
# session, in a directory, and the app merges them (latest `resets_at` wins;
# same window, higher percentage wins; expired windows are ignored). A session
# can now only ever overwrite its own numbers.
#
# It is not only the freshest source, it is the *resilient* one. Everything
# beyond those four numbers — the per-model `weekly_scoped` rows and the org's
# extra-usage `spend` (the app's third and fourth bars) — exists only inside
# Claude Code's own private state file, `~/.claude.json`, under the
# undocumented `cachedUsageUtilization` key. Reading that key directly is a
# standing bet on another program's internals (a `spend` object appeared inside
# it between 2026-08-27 and 2026-08-28), and it refreshes on Claude Code's own
# schedule — measured unmoved for 3.7+ hours during active sessions. So this
# script snapshots those two objects *itself*, on every status line render,
# into the same cache file as the rate limits. The result is a file per session,
# written by us, each at one known age, together carrying everything the app
# draws.
#
# The app still reads `cachedUsageUtilization` directly as a backup
# (`CachedUtilizationReader`) for machines where this hook was never installed,
# has never fired, or has gone stale — but with the hook in place its readings
# win outright rather than being merged by capture time. See
# `FreshestQuotaProvider`.
#
# `rate_limits` only appears for Claude.ai Pro/Max subscribers, and only after the
# session's first API response. The hook fires only while Claude Code is actively
# rendering a status line, so the cache goes cold when you stop working — the app
# treats it as stale after 10 minutes and falls back to the backup source.
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
# Verify with:
#   ls -l "$HOME/Library/Application Support/ClaudeStats/statusline-cache/"
#   cat  "$HOME/Library/Application Support/ClaudeStats/statusline-cache/"*.json
#
# CACHE FORMAT
# ------------
# One file per session, `statusline-cache/<session_id>.json` inside the cache
# directory — `session_id` straight from the payload, stripped to
# `[A-Za-z0-9._-]` so it can't escape that directory, and
# `unknown-session.json` when the payload names no session or `jq` isn't there
# to read it out. Older copies of this script wrote a single
# `statusline-cache.json` beside the directory; that file is no longer written,
# and the app still reads it if it's there.
#
# With `jq` installed, three top-level keys are written per file:
#
#   {"captured_at":1738425600,
#    "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
#                   "seven_day":{"used_percentage":41.2,"resets_at":1738857600}},
#    "utilization":{"limits":[{"kind":"weekly_scoped","percent":0,…}],
#                   "spend":{…},"extra_usage":{…}}}
#
# `captured_at` and `rate_limits` come from stdin — the statusline payload. The
# `utilization` object does not: it is copied out of Claude Code's own
# `cachedUsageUtilization.utilization` (see WHY THIS EXISTS), keeping only the
# parts the app draws that stdin cannot supply — the `weekly_scoped` entries of
# `limits[]`, plus `spend` and `extra_usage` whole. It is nested and named to
# match the shape those keys already have in `~/.claude.json`, so the app's
# existing parsers read it unchanged from either file.
#
# That copy is strictly best-effort and additive. A missing, unreadable or
# malformed state file, or one with no `cachedUsageUtilization` yet, simply
# omits the `utilization` key — `captured_at` and `rate_limits` are written
# exactly as before, and the app falls back to reading the state file itself
# for the two bars this key would have fed. An older cache file written before
# this key existed is read the same way.
#
# The state file is located the way the app locates it: $CLAUDE_CONFIG_DIR
# (trimmed, tilde-expanded) `/.claude.json` when that variable is set to
# something non-blank, else $HOME/.claude.json; first one that opens wins.
#
# The `utilization` copy is shared, not per-session: it comes from a file every
# session sees identically, so the app takes it from the most recently captured
# cache file rather than merging it.
#
# STATE-FILE READ COST
# ---------------------
# `~/.claude.json` is Claude Code's own scratch state (measured ~145 KB, and
# it rewrites the file constantly for reasons that have nothing to do with
# us — the app's own reader, `ClaudeStateFile`, hit exactly this and added a
# fingerprint gate to skip re-parsing an unchanged file). This script fires on
# every status line render, which is far more often than that reader's
# throttled poll, so it carries the same gate here: a sidecar file
# (`statusline-utilization-cache.json`, one for the machine rather than one per
# session, in the cache directory itself) remembers the
# state file's mtime+size+inode alongside the last-extracted `utilization`
# payload, and `extract_utilization` skips the `jq` parse of the (much
# larger) state file entirely when the fingerprint still matches — including
# when the last extraction found nothing to carry, so a Free-tier account
# with no `weekly_scoped`/`spend` data doesn't pay the full parse on every
# render either. Coarser than `ClaudeStateFile`'s nanosecond-mtime version
# (whole-second `stat` resolution, no descriptor-reuse trick): a same-second
# overwrite can be missed, costing one render's staleness on the fourth bar,
# not a correctness bug — the reader already tolerates an absent
# `utilization` key.
#
# Without `jq`, the raw payload is written verbatim to
# `statusline-cache/unknown-session.json`, the app uses the file's modification
# time as the capture time, and no `utilization` key is produced —
# hand-parsing JSON with `grep` is not worth the wrong answers it would give,
# and that includes digging the `session_id` out, so every session on such a
# machine shares that one file. Both shapes are accepted by the reader.
#
# Override the cache directory with $CLAUDE_STATS_CACHE_DIR — useful for
# exercising this script against a scratch directory. That is exactly what
# `Tests/ClaudeStatsCoreTests/StatuslineCacheScriptTests.swift` does: it runs
# this file under `bash` with a scratch $CLAUDE_STATS_CACHE_DIR and $HOME and
# checks what lands on disk, so `swift test` covers the file layout the app
# depends on. There is still no shell test runner in the repo — the harness is
# an XCTest case driving `Process`.

set -uo pipefail

cache_dir="${CLAUDE_STATS_CACHE_DIR:-${HOME:-/tmp}/Library/Application Support/ClaudeStats}"
# One file per Claude Code session lives in here — see ONE FILE PER SESSION.
session_cache_dir="$cache_dir/statusline-cache"
# Used when the payload names no session, or when there's no `jq` to read it.
fallback_session_name="unknown-session"
# Sidecar for the state-file fingerprint gate — see STATE-FILE READ COST above.
# Machine-wide, not per-session: it caches a file every session reads alike.
utilization_cache_file="$cache_dir/statusline-utilization-cache.json"

# Claude Code hands the payload over on stdin.
input=$(cat)

# --- Claude Code's own state file ------------------------------------------
# Mirrors `ClaudeConfigDirectory.stateFileCandidates()`: `$CLAUDE_CONFIG_DIR`
# wins only when set to a non-blank value (trimmed and tilde-expanded, as the
# app does), and `.claude.json` is a *sibling* of the config directory rather
# than a member of it, so `$HOME` is always probed too. First readable
# candidate wins; none is not an error.
find_state_file() {
  local dir candidate
  dir="${CLAUDE_CONFIG_DIR-}"
  dir="${dir#"${dir%%[![:space:]]*}"}"
  dir="${dir%"${dir##*[![:space:]]}"}"
  [ -n "$dir" ] && dir="${dir/#\~/${HOME:-~}}"

  local candidates=()
  [ -n "$dir" ] && candidates+=("$dir/.claude.json")
  candidates+=("${HOME:-}/.claude.json")

  for candidate in "${candidates[@]}"; do
    if [ -r "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Identifies the state file's on-disk contents cheaply enough to gate a full
# parse on it — whole-second mtime, size and inode, via one `stat` call. See
# STATE-FILE READ COST above for why this exists and how it compares to the
# app's own (nanosecond-precision) version of the same gate.
state_fingerprint() {
  stat -f '%m.%z.%i' "$1" 2>/dev/null
}

# Copies out the parts of `cachedUsageUtilization.utilization` that the
# statusline payload can't supply, or prints nothing at all. Anything unexpected
# — no state file, unparseable JSON, no such key, an entry of the wrong type —
# lands on "print nothing", because a missing `utilization` key in the cache is
# a documented, handled state and a wrong one is not.
#
# `strings` on `.kind` is what makes the `weekly_scoped` filter total: a
# non-string `kind` yields no value, so `select` drops the entry instead of
# `ascii_downcase` aborting the whole extraction over one malformed row.
#
# Fingerprint-gated: a hit reuses the sidecar's stored payload (or its stored
# "nothing to carry" verdict) without touching the state file at all; only a
# miss pays for opening and parsing it.
extract_utilization() {
  local state_file fp cached_entry cached_payload
  state_file=$(find_state_file) || return 1
  fp=$(state_fingerprint "$state_file") || return 1

  if [ -r "$utilization_cache_file" ]; then
    cached_entry=$(jq -c --arg fp "$fp" 'select(.source_fingerprint == $fp)' \
      "$utilization_cache_file" 2>/dev/null)
    if [ -n "$cached_entry" ]; then
      cached_payload=$(printf '%s' "$cached_entry" | jq -c '.utilization // empty' 2>/dev/null)
      if [ -n "$cached_payload" ]; then
        printf '%s' "$cached_payload"
        return 0
      fi
      return 1
    fi
  fi

  local payload
  payload=$(jq -c '
    .cachedUsageUtilization.utilization
    | if type == "object" then
        { limits: [ .limits[]? | select((.kind? | strings | ascii_downcase) == "weekly_scoped") ] }
        + (if (.spend | type) == "object" then { spend: .spend } else {} end)
        + (if (.extra_usage | type) == "object" then { extra_usage: .extra_usage } else {} end)
      else empty end
    | if (.limits | length) > 0 or has("spend") or has("extra_usage") then . else empty end
  ' "$state_file" 2>/dev/null)

  # Persist the verdict regardless of outcome — an unchanged state file with
  # nothing to carry should skip the parse next render too, same as a hit
  # with data. Best-effort: a failure here just costs the next render a
  # redundant parse, not correctness.
  local tmp
  tmp=$(mktemp "${utilization_cache_file}.XXXXXX" 2>/dev/null) && {
    if [ -n "$payload" ]; then
      jq -cn --arg fp "$fp" --argjson u "$payload" '{source_fingerprint:$fp, utilization:$u}' >"$tmp" 2>/dev/null
    else
      jq -cn --arg fp "$fp" '{source_fingerprint:$fp, utilization:null}' >"$tmp" 2>/dev/null
    fi
    mv -f "$tmp" "$utilization_cache_file" 2>/dev/null || rm -f "$tmp"
  }

  [ -n "$payload" ] || return 1
  printf '%s' "$payload"
}

# --- write the cache -------------------------------------------------------
# Names this session's cache file. `session_id` is a documented, stable-per-
# session top-level field of the payload; everything outside `[A-Za-z0-9._-]`
# is stripped, so no `/` survives and the name can only ever land inside
# `$session_cache_dir`. An empty result — no `session_id`, or nothing left of
# it — falls back to the shared name, as does the no-`jq` path: hand-parsing
# JSON to find the id would cost more wrong answers than it saves files.
session_cache_file() {
  local id=""
  if command -v jq >/dev/null 2>&1; then
    id=$(printf '%s' "$input" \
      | jq -r 'if (.session_id | type) == "string" then .session_id else empty end' 2>/dev/null)
    id=$(printf '%s' "$id" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
  fi
  [ -n "$id" ] || id="$fallback_session_name"
  printf '%s/%s.json' "$session_cache_dir" "$id"
}

# Never let a cache-write failure break the user's status line: everything here
# is best-effort, and the delegate runs regardless.
write_cache() {
  mkdir -p "$session_cache_dir" || return 1
  local cache_file tmp
  cache_file=$(session_cache_file)
  tmp=$(mktemp "${cache_file}.XXXXXX") || return 1
  # No EXIT trap here: `tmp` is `local` to this function, but a trap installed
  # inside it runs at the *script's* exit, by which point the function has
  # long returned and `tmp` is unset — `set -u` then reports it as unbound.
  # Every path below already removes or renames `$tmp` itself, so no trap is
  # needed.

  if command -v jq >/dev/null 2>&1; then
    # Additive and separately fallible: `utilization` defaults to JSON null and
    # is dropped from the object below when it stays that way, so a state file
    # that can't be read costs the third and fourth bars nothing here — it just
    # leaves them to the app's backup reader — and never the rate limits.
    local utilization
    utilization=$(extract_utilization) || utilization=""
    [ -n "$utilization" ] || utilization="null"

    if ! printf '%s' "$input" | jq -c \
        --argjson now "$(date +%s)" \
        --argjson utilization "$utilization" \
        'if .rate_limits
         then {captured_at: $now, rate_limits: .rate_limits}
              + (if $utilization == null then {} else {utilization: $utilization} end)
         else empty end' \
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
