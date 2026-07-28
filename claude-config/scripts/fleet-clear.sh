#!/bin/bash
# fleet-clear.sh [--name-only] [--dry-run]
#
# Restore THIS agent's session name after a `/clear` -- optionally doing the clear too.
# Run it in the agent's own pane. It never touches another agent.
#
# WHY THIS EXISTS
# `/clear` silently drops the agent's session name, and the SessionStart auto-rename
# cannot put it back. register-agent.sh's settle re-check reads the name from
# `~/.claude/sessions/<pid>.json` -- keyed by PID. `/clear` starts a NEW session inside the
# SAME process, so that file still holds the OLD name. The settle compares it against
# boot_name, sees a match, and correctly concludes there is nothing to do -- while Claude
# Code's actual new session is unnamed. The check is structurally blind to the one case it
# exists for, so waiting longer never helps. Observed on feature-2: cleared at 12:44:19,
# settle at 12:44:24 logged "settled name matches boot name 'feature-2' -- no-op", name gone.
#
# WHY IT IS SELF-TARGETING
# The obvious fix -- have the coordinator drive `/clear` + `/rename` into the agent's pane --
# reintroduces the exact problem being solved: an external process typing into a pane while
# the human is using it. Right after clearing an agent you are normally typing to it, and
# `tmux send-keys` interleaves with your keystrokes. So this only ever sends to its OWN
# pane, only in direct response to you invoking it, and only while you are waiting for it.
# There is no timer, no daemon, and no cross-agent path.
#
# The name is read from the fleet registry, which register-agent.sh rewrites on every
# SessionStart (including the one `/clear` fires) -- so it is correct even though the
# session file is stale. That staleness is the bug; the registry is the source of truth.
#
# MODES
#   (default)     queue `/clear` then `/rename <name>` into this pane -- one step
#   --name-only   just `/rename <name>` -- run it after you cleared by hand
#
# NOT a restart. The process is untouched; only the conversation is cleared. Use
# `agent-fanout.sh restart` to reload machinery from disk.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
[ -r "$here/_fleet.sh" ] && . "$here/_fleet.sh"

REG="$HOME/.claude/running-agents"

die() { echo "fleet-clear: $*" >&2; exit 1; }

name_only=0; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name-only) name_only=1; shift ;;
    --dry-run) dry=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'. Usage: fleet-clear.sh [--name-only] [--dry-run]" ;;
  esac
done

[ -n "${TMUX_PANE:-}" ] || die "not inside a tmux pane -- nothing to send to."
command -v tmux >/dev/null 2>&1 || die "tmux unavailable."
[ -d "$REG" ] || die "no agent registry at $REG -- is this a registered fleet agent?"

command -v fleet_find_self >/dev/null 2>&1 || die "_fleet.sh not found next to this script."
self="$(fleet_find_self "$REG" 2>/dev/null || true)"
# Fail loudly rather than guess. A wrong name here would be typed into a live pane, and
# renaming an agent to something the fleet does not expect breaks message delivery to it.
[ -n "$self" ] || die "could not resolve this agent's name from the registry (pane $TMUX_PANE)."

if [ "$dry" = 1 ]; then
  if [ "$name_only" = 1 ]; then echo "DRY-RUN would send: /rename $self   (pane $TMUX_PANE)"
  else echo "DRY-RUN would send: /clear  then  /rename $self   (pane $TMUX_PANE)"; fi
  exit 0
fi

# Queue the keystrokes into our own pane. They land as ordinary input lines and run in
# order once this turn ends: /clear wipes the conversation, /rename restores the name on
# the session that clear created.
if [ "$name_only" != 1 ]; then
  tmux send-keys -t "$TMUX_PANE" -l "/clear"
  tmux send-keys -t "$TMUX_PANE" Enter
fi
tmux send-keys -t "$TMUX_PANE" -l "/rename $self"
tmux send-keys -t "$TMUX_PANE" Enter

if [ "$name_only" = 1 ]; then echo "fleet-clear: queued /rename $self"
else echo "fleet-clear: queued /clear then /rename $self"; fi
