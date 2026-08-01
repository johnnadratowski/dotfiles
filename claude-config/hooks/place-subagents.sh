#!/bin/bash
# SubagentStart hook — put a newly-spawned subagent's pane where its parent can read it.
#
# With `teammateMode: "tmux"` an Agent-tool spawn becomes a REAL pane, and the harness places it
# wherever tmux puts a new pane — in practice appended into the cell's right-hand companion
# column, squeezed under whatever else lives there. Several at once make the window unusable.
#
# This fires for EVERY agent that spawns a subagent, not just the lead: `fleet-layout subagents`
# targets `$TMUX_PANE`, so each agent stacks its own subagents beneath its own chat pane, and an
# agent's subagents never migrate to somebody else's window.
#
# WHY IT RETRIES, rather than sleeping once. The hook fires as the subagent STARTS. The pane may
# not exist yet, and — the case that actually bit — it may exist while `fleet-layout` still
# cannot ATTRIBUTE it, because attribution reads state the harness writes a moment later. A
# single `sleep 2` then lost the race silently: the verb ran, found nothing to place, reported
# success, and two reviewer panes sat in the right-hand column for a whole review round. So
# poll: up to PLACE_TRIES attempts, PLACE_GAP seconds apart, stopping the moment a run reports
# it placed something. The verb is idempotent — a pane already under the parent is joined where
# it already is — so an early attempt is harmless and a late one is still correct.
#
# WHY IT LOCKS. Spawning two reviewers in one message fires two hooks at once, and with retries
# that is two loops issuing join-pane against the same window. `mkdir` is atomic, so the first
# loop wins and the second exits immediately; the winner places every subagent it can see, not
# just the one whose spawn triggered it, so nothing is missed by the loser bowing out.
#
# Silent and always exit 0: a layout tweak must never fail a tool call.

set -u
payload="$(cat 2>/dev/null || true)"   # the hook payload; kept for the log below

# A SILENT HOOK IS AN UNDIAGNOSABLE HOOK. This one ran for weeks placing nothing, and the
# only symptom was panes in the wrong column — indistinguishable from "the feature does not
# exist". One append-only line per invocation costs nothing and answers the two questions
# that actually matter: did it fire, and whose TMUX_PANE did it fire with. The second is the
# open question: `fleet-layout subagents` treats $TMUX_PANE as the PARENT's pane, so if the
# hook is handed the NEW agent's pane instead, it silently arranges nothing.
PLACE_LOG="$HOME/.claude/debug/place-subagents.log"
mkdir -p "$(dirname "$PLACE_LOG")" 2>/dev/null || true
plog() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PLACE_LOG" 2>/dev/null || true; }
plog "fired. TMUX_PANE=${TMUX_PANE:-<unset>} pane_title=$(tmux display -p -t "${TMUX_PANE:-}" '#{pane_title}' 2>/dev/null || echo '?') payload=$(printf '%s' "$payload" | tr -d '\n' | cut -c1-200)"

# tmux-only. Without it there are no panes to arrange and nothing to do.
[ -n "${TMUX_PANE:-}" ] || { plog "exit: no TMUX_PANE"; exit 0; }
command -v tmux >/dev/null 2>&1 || exit 0

LAYOUT="$HOME/.claude/scripts/fleet-layout.sh"
[ -r "$LAYOUT" ] || exit 0

PLACE_TRIES="${PLACE_SUBAGENTS_TRIES:-6}"
PLACE_GAP="${PLACE_SUBAGENTS_GAP:-2}"

# Detached, with the parent's pane pinned: the subshell inherits TMUX_PANE, so the placement
# targets the pane that DID the spawning even though it runs after the hook returns.
(
  lock="${TMPDIR:-/tmp}/place-subagents.$(printf '%s' "$TMUX_PANE" | tr -d '%').lock"
  # A stale lock (a killed loop) must not disable placement forever. One minute is far longer
  # than PLACE_TRIES * PLACE_GAP, so a live loop is never evicted by this.
  if [ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null || true
  fi
  mkdir "$lock" 2>/dev/null || exit 0
  trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM

  i=0
  while [ "$i" -lt "$PLACE_TRIES" ]; do
    i=$((i + 1))
    sleep "$PLACE_GAP"
    out="$(TMUX_PANE="$TMUX_PANE" bash "$LAYOUT" subagents 2>/dev/null)" || continue
    case "$out" in
      *"placed 0"*|*"no live subagent panes"*) plog "try $i: nothing attributed yet ($out)"; continue ;;
      *"placed "*) plog "try $i: SUCCESS ($out)"; break ;;
      *) plog "try $i: unrecognized output ($out)"; continue ;;
    esac
    [ "$i" -lt "$PLACE_TRIES" ] || plog "gave up after $PLACE_TRIES tries" 
  done
) >/dev/null 2>&1 &

exit 0
