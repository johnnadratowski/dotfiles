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
# WHY BACKGROUNDED WITH A DELAY. The hook fires as the subagent STARTS; the pane may not exist,
# or may not yet be recorded in the team config that `subagents` reads, at the instant we run.
# Waiting inline would block the parent's turn on a cosmetic operation, so this detaches. The
# verb is idempotent — a pane already under the parent is joined to where it already is — so a
# too-early run is harmless and the next spawn catches any straggler.
#
# Silent and always exit 0: a layout tweak must never fail a tool call.

set -u
cat >/dev/null 2>&1 || true   # drain the hook payload (unused)

# tmux-only. Without it there are no panes to arrange and nothing to do.
[ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

LAYOUT="$HOME/.claude/scripts/fleet-layout.sh"
[ -x "$LAYOUT" ] || [ -r "$LAYOUT" ] || exit 0

# Detached, with the parent's pane pinned: the subshell inherits TMUX_PANE, so the placement
# targets the pane that DID the spawning even though it runs after the hook returns.
(
  sleep 2
  TMUX_PANE="$TMUX_PANE" bash "$LAYOUT" subagents
) >/dev/null 2>&1 &

exit 0
