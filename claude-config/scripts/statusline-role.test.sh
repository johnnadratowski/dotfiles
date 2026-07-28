#!/bin/bash
# Self-contained tests for statusline-role.sh.  Run: bash .claude/scripts/statusline-role.test.sh
#
# Hermetic: a throwaway $HOME (never touches the real registry / sidecars) and fixture
# worktree dirs outside any git repo (so the lane lookup stays silent and the badge is
# just the role label).
#
# Locks in the DX-jn-cc-007 statusline hardening:
#   - a LIVE registration beats an alphabetically-earlier stale sidecar (the `4afe6cdd`
#     crash-debris shadow that mislabeled the coordinator `feat` on 2026-07-10)
#   - a DEAD registration does not win — self-ID falls back to the sidecar glob
#   - the sidecar fallback still resolves unregistered/headless sessions
#   - a non-agent cwd stays silent (exit 0, no output)

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$here/statusline-role.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: statusline-role.sh not found at $SCRIPT"; exit 1; }

pass=0; fail=0
eq(){ # eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1));
  else echo "  FAIL: $1"; echo "        expected: [$2]"; echo "        actual:   [$3]"; fail=$((fail+1)); fi
}

FAKEHOME="$(cd "$(mktemp -d)" && pwd -P)"
T="$(cd "$(mktemp -d)" && pwd -P)"
cleanup(){ rm -rf "$FAKEHOME" "$T"; }
trap cleanup EXIT INT TERM

mkdir -p "$FAKEHOME/.claude/running-agents" "$FAKEHOME/.claude/agents" "$T/wt" "$T/wt2"

# A provably dead pid: a subshell that has already been reaped.
( : ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null

# run <cwd> — the widget reads $PWD, $HOME, and drains stdin.
run(){ (cd "$1" && HOME="$FAKEHOME" bash "$SCRIPT" </dev/null); }

echo "statusline-role.sh"

# THE 2026-07-10 REPRO: crash debris — an alphabetically-earlier sidecar pointing at the
# coordinator's cwd, no live registration of its own. The pre-hardening picker took the
# first glob match and badged the coordinator `feat`.
printf '%s\n' "$T/wt" > "$FAKEHOME/.claude/agents/4afe6cdd.cwd"
printf '%s\n' "$T/wt" > "$FAKEHOME/.claude/agents/wf-cc.cwd"
printf 'cwd:%s\n' "$T/wt" > "$FAKEHOME/.claude/running-agents/wf-cc.$$"
eq "a LIVE registration beats alphabetically-earlier stale debris (the 4afe6cdd shadow)" \
   "cc" "$(run "$T/wt")"

# Same debris, but the registration is DEAD → the live pass yields nothing and the
# sidecar-glob fallback (first match) is the documented behavior.
rm -f "$FAKEHOME/.claude/running-agents/wf-cc.$$"
printf 'cwd:%s\n' "$T/wt" > "$FAKEHOME/.claude/running-agents/wf-cc.$DEADPID"
eq "a DEAD registration does not win — falls back to the sidecar glob (first match)" \
   "feat" "$(run "$T/wt")"

# Unregistered/headless: no running-agents entry at all — the fallback still resolves.
printf '%s\n' "$T/wt2" > "$FAKEHOME/.claude/agents/zz-9.cwd"
eq "sidecar fallback still resolves an unregistered agent" "feat" "$(run "$T/wt2")"

# .role override wins over the name pattern, on the live path too.
printf 'cwd:%s\n' "$T/wt2" > "$FAKEHOME/.claude/running-agents/zz-9.$$"
printf 'review\n' > "$FAKEHOME/.claude/agents/zz-9.role"
eq "the .role override applies on the live-registration path" "rev" "$(run "$T/wt2")"
rm -f "$FAKEHOME/.claude/agents/zz-9.role" "$FAKEHOME/.claude/running-agents/zz-9.$$"

# A cwd no agent claims: silent (exit 0, empty output) — the widget must not guess.
mkdir -p "$T/nobody"
out="$(run "$T/nobody")"; rc=$?
eq "an unclaimed cwd prints nothing" "" "$out"
eq "…and exits 0"                    "0" "$rc"

# A running-agents entry whose name has NO .cwd sidecar must not blow up the live pass —
# wf-cc's live registration (restored) must still win past it. `aa-no-sidecar` sorts
# before wf-cc, so a picker that trips on the missing sidecar would misresolve or die.
printf 'cwd:%s\n' "$T/wt" > "$FAKEHOME/.claude/running-agents/aa-no-sidecar.$$"
printf 'cwd:%s\n' "$T/wt" > "$FAKEHOME/.claude/running-agents/wf-cc.$$"
eq "a registration with no .cwd sidecar is skipped, not fatal" "cc" "$(run "$T/wt")"

# ---------------------------------------------------------------- DX-jn-cc-014: lane fallback
# The manifest path is resolved by fleet_manifest_path (_fleet.sh) — no hardcoded project
# filename — and the resolution runs in a subshell that is entered UNCONDITIONALLY: today's
# config subshell is gated on workflow.config EXISTING, and nesting the manifest read inside it
# would lose the lane in a repo that has no workflow.config (contradicting the resolver's
# zero-config promise).
echo
echo "DX-jn-cc-014 — lane fallback via fleet_manifest_path"

lanerepo(){  # <dir> — a git repo with the .claude tree AND a live registration, so the widget
             # resolves a role and reaches the lane block at all (a label-less run prints nothing).
  mkdir -p "$1/.claude" "$LH/.claude/running-agents" "$LH/.claude/agents"
  ( cd "$1" && git init -q . && git commit -q --allow-empty -m x ) 2>/dev/null
  local n; n="lane-$(basename "$1")"
  printf '%s\n' "$1" > "$LH/.claude/agents/$n.cwd"
  printf 'cwd:%s\n' "$1" > "$LH/.claude/running-agents/$n.$$"
}
lrun(){ ( cd "$1" && shift; env "$@" HOME="$LH" bash "$SCRIPT" </dev/null ); }

LH="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$LH/.config" "$LH/.claude/running-agents" "$LH/.claude/agents"
LR="$(cd "$(mktemp -d)" && pwd -P)"; lanerepo "$LR"
printf '{ "worktrees": [ {"path":"%s","lane":7} ] }\n' "$LR" > "$LH/.config/pinned-worktrees.json"

# (a) knob set ONLY in workflow.config (env knob explicitly UNSET — else the row would pass via
#     the env var even with the config read entirely absent: born-green)
printf 'WORKFLOW_WORKTREES_MANIFEST="%s"\n' "$LH/.config/pinned-worktrees.json" > "$LR/.claude/workflow.config"
eq "lane: manifest from workflow.config alone (env unset) → L7" "1" "$(lrun "$LR" -u WORKFLOW_WORKTREES_MANIFEST | grep -c 'L7')"

# (b) an exported env knob WINS over the config file
printf '{ "worktrees": [ {"path":"%s","lane":3} ] }\n' "$LR" > "$LH/.config/env-worktrees.json"
eq "lane: env knob beats the config file → L3" "1" "$(lrun "$LR" WORKFLOW_WORKTREES_MANIFEST="$LH/.config/env-worktrees.json" | grep -c 'L3')"

# (c) NO workflow.config at all + a manifest at the DERIVED default path → lane still resolves.
#     This is the row that reddens if the resolver is nested inside the config-exists branch.
LR2="$(cd "$(mktemp -d)" && pwd -P)"; LD="$LR2/$(basename "$LR2")"; mkdir -p "$LD"; lanerepo "$LD"
rm -f "$LD/.claude/workflow.config"
printf '{ "worktrees": [ {"path":"%s","lane":5} ] }\n' "$LD" > "$LH/.config/$(basename "$LD")-worktrees.json"
eq "lane: no workflow.config + manifest at the derived default → L5" "1" "$(lrun "$LD" -u WORKFLOW_WORKTREES_MANIFEST | grep -c 'L5')"

# (d) unresolvable → blank lane, still exit 0 (display-only: fail-soft, never a broken statusline)
LR3="$(cd "$(mktemp -d)" && pwd -P)"; lanerepo "$LR3"
d_out="$(lrun "$LR3" -u WORKFLOW_WORKTREES_MANIFEST)"; d_rc=$?
eq "lane: unresolvable → exit 0" "0" "$d_rc"
eq "lane: unresolvable → no lane suffix" "0" "$(printf '%s' "$d_out" | grep -c '·L')"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
