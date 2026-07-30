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
mkdir -p "$LANES/feature-2" "$LANES/feature-9" "$TMP/elsewhere"

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
( cd "$TMP/elsewhere" && WORKFLOW_LANES_DIR="$LANES" "$GUARD" </dev/null >/dev/null 2>&1 )
check "non-teammate session is untouched" 0 "$?"

# 2 — teammate standing in its own lane.
as_teammate feature-2 "$LANES/feature-2" >/dev/null 2>&1
check "teammate inside its own lane is allowed" 0 "$?"

# 2b — a subdirectory of its lane is still its lane.
mkdir -p "$LANES/feature-2/server/models"
as_teammate feature-2 "$LANES/feature-2/server/models" >/dev/null 2>&1
check "teammate in a subdir of its lane is allowed" 0 "$?"

# 3 — THE CASE THAT MATTERS. Teammate writing from someone else's tree.
as_teammate feature-2 "$TMP/elsewhere" >/dev/null 2>&1
check "teammate OUTSIDE its lane is BLOCKED" 2 "$?"

# 3b — the specific real-world shape: teammate still sitting in ANOTHER lane
# (lane 0's tree, pre-EnterWorktree) rather than merely somewhere random.
as_teammate feature-2 "$LANES/feature-9" >/dev/null 2>&1
check "teammate sitting in another agent's lane is BLOCKED" 2 "$?"

# 4 — no lane provisioned under this name: the guard cannot know where it belongs,
# so it must not invent a verdict. Fail-open by design.
as_teammate feature-404 "$TMP/elsewhere" >/dev/null 2>&1
check "unknown agent name fails OPEN" 0 "$?"

# 5 — the block must explain itself; a bare exit 2 tells the agent nothing.
as_teammate feature-2 "$TMP/elsewhere" >/dev/null 2>&1
if grep -q 'EnterWorktree' "$TMP/err.txt" && grep -q "$LANES/feature-2" "$TMP/err.txt"; then
  pass=$((pass+1)); echo "  ok   block message names the tool and the target lane"
else
  fail=$((fail+1)); echo "  FAIL block message is missing the remedy or the lane path"
  sed 's/^/       /' "$TMP/err.txt"
fi

echo
echo "  passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
