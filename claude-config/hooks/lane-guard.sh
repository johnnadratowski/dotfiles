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
_clone_root() {
  local common parent
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  parent="$(dirname "$common")"          # the MAIN CLONE, from any linked worktree
  case "$parent" in ''|'/'|'.') return 1 ;; esac
  printf '%s' "$parent"
}
_lanes_dir() {
  local parent
  parent="$(_clone_root)" || return 1
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

# AGENT NAMES ARE PREFIXED; LANE DIRECTORIES ARE NOT.
#
# A project may prefix every agent NAME it registers (goals-onchain sets
# WORKFLOW_AGENT_NAME_PREFIX="g-") so that several fleets can share this machine's
# name-keyed stores — ~/.claude/agents/<name>.*, agent-busy/, running-agents/ — without
# one fleet's cleanup deregistering another's identically-named agent. LANE names are
# deliberately NOT prefixed: a lane is a directory/branch/tmux-window inside ONE clone and
# cannot collide. So the live pairing is agent `g-feature-2` living in lane `feature-2`.
#
# That split made this guard INERT for the entire fleet the day the prefix rolled out:
# `$LANES_DIR/g-feature-2` does not exist, every agent looked unprovisioned, and the
# unknown-name fail-open below fired for all of them — WITHOUT the loud INERT branch, since
# the lanes dir itself was fine. Silent, fleet-wide, and indistinguishable from protection.
#
# Read from the project's config FILES rather than the environment, for the same reason the
# lanes dir is: a hook's environment is whichever one its claude process was launched with,
# so a prefix introduced (or changed) after boot would not be visible here. An exported
# value still wins, matching _config.sh's env-wins contract.
_config_root() {
  case "$LANES_DIR" in
    */.claude/worktrees) printf '%s' "${LANES_DIR%/.claude/worktrees}" ;;
    *) _clone_root ;;
  esac
}
_agent_name_prefix() {
  local root
  if [ -n "${WORKFLOW_AGENT_NAME_PREFIX:-}" ]; then
    printf '%s' "$WORKFLOW_AGENT_NAME_PREFIX"; return 0
  fi
  root="$(_config_root 2>/dev/null || true)"
  [ -n "$root" ] || return 0
  # Subshell: the config files are shell snippets, so they neither leak assignments into the
  # guard nor get to write on its stdout. `set +u` because they are not written for it, and
  # the committed file is sourced BEFORE the gitignored .local one so per-machine wins —
  # the same order _config.sh uses.
  (
    set +u
    { [ -r "$root/.claude/workflow.config" ] && . "$root/.claude/workflow.config"
      [ -r "$root/.claude/workflow.config.local" ] && . "$root/.claude/workflow.config.local"
    } >/dev/null 2>&1
    printf '%s' "${WORKFLOW_AGENT_NAME_PREFIX:-}"
  )
}

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

# THE RAW NAME IS TRIED FIRST, and the stripped one only as a fallback. Order matters both
# ways: a fleet with no prefix (names and dirs coincide) is untouched, and a fleet WITH one
# cannot be made to resolve some other lane, because a directory that literally matches the
# agent's own name always wins. It also means this fix can never start refusing a write that
# used to pass: it only ADDS a resolution where there was none, and a write from inside the
# lane it resolves to is allowed.
if [ ! -d "$expected" ]; then
  _prefix="$(_agent_name_prefix)"
  if [ -n "$_prefix" ]; then
    case "$agent_name" in
      # `?*` so a name that is nothing BUT the prefix cannot strip to the lanes dir itself.
      "$_prefix"?*)
        _bare="${agent_name#"$_prefix"}"
        [ -d "$LANES_DIR/$_bare" ] && expected="$LANES_DIR/$_bare"
        ;;
    esac
  fi
fi

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
# EMPTY counts as broken, not as "nothing to say". The first version of this gated on
# `[ -n "$LANES_DIR" ] && [ ! -d … ]`, so a lanes dir that resolved to the empty string —
# no fleet.env AND `_lanes_dir` unable to derive, e.g. a hook whose cwd is not a git repo —
# fell straight through to `exit 0` with zero bytes of stderr. Measured: set-but-missing gave
# two lines, empty gave none. That is the same silent-off class as the stale-derivation bug
# this branch was written for, reachable by a different route, and it made "the guard cannot
# go quiet" un-certifiable. Unresolvable and wrong are both misconfiguration; both say so.
if [ ! -d "$expected" ]; then
  if [ -z "$LANES_DIR" ] || [ ! -d "$LANES_DIR" ]; then
    echo "lane-guard: INERT — lanes dir '${LANES_DIR:-<unresolved>}' does not exist, so" >&2
    echo "'$agent_name' cannot be placed. Set WORKFLOW_LANES_DIR (see ~/.claude/fleet.env)." >&2
    echo "Writes are UNGUARDED." >&2
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
