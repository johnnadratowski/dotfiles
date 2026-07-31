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
as_teammate() { # as_teammate <name> <cwd>
  local name="$1" dir="$2"
  cat > "$TMP/fake-claude.sh" <<EOF
#!/bin/bash
cd "$dir" || exit 99
WORKFLOW_LANES_DIR="$LANES" "$GUARD" </dev/null 2>"$TMP/err.txt"
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

echo
echo "  passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
