#!/bin/bash
# Fleet watcher — the SINGLE engine that re-nudges (1) PARKED agents so messages don't
# wait on a human keystroke, and (2) ERRORED agents (retriable StopFailure) to continue.
# Both nudges are pure tmux send-keys — NO model/agent calls.
#
# Lifecycle: the COORDINATOR (cc) owns it. cc-watcher-keepalive.sh starts it on the
# coordinator's SessionStart and re-starts it (idempotent `start`) on every cc Stop, so
# a single instance runs machine-wide for as long as a cc is alive (one cc per machine →
# one watcher). The errored-agent SWEEP lives HERE, not in the hook — the hook only keeps
# this daemon up, so the nudge logic isn't duplicated across the two.
#
# The drain hook (.claude/hooks/drain-inbox.sh) still makes message delivery lossless for
# any agent that takes another turn; this daemon covers the idle-fleet gap it can't: a
# parked agent that won't run its drain, or an errored agent sitting idle.
#
# Usage:
#   inbox-watcher.sh [interval_secs] [redeliver_after_secs]   # run the poll loop (foreground)
#   inbox-watcher.sh start [interval] [redeliver]             # spawn ONE detached daemon (single-instance)
#   inbox-watcher.sh stop                                     # kill the daemon
#   inbox-watcher.sh status                                   # running? (pid)
#   defaults: interval=5, redeliver_after=30
# The start/stop/status control mode (single-instance via a pidfile) is what the
# coordinator's cc-watcher-keepalive.sh hook uses to keep exactly one instance alive.
#
# Each poll, for every staged message whose age >= redeliver_after that is still
# present, it reconstructs the original `/agent-msg <sender> <path> [reply|
# followup]` and send-keys it to the recipient's live pane (skipping panes in
# copy-mode). The re-nudge throttle is the DELIVERY-CLAIM's age (a fresh claim —
# whether agent-send's original or our last re-nudge — means a nudge is already
# in flight, so skip). The message file itself is NEVER mtime-bumped: touching
# it broke the drain's oldest-first ordering and reset the 7-day GC clock
# forever for parked mailboxes. A processed message disappears (drain/skill
# deletes it), so the watcher naturally stops nudging it. Messages to a
# non-live recipient are left alone for the drain's time-based GC to collect.

set -u

# The canonical fleet predicates (fleet_busy, …) live in _fleet.sh. Guarded source: a clone
# without it degrades to the inline copies below, never to an undefined function — which would
# fail OPEN (busy reads as idle) and re-nudge a mid-turn agent into duplicate deliveries.
fleet_helper="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/_fleet.sh"
# shellcheck disable=SC1090
[ -r "$fleet_helper" ] && . "$fleet_helper"

# --- daemon control (single-instance via pidfile) ---------------------------
# `start` spawns ONE detached copy running the poll loop and records its pid;
# a second `start` while one is live is a no-op. `stop`/`status` don't need tmux.
PIDFILE="$HOME/.claude/inbox-watcher.pid"
# Every diagnostic this daemon emits (`re-nudged …`, `re-nudge cap reached …`, the startup
# banner) goes to stderr. That used to be redirected to /dev/null, which made the ONE
# component that types into other agents' panes completely unobservable — when it misfired
# there was no evidence anywhere, so the only way to reason about it was guesswork. Keep the
# log; it is a few lines per nudge and it is the sole record of why an agent got poked.
LOGFILE="${WORKFLOW_INBOX_WATCHER_LOG:-$HOME/.claude/inbox-watcher.log}"
_running_pid() { local p; [ -f "$PIDFILE" ] && p="$(cat "$PIDFILE" 2>/dev/null)" && [ -n "$p" ] && kill -0 "$p" 2>/dev/null && printf '%s' "$p"; }
case "${1:-}" in
  start)
    shift
    p="$(_running_pid || true)"; [ -n "$p" ] && { echo "inbox-watcher: already running (pid $p)"; exit 0; }
    mkdir -p "$(dirname "$PIDFILE")"
    # Truncate if it has grown past ~1MB. An unbounded append in $HOME is its own defect,
    # and rotation would be overkill for a few lines per nudge.
    [ -f "$LOGFILE" ] && [ "$(wc -c <"$LOGFILE" 2>/dev/null || echo 0)" -gt 1048576 ] && : >"$LOGFILE"
    nohup "$0" "$@" >>"$LOGFILE" 2>&1 &          # re-exec self in loop mode, detached
    echo $! > "$PIDFILE"
    echo "inbox-watcher: started (pid $(cat "$PIDFILE")); log: $LOGFILE"; exit 0 ;;
  stop)
    p="$(_running_pid || true)"; if [ -n "$p" ]; then kill "$p" 2>/dev/null; echo "inbox-watcher: stopped (pid $p)"; else echo "inbox-watcher: not running"; fi
    rm -f "$PIDFILE"; exit 0 ;;
  status)
    p="$(_running_pid || true)"; [ -n "$p" ] && echo "inbox-watcher: running (pid $p)" || echo "inbox-watcher: not running"; exit 0 ;;
esac

# This watcher's entire job is to re-NUDGE parked agents via tmux send-keys, so it
# is a tmux-only convenience (DX-jn-8-019). Without tmux there's nothing it can do —
# the durable mailbox + Stop-drain still deliver at each agent's next turn.
if [ -z "${TMUX_PANE:-}" ] && ! command -v tmux >/dev/null 2>&1; then
  echo "inbox-watcher: tmux unavailable — nothing to nudge (messages still drain at each agent's next turn); exiting." >&2
  exit 0
fi
interval="${1:-5}"
redeliver_after="${2:-30}"
inbox="$HOME/.claude/agent-inbox"
reg="$HOME/.claude/running-agents"

mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Live pane for an agent name, or empty if not live.
pane_for() {
  local target="$1" f bn pid pane
  shopt -s nullglob
  for f in "$reg/$target".*; do
    [ -f "$f" ] || continue
    bn="$(basename "$f")"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
    kill -0 "$pid" 2>/dev/null || continue
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane" || continue
    printf '%s' "$pane"; return 0
  done
  return 1
}

# Timestamp every line: this log's whole job is answering "when did the watcher poke agent
# X, and how many times" — undated lines can't do that, and the poll loop appends forever.
_log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2; }

_log "inbox-watcher: started interval=${interval}s redeliver_after=${redeliver_after}s busy_stale=${WORKFLOW_BUSY_STALE_MIN:-30}min inbox=$inbox"
trap '_log "inbox-watcher: stopping"; exit 0' INT TERM

while :; do
  now=$(date +%s)
  shopt -s nullglob
  for path in "$inbox"/*/*.txt; do
    [ -f "$path" ] || continue
    mtime="$(mtime_of "$path")"; [ -n "$mtime" ] || mtime="$now"
    [ $(( now - mtime )) -ge "$redeliver_after" ] || continue

    recipient="$(basename "$(dirname "$path")")"
    fname="$(basename "$path")"
    base="${fname%.txt}"; kind="${base##*.}"; rest="${base%.*}"; sender="${rest#*.}"
    case "$kind" in rep) kw=" reply" ;; fwd) kw=" followup" ;; *) kw="" ;; esac

    pane="$(pane_for "$recipient" || true)"
    [ -n "$pane" ] || continue   # recipient not live — leave for GC
    [ "$(tmux display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ] && continue
    # Skip busy recipients — their Stop-drain delivers at the end of the turn;
    # re-nudging a busy agent would just buffer and replay as a duplicate.
    bm="$HOME/.claude/agent-busy/$recipient"
    if command -v fleet_busy >/dev/null 2>&1; then
      fleet_busy "$recipient" && continue
    else
      [ -f "$bm" ] && [ -n "$(find "$bm" -mmin "-${WORKFLOW_BUSY_STALE_MIN:-30}" 2>/dev/null)" ] && continue
    fi
    # Skip HELD recipients (DX-jn-8-031) — parked on a Monocle interactive verdict wait, a
    # single long tool call whose busy marker goes stale (so the check above stops catching
    # it). NO staleness test: a human review can run for hours, and the hold is bounded by the
    # recipient's Stop / next-tool / SessionEnd clears. The message drains ONCE at its Stop.
    [ -f "$HOME/.claude/agent-hold/$recipient" ] && continue

    # Respect an existing FRESH claim (< redeliver_after): a nudge is already in
    # flight — agent-send's original, or our own last re-nudge — so re-nudging now
    # would just buffer a duplicate /agent-msg line. The claim's age IS the re-nudge
    # throttle (replaces the old `touch "$path"`, which corrupted ordering + GC).
    # The claim file also carries the redelivery COUNT (see the cap below).
    claim="$HOME/.claude/agent-nudge-claim/$fname"
    count=0
    if [ -f "$claim" ]; then
      cmt="$(mtime_of "$claim")"
      [ -n "$cmt" ] && [ $(( now - cmt )) -lt "$redeliver_after" ] && continue
      count="$(cat "$claim" 2>/dev/null)"; case "$count" in ''|*[!0-9]*) count=0 ;; esac
    fi
    # Re-nudge CAP (DX-jn-8-031): after WORKFLOW_MAX_REDELIVER re-nudges, stop nudging this
    # message and leave it for the lossless Stop-drain, so ANY long block (not just a
    # Monocle wait — e.g. a test run that outlasts WORKFLOW_BUSY_STALE_MIN) can't
    # spam the recipient's prompt. count is redeliveries so far (agent-send's original nudge
    # isn't counted here — it doesn't write a count).
    max_redeliver="${WORKFLOW_MAX_REDELIVER:-3}"
    case "$max_redeliver" in ''|*[!0-9]*) max_redeliver=3 ;; esac   # non-int override → default (avoid `[ -ge ]` throw)
    if [ "$count" -ge "$max_redeliver" ]; then
      if [ "$count" -eq "$max_redeliver" ]; then
        _log "re-nudge cap reached for $recipient/$fname (${max_redeliver}x) — leaving for Stop-drain"
        printf '%s' "$((count + 1))" > "$claim" 2>/dev/null || true  # bump once past the log threshold
      fi
      continue
    fi
    # Claim delivery FIRST (same as agent-send): the target's Stop-drain skips this fresh-claimed
    # file so it won't ALSO inject it → no "file gone" duplicate. Claim before the send-keys to
    # close the drain-in-the-gap window. The claim's CONTENT is the running redelivery count.
    # Cleared on delivery by agent-msg.sh.
    mkdir -p "$HOME/.claude/agent-nudge-claim" 2>/dev/null || true
    printf '%s' "$((count + 1))" > "$claim" 2>/dev/null || true
    # Final existence re-check immediately before send-keys (DX-jn-8-032): the file may have
    # been consumed by a live nudge / manual drain during the busy/hold/claim/cap checks above.
    # Injecting a doomed /agent-msg costs the recipient a full skill-load turn to discover it's
    # spent — the exact waste we're cutting — so drop it here if it's already gone.
    [ -f "$path" ] || { rm -f "$claim" 2>/dev/null; continue; }
    tmux send-keys -t "$pane" -l "/agent-msg $sender $recipient/$fname$kw"
    tmux send-keys -t "$pane" Enter
    _log "re-nudged $recipient about $fname (sender=$sender kind=$kind n=$((count + 1)))"
  done

  # (2) Nudge ERRORED agents (retriable StopFailure) to continue. This is the SOLE
  # errored-agent sweep — the cc keep-alive hook no longer duplicates it. Throttled via
  # ~/.claude/agent-nudged/<name> so a given agent is nudged at most once per window.
  throttle_min="${WORKFLOW_RESUME_THROTTLE_MIN:-2}"
  nudged_dir="$HOME/.claude/agent-nudged"; mkdir -p "$nudged_dir"
  for ef in "$HOME/.claude/agent-error"/*; do
    [ -f "$ef" ] || continue
    name="$(basename "$ef")"
    # Only nudge RETRIABLE error categories (the marker's content, written by mark-error.sh).
    # "Continue" can't fix auth/billing/invalid_request — nudging those would just retry a
    # doomed error every throttle window. Those (and unparsed "error") are left for the user.
    case "$(head -1 "$ef" 2>/dev/null)" in rate_limit|overloaded|server_error) ;; *) continue ;; esac
    pane="$(pane_for "$name" || true)"; [ -n "$pane" ] || continue   # not live → skip
    [ "$(tmux display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ] && continue
    tf="$nudged_dir/$name"
    [ -f "$tf" ] && [ -n "$(find "$tf" -mmin "-$throttle_min" 2>/dev/null)" ] && continue
    tmux send-keys -t "$pane" -l "Continue — the API rate limit should have cleared. Resume where you left off."
    tmux send-keys -t "$pane" Enter
    : > "$tf"
    _log "nudged errored agent $name to continue (pane $pane)"
  done

  sleep "$interval"
done
