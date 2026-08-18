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

# THE EXECUTABLE, NEVER THE ARGUMENTS. This was `case "$(ps -o command= …)" in *claude*)`,
# a substring test against the WHOLE command line — so any process whose arguments merely
# mentioned a claude-ish path was read as a claude session. That is not a corner case on this
# machine: every agent's scratchpad lives under `/private/tmp/claude-501/…`, so an ordinary
# `tmux split-window` running anything out of a scratchpad was identified as the window's
# resident agent, and this hook then relocated every live subagent pane into that window.
# Measured twice, reproducibly, with four teammate panes moved into a throwaway session.
#
# `ps -o comm=` is the executable PATH and nothing else, so no argument can reach this test.
# Two spellings are legitimate, because the fleet launches claude two ways: the lead gets the
# `claude` launcher on PATH, and every teammate gets the versioned binary the launcher execs
# (`~/.local/share/claude/versions/<version>` — whose basename is the VERSION, which is why
# `pane_current_command` on a teammate pane reads `2.1.233` and a basename test alone would
# miss all of them).
claude_exe() {  # claude_exe <executable path> -> 0 when it is a claude session's
  case "${1:-}" in
    claude|*/claude) return 0 ;;
    */claude/versions/*) return 0 ;;
  esac
  return 1
}
is_claude_pid() { claude_exe "$(ps -o comm= -p "${1:-}" 2>/dev/null)"; }

# SOURCEABLE FOR TEST. Everything above is definitions; everything below acts. The test
# suite sources this file to drive `claude_exe` against paths it can fabricate, which is the
# only way to assert the NEGATIVE case — that a command merely mentioning `claude` is not a
# claude process — without standing up a real agent to prove it.
[ "${PLACE_SUBAGENTS_LIB:-}" = "1" ] && return 0


LOG="$HOME/.claude/debug/place-subagents.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
plog() { printf '%s [tmux] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

command -v tmux >/dev/null 2>&1 || exit 0
LAYOUT="$HOME/.claude/scripts/fleet-layout.sh"
[ -r "$LAYOUT" ] || exit 0

# TARGETED BY THE NEW PANE'S ID, resolved to its window here.
#
# NOT `#{hook_pane}` or `#{hook_window}`. Both are documented in tmux 3.7b's man page and
# both expand to the EMPTY STRING at fire time — measured, by pointing the hook at
# `echo 'pane=#{hook_pane} win=#{hook_window} active=#{pane_id}'`. Only `#{pane_id}` was
# populated, and at after-split-window it names the pane that was just created, which is
# what we want.
#
# The empty expansion was invisible: the script fell back to "the currently active window",
# which for a real teammate spawn IS the right window, so placement worked. It only showed up
# when a background (`-d`) split in an unrelated window resolved to a third window entirely —
# and even then did no damage, because layout_subagents refuses a window holding no fleet
# agent. A wrong target that silently no-ops is the shape of bug this hook has had twice now.
PANE="${1:-}"
[ -n "$PANE" ] || PANE="$(tmux display-message -p '#{pane_id}' 2>/dev/null)"
[ -n "$PANE" ] || exit 0
WIN="$(tmux display-message -p -t "$PANE" '#{window_id}' 2>/dev/null)"
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
    if is_claude_pid "$k"; then agent_pane="$p"; break; fi
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
