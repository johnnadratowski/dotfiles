#!/bin/bash
# Tests for lane-guard.sh.
#
# The teammate case is simulated by invoking the guard from a parent process whose
# argv literally contains `--agent-name <n>` — which is exactly what the guard
# scans the process tree for, so the simulation exercises the real code path rather
# than a stubbed one.
#
# NON-VACUITY: case 3 must BLOCK. If the guard ever degrades to an unconditional
# `exit 0`, cases 1/2/4 all still pass and only case 3 turns red. That is the whole
# reason it is here, so it is asserted first-class rather than as a smoke check.

set -u
GUARD="$(cd "$(dirname "$0")" && pwd)/lane-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LANES="$TMP/lanes"
# LANE NAMES NO REAL AGENT CAN CARRY. The guard resolves its subject by walking the AMBIENT
# process tree, so a fixture lane named `feature-2` made case 1 resolve the NAME OF WHOEVER RAN
# THE SUITE, find that lane, and block — the row went red on correct code whenever a teammate
# named feature-2 or feature-9 ran it. The `lgt-` prefix cannot collide with a lane.
mkdir -p "$LANES/lgt-alpha" "$LANES/lgt-beta" "$TMP/elsewhere"

pass=0; fail=0
check() { # check <label> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s (exit %s)\n' "$1" "$3"
  else fail=$((fail+1)); printf '  FAIL %s: expected exit %s, got %s\n' "$1" "$2" "$3"; fi
}

# Runs the guard from a parent whose command line carries --agent-name.
# The lanes dir is a parameter so a row can stub it to its FAILURE value — a directory that
# does not exist — which is the only way to exercise the guard's silent-off path.
as_teammate() { # as_teammate <name> <cwd> [lanes-dir]
  # `${3-…}`, NOT `${3:-…}`: row 6b passes an explicitly EMPTY lanes dir, and the colon form
  # substitutes the default for empty as well as unset — so that row silently ran against the
  # real $LANES, found the lane, and reported BLOCKED instead of exercising the branch it names.
  # `${5-}` is the AGENT NAME PREFIX, and it is passed set-but-EMPTY by default on purpose:
  # that is the shape the guard sees in production (no exported prefix), so the default rows
  # exercise the config-FILE lookup rather than the env short-circuit.
  local name="$1" dir="$2" lanes="${3-$LANES}" home="${4:-$HOME}" prefix="${5-}"
  cat > "$TMP/fake-claude.sh" <<EOF
#!/bin/bash
cd "$dir" || exit 99
HOME="$home" WORKFLOW_LANES_DIR="$lanes" WORKFLOW_AGENT_NAME_PREFIX="$prefix" \
  "$GUARD" </dev/null 2>"$TMP/err.txt"
EOF
  chmod +x "$TMP/fake-claude.sh"
  /bin/bash "$TMP/fake-claude.sh" --agent-name "$name"
}

echo "lane-guard.sh"

# 1 — not a teammate at all: the lead, or any ordinary session. Never blocked.
#
# RUN DETACHED, deliberately. The guard walks the ambient process tree for `--agent-name`, and
# this suite's own ancestors ARE a teammate whenever an agent runs it — so invoked plainly this
# row resolved the runner's identity and passed only via the unrelated `[ -d "$expected" ] ||
# exit 0` fail-open further down. Deleting the no-name early return left the suite fully green.
# `setsid` (or a detached subshell where setsid is absent) severs the ancestry so the row
# exercises the branch it names.
_detached() {
  if command -v setsid >/dev/null 2>&1; then
    setsid env -u CLAUDE_AGENT_NAME WORKFLOW_LANES_DIR="$LANES" "$GUARD" </dev/null >/dev/null 2>&1
  else
    ( cd "$TMP/elsewhere" && exec -a sh /bin/sh -c \
        'WORKFLOW_LANES_DIR="'"$LANES"'" "'"$GUARD"'" </dev/null >/dev/null 2>&1' )
  fi
}
( cd "$TMP/elsewhere" && _detached )
check "non-teammate session is untouched" 0 "$?"

# 2 — teammate standing in its own lane.
as_teammate lgt-alpha "$LANES/lgt-alpha" >/dev/null 2>&1
check "teammate inside its own lane is allowed" 0 "$?"

# 2b — a subdirectory of its lane is still its lane.
mkdir -p "$LANES/lgt-alpha/server/models"
as_teammate lgt-alpha "$LANES/lgt-alpha/server/models" >/dev/null 2>&1
check "teammate in a subdir of its lane is allowed" 0 "$?"

# 3 — THE CASE THAT MATTERS. Teammate writing from someone else's tree.
as_teammate lgt-alpha "$TMP/elsewhere" >/dev/null 2>&1
check "teammate OUTSIDE its lane is BLOCKED" 2 "$?"

# 3b — the specific real-world shape: teammate still sitting in ANOTHER lane
# (lane 0's tree, pre-EnterWorktree) rather than merely somewhere random.
as_teammate lgt-alpha "$LANES/lgt-beta" >/dev/null 2>&1
check "teammate sitting in another agent's lane is BLOCKED" 2 "$?"

# 4 — no lane provisioned under this name: the guard cannot know where it belongs,
# so it must not invent a verdict. Fail-open by design.
as_teammate feature-404 "$TMP/elsewhere" >/dev/null 2>&1
check "unknown agent name fails OPEN" 0 "$?"

# 5 — the block must explain itself; a bare exit 2 tells the agent nothing.
as_teammate lgt-alpha "$TMP/elsewhere" >/dev/null 2>&1
if grep -q 'EnterWorktree' "$TMP/err.txt" && grep -q "$LANES/lgt-alpha" "$TMP/err.txt"; then
  pass=$((pass+1)); echo "  ok   block message names the tool and the target lane"
else
  fail=$((fail+1)); echo "  FAIL block message is missing the remedy or the lane path"
  sed 's/^/       /' "$TMP/err.txt"
fi

# 6 — A LANES DIR THAT DOES NOT EXIST TURNS THE GUARD OFF FOR THE WHOLE FLEET, so it has to
# say so. This is the failure the guard is least able to notice about itself: every lane looks
# unprovisioned, row 4's deliberate fail-open fires for every agent, and the result is
# indistinguishable from a protected fleet. It is not hypothetical — the derived fallback went
# stale when the lanes moved, and on any machine without ~/.claude/fleet.env this fired for
# every agent, silently.
#
# Stubbing the INPUT to its failure value, not mutating the guard: an input that fails open is
# invisible to happy-path reasoning, and every other row here supplies a lanes dir that exists.
as_teammate lgt-alpha "$TMP/elsewhere" "$TMP/no-such-lanes-dir" >/dev/null 2>&1
check "a non-existent lanes dir still fails OPEN" 0 "$?"
if grep -q 'INERT' "$TMP/err.txt" && grep -q 'UNGUARDED' "$TMP/err.txt"; then
  pass=$((pass+1)); echo "  ok   …but says so, naming the dir and the consequence"
else
  fail=$((fail+1)); echo "  FAIL a non-existent lanes dir disabled the guard SILENTLY"
  sed 's/^/       /' "$TMP/err.txt"
fi

# 6b — AND AN UNRESOLVABLE LANES DIR IS THE SAME CLASS, reached by a different route: no
# fleet.env AND `_lanes_dir` unable to derive (a hook whose cwd is not a git repo). The first
# version of the loud branch gated on `[ -n "$LANES_DIR" ]`, so this case fell through to
# exit 0 with zero bytes — set-but-missing shouted, empty stayed silent. A fix that closes one
# route into a silent-off state and leaves the other open has not closed the class.
# HOME is stubbed to an empty dir, and that is load-bearing rather than tidiness: the guard
# sources ~/.claude/fleet.env, whose entries are `${VAR:-default}` — so an explicitly EMPTY
# WORKFLOW_LANES_DIR gets the machine's real lanes dir substituted straight back in, and this
# row would silently exercise the set-and-exists path on any machine that has a fleet. The
# empty case is only REACHABLE where fleet.env is absent, which is exactly the machine this
# row is about.
mkdir -p "$TMP/nohome"
as_teammate lgt-alpha "$TMP/elsewhere" "" "$TMP/nohome" >/dev/null 2>&1
check "an UNRESOLVABLE lanes dir still fails OPEN" 0 "$?"
if grep -q 'INERT' "$TMP/err.txt"; then
  pass=$((pass+1)); echo "  ok   …and says so too, not only when the dir is merely missing"
else
  fail=$((fail+1)); echo "  FAIL an empty lanes dir disabled the guard SILENTLY"
fi

# Paired positive, so row 6 cannot pass by the guard shouting on every invocation: the ordinary
# unknown-agent fail-open (row 4) must stay quiet, because there the fleet is fine and only this
# one name is unrecognised.
as_teammate feature-404 "$TMP/elsewhere" >/dev/null 2>&1
if grep -q 'INERT' "$TMP/err.txt"; then
  fail=$((fail+1)); echo "  FAIL an unknown agent name wrongly reports the whole guard inert"
else
  pass=$((pass+1)); echo "  ok   …and stays quiet when only the NAME is unknown"
fi

# 7 — PREFIXED AGENT NAME, BARE LANE DIRECTORY. The live shape since goals-onchain set
# WORKFLOW_AGENT_NAME_PREFIX="g-": the agent is `g-feature-2`, its lane is `feature-2`.
# Measured before the fix: EVERY row in this block exited 0 — the guard resolved
# `$LANES/g-feature-2`, found nothing, and took row 4's fail-open, silently, for the whole
# fleet. These rows are the regression pin: they redden if prefix handling is ever dropped.
as_teammate g-lgt-alpha "$TMP/elsewhere" "$LANES" "$HOME" "g-" >/dev/null 2>&1
check "PREFIXED name outside its (bare-named) lane is BLOCKED" 2 "$?"

as_teammate g-lgt-alpha "$LANES/lgt-beta" "$LANES" "$HOME" "g-" >/dev/null 2>&1
check "PREFIXED name sitting in another lane is BLOCKED" 2 "$?"

# The paired positive: the fix must not start refusing CORRECT writes. Four live lane agents
# depend on this the moment it goes live.
as_teammate g-lgt-alpha "$LANES/lgt-alpha" "$LANES" "$HOME" "g-" >/dev/null 2>&1
check "PREFIXED name INSIDE its bare-named lane is allowed" 0 "$?"

as_teammate g-lgt-alpha "$LANES/lgt-alpha/server/models" "$LANES" "$HOME" "g-" >/dev/null 2>&1
check "PREFIXED name in a subdir of its lane is allowed" 0 "$?"

# The block must name the LANE, not the prefixed agent name, or the remedy it prints is an
# EnterWorktree path that does not exist.
as_teammate g-lgt-alpha "$TMP/elsewhere" "$LANES" "$HOME" "g-" >/dev/null 2>&1
# Matched by SHAPE, not by "$LANES/lgt-alpha": the guard prints the symlink-resolved path
# (`pwd -P`), so on macOS the fixture's /var/… becomes /private/var/… and a literal compare
# fails on correct output. The `/lgt-alpha"` tail is what carries the claim — it reddens if
# the guard ever prints the prefixed name.
if grep -q 'path: "[^"]*/lgt-alpha"' "$TMP/err.txt"; then
  pass=$((pass+1)); echo "  ok   …and the remedy names the BARE lane path"
else
  fail=$((fail+1)); echo "  FAIL the remedy path is not the bare lane"
  sed 's/^/       /' "$TMP/err.txt"
fi

# 7c — a prefix being CONFIGURED must not disturb a name that does not carry it. The raw
# name is tried first, so an unprefixed agent resolves exactly as it did before.
as_teammate lgt-alpha "$TMP/elsewhere" "$LANES" "$HOME" "g-" >/dev/null 2>&1
check "unprefixed name still resolves when a prefix IS configured" 2 "$?"

# 7d — a name that is NOTHING BUT the prefix must not strip to the lanes dir itself, which
# every lane is inside — i.e. it would allow writes from anywhere in the fleet.
as_teammate g- "$TMP/elsewhere" "$LANES" "$HOME" "g-" >/dev/null 2>&1
check "a name that is only the prefix does not resolve to the lanes dir" 0 "$?"

# 8 — THE PREFIX COMES FROM THE PROJECT'S CONFIG FILE, not the environment. That is the only
# path that runs in production: a hook inherits the environment its claude process was
# launched with, so a prefix added or changed after boot is invisible there. Rows above pass
# it via env; if only those existed, the live-shaped lookup would be untested.
ROOT="$TMP/clone"
mkdir -p "$ROOT/.claude/worktrees/lgt-gamma" "$ROOT/.claude"
echo 'WORKFLOW_AGENT_NAME_PREFIX="zz-"' > "$ROOT/.claude/workflow.config"
as_teammate zz-lgt-gamma "$TMP/elsewhere" "$ROOT/.claude/worktrees" >/dev/null 2>&1
check "prefix read from workflow.config: outside lane is BLOCKED" 2 "$?"
as_teammate zz-lgt-gamma "$ROOT/.claude/worktrees/lgt-gamma" "$ROOT/.claude/worktrees" >/dev/null 2>&1
check "prefix read from workflow.config: inside lane is allowed" 0 "$?"

# 8b — the gitignored per-machine file wins over the committed one, matching _config.sh's
# sourcing order. Without this, a machine-local prefix would be read as the committed one and
# the guard would resolve the wrong lane name.
mkdir -p "$ROOT/.claude/worktrees/lgt-delta"
echo 'WORKFLOW_AGENT_NAME_PREFIX="yy-"' > "$ROOT/.claude/workflow.config.local"
as_teammate yy-lgt-delta "$TMP/elsewhere" "$ROOT/.claude/worktrees" >/dev/null 2>&1
check "workflow.config.local overrides the committed prefix" 2 "$?"

echo
echo "  passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
