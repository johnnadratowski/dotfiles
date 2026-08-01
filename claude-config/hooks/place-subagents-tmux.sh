#!/bin/bash
# tmux `after-split-window` hook — put a newly-split agent pane under its parent.
#
# WHY THIS REPLACES THE CLAUDE-SIDE HOOK.
#
# `place-subagents.sh` is wired to Claude Code's `SubagentStart`. That event fires for
# IN-SESSION subagents. It does NOT fire for agent-team teammates — and with
# `teammateMode: "tmux"` every `Agent` spawn becomes a teammate, so on this machine it never
# fired at all. Verified twice: the docs list no hook for teammate creation (`TeammateIdle`
# is the only team hook, and it fires on idle, not spawn), and a probe spawn produced a pane
# with no log line whatsoever from an instrumented `place-subagents.sh`.
#
# That is why panes kept landing in the right-hand column: nothing was ever moving them. The
# retry loop, the lock, the attribution — all of it was correct code on a dead event.
#
# tmux's own `after-split-window` is the only event that actually fires here, because the
# harness creates the pane by splitting. It has no race: the pane exists by definition when
# the hook runs.
#
# TARGETING. `fleet-layout subagents` treats its `$TMUX_PANE` as the PARENT's pane and
# refuses to let a subagent rearrange its siblings. At `after-split-window` the active pane
# is the NEW one, so passing it through would hit exactly that guard. We therefore resolve
# the window's RESIDENT agent — the pane running a `--agent-name` claude that occupies a lane
# — and hand that in instead.
#
# BLAST RADIUS. The hook is global, so it fires on every split you make anywhere. It exits
# without touching anything unless the window contains a live fleet agent, and
# `layout_subagents` re-checks membership itself. Silent, always exit 0: a layout tweak must
# never break a split.

set -u

LOG="$HOME/.claude/debug/place-subagents.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
plog() { printf '%s [tmux] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

command -v tmux >/dev/null 2>&1 || exit 0
LAYOUT="$HOME/.claude/scripts/fleet-layout.sh"
[ -r "$LAYOUT" ] || exit 0

WIN="${1:-}"
[ -n "$WIN" ] || WIN="$(tmux display-message -p '#{window_id}' 2>/dev/null)"
[ -n "$WIN" ] || exit 0

# The window's resident agent = the FIRST pane (by tmux's own order) running any claude.
#
# NOT "the pane whose argv has --agent-name", which was the first attempt and picked a
# reviewer: only teammates and subagents are launched with --agent-name. The LEAD is started
# by team-boot typing a bare `claude --continue`, so it has no such flag and was skipped,
# leaving the first subagent to be named as its own parent. `fleet-layout subagents` then
# correctly refused — "this pane is itself a subagent" — and placed nothing.
#
# Pane order is the discriminator that holds for both cases: an agent window is created for
# its agent, and everything else in it arrived by splitting afterwards.
agent_pane=""
for p in $(tmux list-panes -t "$WIN" -F '#{pane_id}' 2>/dev/null); do
  ppid="$(tmux display -p -t "$p" '#{pane_pid}' 2>/dev/null)" || continue
  [ -n "$ppid" ] || continue
  # `ps`, not `pgrep -P`. On this macOS, `pgrep -P <pid>` with no pattern returns nothing
  # even when ps plainly shows the child — which silently skipped the LEAD's pane (whose
  # pane_pid is the zsh that claude runs under) and handed the job to the first reviewer.
  for k in $ppid $(ps -axo pid=,ppid= 2>/dev/null | awk -v pp="$ppid" '$2==pp{print $1}' | head -4); do
    case "$(ps -o command= -p "$k" 2>/dev/null)" in
      *claude*) agent_pane="$p"; break ;;
    esac
  done
  [ -n "$agent_pane" ] && break
done

[ -n "$agent_pane" ] || { plog "split in $WIN: no resident agent — leaving it alone"; exit 0; }

# Detached: the split should not wait on us, and tmux serialises its own commands anyway.
(
  out="$(TMUX_PANE="$agent_pane" bash "$LAYOUT" subagents 2>&1)"
  plog "split in $WIN, parent=$agent_pane -> $(printf '%s' "$out" | tr '\n' ';' | cut -c1-200)"
) >/dev/null 2>&1 &

exit 0
