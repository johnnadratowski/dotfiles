#!/bin/bash
# lane-guard — refuse writes from a teammate that is not standing in its own lane.
#
# WHY THIS EXISTS
#
# A teammate cannot be launched into a directory. There is no cwd parameter on the
# spawn; every teammate boots in the LEAD's worktree, on the lead's branch, and has
# to move itself with EnterWorktree as its first act. Between boot and that call it
# is a fully capable agent sitting in the wrong tree — verified in the spike, where
# a teammate ran in the lead's checkout until it obeyed the instruction. An agent
# that defers, forgets, or is interrupted before that call edits lane 0's files
# believing they are its own.
#
# It also guards a second failure, though a smaller one than it used to. Lanes now live
# INSIDE the main clone, at `<main clone>/.claude/worktrees/<agent>` — the one location
# EnterWorktree's permission gate carves out, which is why staffing no longer needs a
# human to approve a prompt per agent. This paragraph used to say the opposite: that lanes
# sat outside the checkout root and we depended on undocumented leniency to enter them at
# all. That leniency is no longer load-bearing. What remains is the window between boot and
# the EnterWorktree call, which is what the guard is really for.
#
# CONTRACT
#   PreToolUse, matcher Edit|Write|NotebookEdit. Exit 2 + stderr blocks the call.
#   Non-teammate sessions (no --agent-name in the process tree) are never affected,
#   so the lead and any ordinary session are untouched.
#
# FAILS OPEN, DELIBERATELY. If identity cannot be resolved this allows the write.
# A guard that fails closed on an unreadable /proc or an unexpected argv would brick
# every agent in the fleet at once; the cost of failing open is that the original
# hazard is merely not-improved, which is where we already were.

set -u

# DERIVED, never a project name — this hook lives in dotfiles and runs in every repo, so a
# hardcoded product path silently measured one product's lanes against another's writes.
# Unresolvable leaves it empty, which the fail-open contract above already handles.
_lanes_dir() {
  local common parent
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  parent="$(dirname "$common")"          # the MAIN CLONE, from any linked worktree
  case "$parent" in ''|'/'|'.') return 1 ;; esac
  printf '%s/.claude/worktrees' "$parent"
}
# Machine-local layout (see the long note in scripts/_fleet.sh). Sourced DIRECTLY rather than
# via _fleet.sh, because this hook must stay dependency-free — and read from a FILE rather than
# taken from the environment, because a hook's environment is the one its claude process was
# launched with. A lane directory that moves while the fleet is up would otherwise leave this
# guard computing a path that no longer exists, and line 69 below turns that into a silent
# exit 0: the guard would be off and nothing would say so.
[ -r "$HOME/.claude/fleet.env" ] && . "$HOME/.claude/fleet.env"
LANES_DIR="${WORKFLOW_LANES_DIR:-$(_lanes_dir 2>/dev/null || true)}"

# Walk up the process tree to find the claude process and read its --agent-name.
# The hook runs as a grandchild (claude -> shell -> this), and the depth is not
# contractual, so scan rather than assume a fixed number of hops.
agent_name=""
pid=$$
for _ in 1 2 3 4 5 6 7 8; do
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] || break
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
  case "$cmd" in
    *--agent-name*)
      agent_name="$(printf '%s' "$cmd" | sed -n 's/.*--agent-name[ =]\([^ ]*\).*/\1/p')"
      break ;;
  esac
done

# Not a teammate (lead, or any ordinary session) -> not our business.
[ -n "$agent_name" ] || exit 0

expected="$LANES_DIR/$agent_name"

# No lane provisioned under this name: we cannot say where it SHOULD be, so we do
# not get to say it is in the wrong place.
#
# BUT SAY SO. This is the guard's whole silent-failure surface: a wrong LANES_DIR makes
# every lane look unprovisioned, so the guard turns itself off for the entire fleet and
# nothing anywhere reports it. That is not hypothetical — the derivation above went stale
# when the lanes moved, and on any machine without ~/.claude/fleet.env this branch fired for
# every agent. One stderr line is the difference between "misconfigured, and it told me" and
# "protected, apparently". stderr on a non-blocking hook exit is surfaced to the agent, not
# to the user, which is the right audience: the agent is the thing standing in the wrong tree.
if [ ! -d "$expected" ]; then
  if [ -n "$LANES_DIR" ] && [ ! -d "$LANES_DIR" ]; then
    echo "lane-guard: INERT — lanes dir '$LANES_DIR' does not exist, so '$agent_name' cannot be" >&2
    echo "placed. Set WORKFLOW_LANES_DIR (see ~/.claude/fleet.env). Writes are UNGUARDED." >&2
  fi
  exit 0
fi

# Resolve both sides through symlinks so /tmp vs /private/tmp style aliasing does
# not produce a false block.
here="$(cd "$PWD" 2>/dev/null && pwd -P)" || exit 0
want="$(cd "$expected" 2>/dev/null && pwd -P)" || exit 0

case "$here" in
  "$want"|"$want"/*) exit 0 ;;
esac

cat >&2 <<EOF
BLOCKED: teammate '$agent_name' tried to write from outside its lane.

  cwd:      $here
  its lane: $want

You have not entered your worktree yet. Writing here edits ANOTHER agent's tree.

Call EnterWorktree with path: "$want" and retry. If that call fails, stop and
report the verbatim error — do not work around it by editing here.
EOF
exit 2
