#!/bin/bash
# fleet-status.sh — one line per lane: state · context · uptime · issue · question · last 📌
#
# WHY THIS EXISTS, and why the agent panel cannot do it instead.
#
# The panel below the prompt lists every agent, and `subagentStatusLine` decorates its rows
# — but only SOME of them. Read off the harness (2.1.220), the eligibility filter is:
#
#     isTask(t)  =  t.type === "local_agent"
#     eligible   =  isTask(t) && t.agentType !== "main-session" && t.evictAfter !== 0
#
# and the runner returns early when that list is empty, so the script is never even spawned.
# The other task types the harness knows — `in_process_teammate`, `remote_agent`, `local_bash`,
# `local_workflow` — are all excluded, as is the `main` row. A tmux teammate is not a task in
# the parent at all; it is a separate process the parent merely lists.
#
# The consequence, which cost a long time to find: the TEAM LEAD's panel is made of teammates
# plus `main`, so it has zero eligible rows and its decorations never run — while a feature
# agent's panel, made of Task-spawned subagents, decorates fine. That is not a misconfiguration
# and no setting fixes it: switching teammateMode only turns tmux teammates into
# `in_process_teammate`, which is excluded too.
#
# So the lead reads the same facts off disk instead. Every field below comes from a file the
# agent itself wrote (_agent_facts.py):
#
#   state     registry entry + pid liveness, then the busy marker  (same predicates the
#             destructive fleet verbs gate on — _fleet.sh, one definition)
#   ctx%      summed usage of the last assistant turn in the lane's transcript
#   uptime    elapsed time of the lane's claude process
#   ▸ ID      the lane's in-progress tracker id, from .claude/current-work
#   ❓        .claude/needs-input — the agent saying it is blocked on a human
#   📌        the agent's own last summary line
#
# A field that is unavailable is dropped; the rest still renders. `down` means no live
# registry entry — the lane exists on disk but nothing occupies it.
#
# Usage:
#   fleet-status.sh                 one-shot table
#   fleet-status.sh --watch [SECS]  redraw every SECS (default 5) — for a companion pane
#   fleet-status.sh --json          machine-readable, one object per lane
#   fleet-status.sh --lanes-dir D   override lane discovery (else: git-derived, per _fleet.sh)

set -u

# WATCH IS THE DEFAULT. This is meant to be run in a window and left there; a one-shot
# default would mean every reader learns to type a flag to get the useful behaviour.
WATCH=1 INTERVAL=5 JSON=0 LANES_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --watch) WATCH=1; case "${2:-}" in ''|-*) ;; *) INTERVAL="$2"; shift ;; esac ;;
    --once|-1) WATCH=0 ;;
    --json) JSON=0; JSON=1; WATCH=0 ;;          # machine-readable implies one-shot
    --lanes-dir) LANES_DIR="${2:-}"; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "fleet-status: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -r "$HERE/_fleet.sh" ] && . "$HERE/_fleet.sh"

is_alive() {  # pid token — canonical predicate when sourced, plain pid check otherwise
  if command -v fleet_alive >/dev/null 2>&1; then fleet_alive "$1" "$2"; else kill -0 "$1" 2>/dev/null; fi
}

# busy | waiting | idle, from the marker mark-busy.sh maintains.
#
# NOT fleet_busy. That predicate answers "may a destructive verb touch this agent", and its
# 30-minute staleness window is deliberately generous for that job — it exists so a wedged
# agent can still be restarted. Read as a STATUS it is useless: everything reads busy for half
# an hour after finishing. The marker itself carries a finer signal, now that Stop removes it:
#
#   absent                       turn ended cleanly            idle
#   present, touched recently    tool calls still landing      busy
#   present, gone quiet          turn open, nothing happening  waiting  (a question, a
#                                                                       permission prompt,
#                                                                       a plan approval)
#
# FLEET_BUSY_FRESH_SEC bounds "recently". It is a display threshold, so it fails toward
# `waiting` — the state that draws the eye — rather than toward a confident `idle`.
agent_state() {  # name
  local m="$HOME/.claude/agent-busy/$1"
  [ -f "$m" ] || { echo idle; return; }
  if [ -n "$(find "$m" -newermt "-${FLEET_BUSY_FRESH_SEC:-120} seconds" 2>/dev/null)" ]; then
    echo busy
  else
    echo waiting
  fi
}

resolve_lanes_dir() {
  [ -n "$LANES_DIR" ] && { printf '%s' "$LANES_DIR"; return 0; }
  command -v fleet_lanes_dir >/dev/null 2>&1 || return 1
  fleet_lanes_dir 2>/dev/null
}

# Emit one TAB-separated record per lane: name, path, state, uptime.
# Everything else is read from the lane's own files by the renderer.
collect() {
  local dir="$1" registry="$HOME/.claude/running-agents" p name f bn pid token state up
  shopt -s nullglob
  for p in "$dir"/*/; do
    p="${p%/}"
    [ -d "$p" ] || continue
    name="$(basename "$p")"
    state=down up=""
    for f in "$registry/$name".*; do
      bn="$(basename "$f")"; pid="${bn##*.}"
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      token="$(cat "$f" 2>/dev/null)"
      if is_alive "$pid" "$token"; then
        state="$(agent_state "$name")"
        up="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
        break
      fi
    done
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$p" "$state" "$up" "lane"
  done

  # EVERY OTHER LIVE AGENT — reviewers, testers, planners. They occupy no lane (they run in
  # whoever spawned them cwd), so the lane loop above cannot see them, and leaving them out
  # makes the view claim a quiet fleet while four subagents are mid-audit. Their cwd comes
  # from the sidecar mark-busy.sh keeps current.
  local seen=""
  for f in "$registry"/*; do
    [ -f "$f" ] || continue
    bn="$(basename "$f")"; name="${bn%.*}"; pid="${bn##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ -d "$dir/$name" ] && continue                       # already emitted as a lane
    case " $seen " in *" $name "*) continue ;; esac
    token="$(cat "$f" 2>/dev/null)"
    is_alive "$pid" "$token" || continue
    seen="${seen:-} $name"
    p="$(cat "$HOME/.claude/agents/$name.cwd" 2>/dev/null)"
    up="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${p:-}" "$(agent_state "$name")" "$up" "subagent"
  done
}

render() {
  local dir="$1"
  collect "$dir" | COLUMNS="${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}" \
    FLEET_JSON="$JSON" FLEET_LANES="$dir" FLEET_NOW="$(date '+%H:%M:%S')" \
    python3 "$HERE/_fleet_status.py"
}

dir="$(resolve_lanes_dir)" || { echo "fleet-status: cannot resolve a lanes directory from $PWD" >&2; exit 1; }
[ -d "$dir" ] || { echo "fleet-status: lanes directory does not exist: $dir" >&2; exit 1; }

if [ "$WATCH" = 1 ]; then
  # The pane is the consumer here: clear-and-redraw, and never die on a transient error.
  while :; do
    out="$(render "$dir" 2>&1)"
    printf '\033[H\033[2J%s\n' "$out"
    sleep "$INTERVAL" || exit 0
  done
else
  render "$dir"
fi
