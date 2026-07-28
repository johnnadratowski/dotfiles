#!/bin/bash
# fleet-clear.sh <agent> [<agent> ...] [--role R] [--dry-run]
#
# Clear a fleet agent's context AND restore its session name, in one deterministic
# sequence: `/clear` then `/rename <name>`.
#
# WHY THIS EXISTS
# `/clear` silently drops the agent's name, and the SessionStart auto-rename cannot fix it.
# register-agent.sh's settle re-check reads the session name from
# `~/.claude/sessions/<pid>.json` -- keyed by PID. `/clear` starts a NEW session inside the
# SAME process, so that file still holds the OLD name. The settle compares it against
# boot_name, sees a match, and correctly concludes there is nothing to do -- while Claude
# Code's actual new session is unnamed. The check is structurally blind to the one case it
# exists for, so waiting longer never helps. Observed on feature-2: cleared at 12:44:19,
# settle at 12:44:24 logged "settled name matches boot name 'feature-2' -- no-op", name gone.
#
# This drives both keystrokes itself instead of relying on that fallback. Run it from a
# DIFFERENT pane (normally the coordinator's) so the sends never race the human's typing --
# the fragility that made the auto-rename unreliable even when it did fire.
#
# Sequenced, not fired blind: it waits for the SessionStart that `/clear` triggers (a new
# line in register-agent.sh's debug log) before sending `/rename`, so the rename cannot
# land in the window where Claude Code is still tearing the old session down.
#
# NOT a restart. The process is untouched; only the conversation is cleared. Use
# `agent-fanout.sh restart` when the goal is to reload machinery from disk.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
[ -r "$here/_fleet.sh" ] && . "$here/_fleet.sh"

REG="$HOME/.claude/running-agents"
LOG="$HOME/.claude/debug/register-agent.log"
SETTLE_TIMEOUT="${WORKFLOW_CLEAR_SETTLE_TIMEOUT:-15}"

die() { echo "fleet-clear: $*" >&2; exit 1; }

command -v tmux >/dev/null 2>&1 || die "tmux unavailable -- this drives panes, nothing to do."
[ -d "$REG" ] || die "no agent registry at $REG"

# --- args ---------------------------------------------------------------
names=(); role=""; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) names+=("$1"); shift ;;
  esac
done

# Never clear the caller: it would destroy the context of the session issuing the command,
# mid-turn, and nothing would be left to send the /rename or verify it.
self=""
if command -v fleet_find_self >/dev/null 2>&1; then self="$(fleet_find_self "$REG" 2>/dev/null || true)"; fi

if [ -n "$role" ]; then
  command -v fleet_resolve_role >/dev/null 2>&1 || die "--role needs _fleet.sh (not found next to this script)"
  shopt -s nullglob
  for f in "$REG"/*; do
    n="$(basename "$f" | sed 's/\.[0-9]*$//')"
    [ "$n" = "$self" ] && continue
    [ "$(fleet_resolve_role "$n" 2>/dev/null)" = "$role" ] && names+=("$n")
  done
fi

[ "${#names[@]}" -gt 0 ] || die "no targets. Usage: fleet-clear.sh <agent> [...] [--role R] [--dry-run]"

# --- helpers ------------------------------------------------------------
pane_for() {
  local target="$1" f bn pid pane
  shopt -s nullglob
  for f in "$REG/$target".*; do
    [ -f "$f" ] || continue
    bn="$(basename "$f")"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
    kill -0 "$pid" 2>/dev/null || continue
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane" || continue
    printf '%s %s' "$pane" "$pid"; return 0
  done
  return 1
}

rc=0
for name in "${names[@]}"; do
  if [ "$name" = "$self" ]; then
    echo "SKIP $name — that's me; clearing myself would destroy the session running this."
    continue
  fi

  read -r pane pid <<<"$(pane_for "$name" || true)"
  if [ -z "${pane:-}" ]; then echo "SKIP $name — not live in the registry."; rc=1; continue; fi

  # Idle-gate, same rule as restart/compact: clearing mid-turn discards in-flight work.
  if command -v fleet_busy >/dev/null 2>&1 && fleet_busy "$name"; then
    echo "SKIP $name — BUSY (mid-turn). Wait for idle and re-run."; rc=1; continue
  fi
  if [ "$(tmux display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null || echo 0)" = "1" ]; then
    echo "SKIP $name — pane $pane is in copy-mode (scrolled back)."; rc=1; continue
  fi

  if [ "$dry" = 1 ]; then echo "DRY-RUN would clear+rename $name (pane $pane, pid $pid)"; continue; fi

  before=$(wc -l <"$LOG" 2>/dev/null || echo 0)

  tmux send-keys -t "$pane" -l "/clear"; tmux send-keys -t "$pane" Enter

  # Wait for the SessionStart that /clear fires, so /rename lands on the NEW session.
  waited=0; settled=0
  while [ "$waited" -lt "$SETTLE_TIMEOUT" ]; do
    sleep 1; waited=$((waited + 1))
    now=$(wc -l <"$LOG" 2>/dev/null || echo 0)
    [ "$now" -gt "$before" ] && { settled=1; break; }
  done
  # Fall through on timeout rather than abort: the clear already happened, so an unnamed
  # session is the worse outcome. Send the rename anyway and report that we did not see
  # the SessionStart.
  [ "$settled" = 1 ] || echo "WARN $name — no SessionStart seen in ${SETTLE_TIMEOUT}s; sending /rename regardless."

  tmux send-keys -t "$pane" -l "/rename $name"; tmux send-keys -t "$pane" Enter

  # Verify against the session file /rename writes. Same PID across a clear, so the path
  # is stable.
  ok=0
  for _ in 1 2 3 4 5 6; do
    sleep 1
    got="$(jq -r '.name // empty' "$HOME/.claude/sessions/$pid.json" 2>/dev/null || true)"
    [ "$got" = "$name" ] && { ok=1; break; }
  done
  if [ "$ok" = 1 ]; then echo "OK   $name — cleared and renamed (pane $pane)"
  else echo "WARN $name — cleared, but the name did not verify. Check the pane and /rename by hand."; rc=1; fi
done

exit "$rc"
