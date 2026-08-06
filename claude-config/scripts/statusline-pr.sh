#!/bin/bash
# ~/.claude/scripts/statusline-pr.sh (dotfiles)
#
# ccstatusline `custom-command` widget: prints "⇪ #133 #130" = every OPEN GitHub PR
# belonging to THIS worktree, each an OSC 8 hyperlink to the PR.
#
# WHY IT IS NOT A `gh` CALL. A status line renders on every prompt; a network round trip
# there would stall the bar. So this reads the same cache the fleet panel does
# (~/.claude/cache/fleet-prs.json, written by _agent_facts.refresh_open_prs on the panel's
# own schedule) and NEVER fetches. A stale or missing cache means the widget is silent, not
# that the prompt hangs.
#
# WHY IT DOES NOT MATCH ON THE BRANCH. A PR ships from a dedicated branch and the lane
# switches back to its own immediately after `gh pr create` — so from the moment a PR exists,
# this worktree's branch no longer names it. The match is on the ISSUE ID from
# `.claude/current-work`, which appears in both the PR title (`(Fixes FEAT-6)`) and the head
# branch (`john/feat-6-…`). Branch equality is kept only as the before-a-PR-exists case.
#
# Silent when there is nothing to say: no cache, no ids, no match. A draft is marked with a
# trailing "…" so it cannot read as ready to merge.
#
# Requires the widget's `preserveColors: true` (so ccstatusline keeps the OSC 8 escape) and
# tmux `terminal-features *:hyperlinks`. Same contract as statusline-todo.sh — keep in step.

cat >/dev/null 2>&1 || true   # drain the StatusJSON ccstatusline pipes in (unused)

root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f "$root/.claude/workflow.config" ] || exit 0

exec /usr/bin/env python3 - "$root" <<'PY'
import json, os, sys

root = sys.argv[1]
sys.path.insert(0, os.path.expanduser("~/.claude/scripts"))
try:
    from _agent_facts import open_prs_for
except Exception:
    sys.exit(0)

try:
    prs = open_prs_for(root)
except Exception:
    sys.exit(0)
if not prs:
    sys.exit(0)

# OSC 8, ST-terminated — byte-identical to ccstatusline's own `link` widget. ST, never BEL:
# the width-stripper treats ST as zero visible width and counts a BEL-terminated URL's bytes,
# which truncates the bar mid-escape and leaves the raw URL on screen.
def link(label, url):
    return "\033]8;;%s\033\\%s\033]8;;\033\\" % (url, label) if url else label

out = " ".join(link("#%s%s" % (n, "…" if d else ""), u) for n, u, d in prs)
sys.stdout.write("⇪ " + out)
PY
