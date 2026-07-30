#!/bin/bash
# Self-contained tests for fleet-layout.sh.  Run: bash .claude/scripts/fleet-layout.test.sh
#
# Hermetic on two axes:
#   1. a throwaway $HOME  — never touches the real registry / agent sidecars
#   2. a throwaway tmux SERVER on its own socket — never touches the live fleet
#
# (2) is the sanctioned exception to fleet-layout's "never spawn a second tmux server"
# invariant. It is safe ONLY because every tmux call below carries -L "$SOCKET", including
# the EXIT trap. A bare `tmux kill-server` in a teardown would reset every pane id on the
# DEFAULT socket and staleness-bomb the live fleet's registry (the pruning path would
# prune live agents). assert_scratch_socket() enforces that before anything destructive.
#
# Locks in the findings from the DX-jn-cc-001 plan + diff reviews:
#   - a companion that `cd`s into a SUBDIR still matches (boundary-aware prefix)
#   - a SIBLING worktree whose path shares a string prefix must NOT match, and neither does a
#     prefix-sharing directory that NO agent owns (longest-match alone wouldn't catch that)
#   - another agent's claude pane is never a companion
#   - a stale .cwd sidecar (no live registry entry) claims nothing
#   - the @fleet-layout-skip opt-out marker is honored
#   - window naming: single / same-role / mixed-role / no-agents
#   - --dry-run mutates nothing;  name-windows is idempotent
#   - a failed join ABORTS instead of leaving a half-built window (invariant 6)
#   - attribution is snapshotted before any pane moves (mid-build rescan drops companions)
#   - `wide` really assembles: geometry, no pane destroyed, idempotent
#   - a duplicate window name cannot make `wide` break out a second `features` window
#   - kill verbs are ALLOWLISTED (DX-jn-cc-010): kill-pane only inside _down_kill_pane
#     (the `down` verb's single kill helper), one kill-window (placeholder drop), one
#     kill-session (_teardown_ext via _rw), no kill-server, no pid signal but kill -0
#   - boot builds each new window into the cell (DX-jn-cc-012): claude full-height left,
#     monocle top-right, shell bottom-right; a failed split/keystroke degrades loudly
#     without losing the claude launch

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$here/fleet-layout.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: fleet-layout.sh not found at $SCRIPT"; exit 1; }

# _config.sh is PROJECT content — it ships in the consuming repo's .claude/scripts/, not
# alongside this file. The scratch-repo tests below need the real loader (a stub would prove
# nothing about whether fleet-layout reads workflow.config), so resolve it from the invoking
# project and SKIP those tests loudly if it cannot be found. Previously these lines copied
# "$here/_config.sh", which never exists: one site swallowed the error with `|| true` and its
# assertion then failed for the wrong reason, the other printed a bare `cp: No such file`.
CONFIG_SH=""
for _c in "$here/_config.sh" \
          "$(git rev-parse --show-toplevel 2>/dev/null)/.claude/scripts/_config.sh"; do
  [ -f "$_c" ] && { CONFIG_SH="$_c"; break; }
done
[ -n "$CONFIG_SH" ] || echo "NOTE: _config.sh not resolvable — workflow.config-loading tests will SKIP"

# --- GIT ISOLATION TRIPWIRE (DX-jn-cc-020) — the THIRD hermetic axis ------------------------
# This test builds SCRATCH git repos (git init/commit/worktree-add in mktemp dirs). A setup
# escape once let those MUTATIONS hit the CALLER'S real repo: on 2026-07-20 a push ran this
# test via the pre-push hook and it committed junk `x` commits + `wt`/`wtb` branches onto the
# live `john-cc` branch, then a wipe. Wrap `git` so a mutating subcommand can NEVER land in the
# invoking repo: if the resolved git-dir is the real one, abort LOUD instead of corrupting it.
_REALGIT="$(command -v git)"
_REAL_GITDIR="$( cd "$here" && "$_REALGIT" rev-parse --absolute-git-dir 2>/dev/null || echo __no_real_repo__ )"
# THE actual escape (2026-07-20): git exports GIT_DIR / GIT_INDEX_FILE / … into hook processes,
# so when the PRE-PUSH hook ran this test, GIT_DIR pointed at the real repo and OVERRODE cwd-based
# discovery — a scratch `git init`/`commit` mutated the caller's repo no matter which dir it cd'd
# into. That is why it only ever struck during a push, never standalone. Unset the inherited git
# env so scratch dirs are the ONLY context git can resolve. (The wrapper below is defense-in-depth.)
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_NAMESPACE GIT_PREFIX GIT_CONFIG 2>/dev/null || true
git() {
  # Find the subcommand, skipping leading global options (-c k=v, -C dir, --git-dir=…, …).
  local sub="" skipnext=0 a
  for a in "$@"; do
    if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
    case "$a" in
      -c|-C|--git-dir|--work-tree|--namespace) skipnext=1; continue ;;
      -*) continue ;;
      *) sub="$a"; break ;;
    esac
  done
  case "$sub" in
    init|clone|commit|add|worktree|branch|checkout|switch|reset|merge|rebase|rm|mv|apply|am|tag|update-ref|fetch|pull|push|stash|cherry-pick|restore)
      local gd
      gd="$( "$_REALGIT" rev-parse --absolute-git-dir 2>/dev/null || true )"
      if [ -n "$gd" ] && [ "$gd" = "$_REAL_GITDIR" ]; then
        echo "FATAL (DX-jn-cc-020 tripwire): refusing 'git $sub' — it resolves to the REAL repo ($gd)." >&2
        echo "  A scratch-repo setup escaped isolation; refusing to mutate the caller's branch." >&2
        exit 97
      fi ;;
  esac
  "$_REALGIT" "$@"
}

command -v tmux >/dev/null 2>&1 || { echo "fleet-layout.test.sh: tmux not installed — skipping"; exit 0; }

SOCKET="fleetlayouttest.$$"
pass=0; fail=0

# ok() runs under `set -o pipefail`, and `grep -q` exits on its first match — which SIGPIPEs
# the producer, so `<cmd> | grep -q <present-pattern>` reports 141 even on success. Use ok()
# only for NEGATIVE greps (`! … | grep -q`), where the producer always runs to completion.
# To assert a pattern IS present, use eq() against the matched line.
ok(){ if eval "$2" >/dev/null 2>&1; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }
eq(){ # eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1));
  else echo "  FAIL: $1"; echo "        expected: [$2]"; echo "        actual:   [$3]"; fail=$((fail+1)); fi
}

# ---------------------------------------------------------------- socket guard
# Every tmux call in this file goes through t(). Nothing else may call tmux.
t(){ command tmux -L "$SOCKET" "$@"; }

assert_scratch_socket(){
  case "$SOCKET" in
    ''|default) echo "REFUSING: destructive tmux verb on the default socket"; exit 1 ;;
  esac
  case "$SOCKET" in
    fleetlayouttest.*) : ;;
    *) echo "REFUSING: socket '$SOCKET' is not a recognized scratch socket"; exit 1 ;;
  esac
}

cleanup(){
  assert_scratch_socket
  t kill-server 2>/dev/null
  rm -f "/tmp/tmux-$(id -u)/$SOCKET"        # kill-server leaves the socket file behind
  [ -n "${T:-}" ] && rm -rf "$T"
  [ -n "${FAKEHOME:-}" ] && rm -rf "$FAKEHOME"
}
trap cleanup EXIT INT TERM   # EXIT alone leaks the scratch server + tmpdirs on Ctrl-C

# ---------------------------------------------------------------- fixture
# Worktrees are deliberately named so that `proj` is a literal string prefix of
# `proj-2` — the exact trap that makes naive prefix matching misattribute panes.
# Physical paths. macOS symlinks /var -> /private/var, and tmux reports pane_current_path
# resolved; a logical $T would match no pane and silently empty every fixture variable.
T="$(cd "$(mktemp -d)" && pwd -P)"
FAKEHOME="$(cd "$(mktemp -d)" && pwd -P)"
# `proj-extra` shares a string prefix with `proj` and is owned by NO agent. It is what
# isolates the boundary-aware prefix rule: `proj-2` alone cannot, because longest-match
# would hand that pane to x-2 even under a (wrong) bare-prefix comparison.
mkdir -p "$T/proj/server" "$T/proj-2" "$T/proj-3" "$T/proj-4" "$T/proj-extra" "$T/pr" "$T/test"
mkdir -p "$FAKEHOME/.claude/running-agents" "$FAKEHOME/.claude/agents"

assert_scratch_socket
# w1: claude(x-1) + companion in a SUBDIR + a skip-marked companion at the root
# -x/-y give the detached server a real size, so join-pane has room and _precheck_room passes.
t new-session  -d -x 200 -y 50 -s main -n w1 -c "$T/proj" 'sleep 600'
t split-window -d -t main:w1   -c "$T/proj/server"  'sleep 600'
t split-window -d -t main:w1   -c "$T/proj"         'sleep 600'
t split-window -d -t main:w1   -c "$T/proj-extra"   'sleep 600'
# w2: claude(x-2) + companion  (sibling worktree — string-prefix trap)
t new-window   -d -t main -n w2 -c "$T/proj-2"      'sleep 600'
t split-window -d -t main:w2   -c "$T/proj-2"       'sleep 600'
# w3: two claude panes, MIXED roles (review + test) — a legacy pane shape (grandfathered names; the post-DX-jn-cc-005 fleet is cc + feature)
t new-window   -d -t main -n w3 -c "$T/pr"           'sleep 600'
t split-window -d -t main:w3   -c "$T/test"          'sleep 600'
# w4/w5: feature agents 3 and 4. Four features is what makes `wide` a real 2x2, and what makes
# `dual` produce TWO windows that derive the same name and must be disambiguated.
t new-window   -d -t main -n w4 -c "$T/proj-3"      'sleep 600'
t split-window -d -t main:w4   -c "$T/proj-3"       'sleep 600'
t new-window   -d -t main -n w5 -c "$T/proj-4"      'sleep 600'
t split-window -d -t main:w5   -c "$T/proj-4"       'sleep 600'

read_panes(){ t list-panes -a -F '#{window_name} #{pane_id} #{pane_current_path}'; }
pane_at(){ read_panes | awk -v w="$1" -v p="$2" '$1==w && $3==p {print $2; exit}'; }

P_A="$(pane_at w1 "$T/proj")"            # claude(x-1)  — first pane created in w1
P_B="$(pane_at w1 "$T/proj/server")"     # companion in a subdir
P_C="$(read_panes | awk -v w=w1 -v p="$T/proj" '$1==w && $3==p {print $2}' | tail -1)"  # skip-marked
P_H="$(pane_at w1 "$T/proj-extra")"      # prefix-sharing dir owned by NO agent
P_D="$(pane_at w2 "$T/proj-2")"          # claude(x-2)
P_E="$(read_panes | awk -v w=w2 -v p="$T/proj-2" '$1==w && $3==p {print $2}' | tail -1)"
P_F="$(pane_at w3 "$T/pr")"               # claude(x-pr)
P_G="$(pane_at w3 "$T/test")"             # claude(x-test-1)
P_I="$(pane_at w4 "$T/proj-3")"          # claude(x-3)
P_J="$(read_panes | awk -v w=w4 -v p="$T/proj-3" '$1==w && $3==p {print $2}' | tail -1)"
P_K="$(pane_at w5 "$T/proj-4")"          # claude(x-4)
P_L="$(read_panes | awk -v w=w5 -v p="$T/proj-4" '$1==w && $3==p {print $2}' | tail -1)"

# Guard the fixture itself. An empty pane id would make the assertions below compare "" to ""
# and pass without exercising anything — the failure mode this fixture already had once.
for v in P_A P_B P_C P_D P_E P_F P_G P_H P_I P_J P_K P_L; do
  eval "val=\$$v"
  [ -n "$val" ] || { echo "FATAL: fixture pane $v is empty — the harness is broken, not the script"; exit 1; }
done
[ "$P_A" != "$P_C" ] || { echo "FATAL: fixture pane P_A and P_C are the same pane"; exit 1; }

t set-option -p -t "$P_C" @fleet-layout-skip 1

# Registry: <name>.<pid> containing the pane id.  $$ is a real live pid, so fleet_alive passes.
reg(){ printf '%s\n' "$2" > "$FAKEHOME/.claude/running-agents/$1.$$"; printf '%s\n' "$3" > "$FAKEHOME/.claude/agents/$1.cwd"; }
reg x-1      "$P_A" "$T/proj"
reg x-2      "$P_D" "$T/proj-2"
reg x-pr     "$P_F" "$T/pr"
reg x-test-1 "$P_G" "$T/test"
reg x-3      "$P_I" "$T/proj-3"
reg x-4      "$P_K" "$T/proj-4"
# Stale sidecar: a dead agent whose .cwd still points at a live worktree. Must claim nothing.
printf '%s\n' "$T/proj" > "$FAKEHOME/.claude/agents/x-dead.cwd"

# Run the script's library half with our fake HOME + scratch socket.
# TMUX_PANE must be non-empty or the dispatcher's fleet_tmux_ok gate exits 0 before doing
# anything — every `run` test then passes its "exits 0" check while asserting against a
# layout that never ran (27 silent failures when the suite is invoked headless).
#
# FORCE the sentinel — NEVER inherit the ambient $TMUX_PANE. This is the root of the 12% flake
# (root-caused 2026-07-11): the real pane running the suite has an id like %59; the SCRATCH server
# mints its own ids from %0 upward; and the fixtures below deliberately use $TMUX_PANE as the
# self-token. Once a run had created enough panes to reach that number, an AGENT's scratch pane id
# COLLIDED with the self-token — `down` saw the agent as ITSELF and refused to kill it
# ("REFUSED (self …)"), and boot's self-skip could misfire the same way. Intermittent by
# construction (it depended on how many panes the run happened to create) and invisible whenever
# the suite ran outside tmux. A wider FLEET_DOWN_SETTLE cannot mask it: a REFUSED kill never
# reaches the settle loop, which only waits on kills it actually attempted.
# Reproduce the old bug with:  TMUX_PANE='%59' bash fleet-layout.test.sh
export TMUX_PANE='%fl-test'
lib(){ HOME="$FAKEHOME" FLEET_TMUX_SOCKET="$SOCKET" FLEET_LAYOUT_LIB=1 bash -c "source '$SCRIPT'; $*"; }
run(){ HOME="$FAKEHOME" FLEET_TMUX_SOCKET="$SOCKET" bash "$SCRIPT" "$@"; }

echo "fleet-layout.sh — socket=$SOCKET"

echo; echo "live_agents"
eq "finds exactly the 6 registered live agents" \
   "x-1 x-2 x-3 x-4 x-pr x-test-1" \
   "$(lib 'live_agents' | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"
ok "the stale x-dead sidecar is not a live agent" \
   "! lib 'live_agents' | cut -f1 | grep -qx x-dead"

echo; echo "attribute_panes"
eq "x-1's claude pane is its registry token" "$P_A" "$(lib 'attribute_panes' | awk -F'\t' '$1=="x-1"{print $2}')"
eq "x-1's companion is the SUBDIR pane only (boundary prefix; skip-marked pane excluded)" \
   "$P_B" "$(lib 'attribute_panes' | awk -F'\t' '$1=="x-1"{print $3}')"
ok "the sibling worktree's panes never attach to x-1 (longest-match)" \
   "! lib 'attribute_panes' | awk -F'\t' '\$1==\"x-1\"{print \$3}' | grep -q '$P_D\|$P_E'"
# Isolates the boundary rule: no agent owns proj-extra, so longest-match cannot rescue this.
# A bare `case \$ppath in \$a_cwd*` would hand this pane to x-1.
ok "an unowned dir sharing x-1's string prefix is NOT a companion (boundary-aware prefix)" \
   "! lib 'attribute_panes' | cut -f3 | grep -q '$P_H'"
eq "x-2 claims its own companion" "$P_E" "$(lib 'attribute_panes' | awk -F'\t' '$1=="x-2"{print $3}')"
ok "another agent's claude pane is never a companion" \
   "! lib 'attribute_panes' | cut -f3 | grep -q '$P_G'"
eq "x-pr has a claude pane and no companions" "$P_F|" "$(lib 'attribute_panes' | awk -F'\t' '$1=="x-pr"{print $2"|"$3}')"

echo; echo "window_name_from_names"
eq "one agent -> its own name"            "x-1"         "$(lib 'window_name_from_names x-1')"
eq "two features -> the plural role"      "features"    "$(lib 'window_name_from_names x-1 x-2')"
eq "review + test -> sorted, hyphenated"  "review-test" "$(lib 'window_name_from_names x-pr x-test-1')"
eq "no agents -> empty (window untouched)" ""           "$(lib 'window_name_from_names')"

echo; echo "name-windows"
before="$(t list-windows -t main -F '#{window_name}' | tr '\n' ',')"
run name-windows --dry-run >/dev/null 2>&1
eq "--dry-run mutates nothing" "$before" "$(t list-windows -t main -F '#{window_name}' | tr '\n' ',')"

run name-windows >/dev/null 2>&1
# Anchored to the AGENTS' panes, not window indices: name-windows also reorders the session
# (cc, features, review/test, others), so an index no longer identifies a fixture window.
wname(){ t list-panes -a -F '#{pane_id} #{window_name}' | awk -v q="$1" '$1==q{print $2; exit}'; }
eq "the window with one claude pane is named for its agent" "x-1"         "$(wname "$P_A")"
eq "x-2's window is named for it"                           "x-2"         "$(wname "$P_D")"
eq "the review + test co-tenant window is named by role"    "review-test" "$(wname "$P_F")"
eq "…and both co-tenants agree on it"                       "review-test" "$(wname "$P_G")"

after1="$(t list-windows -t main -F '#{window_name}' | tr '\n' ',')"
run name-windows >/dev/null 2>&1
eq "name-windows is idempotent" "$after1" "$(t list-windows -t main -F '#{window_name}' | tr '\n' ',')"

echo; echo "layout geometry (dry-run command stream)"
# x-1 and x-2 are the two live feature agents, ordered f1, f2 by fleet_agent_id.
eq "wide seeds the grid by breaking f1's claude pane into 'features'" \
   "tmux break-pane -d -s $P_A -n features" \
   "$(run wide --dry-run 2>/dev/null | grep 'break-pane')"
# grep patterns must be boundary-anchored: "-s %1" is a substring of "-s %11".
eq "wide places f2 to the RIGHT of f1 (side-by-side cells)" \
   "tmux join-pane -h -s $P_D -t $P_A" \
   "$(run wide --dry-run 2>/dev/null | grep -E -- "-s ${P_D}( |\$)")"
eq "dual STACKS f2 below f1 (one column of rows, not side-by-side)" \
   "tmux join-pane -v -s $P_D -t $P_A" \
   "$(run dual --dry-run 2>/dev/null | grep -E -- "-s ${P_D}( |\$)")"
eq "a cell puts its companion to the right of the claude pane" \
   "tmux join-pane -h -s $P_B -t $P_A" \
   "$(run wide --dry-run 2>/dev/null | grep -E -- "-s ${P_B}( |\$)")"
eq "dual seeds features-1 from f1's claude pane" \
   "tmux break-pane -d -s $P_A -n features-1" \
   "$(run dual --dry-run 2>/dev/null | grep -E -- "break-pane -d -s ${P_A}( |\$)")"
eq "dual seeds features-2 from f3's claude pane" \
   "tmux break-pane -d -s $P_I -n features-2" \
   "$(run dual --dry-run 2>/dev/null | grep -E -- "break-pane -d -s ${P_I}( |\$)")"

echo; echo "abort on a failed join (invariant: never partially apply)"
# Stub _rw so join-pane fails. A build that ignores the return code emits a SECOND join and
# reports success — that is the bug this locks down. DRY_RUN=1 makes _precheck_room pass, so
# a nonzero rc can only come from the join, never from the size guard.
FAILJOIN='DRY_RUN=1; _rw(){ case "$1" in join-pane) echo "JOIN $*"; return 1;; *) echo "OTHER $*"; return 0;; esac; }'
eq "build_cell returns nonzero on a failed join"      "1" "$(lib "$FAILJOIN; build_cell %90 %91 %92 >/dev/null" 2>/dev/null; echo $?)"
eq "build_cell stops after the FIRST join, not two"   "1" "$(lib "$FAILJOIN; build_cell %90 %91 %92" 2>/dev/null | grep -c '^JOIN')"
eq "_gather_grid propagates the abort"                "1" "$(lib "$FAILJOIN; _snapshot_attr; _gather_grid features x-1 x-2 >/dev/null" 2>/dev/null; echo $?)"
eq "_gather_grid aborted at the join, not the precheck" "1" "$(lib "$FAILJOIN; _snapshot_attr; _gather_grid features x-1 x-2" 2>/dev/null | grep -c '^JOIN')"
eq "_gather_pair propagates the abort"                "1" "$(lib "$FAILJOIN; _snapshot_attr; _gather_pair features-1 x-1 x-2 >/dev/null" 2>/dev/null; echo $?)"
eq "build_cell succeeds when every join succeeds"     "0" "$(lib 'DRY_RUN=1; _rw(){ return 0; }; build_cell %90 %91 %92' >/dev/null 2>&1; echo $?)"

echo; echo "attribution is snapshotted before any pane moves"
# Re-deriving mid-build would drop a cell's companions: once a claude pane joins the seed's
# session, its companions are still in their original one and fail the same-session check.
eq "_attr serves the snapshot when FL_ATTR is set"    "SNAP" "$(lib 'FL_ATTR=SNAP; _attr')"
eq "_attr falls back to a live scan when unset"       "x-1"  "$(lib '_attr' | cut -f1 | head -1)"
eq "layout_wide snapshots before it moves anything" "1" \
   "$(grep -A3 '^layout_wide' "$SCRIPT" | grep -c '_snapshot_attr')"

echo; echo "cell balance is cell-relative, not window-relative"
# `resize-pane -x N%` is a percentage of the WINDOW. In an N-cell grid it overshoots the cell:
# it clamps the companion column to 1 col AND steals columns from the neighbouring cell.
ok "the script never resizes by percentage" \
   "! grep -qE 'resize-pane[^|]*-x [0-9]+%' '$SCRIPT'"
# cell = 50 + 49 + 1 border = 100 cols; 60% of the CELL = 60. (60% of a 200-col window = 120.)
eq "_balance_cell computes 60% of the CELL (claude+comp+border), in columns" \
   "60" \
   "$(lib '_pane_width(){ case "$1" in %90) echo 50;; %91) echo 49;; esac; }
           tmux(){ [ "$1" = resize-pane ] && echo "$5"; }
           _balance_cell %90 %91')"
eq "_balance_cell leaves a cell too narrow to split alone" \
   "" \
   "$(lib '_pane_width(){ case "$1" in %90) echo 12;; %91) echo 12;; esac; }
           tmux(){ [ "$1" = resize-pane ] && echo "$5"; }
           _balance_cell %90 %91')"

echo; echo "safety (kill-verb allowlist on comment-stripped source — DX-jn-cc-010)"
# Counting method (calibrated): executable invocations on COMMENT-STRIPPED source. A
# dry-run printf is executable source — the old raw kill-session count of 4 hid exactly
# that (2 comments + a hand-rolled dry-run printf + the call); _teardown_ext's kill now
# routes through the verb-generic _rw, so the expected count is 1 and the check provably
# passes on correct code AND fails on any new kill-session.
nocom(){ grep -vE '^[[:space:]]*#' "$SCRIPT"; }
eq "kill-server never appears"                      "0" "$(nocom | grep -c 'kill-server')"
eq "the only kill-window is the placeholder drop"   "1" "$(nocom | grep -c 'kill-window')"
eq "the only kill-session is _teardown_ext's (via _rw)" "1" "$(nocom | grep -c 'kill-session')"
# kill-pane is confined to ONE helper: the whole-file count must equal the count inside
# _down_kill_pane's body. A kill-pane leaking anywhere else breaks the equality; the
# >=1 row keeps the equality from passing vacuously (0 == 0) if the helper is renamed.
kp_file="$(nocom | grep -c 'kill-pane')"
kp_body="$(awk '/^_down_kill_pane\(\)/,/^}/' "$SCRIPT" | grep -vE '^[[:space:]]*#' | grep -c 'kill-pane')"
ok "_down_kill_pane exists and holds a kill-pane (so the equality below can fail)" "[ '$kp_body' -ge 1 ]"
eq "every kill-pane in the file lives inside _down_kill_pane" "$kp_file" "$kp_body"
# Caller allowlist: confining the STRING to one helper doesn't stop a layout verb from
# CALLING it — only down-path functions may.
ok "only down-path functions call _down_kill_pane" \
   "[ -z \"\$(awk '/^[A-Za-z_][A-Za-z0-9_]*\(\)/{fn=\$1} /_down_kill_pane/ && !/^[[:space:]]*#/{print fn}' '$SCRIPT' | sed 's/().*//' | sort -u | grep -vE '^(_down_|down_fleet)')\" ]"
# down never signals pids: the only `kill -` in the file is the kill -0 liveness probe.
eq "no pid signal other than kill -0" "0" "$(nocom | grep -E 'kill +-' | grep -vc 'kill -0' | tail -1)"
# _teardown_ext must never destroy a session that still hosts an agent.
eq "_teardown_ext refuses while a live agent's pane is in the external session" "refused" \
   "$(lib 'FL_HOME_SESSION=notmain; FL_EXT_SESSION=main
           _close_iterm_window(){ echo "CLOSED"; }
           tmux(){ case "$1" in kill-session) echo "KILLED";; show-options) echo "";; *) command tmux -L '"$SOCKET"' "$@";; esac; }
           out=$(_teardown_ext 2>&1); case "$out" in *"still hosts agent pane"*) echo refused;; *) echo "$out";; esac')"
# A registry with corrupted / padded / empty / garbage token files. _registry_tokens must
# normalize them, because a token differing from tmux's `%N` by one byte defeats every
# comparison in the guard and leaves a live agent unprotected.
RH="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$RH/.claude/running-agents"
printf '%%3\r\n'   > "$RH/.claude/running-agents/a.1"     # CRLF
printf '  %%7  \n'  > "$RH/.claude/running-agents/b.2"     # padded
printf ''           > "$RH/.claude/running-agents/c.3"     # empty
printf 'garbage\n'  > "$RH/.claude/running-agents/d.4"     # not a pane id
printf '%%5\n%%6\n' > "$RH/.claude/running-agents/e.5"     # multi-line: BOTH tokens protected
printf '%%8 %%9\n'  > "$RH/.claude/running-agents/f.6"     # two tokens on ONE line: split, not merged
rlib(){ HOME="$RH" FLEET_TMUX_SOCKET="$SOCKET" FLEET_LAYOUT_LIB=1 bash -c "source '$SCRIPT'; $*"; }
eq "_registry_tokens normalizes CRLF/padding, splits lines AND words, drops empty + garbage" "%3 %7 %5 %6 %8 %9" \
   "$(rlib '_registry_tokens' | tr '\n' ' ' | sed 's/ $//')"
# Glob metacharacters in a corrupted line are DATA, not patterns: the unquoted word-split
# would pathname-expand '%*' against the invoking CWD, emitting a FILENAME (which can pass
# the %N shape check) as a token. Found by the reviewer subagent's first dry-run (DX-jn-cc-005).
printf '%%*\n' > "$RH/.claude/running-agents/g.7"
GLOBDIR="$(mktemp -d)"; : > "$GLOBDIR/%3-decoy"
eq "_registry_tokens never glob-expands a corrupted line against the CWD" "" \
   "$(cd "$GLOBDIR" && rlib '_registry_tokens' | grep -- '-decoy')"
rm -f "$RH/.claude/running-agents/g.7"; rm -rf "$GLOBDIR"

# The kill decision must come from the SESSION'S OWN pane list, not solely registry->display-message.
# Each of these killed a live agent before (found by adversarial review).
KILLSTUB='FL_HOME_SESSION=main; FL_EXT_SESSION=x; _session_exists(){ return 0; }; _close_iterm_window(){ :; }'
eq "_teardown_ext refuses when list-panes -a omits the agent's pane (correlated partial reply)" "refused" \
   "$(rlib "$KILLSTUB
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; 'display-message -p -t') echo ''; return 0;; esac
              case \"\$1\" in list-panes) echo '%1';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *KILLED*) echo FAIL_OPEN;; *) echo refused;; esac")"
# NOTE: the refusal here fires via the DIRECT pane-list check (%3 is in list-panes), not the
# corroboration equality it is named for — correct as a regression test for the original kill
# (display-message was then the sole oracle); the equality branch itself is pinned two tests down.
eq "_teardown_ext refuses when display-message reports a WRONG non-empty session" "refused" \
   "$(rlib "$KILLSTUB
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; 'display-message -p -t') echo 'othersess'; return 0;; esac
              case \"\$1\" in list-panes) echo '%3';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *KILLED*) echo FAIL_OPEN;; *) echo refused;; esac")"
eq "_teardown_ext refuses when the registry directory is missing" "refused" \
   "$(HOME=/tmp/fl-no-such-home-$$ FLEET_TMUX_SOCKET="$SOCKET" FLEET_LAYOUT_LIB=1 bash -c "source '$SCRIPT'
      $KILLSTUB
      tmux(){ case \"\$1\" in list-panes) echo '%3';; kill-session) echo KILLED;; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *KILLED*) echo FAIL_OPEN;; *) echo refused;; esac")"
# Shell option state is a guard input too: inherited noglob (exported SHELLOPTS) blinds
# BOTH registry readdir globs — the registry reads as empty and the kill proceeds past a
# registered agent. Without the entry guard this scenario KILLS (found by reviewer R4).
eq "_teardown_ext refuses under inherited noglob (registry globs go blind)" "refused" \
   "$(rlib "$KILLSTUB
      set -f
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; esac
              case \"\$1\" in list-panes) echo '%1';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *noglob*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo \"\$out\";; esac")"
# The corroboration EQUALITY branch on its own: token NOT in the session's pane list, but
# display-message resolves it and claims it IS in ext. Deleting the branch must redden this.
eq "_teardown_ext refuses when corroboration places an off-list pane in ext" "refused" \
   "$(rlib "$KILLSTUB
      _registry_tokens(){ echo '%3'; }
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; 'display-message -p -t') echo 'x'; return 0;; esac
              case \"\$1\" in list-panes) echo '%1';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *'still hosts agent pane'*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo \"\$out\";; esac")"
# The dead-agent path must not trust a LONE negative from display-message: rc!=0 while the
# pane is still visible server-wide is tmux contradicting itself. (Genuine death is absent
# from -a too — the dead-agent control below stays green.)
eq "_teardown_ext refuses when display-message errors but the pane exists server-wide" "refused" \
   "$(rlib "$KILLSTUB
      _registry_tokens(){ echo '%3'; }
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; 'display-message -p -t') return 1;; esac
              case \"\$1 \$2\" in 'list-panes -a') printf '%s\n' '%1' '%3'; return 0;; esac
              case \"\$1\" in list-panes) echo '%1';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *'exists server-wide'*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo \"\$out\";; esac")"
# An EMPTY list-panes -a must never corroborate death: ext's own list already enumerated
# non-empty and -a is a superset of -s, so a blank -a is a contradiction by construction.
# (The dead-agent control below stays green — its -a reply is non-empty.)
eq "_teardown_ext refuses when display-message errors and list-panes -a is empty" "refused" \
   "$(rlib "$KILLSTUB
      _registry_tokens(){ echo '%3'; }
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; 'display-message -p -t') return 1;; esac
              case \"\$1 \$2\" in 'list-panes -a') return 0;; esac
              case \"\$1\" in list-panes) echo '%1';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *'cannot enumerate the server'*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo \"\$out\";; esac")"
# A WHITESPACE-ONLY session name is 'no session' wearing padding — it must hit the
# no-session refusal, not read as 'agent is elsewhere'.
eq "_teardown_ext refuses when a pane reports a whitespace-only session" "refused" \
   "$(rlib "$KILLSTUB
      _registry_tokens(){ echo '%3'; }
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; 'display-message -p -t') echo ' '; return 0;; esac
              case \"\$1\" in list-panes) echo '%1';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *'reports no session'*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo \"\$out\";; esac")"
# An UNREADABLE registry entry is UNKNOWN content (it may name a pane in this session) and must
# refuse — reproduced kill: tr failed silently, the token vanished, the agent went unprotected.
# Readable-but-garbage stays dropped (see the _registry_tokens normalization test above).
URH="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$URH/.claude/running-agents"
printf '%%3\n' > "$URH/.claude/running-agents/u.1"; chmod 000 "$URH/.claude/running-agents/u.1"
eq "_teardown_ext refuses when a registry file is unreadable" "refused" \
   "$(HOME="$URH" FLEET_TMUX_SOCKET="$SOCKET" FLEET_LAYOUT_LIB=1 bash -c "source '$SCRIPT'
      $KILLSTUB
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; esac
              case \"\$1\" in list-panes) echo '%3';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *'not a readable file'*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo \"\$out\";; esac")"
chmod 600 "$URH/.claude/running-agents/u.1"
DRH="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$DRH/.claude/running-agents/notafile.9"
eq "_teardown_ext refuses when a registry entry is dir-shaped" "refused" \
   "$(HOME="$DRH" FLEET_TMUX_SOCKET="$SOCKET" FLEET_LAYOUT_LIB=1 bash -c "source '$SCRIPT'
      $KILLSTUB
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; esac
              case \"\$1\" in list-panes) echo '%3';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *'not a readable file'*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo \"\$out\";; esac")"

# CONTROL. Without this, a guard that refuses unconditionally would pass every test above.
EH="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$EH/.claude/running-agents"
eq "_teardown_ext DOES tear down a session with no agents in it (the guard isn't vacuous)" "killed" \
   "$(HOME="$EH" FLEET_TMUX_SOCKET="$SOCKET" FLEET_LAYOUT_LIB=1 bash -c "source '$SCRIPT'
      $KILLSTUB
      tmux(){ case \"\$1 \$2 \$3\" in 'display-message -p #{pid}') return 0;; esac
              case \"\$1\" in list-panes) echo '%99';; kill-session) echo KILLED;; show-options) echo '';; *) return 0;; esac; }
      out=\$(_teardown_ext 2>&1); case \"\$out\" in *KILLED*) echo killed;; *) echo \"over-refused: \$out\";; esac")"

# Config footgun: WORKFLOW_FLEET_EXT_SESSION=main would make `single` tear down the home
# session and every agent in it.
eq "_teardown_ext refuses when the external session IS the home session" "refused" \
   "$(lib 'FL_HOME_SESSION=main; FL_EXT_SESSION=main
           _session_exists(){ return 0; }; _close_iterm_window(){ :; }
           _registry_tokens(){ echo "%999"; }
           tmux(){ case "$1" in list-panes) echo "%1";; kill-session) echo KILLED;; *) return 0;; esac; }
           out=$(_teardown_ext 2>&1); case "$out" in *"it is the home session"*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo "$out";; esac')"

# The guard must not depend on tmux liveness. `live_agents` filters through fleet_alive ->
# `tmux list-panes -a`; a transient hiccup there silently drops an agent, which for a destroy
# guard is a FAIL-OPEN (reproduced under CPU load by an adversarial review). Tokens are read
# from disk instead.
eq "_teardown_ext refuses even when tmux liveness goes blind (registry read from disk)" "refused" \
   "$(lib 'FL_HOME_SESSION=main; FL_EXT_SESSION=x
           _session_exists(){ return 0; }
           _close_iterm_window(){ :; }
           live_agents(){ echo ""; }
           _registry_tokens(){ echo "%3"; }
           tmux(){ case "$1 $2 $3" in "display-message -p #{pid}") return 0;;
                                     "display-message -p -t") echo "x";; esac
                   case "$1" in list-panes) echo "%3";; kill-session) echo KILLED;; show-options) echo "";; *) return 0;; esac; }
           out=$(_teardown_ext 2>&1); case "$out" in *"still hosts agent pane"*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo "$out";; esac')"

# The verification review's residual: a PARTIAL list-panes reply that omits the agent's pane.
# The pane exists server-wide but its session cannot be resolved -> tmux is inconsistent -> refuse.
# The pane is NOT in the ext session's own list, so the direct check misses it. display-message
# then RESOLVES the pane (exit 0) but reports no session — tmux contradicting itself. Refuse.
# Exit status, not emptiness, is the oracle for "does this pane exist": tmux errors on unknown.
eq "_teardown_ext refuses when a pane resolves but reports no session" "refused" \
   "$(lib 'FL_HOME_SESSION=main; FL_EXT_SESSION=x
           _session_exists(){ return 0; }
           _close_iterm_window(){ :; }
           _registry_tokens(){ echo "%3"; }
           tmux(){ case "$1 $2 $3" in "display-message -p #{pid}") return 0;;
                                     "display-message -p -t") echo ""; return 0;; esac
                   case "$1" in list-panes) echo "%1";; kill-session) echo KILLED;; show-options) echo "";; *) return 0;; esac; }
           out=$(_teardown_ext 2>&1); case "$out" in *"reports no session"*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo "$out";; esac')"

# …but a pane tmux says does NOT exist (non-zero exit) is a dead agent, and must not block teardown.
eq "_teardown_ext allows teardown when a registry pane no longer exists (dead agent)" "killed" \
   "$(lib 'FL_HOME_SESSION=main; FL_EXT_SESSION=x
           _session_exists(){ return 0; }
           _close_iterm_window(){ :; }
           _registry_tokens(){ echo "%3"; }
           tmux(){ case "$1 $2 $3" in "display-message -p #{pid}") return 0;;
                                     "display-message -p -t") return 1;; esac
                   case "$1" in list-panes) echo "%1";; kill-session) echo KILLED;; show-options) echo "";; *) return 0;; esac; }
           out=$(_teardown_ext 2>&1); case "$out" in *KILLED*) echo killed;; *) echo "over-refused: $out";; esac')"

# tmux that will not even answer a trivial query -> its later answers mean nothing -> refuse.
eq "_teardown_ext refuses when tmux answers nothing at all" "refused" \
   "$(lib 'FL_HOME_SESSION=main; FL_EXT_SESSION=x
           _session_exists(){ return 0; }
           _close_iterm_window(){ :; }
           _registry_tokens(){ echo ""; }
           tmux(){ case "$1" in kill-session) echo KILLED;; *) return 1;; esac; }
           out=$(_teardown_ext 2>&1); case "$out" in *"not answering"*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo "$out";; esac')"

# The tty parse: iTerm returning a winid with NO tty must not pass the non-empty guard.
eq "_spawn_ext_client rejects a winid with no tty" "rejected" \
   "$(lib 'res="22361"
           winid="${res%% *}"; wintty="${res##* }"
           case "$res" in *" "*) : ;; *) wintty="" ;; esac
           case "$wintty" in /dev/*) : ;; *) wintty="" ;; esac
           [ -n "$winid" ] && [ -n "$wintty" ] && echo accepted || echo rejected')"
eq "_spawn_ext_client accepts a real winid + tty" "accepted" \
   "$(lib 'res="22361 /dev/ttys016"
           winid="${res%% *}"; wintty="${res##* }"
           case "$res" in *" "*) : ;; *) wintty="" ;; esac
           case "$wintty" in /dev/*) : ;; *) wintty="" ;; esac
           [ -n "$winid" ] && [ -n "$wintty" ] && echo accepted || echo rejected')"

# An empty pane enumeration must never read as "no agents here".
eq "_teardown_ext fails CLOSED when it cannot enumerate the session" "refused" \
   "$(lib 'FL_HOME_SESSION=main; FL_EXT_SESSION=zzz
           _session_exists(){ return 0; }
           _close_iterm_window(){ :; }
           tmux(){ case "$1" in list-panes) echo "";; kill-session) echo KILLED;; *) return 0;; esac; }
           out=$(_teardown_ext 2>&1); case "$out" in *"cannot enumerate"*) echo refused;; *KILLED*) echo FAIL_OPEN;; *) echo "$out";; esac')"
# NOT `! producer | grep -q KILLED` — that passes when the producer emits NOTHING (a crash).
# Capture, assert non-empty, then assert the absence.
td_out="$(lib 'FL_HOME_SESSION=notmain; FL_EXT_SESSION=main
           _close_iterm_window(){ echo CLOSED; }
           tmux(){ case "$1" in kill-session) echo KILLED;; show-options) echo "";; *) command tmux -L '"$SOCKET"' "$@";; esac; }
           _teardown_ext 2>&1')"
ok "_teardown_ext actually ran (non-empty output, so the check below can fail)" "[ -n \"\$td_out\" ]"
eq "_teardown_ext emits no kill-session when an agent is present" "0" \
   "$(printf '%s\n' "$td_out" | grep -c KILLED)"
# Same trap: capture first, prove the dry-run produced commands, then assert none are destructive.
dry_out="$(run wide --dry-run 2>/dev/null)"
ok "wide --dry-run actually emits commands (so the check below can fail)" "[ -n \"\$dry_out\" ]"
eq "wide --dry-run emits no destructive verb" "0" \
   "$(printf '%s\n' "$dry_out" | grep -cE 'kill-|respawn')"
ok "wide --dry-run leaves the window set unchanged" \
   "[ \"\$(t list-windows -t main -F '#{window_name}' | tr '\n' ',')\" = '$after1' ]"

# --------------------------------------------------------------------------------
# Everything below MUTATES the fixture — keep it last.
# This is the only place `wide` is executed for real. It retires two risks at once: that the
# 12-pane join order was only ever reasoned about, and that idempotency was only proven for
# name-windows.
echo; echo "wide, executed for real"
run wide >/dev/null 2>&1
eq "wide exits 0" "0" "$?"

feat_win="$(t list-panes -a -F '#{pane_id} #{window_id}' | awk -v p="$P_A" '$1==p{print $2}')"
eq "the features window holds exactly all four agents' cells" \
   "$(printf '%s\n' "$P_A" "$P_B" "$P_D" "$P_E" "$P_I" "$P_J" "$P_K" "$P_L" | sort | tr '\n' ' ')" \
   "$(t list-panes -t "$feat_win" -F '#{pane_id}' | sort | tr '\n' ' ')"
eq "wide is a 2x2: f3 is BELOW f1, f4 BELOW f2" "yes" \
   "$(t list-panes -t "$feat_win" -F '#{pane_id} #{pane_top}' | awk -v a="$P_A" -v c="$P_I" -v b="$P_D" -v d="$P_K" '
      $1==a{x=$2} $1==c{y=$2} $1==b{z=$2} $1==d{w=$2} END{print (y>x && w>z) ? "yes" : "no"}')"
eq "f1's claude pane is left of its companion" "yes" \
   "$(t list-panes -t "$feat_win" -F '#{pane_id} #{pane_left}' | awk -v a="$P_A" -v b="$P_B" '$1==a{x=$2} $1==b{y=$2} END{print (x<y)?"yes":"no"}')"
eq "f2's cell is to the right of f1's" "yes" \
   "$(t list-panes -t "$feat_win" -F '#{pane_id} #{pane_left}' | awk -v b="$P_B" -v d="$P_D" '$1==b{x=$2} $1==d{y=$2} END{print (x<y)?"yes":"no"}')"
eq "no pane was destroyed — all 12 fixture panes still live" "12" \
   "$(t list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
eq "the window is named for its residents" "features" \
   "$(t display-message -p -t "$feat_win" '#{window_name}')"

# EXACT, not a range. `balance_cells` runs last and heals a bad build_cell resize, so a loose
# range check here passes even when build_cell is broken — the structural grep above is what
# guards that. What this must pin is _balance_cell's own arithmetic on real panes.
#
# (The old "the two cells did not steal columns from each other" assertion lived here. It was
# VACUOUS: a forced 40-column overshoot still passed it, because the cell boundary is the
# top-level split and _balance_cell only moves the claude/companion divider inside a cell.
# Deleted rather than left as decoration.)
pw(){ t list-panes -t "$feat_win" -F '#{pane_id} #{pane_width}' | awk -v p="$1" '$1==p{print $2}'; }
claude_w="$(pw "$P_A")"; comp_w="$(pw "$P_B")"; cell_w=$(( claude_w + comp_w + 1 ))
# Tolerance 1: tmux splits integer columns, so 60% of an odd cell rounds. Exact equality here
# is flaky under load, which is worse than a loose check. The exact arithmetic is pinned by the
# stubbed `_balance_cell computes 60% of the CELL` unit test above, where nothing rounds.
eq "f1's claude pane is 60% of its cell, +/-1 col (cell=${cell_w}, claude=${claude_w})" "yes" \
   "$(awk -v c="$claude_w" -v t="$(( cell_w * 60 / 100 ))" 'BEGIN{d=c-t; if(d<0)d=-d; print (d<=1)?"yes":"no (want "t")"}')"
ok "f1's companion column is usable, not clamped to 1 col (got ${comp_w})" "[ '$comp_w' -ge 15 ]"
# Guards the JOIN STRUCTURE, not the balance: cell widths come from the 2x2 split, and
# _balance_cell only moves the divider inside a cell. A 200-col window splits 100/99 (+border),
# so the four cells must agree within 1. A wrong join order (three columns, say) breaks this.
eq "the 2x2 join order yields four evenly-sized cells (within 1 col)" "yes" \
   "$(for pair in "$P_A $P_B" "$P_D $P_E" "$P_I $P_J" "$P_K $P_L"; do
        set -- $pair; echo $(( $(pw "$1") + $(pw "$2") + 1 ))
      done | sort -n | awk 'NR==1{min=$1} {max=$1} END{print (max-min<=1)?"yes":"no ("min".."max")"}')"

echo; echo "canonical window order: cc, features, review/test, others"
eq "_window_rank: coordinator first"        "0"   "$(lib '_window_rank 0 x-cc' 2>/dev/null || lib '_role_of(){ echo coordinator; }; _window_rank 0 zz')"
eq "_window_rank: feature by agent number"  "101" "$(lib '_window_rank 0 x-1')"
eq "_window_rank: features-2 sorts after features-1" "103" "$(lib '_window_rank 0 x-3 x-4')"
eq "_window_rank: review/test after features" "200" "$(lib '_window_rank 0 x-pr x-test-1')"
eq "_window_rank: agent-free windows last, keeping their index" "307" "$(lib '_window_rank 7')"
# A failed park must still renumber. Otherwise windows are stranded at 900+, index 900 stays
# occupied, and EVERY later run re-fails — on every SessionStart, forever. (Found by review.)
ORDSTUB='_session_exists(){ return 0; }
         _pane_rows(){ printf "%%1\tmain\t@2\t/tmp\n%%3\tmain\t@1\t/tmp\n"; }
         live_agents(){ printf "zz-cc\t%%1\t/tmp\tcoordinator\nzz-1\t%%3\t/tmp\tfeature\n"; }
         tmux(){ case "$1" in list-windows) printf "@1\n@2\n";; *) return 0;; esac; }'
eq "_order_windows renumbers even when a park fails (nothing stranded at 900+)" "RENUMBERED" \
   "$(lib "$ORDSTUB
           _rw(){ case \"\$1\" in move-window) return 1;; esac; return 0; }
           _renumber(){ echo RENUMBERED; }
           _order_windows main 2>/dev/null" | head -1)"
eq "_order_windows reports the failure to its caller" "1" \
   "$(lib "$ORDSTUB
           _rw(){ case \"\$1\" in move-window) return 1;; esac; return 0; }
           _renumber(){ :; }
           _order_windows main >/dev/null 2>&1; echo \$?")"
eq "_order_windows parks in rank order (cc before the feature agent)" "@2 @1" \
   "$(lib "$ORDSTUB
           _rw(){ [ \"\$1\" = move-window ] && printf '%s ' \"\$4\"; return 0; }
           _renumber(){ :; }
           _order_windows main 2>/dev/null" | sed 's/ $//')"

ok "ordering is idempotent — a second name-windows emits nothing" \
   "[ -z \"\$(run name-windows --dry-run 2>/dev/null)\" ]"

echo; echo "a live-but-unplaced coordinator never gets demoted to last (partial-registry guard)"
# The bug: on a mass `claude --continue` restart the settle-recheck re-ran _order_windows while
# cc's own registration was momentarily gone (its window shows zero resident agents → ranked
# 300+ → sorted LAST). Two windows in the WRONG order + cc live but unplaced: without the guard
# this reorders (park + renumber); with it, nothing moves until the registry settles.
GUARDSTUB='FL_HOME_SESSION=main; FL_EXT_SESSION=x; _session_exists(){ return 0; }
           _pane_rows(){ printf "%%3\tmain\t@2\t/tmp\n"; }
           live_agents(){ printf "zz-cc\t%%1\t/tmp\tcoordinator\nzz-1\t%%3\t/tmp\tfeature\n"; }
           tmux(){ case "$1" in list-windows) printf "@1\n@2\n";; *) return 0;; esac; }'
eq "home session: live coordinator unplaced ⇒ order held (no move, no renumber)" "" \
   "$(lib "$GUARDSTUB
           _rw(){ printf 'MOVE '; }; _renumber(){ printf 'RENUMBER '; }
           _order_windows main 2>/dev/null")"
# Negative control: the SAME wrong order, but cc IS placed → the guard must NOT fire (reorders).
eq "home session: coordinator placed ⇒ still reorders (guard does not over-trigger)" "REORDERED" \
   "$(lib "FL_HOME_SESSION=main; FL_EXT_SESSION=x; _session_exists(){ return 0; }
           _pane_rows(){ printf '%%1\tmain\t@2\t/tmp\n%%3\tmain\t@1\t/tmp\n'; }
           live_agents(){ printf 'zz-cc\t%%1\t/tmp\tcoordinator\nzz-1\t%%3\t/tmp\tfeature\n'; }
           tmux(){ case \"\$1\" in list-windows) printf '@1\n@2\n';; *) return 0;; esac; }
           _rw(){ :; }; _renumber(){ echo REORDERED; }
           _order_windows main 2>/dev/null" | head -1)"
# The guard is HOME-scoped: cc lives only in the home session, so the external feature-grid
# session must keep ordering its windows even though no coordinator is resident there.
eq "external session: feature windows still reorder (guard is home-scoped, not global)" "REORDERED" \
   "$(lib "FL_HOME_SESSION=main; FL_EXT_SESSION=x; _session_exists(){ return 0; }
           _pane_rows(){ printf '%%3\tx\t@2\t/tmp\n%%5\tx\t@1\t/tmp\n'; }
           live_agents(){ printf 'zz-cc\t%%1\t/tmp\tcoordinator\nzz-1\t%%3\t/tmp\tfeature\nzz-2\t%%5\t/tmp\tfeature\n'; }
           tmux(){ case \"\$1\" in list-windows) printf '@1\n@2\n';; *) return 0;; esac; }
           _rw(){ :; }; _renumber(){ echo REORDERED; }
           _order_windows x 2>/dev/null" | head -1)"

echo; echo "--label-only relabels without reordering (the settle-recheck path)"
# Shared stub: one already-correctly-labelled coordinator window, so the label loop is a no-op
# and the only observable effect is whether _order_windows runs.
LOSTUB='FL_HOME_SESSION=main; FL_EXT_SESSION=x
        live_agents(){ printf "zz-cc\t%%1\t/tmp\tcoordinator\n"; }
        _pane_rows(){ printf "%%1\tmain\t@1\t/tmp\n"; }
        _min_agent_num(){ echo 0; }; window_name_from_names(){ echo coordinators; }
        _rw(){ :; }
        tmux(){ case "$1" in display-message) echo coordinators;; list-windows) printf "@1\n";; *) return 0;; esac; }'
eq "name_windows --label-only: _order_windows NOT called" "" \
   "$(lib "$LOSTUB; FL_LABEL_ONLY=1; _order_windows(){ printf 'ORDER '; }
           name_windows 2>/dev/null")"
eq "name_windows default: _order_windows IS called (home + ext)" "ORDER ORDER" \
   "$(lib "$LOSTUB; _order_windows(){ printf 'ORDER '; }
           name_windows 2>/dev/null" | sed 's/ $//')"
ok "name-windows --label-only is accepted, not a usage error" \
   "run name-windows --label-only --dry-run >/dev/null 2>&1"

echo; echo "windows renumber instead of leaving holes"
eq "no gaps in the home session's window indices" "yes" \
   "$(t list-windows -t main -F '#{window_index}' | awk 'NR!=$1{bad=1} END{print bad?"no":"yes"}')"

echo; echo "wide moves the grid into a DEDICATED session once one is attached"
eq "with no client on 'wide', the grid stays in main (never crushed into an 80x24 session)" \
   "main" "$(t list-windows -a -F '#{window_id} #{session_name}' | awk -v w="$feat_win" '$1==w{print $2}')"
ok "a grouped session would have shared the window; a dedicated one does not" \
   "! t has-session -t =wide 2>/dev/null"

echo; echo "wide is idempotent, even against a duplicate window name"
# tmux allows two windows to share a name. If the target were resolved by NAME, the idempotency
# check could compare the wrong window, break out a second `features`, and do it again on every
# re-run — unbounded and never convergent. Resolving from the seed pane fixes it. Mutating
# _assemble_prelude back to a name lookup turns the assertion below red.
t new-window -d -t main -n features -c "$T/pr" 'sleep 600'
decoy_win="$(t list-windows -t main -F '#{window_id} #{window_name}' | awk -v r="$feat_win" '$2=="features" && $1!=r{print $1; exit}')"
[ -n "$decoy_win" ] || { echo "FATAL: decoy window not created"; exit 1; }
# Move the decoy to the LOWEST index so a name lookup would find IT first, not the real one.
# Without this the assertion passes on window ordering rather than on the seed-pane mechanism.
t move-window -s "$decoy_win" -t main:0 2>/dev/null
eq "the decoy sorts BEFORE the real features window" "$decoy_win" \
   "$(t list-windows -a -F '#{window_id} #{window_name}' | awk '$2=="features"{print $1; exit}')"
eq "a decoy 'features' window exists" "2" \
   "$(t list-windows -t main -F '#{window_name}' | grep -cx features)"
# Behavioral, not string-exact: global options, a cosmetic re-balance, and the pending
# move-window to the external session (which this scratch server can never have a client for)
# are all fine to re-emit. RE-ASSEMBLING THE GRID is not. Reverting _assemble_prelude to a name
# lookup makes this non-zero.
eq "re-running wide does NOT re-assemble the grid (already assembled)" "0" \
   "$(run wide --dry-run 2>/dev/null | grep -cE 'join-pane|break-pane')"
run wide >/dev/null 2>&1
eq "a real re-run does not break out a third features window" "2" \
   "$(t list-windows -t main -F '#{window_name}' | grep -cx features)"
eq "and the cells are still intact" \
   "$(printf '%s\n' "$P_A" "$P_B" "$P_D" "$P_E" "$P_I" "$P_J" "$P_K" "$P_L" | sort | tr '\n' ' ')" \
   "$(t list-panes -t "$feat_win" -F '#{pane_id}' | sort | tr '\n' ' ')"

# The decoy `features` window and the w1 remnant (skip-marked + unowned panes) are agent-free,
# so the script correctly leaves them alone. They would pollute name-greps below, so anchor every
# assertion from here on to the AGENTS' panes, and retire the decoy.
t kill-window -t "$decoy_win" 2>/dev/null
win_of(){ t list-panes -a -F '#{pane_id} #{window_name}' | awk -v q="$1" '$1==q{print $2; exit}'; }

echo; echo "dual: two windows that derive the same name get disambiguated"
run dual >/dev/null 2>&1
eq "dual exits 0" "0" "$?"
eq "the two feature windows are features-1 and features-2 (not both 'features')" "features-1 features-2" \
   "$(for p in $P_A $P_D $P_I $P_K; do win_of "$p"; done | sort -u | tr '\n' ' ' | sed 's/ $//')"
eq "features-1 holds f1 + f2" "features-1 features-1" "$(win_of "$P_A") $(win_of "$P_D")"
eq "features-2 holds f3 + f4" "features-2 features-2" "$(win_of "$P_I") $(win_of "$P_K")"
eq "dual STACKS the pair: f2 below f1" "yes" \
   "$(t list-panes -a -F '#{pane_id} #{pane_top}' | awk -v a="$P_A" -v b="$P_D" '$1==a{x=$2} $1==b{y=$2} END{print (y>x)?"yes":"no"}')"
eq "still 12 panes; nothing destroyed" "12" "$(t list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"

echo; echo "single: every feature agent comes home to its own window"
run single >/dev/null 2>&1
eq "single exits 0" "0" "$?"
eq "each feature agent is alone in a window named for it" "x-1 x-2 x-3 x-4" \
   "$(for p in $P_A $P_D $P_I $P_K; do win_of "$p"; done | sort | tr '\n' ' ' | sed 's/ $//')"
eq "no feature agent is left in a features* window" "0" \
   "$(for p in $P_A $P_D $P_I $P_K; do win_of "$p"; done | grep -c '^features' || true)"
eq "still 12 panes; nothing destroyed" "12" "$(t list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
eq "the review/test co-tenant window is untouched by single" "1" \
   "$(t list-windows -a -F '#{window_name}' | grep -cx review-test)"

# --------------------------------------------------------------------------------
# boot (DX-jn-cc-007). Own home + own tmux session (bootsess) so the layout fixtures
# above stay untouched. Every absence-shaped assertion is POSITIVELY PAIRED (exit 0 +
# the expected report line): pre-implementation, `boot` hits the unknown-verb dispatch
# (usage, exit 2), and an unpaired "no window created" would pass vacuously against it.
echo; echo "boot: manifest parsing + validation (loud-fail, never empty-fleet exit 0)"

t new-session -d -x 200 -y 50 -s bootsess -n seed -c "$T" 'sleep 600'
mkdir -p "$T/boot-1" "$T/boot-2" "$T/boot-3" "$T/boot-4"

# A provably dead pid: a subshell that has already been reaped.
( : ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null

# Per-case boot homes. bmk <home> writes the standard .claude skeleton.
bmk(){ mkdir -p "$1/.claude/running-agents" "$1/.claude/agents" "$1/.config" "$1/.claude/projects"; }
# manifest <home> <entries-json…> — wraps entries in the worktrees envelope.
# The manifest path is a KNOB now (P1/P2). The harness pins it explicitly for every boot/down
# invocation: fleet-layout.sh sources _config.sh, so the REPO's own workflow.config would
# otherwise leak in. Exported values win (_config.sh's env-wins snapshot/re-apply).
MANIFEST_REL='.config/wf-worktrees.json'
manifest(){ local h="$1"; shift; printf '{ "worktrees": [ %s ] }\n' "$*" > "$h/$MANIFEST_REL"; }
brun(){ local h="$1"; shift; HOME="$h" WORKFLOW_FLEET_HOME_SESSION=bootsess WORKFLOW_WORKTREES_MANIFEST="${WTM_OVERRIDE-$h/$MANIFEST_REL}" WORKFLOW_CELL_COMMAND="${CELLCMD-monocle}" FLEET_TMUX_SOCKET="$SOCKET" TMUX_PANE="${BPANE:-$TMUX_PANE}" bash "$SCRIPT" "$@"; }
blib(){ local h="$1"; shift; HOME="$h" WORKFLOW_FLEET_HOME_SESSION=bootsess WORKFLOW_WORKTREES_MANIFEST="${WTM_OVERRIDE-$h/$MANIFEST_REL}" WORKFLOW_CELL_COMMAND="${CELLCMD-monocle}" FLEET_TMUX_SOCKET="$SOCKET" FLEET_LAYOUT_LIB=1 bash -c "source '$SCRIPT'; $*"; }
bwins(){ t list-windows -t bootsess -F '#{window_name}' | sort | tr '\n' ' ' | sed 's/ $//'; }

# Corrupt JSON → loud non-zero, never an empty-fleet success.
CJH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$CJH"
printf '{ not json' > "$CJH/$MANIFEST_REL"
cj_out="$(brun "$CJH" boot 2>&1)"; cj_rc=$?
eq "corrupt manifest JSON → non-zero exit"          "1" "$([ "$cj_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…with an explicit manifest error, not silence"  "1" "$(printf '%s\n' "$cj_out" | grep -ci 'manifest')"
# Missing file → same loud failure (a fleet machine always has one).
MFH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$MFH"
mf_out="$(brun "$MFH" boot 2>&1)"; mf_rc=$?
eq "missing manifest file → non-zero exit"          "1" "$([ "$mf_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…names the manifest in the error"               "1" "$(printf '%s\n' "$mf_out" | grep -ci 'manifest')"
# Unreadable file → loud failure.
UBH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$UBH"
manifest "$UBH" '{"path": "'"$T/boot-1"'", "lane": 1, "agent": "b-1"}'
chmod 000 "$UBH/$MANIFEST_REL"
ub_rc=0; brun "$UBH" boot >/dev/null 2>&1 || ub_rc=$?
eq "unreadable manifest → non-zero exit"            "1" "$([ "$ub_rc" -ne 0 ] && echo 1 || echo 0)"
chmod 600 "$UBH/$MANIFEST_REL"
# python3 gone (stubbed to the command-not-found rc) → loud failure, not empty fleet.
py_rc=0; blib "$CJH" 'python3(){ return 127; }; _boot_manifest_agents' >/dev/null 2>&1 || py_rc=$?
eq "python3 unavailable → _boot_manifest_agents fails non-zero" "1" "$([ "$py_rc" -ne 0 ] && echo 1 || echo 0)"

echo; echo "boot: garbage entries never reach the destructive glob"
GBH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$GBH"
# evXil.<dead> matches the rm glob a naive 'ev*il.*' sweep would expand — it must survive.
printf 'cwd:%s\n' "$T/boot-1" > "$GBH/.claude/running-agents/evXil.$DEADPID"
manifest "$GBH" '{"path": "'"$T/boot-1"'", "lane": 1, "agent": "ev*il"}'
gb_before="$(bwins)"
gb_rc=0; gb_out="$(brun "$GBH" boot 2>&1)" || gb_rc=$?
eq "glob-metachar agent name → non-zero exit"       "1" "$([ "$gb_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…and names the offending agent"                 "1" "$(printf '%s\n' "$gb_out" | grep -c 'ev\*il')"
ok "…the decoy registry entry survived (no rm ran)" "[ -f '$GBH/.claude/running-agents/evXil.$DEADPID' ]"
eq "…and no window was created"                     "$gb_before" "$(bwins)"
RPH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$RPH"
manifest "$RPH" '{"path": "relative/dir", "lane": 1, "agent": "b-1"}'
rp_rc=0; brun "$RPH" boot >/dev/null 2>&1 || rp_rc=$?
eq "relative path entry → non-zero exit"            "1" "$([ "$rp_rc" -ne 0 ] && echo 1 || echo 0)"

echo; echo "boot: the cold-boot path (skip live / sweep dead / create / launch / report)"
BH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$BH"
REC="$BH/launch.rec"
# b-1: dead registry entry + a prior-session projects dir  → swept, booted with --continue
# b-2: LIVE registration (cwd token: pid-only liveness)    → skipped, never pruned
# b-3: no registry entry, no projects dir                  → booted fresh (plain claude)
# b-held: active:false                                     → held, no window
# b-cc: registry token = OUR $TMUX_PANE → fleet_find_self  → skipped (self)
# b-gone: path does not exist                              → warned, others still boot
# (plus one plain worktree entry with no agent field       → ignored entirely)
printf 'cwd:%s\n' "$T/boot-1" > "$BH/.claude/running-agents/b-1.$DEADPID"
printf '%s\n' "$T/boot-1"     > "$BH/.claude/agents/b-1.cwd"
printf 'cwd:%s\n' "$T/boot-2" > "$BH/.claude/running-agents/b-2.$$"
printf '%s\n' "$T/boot-2"     > "$BH/.claude/agents/b-2.cwd"
printf '%s\n' "$TMUX_PANE"    > "$BH/.claude/running-agents/b-cc.$$"
printf '%s\n' "$T/boot-4"     > "$BH/.claude/agents/b-cc.cwd"
mkdir -p "$BH/.claude/projects/$(printf '%s' "$T/boot-1" | tr -c 'A-Za-z0-9' '-')"
: > "$BH/.claude/projects/$(printf '%s' "$T/boot-1" | tr -c 'A-Za-z0-9' '-')/s.jsonl"
manifest "$BH" \
  '{"path": "'"$T/boot-2"'", "lane": 2, "agent": "b-2"},' \
  '{"path": "'"$T/boot-1"'", "lane": 1, "agent": "b-1"},' \
  '{"path": "'"$T/boot-3"'", "lane": 3, "agent": "b-3"},' \
  '{"path": "'"$T"'/held",   "lane": 5, "agent": "b-held", "active": false},' \
  '{"path": "'"$T/boot-4"'", "lane": 4, "agent": "b-cc"},' \
  '{"path": "'"$T"'/no-such-dir", "lane": 6, "agent": "b-gone"},' \
  '{"path": "'"$T"'/plain",  "lane": 7}'
boot_out="$(FLEET_BOOT_LAUNCH_RECORDER="$REC" brun "$BH" boot 2>&1)"; boot_rc=$?
eq "boot exits 0"                                   "0" "$boot_rc"
eq "b-2 reported live"            "1" "$(printf '%s\n' "$boot_out" | grep -Ec 'b-2 +live')"
eq "b-1 reported booted --continue" "1" "$(printf '%s\n' "$boot_out" | grep -Ec 'b-1 +booted \(claude --continue\)')"
eq "b-3 reported booted fresh"    "1" "$(printf '%s\n' "$boot_out" | grep -Ec 'b-3 +booted \(claude\)')"
eq "b-held reported held"         "1" "$(printf '%s\n' "$boot_out" | grep -Ec 'b-held +held')"
eq "b-cc reported skipped (self)" "1" "$(printf '%s\n' "$boot_out" | grep -Ec 'b-cc +skipped \(self\)')"
eq "b-gone reported missing-path" "1" "$(printf '%s\n' "$boot_out" | grep -Ec 'b-gone +missing-path')"
ok "b-1's dead registry entry was swept"            "[ ! -f '$BH/.claude/running-agents/b-1.$DEADPID' ]"
ok "b-2's LIVE registry entry was NOT pruned"       "[ -f '$BH/.claude/running-agents/b-2.$$' ]"
eq "windows created for b-1 and b-3 only (b-2 live, b-cc self, b-held held)" \
   "b-1 b-3 seed" "$(bwins)"
eq "b-1's window opened at its manifest cwd" "$T/boot-1" \
   "$(t list-panes -s -t bootsess -F '#{window_name} #{pane_current_path}' | awk '$1=="b-1"{print $2; exit}')"
eq "the recorder saw launches + monocle keystrokes, per-agent, in canonical (agent-number) order" \
   "b-1:claude --continue,b-1:monocle,b-3:claude,b-3:monocle" \
   "$(awk -F'\t' '{printf "%s:%s,", $1, $2}' "$REC" | sed 's/,$//')"
eq "the report reminds that resume prompts are human-answered" "1" \
   "$(printf '%s\n' "$boot_out" | grep -ci 'resume prompt')"

# Cell geometry (DX-jn-cc-012): each booted window is the wide cell — claude full-height
# on the left (~60%, wider than the right column), right pair stacked (same left edge,
# equal width, one top one bottom), every pane at the worktree. One canonical shape
# string so the whole structure is a single strong assertion.
cellshape(){
  t list-panes -t "bootsess:$1" -F '#{pane_left} #{pane_top} #{pane_width} #{pane_height} #{window_height} #{pane_current_path}' \
  | awk -v p="$2" '
      { n++; if ($6 != p) badpath++
        if ($1 == 0) { l++; cw=$3; if ($4 == $5) fullh++ }
        else { r++; if (rl=="") rl=$1; else if ($1 != rl) rleq=1
               if (rw=="") rw=$3; else if ($3 != rw) rweq=1
               if ($2 == 0) rtop++; else rbot++ }
      }
      END { printf "n=%d badpath=%d left=%d fullh=%d right=%d rtop=%d rbot=%d rsplit=%d cwider=%d",
              n, badpath+0, l+0, fullh+0, r+0, rtop+0, rbot+0, (rleq+0)+(rweq+0), (cw+0 > rw+0) ? 1 : 0 }'
}
CELL_OK="n=3 badpath=0 left=1 fullh=1 right=2 rtop=1 rbot=1 rsplit=0 cwider=1"
eq "b-1's window is the cell: claude full-height left, stacked right pair, all at the worktree" \
   "$CELL_OK" "$(cellshape b-1 "$T/boot-1")"
eq "b-3's window is the cell too" \
   "$CELL_OK" "$(cellshape b-3 "$T/boot-3")"

echo; echo "boot: idempotent re-run + the window-exists guard"
rerun_out="$(FLEET_BOOT_LAUNCH_RECORDER="$REC" brun "$BH" boot 2>&1)"; rerun_rc=$?
eq "re-run exits 0" "0" "$rerun_rc"
eq "re-run creates no second window"                "b-1 b-3 seed" "$(bwins)"
eq "re-run reports the existing windows as window-exists (never re-keys a pane it didn't create)" \
   "2" "$(printf '%s\n' "$rerun_out" | grep -Ec '(b-1|b-3) +window-exists')"
eq "re-run recorded no new launch" "4" "$(wc -l < "$REC" | tr -d ' ')"
eq "re-run added no pane to b-1's cell (still exactly 3)" \
   "3" "$(t list-panes -t bootsess:b-1 -F '#{pane_id}' | wc -l | tr -d ' ')"

echo; echo "boot: liveness asymmetry (skip = pid+pane, sweep = pid-only)"
LAH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$LAH"
# Live pid + a pane token that does not exist on this server: not "live" (window gets
# rebuilt) but NOT swept either — sweeping a live pid is the riskier error.
printf '%%999\n' > "$LAH/.claude/running-agents/b-1.$$"
printf '%s\n' "$T/boot-1" > "$LAH/.claude/agents/b-1.cwd"
manifest "$LAH" '{"path": "'"$T/boot-1"'", "lane": 1, "agent": "b-1"}'
la_out="$(FLEET_BOOT_LAUNCH_RECORDER="$LAH/rec" brun "$LAH" boot 2>&1)"; la_rc=$?
eq "live-pid/dead-pane: boot exits 0"               "0" "$la_rc"
eq "…agent not treated as live (window-exists from the earlier run's window)" \
   "1" "$(printf '%s\n' "$la_out" | grep -Ec 'b-1 +(booted|window-exists)')"
ok "…its live-pid registry entry was NOT swept"     "[ -f '$LAH/.claude/running-agents/b-1.$$' ]"

echo; echo "boot: --dry-run mutates nothing"
DBH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$DBH"
printf 'cwd:%s\n' "$T/boot-4" > "$DBH/.claude/running-agents/b-4.$DEADPID"
manifest "$DBH" '{"path": "'"$T/boot-4"'", "lane": 4, "agent": "b-4"}'
dwins_before="$(bwins)"
dry_boot="$(brun "$DBH" boot --dry-run 2>&1)"; dry_rc=$?
eq "dry-run exits 0"                                "0" "$dry_rc"
eq "dry-run prints the new-window command"          "1" "$(printf '%s\n' "$dry_boot" | grep -c 'new-window.*-n b-4')"
eq "dry-run prints the send-keys launch"            "1" "$(printf '%s\n' "$dry_boot" | grep -c 'send-keys.*claude')"
eq "dry-run prints the two cell splits (DX-jn-cc-012)" "2" "$(printf '%s\n' "$dry_boot" | grep -c 'split-window')"
eq "dry-run prints the monocle keystroke"           "1" "$(printf '%s\n' "$dry_boot" | grep -c 'send-keys.*monocle')"
ok "dry-run actually emitted commands (so the check below can fail)" "[ -n \"\$dry_boot\" ]"
eq "dry-run emits no destructive verb"              "0" "$(printf '%s\n' "$dry_boot" | grep -cE 'kill-|respawn')"
eq "dry-run created no window"                      "$dwins_before" "$(bwins)"
ok "dry-run did not sweep the dead registry entry"  "[ -f '$DBH/.claude/running-agents/b-4.$DEADPID' ]"

echo; echo "boot: _boot_claude_cmd (lib mode)"
eq "prior sessions → claude --continue" "claude --continue" "$(blib "$BH" "_boot_claude_cmd '$T/boot-1'")"
eq "no projects dir → plain claude"     "claude"            "$(blib "$BH" "_boot_claude_cmd '$T/boot-3'")"
MUNGE_DIR="$T/boot.x_1"; mkdir -p "$MUNGE_DIR"
mkdir -p "$BH/.claude/projects/$(printf '%s' "$MUNGE_DIR" | tr -c 'A-Za-z0-9' '-')"
: > "$BH/.claude/projects/$(printf '%s' "$MUNGE_DIR" | tr -c 'A-Za-z0-9' '-')/s.jsonl"
eq "nonalnum path munges per register-agent's rule (nonalnum→'-', not just '/')" \
   "claude --continue" "$(blib "$BH" "_boot_claude_cmd '$MUNGE_DIR'")"

echo; echo "boot: cell degradation — a failed split/keystroke never loses the claude launch (DX-jn-cc-012)"
mkdir -p "$T/boot-dg"
DGH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$DGH"
# h-split fails (tmux() re-defined post-source, the established stub pattern; every other
# verb still reaches the scratch server): full boot_fleet — the launch must survive, the
# degradation must be REPORTED, and the run's exit must be tainted (loud-failure model).
manifest "$DGH" '{"path": "'"$T/boot-dg"'", "lane": 1, "agent": "b-dg"}'
dg_rc=0
dg_out="$(blib "$DGH" "
  tmux(){ if [ \"\$1\" = split-window ]; then return 1; fi; command tmux -L \"\$FLEET_TMUX_SOCKET\" \"\$@\"; }
  export FLEET_BOOT_LAUNCH_RECORDER='$DGH/rec'
  boot_fleet" 2>&1)" || dg_rc=$?
eq "h-split failure taints boot's exit (non-zero)"  "1" "$([ "$dg_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…but the claude launch still happened and was reported" \
   "1" "$(printf '%s\n' "$dg_out" | grep -Ec 'b-dg +booted \(claude\)')"
eq "…and the degradation is reported, not silent"   "1" "$(printf '%s\n' "$dg_out" | grep -c 'cell DEGRADED')"
eq "…the claude window exists with its single pane intact" \
   "1" "$(t list-panes -t bootsess:b-dg -F '#{pane_id}' | wc -l | tr -d ' ')"
eq "…the launch was recorded, and NO monocle keystroke was" \
   "b-dg:claude" "$(awk -F'\t' '{printf "%s:%s,", $1, $2}' "$DGH/rec" | sed 's/,$//')"

# v-split fails (h-split runs for real): the single right pane is left AT THE PROMPT —
# no monocle keystroke (a bare shell is the safe degraded state). Absence of the
# keystroke is positively paired with the DEGRADED report line.
DVP="$(t new-window -d -P -F '#{pane_id}' -t bootsess -n b-dv -c "$T/boot-dg" 'sleep 600')"
dv_rc=0
dv_out="$(blib "$DGH" "
  tmux(){ if [ \"\$1\" = split-window ]; then case \" \$* \" in *' -v '*) return 1 ;; esac; fi; command tmux -L \"\$FLEET_TMUX_SOCKET\" \"\$@\"; }
  export FLEET_BOOT_LAUNCH_RECORDER='$DGH/rec-dv'
  _boot_cell b-dv '$DVP' '$T/boot-dg'" 2>&1)" || dv_rc=$?
eq "v-split failure returns 1"                      "1" "$dv_rc"
eq "…and reports the right pane left at the prompt" "1" "$(printf '%s\n' "$dv_out" | grep -c 'cell DEGRADED (v-split')"
eq "…h-split pane survives (window has exactly 2 panes)" \
   "2" "$(t list-panes -t bootsess:b-dv -F '#{pane_id}' | wc -l | tr -d ' ')"
ok "…no monocle keystroke was recorded"             "[ ! -s '$DGH/rec-dv' ]"

# The monocle keystroke itself fails (real splits, recorder UNSET so the real keying
# path runs): guarded + reported + return 1 — never an accidental return status.
DKP="$(t new-window -d -P -F '#{pane_id}' -t bootsess -n b-dk -c "$T/boot-dg" 'sleep 600')"
dk_rc=0
dk_out="$(blib "$DGH" "
  tmux(){ if [ \"\$1\" = send-keys ]; then return 1; fi; command tmux -L \"\$FLEET_TMUX_SOCKET\" \"\$@\"; }
  _boot_cell b-dk '$DKP' '$T/boot-dg'" 2>&1)" || dk_rc=$?
eq "monocle keystroke failure returns 1"            "1" "$dk_rc"
eq "…and is reported, not an accidental status"     "1" "$(printf '%s\n' "$dk_out" | grep -c 'cell DEGRADED (monocle')"
eq "…both splits survive (window has exactly 3 panes)" \
   "3" "$(t list-panes -t bootsess:b-dk -F '#{pane_id}' | wc -l | tr -d ' ')"

echo; echo "boot: refocuses the invoking window at the end (DX-jn-cc-013)"
SEEDP="$(t list-panes -t bootsess:seed -F '#{pane_id}' | head -1)"
SEEDW="$(t display-message -p -t "$SEEDP" '#{window_id}')"
t select-window -t bootsess:b-3
rf_rc=0; BPANE="$SEEDP" brun "$BH" boot >/dev/null 2>&1 || rf_rc=$?
eq "idempotent re-run (zero launches) exits 0"      "0" "$rf_rc"
eq "…and hands the selection back to the invoking pane's window" \
   "$SEEDW" "$(t list-windows -t bootsess -F '#{window_id} #{window_active}' | awk '$2==1{print $1}')"
# Cosmetic degradation: an unresolvable invoking pane must never taint the run.
rfx_rc=0; BPANE='%9999' brun "$BH" boot >/dev/null 2>&1 || rfx_rc=$?
eq "unresolvable invoking pane degrades silently (exit 0)" "0" "$rfx_rc"
rf_wins_before="$(bwins)"
rfd="$(BPANE="$SEEDP" brun "$DBH" boot --dry-run 2>&1)"
eq "dry-run prints the select-window"               "1" "$(printf '%s\n' "$rfd" | grep -c 'select-window')"
eq "…and still created no window"                   "$rf_wins_before" "$(bwins)"

# --------------------------------------------------------------------------------
# down (DX-jn-cc-010). Inverse of boot: kill fleet-agent panes, path-keyed, guarded.
# Own session (downsess) + per-case homes. Panes are killed FOR REAL on the scratch
# server — before/after `t list-panes` is the oracle. FLEET_DOWN_SETTLE=0 keeps the
# settle poll from sleeping. Every absence-shaped assertion is positively paired.
echo; echo "down: the clean path (kill + verify / transient name / self / not-running)"

t new-session -d -x 200 -y 50 -s downsess -n dseed -c "$T" 'sleep 600' 2>/dev/null \
  || t new-window -d -t downsess -n dseed -c "$T" 'sleep 600' 2>/dev/null || true
for d in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 other other2; do mkdir -p "$T/dn-$d"; done

dwin(){ t new-window   -d -P -F '#{pane_id}' -t downsess -n "$1" -c "$2" 'sleep 600'; }
dsplit(){ t split-window -d -P -F '#{pane_id}' -t "downsess:$1" -c "$2" 'sleep 600'; }
alive(){ t list-panes -a -F '#{pane_id}' | grep -qx "$1"; }
# wait_path <pane_id> <expected-path> — block until tmux reports the pane's cwd. A pane's
# pane_current_path is NOT populated the instant it is created; `down` correctly refuses to kill a
# pane whose location it cannot corroborate, so a test that races the pane's cwd is testing the
# race, not the verb. (Diff review reproduced this at 12% — and proved FLEET_DOWN_SETTLE cannot
# mask it: a refused kill never reaches the settle loop.)
wait_path(){
  local pid="$1" want="$2" i=0 got
  while [ "$i" -lt 100 ]; do
    got="$(t display-message -p -t "$pid" '#{pane_current_path}' 2>/dev/null)"
    [ "$got" = "$want" ] && return 0
    i=$((i+1)); sleep 0.05
  done
  echo "  WARN: pane $pid never reported cwd $want (got '$got')" >&2
  return 1
}
drun(){ local h="$1"; shift; HOME="$h" WORKFLOW_FLEET_HOME_SESSION=downsess WORKFLOW_WORKTREES_MANIFEST="$h/$MANIFEST_REL" FLEET_TMUX_SOCKET="$SOCKET" FLEET_DOWN_SETTLE=0 TMUX_PANE="${DPANE:-$TMUX_PANE}" bash "$SCRIPT" "$@"; }
dlib(){ local h="$1"; shift; HOME="$h" WORKFLOW_FLEET_HOME_SESSION=downsess WORKFLOW_WORKTREES_MANIFEST="$h/$MANIFEST_REL" FLEET_TMUX_SOCKET="$SOCKET" FLEET_DOWN_SETTLE=0 TMUX_PANE="${DPANE:-$TMUX_PANE}" FLEET_LAYOUT_LIB=1 bash -c "source '$SCRIPT'; $*"; }
dreg(){ printf '%s\n' "$3" > "$1/.claude/running-agents/$2.$$"; printf '%s\n' "$4" > "$1/.claude/agents/$2.cwd"; }

# The clean run: d-1 (claude + companion, plus a skip-marked survivor and a co-tenant at a
# DIFFERENT cwd in the same window), dt-2 (live under a TRANSIENT registration name — the
# raison d'être), d-self (registration token == our TMUX_PANE), d-nr (nothing anywhere).
DKH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$DKH"
K_C1="$(dwin dka "$T/dn-1")"; K_M1="$(dsplit dka "$T/dn-1")"
K_S1="$(dsplit dka "$T/dn-1")"; K_O1="$(dsplit dka "$T/dn-other")"
t set-option -p -t "$K_S1" @fleet-layout-skip 1
K_C2="$(dwin dkb "$T/dn-2")"
K_CS="$(dwin dkc "$T/dn-3")"
for v in K_C1 K_M1 K_S1 K_O1 K_C2 K_CS; do eval "val=\$$v"; [ -n "$val" ] || { echo "FATAL: down fixture pane $v empty"; exit 1; }; done
dreg "$DKH" d-1                 "$K_C1" "$T/dn-1"
dreg "$DKH" wf-proj-2-69  "$K_C2" "$T/dn-2"
dreg "$DKH" d-self              "$K_CS" "$T/dn-3"
# a DEAD registration at a targeted path: the pid-only sweep must remove it
printf 'cwd:%s\n' "$T/dn-1" > "$DKH/.claude/running-agents/d-1-old.$DEADPID"
printf '%s\n' "$T/dn-1"     > "$DKH/.claude/agents/d-1-old.cwd"
manifest "$DKH" \
  '{"path": "'"$T/dn-1"'", "lane": 1, "agent": "d-1"},' \
  '{"path": "'"$T/dn-2"'", "lane": 2, "agent": "dt-2"},' \
  '{"path": "'"$T/dn-3"'", "lane": 3, "agent": "d-self"},' \
  '{"path": "'"$T/dn-4"'", "lane": 4, "agent": "d-nr"}'
dk_out="$(DPANE="$K_CS" drun "$DKH" down 2>&1)"; dk_rc=$?
eq "clean down exits 0"                             "0" "$dk_rc"
eq "d-1 reported downed (2 panes)"  "1" "$(printf '%s\n' "$dk_out" | grep -Ec 'd-1 +downed \(2 panes')"
eq "dt-2 downed under its TRANSIENT registration name" "1" "$(printf '%s\n' "$dk_out" | grep -Ec 'dt-2 +downed \(1 pane')"
eq "d-self reported skipped (self) without tainting the rc" "1" "$(printf '%s\n' "$dk_out" | grep -Ec 'd-self +skipped \(self\)')"
eq "d-nr reported not running"      "1" "$(printf '%s\n' "$dk_out" | grep -Ec 'd-nr +not running')"
ok "d-1's claude pane is dead"      "! alive '$K_C1'"
ok "d-1's companion is dead"        "! alive '$K_M1'"
ok "the transient-name claude pane is dead" "! alive '$K_C2'"
ok "the skip-marked pane SURVIVED"  "alive '$K_S1'"
ok "the co-tenant pane at a different cwd SURVIVED" "alive '$K_O1'"
ok "…and its window survived"       "t list-windows -t downsess -F '#{window_name}' | grep -qx dka"
ok "self's pane SURVIVED"           "alive '$K_CS'"
ok "the dead registration at a targeted path was swept"    "[ ! -f '$DKH/.claude/running-agents/d-1-old.$DEADPID' ]"
ok "the live-pid (dead-pane) registration was NOT swept"   "[ -f '$DKH/.claude/running-agents/d-1.$$' ]"
rerun_dk="$(DPANE="$K_CS" drun "$DKH" down 2>&1)"; rerun_dk_rc=$?
eq "re-run is idempotent: exit 0 (skip-marked survivor is sanctioned, not UNACCOUNTED)" "0" "$rerun_dk_rc"
eq "re-run reports d-1 not running" "1" "$(printf '%s\n' "$rerun_dk" | grep -Ec 'd-1 +not running')"

echo; echo "down: idle gate (busy marker, --force, unreadable dir fails toward BUSY)"
KBH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$KBH"; mkdir -p "$KBH/.claude/agent-busy"
B_C="$(dwin dkd "$T/dn-6")"
dreg "$KBH" d-busy "$B_C" "$T/dn-6"
touch "$KBH/.claude/agent-busy/d-busy"
manifest "$KBH" '{"path": "'"$T/dn-6"'", "lane": 6, "agent": "d-busy"}'
by_out="$(drun "$KBH" down 2>&1)"; by_rc=$?
eq "busy agent → non-zero exit"     "1" "$([ "$by_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…reported BUSY"                 "1" "$(printf '%s\n' "$by_out" | grep -c 'BUSY')"
ok "…its pane survived"             "alive '$B_C'"
fy_out="$(drun "$KBH" down --force 2>&1)"; fy_rc=$?
eq "--force kills the busy agent (exit 0)" "0" "$fy_rc"
ok "…its pane is dead"              "! alive '$B_C'"
# stale marker = idle
B_C2="$(dwin dke "$T/dn-7")"
dreg "$KBH" d-stale "$B_C2" "$T/dn-7"
touch -t 202001010000 "$KBH/.claude/agent-busy/d-stale" 2>/dev/null || touch "$KBH/.claude/agent-busy/d-stale"
manifest "$KBH" '{"path": "'"$T/dn-7"'", "lane": 7, "agent": "d-stale"}'
touch -t 202001010000 "$KBH/.claude/agent-busy/d-stale" 2>/dev/null
st_rc=0; drun "$KBH" down >/dev/null 2>&1 || st_rc=$?
eq "stale marker reads idle → killed, exit 0" "0" "$st_rc"
ok "…stale-marked agent's pane is dead" "! alive '$B_C2'"
# unreadable busy dir = UNKNOWN = BUSY (fail closed)
B_C3="$(dwin dkf "$T/dn-8")"
dreg "$KBH" d-ub "$B_C3" "$T/dn-8"
manifest "$KBH" '{"path": "'"$T/dn-8"'", "lane": 8, "agent": "d-ub"}'
chmod 000 "$KBH/.claude/agent-busy"
ub2_out="$(drun "$KBH" down 2>&1)"; ub2_rc=$?
chmod 700 "$KBH/.claude/agent-busy"
eq "unreadable busy dir → treated BUSY (non-zero)" "1" "$([ "$ub2_rc" -ne 0 ] && echo 1 || echo 0)"
ok "…and the pane survived (fail closed)"          "alive '$B_C3'"

echo; echo "down: guard-input matrix (each input stubbed to its failure value → refuse, zero kills)"
# a reusable live witness pane: any guard refusal must leave it alive
W_P="$(dwin dkw "$T/dn-10")"
mkgood(){ local h; h="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$h"
          dreg "$h" d-ok "$W_P" "$T/dn-10"
          manifest "$h" '{"path": "'"$T/dn-10"'", "lane": 10, "agent": "d-ok"}'
          printf '%s' "$h"; }
gm(){ # gm <desc> <home> [args…] — expect non-zero AND the witness pane alive
  local desc="$1" h="$2"; shift 2
  local rc=0; drun "$h" down "$@" >/dev/null 2>&1 || rc=$?
  eq "$desc → non-zero exit" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  ok "…zero kills (witness pane alive)" "alive '$W_P'"
}
gm "corrupt manifest"    "$CJH"
gm "missing manifest"    "$MFH"
chmod 000 "$UBH/$MANIFEST_REL"
gm "unreadable manifest" "$UBH"
chmod 600 "$UBH/$MANIFEST_REL"
gm "glob-metachar agent name" "$GBH"
gm "relative path entry"      "$RPH"
# zero agent entries: parses fine, enumerates nothing — the vacuous-exit-0 trap
ZAH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$ZAH"
manifest "$ZAH" '{"path": "'"$T/plain"'", "lane": 9}'
za_out="$(drun "$ZAH" down 2>&1)"; za_rc=$?
eq "manifest with NO agent entries → non-zero (never a vacuous 'fleet is down')" "1" "$([ "$za_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…names the empty enumeration" "1" "$(printf '%s\n' "$za_out" | grep -ci 'no agent entries')"
# registry dir missing
NRH="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$NRH/.config" "$NRH/.claude/agents"
manifest "$NRH" '{"path": "'"$T/dn-10"'", "lane": 10, "agent": "d-ok"}'
gm "registry directory missing" "$NRH"
# unreadable registry entry
URH2="$(mkgood)"
printf '%%1\n' > "$URH2/.claude/running-agents/u.42"; chmod 000 "$URH2/.claude/running-agents/u.42"
gm "unreadable registry entry" "$URH2"
chmod 600 "$URH2/.claude/running-agents/u.42"
# sidecar failure values: a LIVE registration we cannot place → refuse the WHOLE run
SC_P="$(dwin dkx "$T/dn-9")"
for sc in missing empty unreadable unresolvable; do
  SH="$(mkgood)"
  printf '%s\n' "$SC_P" > "$SH/.claude/running-agents/d-sc.$$"
  case "$sc" in
    missing)      : ;;
    empty)        : > "$SH/.claude/agents/d-sc.cwd" ;;
    unreadable)   printf '%s\n' "$T/dn-9" > "$SH/.claude/agents/d-sc.cwd"; chmod 000 "$SH/.claude/agents/d-sc.cwd" ;;
    unresolvable) printf '%s\n' "$T/never-created-dir" > "$SH/.claude/agents/d-sc.cwd" ;;
  esac
  gm "live registration with $sc sidecar" "$SH"
done
# noglob, blind tmux, empty pane list, unresolvable self — stubbed at lib level
GH2="$(mkgood)"
ng_rc=0; dlib "$GH2" 'set -f; down_fleet' >/dev/null 2>&1 || ng_rc=$?
eq "inherited noglob → non-zero" "1" "$([ "$ng_rc" -ne 0 ] && echo 1 || echo 0)"
dm_rc=0; dlib "$GH2" 'tmux(){ case "$1" in display-message) return 1;; *) command tmux -L "'"$SOCKET"'" "$@";; esac; }; down_fleet' >/dev/null 2>&1 || dm_rc=$?
eq "tmux not answering → non-zero" "1" "$([ "$dm_rc" -ne 0 ] && echo 1 || echo 0)"
ep_rc=0; dlib "$GH2" 'tmux(){ case "$1" in list-panes) return 0;; *) command tmux -L "'"$SOCKET"'" "$@";; esac; }; down_fleet' >/dev/null 2>&1 || ep_rc=$?
eq "empty server pane list → non-zero" "1" "$([ "$ep_rc" -ne 0 ] && echo 1 || echo 0)"
su_rc=0; dlib "$GH2" 'git(){ return 1; }; TMUX_PANE=%nomatch; down_fleet' >/dev/null 2>&1 || su_rc=$?
eq "self unresolvable (no token match, no toplevel) → non-zero" "1" "$([ "$su_rc" -ne 0 ] && echo 1 || echo 0)"
ok "…all lib-level refusals killed nothing (witness alive)" "alive '$W_P'"
# --force belongs to down alone — on any other verb it is a usage error, never
# silently ignored (rev-a/rev-b fix-round prescription)
ff_rc=0; drun "$GH2" wide --force >/dev/null 2>&1 || ff_rc=$?
eq "--force on a layout verb → usage error (exit 2)" "2" "$ff_rc"
# outside tmux: down must NOT take the layout verbs' soft exit 0
ot_out="$(env -u TMUX -u TMUX_PANE HOME="$GH2" WORKFLOW_FLEET_HOME_SESSION=downsess FLEET_TMUX_SOCKET="$SOCKET" FLEET_DOWN_SETTLE=0 bash "$SCRIPT" down 2>&1)"; ot_rc=$?
eq "outside tmux → non-zero (no silent 'nothing to do')" "1" "$([ "$ot_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…and says why (tmux), not usage noise" "1" "$(printf '%s\n' "$ot_out" | grep -ci 'tmux')"
# wrong-path token: registry and tmux contradict each other → that agent refused, others downed
WPH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$WPH"
WP_BAD="$(dwin dky "$T/dn-other2")"   # pane lives at dn-other2…
WP_OK="$(dwin dkz "$T/dn-12")"
printf '%s\n' "$WP_BAD" > "$WPH/.claude/running-agents/d-wp.$$"
printf '%s\n' "$T/dn-11" > "$WPH/.claude/agents/d-wp.cwd"   # …but claims dn-11
dreg "$WPH" d-ok2 "$WP_OK" "$T/dn-12"
manifest "$WPH" \
  '{"path": "'"$T/dn-11"'", "lane": 11, "agent": "d-wp"},' \
  '{"path": "'"$T/dn-12"'", "lane": 12, "agent": "d-ok2"}'
wp_out="$(drun "$WPH" down 2>&1)"; wp_rc=$?
eq "wrong-path token → non-zero"     "1" "$([ "$wp_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…that agent REFUSED"             "1" "$(printf '%s\n' "$wp_out" | grep -c 'REFUSED')"
ok "…its pane untouched"             "alive '$WP_BAD'"
eq "…but the OTHER agent still downed (partial-failure semantics)" "1" "$(printf '%s\n' "$wp_out" | grep -Ec 'd-ok2 +downed')"
ok "…and its pane is dead"           "! alive '$WP_OK'"

echo; echo "down: 'downed' is earned by observation, never by kill-pane's exit status"
KVH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$KVH"
KV_P="$(dwin dkv "$T/dn-13")"
dreg "$KVH" d-kv "$KV_P" "$T/dn-13"
manifest "$KVH" '{"path": "'"$T/dn-13"'", "lane": 13, "agent": "d-kv"}'
mk_out="$(dlib "$KVH" 'tmux(){ case "$1" in kill-pane) return 0;; *) command tmux -L "'"$SOCKET"'" "$@";; esac; }; down_fleet' 2>&1)"; mk_rc=$?
eq "masked kill-pane (rc 0, pane survives) → FAILED"  "1" "$(printf '%s\n' "$mk_out" | grep -c 'FAILED')"
eq "…never reported downed"                            "0" "$(printf '%s\n' "$mk_out" | grep -Ec 'd-kv +downed')"
eq "…and exits non-zero"                               "1" "$([ "$mk_rc" -ne 0 ] && echo 1 || echo 0)"
ok "…the pane it failed to kill is alive"              "alive '$KV_P'"
# the mid-run race: the masked kill ALSO sets the skip marker — verification must admit
# NO exemption ('observed dead, skip-marked or not'); this row alone reddens an
# exemption-honoring verification.
rc_out="$(dlib "$KVH" 'tmux(){ case "$1" in kill-pane) command tmux -L "'"$SOCKET"'" set-option -p -t "$3" @fleet-layout-skip 1; return 0;; *) command tmux -L "'"$SOCKET"'" "$@";; esac; }; down_fleet' 2>&1)"; rc_rc=$?
eq "marker set MID-RUN by the masked kill → still FAILED (no verification exemption)" "1" "$(printf '%s\n' "$rc_out" | grep -c 'FAILED')"
eq "…never downed"                                     "0" "$(printf '%s\n' "$rc_out" | grep -Ec 'd-kv +downed')"
eq "…non-zero"                                         "1" "$([ "$rc_rc" -ne 0 ] && echo 1 || echo 0)"
t set-option -p -t "$KV_P" -u @fleet-layout-skip 2>/dev/null
# a GENUINELY erroring kill-pane (rc!=0) must produce a per-entry report line, not just
# tmux stderr + a bare non-zero exit (rev-a/rev-b diff-round nit)
ek_out="$(dlib "$KVH" 'tmux(){ case "$1" in kill-pane) return 1;; *) command tmux -L "'"$SOCKET"'" "$@";; esac; }; down_fleet' 2>&1)"; ek_rc=$?
eq "erroring kill-pane → per-entry FAILED report" "1" "$(printf '%s\n' "$ek_out" | grep -c 'FAILED (kill errored')"
eq "…never downed"                                "0" "$(printf '%s\n' "$ek_out" | grep -Ec 'd-kv +downed')"
eq "…non-zero"                                    "1" "$([ "$ek_rc" -ne 0 ] && echo 1 || echo 0)"
# _down_verify_dead unit rows: the observation itself, each input stubbed
eq "_down_verify_dead: alive pane → not dead"          "1" "$(dlib "$KVH" "_down_verify_dead '$KV_P' >/dev/null 2>&1; echo \$?")"
eq "_down_verify_dead: absent pane, non-empty list → dead" "0" "$(dlib "$KVH" "_down_verify_dead '%9999' >/dev/null 2>&1; echo \$?")"
eq "_down_verify_dead: EMPTY list-panes is a contradiction → not dead (anti-vacuity)" "1" \
   "$(dlib "$KVH" 'tmux(){ case "$1" in list-panes) return 0;; *) command tmux -L "'"$SOCKET"'" "$@";; esac; }; _down_verify_dead %9999 >/dev/null 2>&1; echo $?')"

echo; echo "down: skip-marked claude pane is a PRE-kill decision; the marker read fails CLOSED"
KSH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$KSH"
KS_P="$(dwin dks "$T/dn-14")"
t set-option -p -t "$KS_P" @fleet-layout-skip 1
dreg "$KSH" d-skip "$KS_P" "$T/dn-14"
manifest "$KSH" '{"path": "'"$T/dn-14"'", "lane": 14, "agent": "d-skip"}'
sk_out="$(drun "$KSH" down 2>&1)"; sk_rc=$?
eq "skip-marked claude → skipped, non-zero (fleet not fully down)" "1" "$([ "$sk_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…reported as the marker skip"   "1" "$(printf '%s\n' "$sk_out" | grep -c 'skip-marked')"
ok "…pane survived"                 "alive '$KS_P'"
sf_rc=0; drun "$KSH" down --force >/dev/null 2>&1 || sf_rc=$?
eq "--force does NOT override the marker (BUSY gate only)" "1" "$([ "$sf_rc" -ne 0 ] && echo 1 || echo 0)"
ok "…pane still alive under --force" "alive '$KS_P'"
# belt-and-suspenders: pre-kill filter dropped AND an exemption branch added — the double
# regression. Inert on correct code (the filter skips before any kill).
bl_out="$(dlib "$KSH" 'tmux(){ case "$1" in kill-pane) return 0;; *) command tmux -L "'"$SOCKET"'" "$@";; esac; }; down_fleet' 2>&1)"; bl_rc=$?
eq "marked pane + masked kill → still the marker skip, never downed" "0" "$(printf '%s\n' "$bl_out" | grep -Ec 'd-skip +downed')"
ok "…pane alive"                    "alive '$KS_P'"
eq "…non-zero"                      "1" "$([ "$bl_rc" -ne 0 ] && echo 1 || echo 0)"
# marker read failure ≠ marker unset: a flaked query must refuse, not kill
mr_out="$(dlib "$KSH" 'tmux(){ case "$1" in show-options) return 1;; *) command tmux -L "'"$SOCKET"'" "$@";; esac; }; down_fleet' 2>&1)"; mr_rc=$?
eq "failed marker query → REFUSED (cannot read skip marker)" "1" "$(printf '%s\n' "$mr_out" | grep -c 'cannot read skip marker')"
eq "…non-zero"                      "1" "$([ "$mr_rc" -ne 0 ] && echo 1 || echo 0)"
ok "…the (genuinely marked) pane survived" "alive '$KS_P'"
# _skip_state unit rows (the ONE tri-state primitive both callers share)
eq "_skip_state: marked pane"    "marked"   "$(dlib "$KSH" "_skip_state '$KS_P'")"
eq "_skip_state: unmarked pane"  "unmarked" "$(dlib "$KSH" "_skip_state '$W_P'")"
eq "_skip_state: failed query"   "unknown"  "$(dlib "$KSH" 'tmux(){ return 1; }; _skip_state %1')"

echo; echo "down: headless registration, UNACCOUNTED probe, dry-run"
KHH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$KHH"
printf 'cwd:%s\n' "$T/dn-15" > "$KHH/.claude/running-agents/d-hl.$$"
printf '%s\n' "$T/dn-15"     > "$KHH/.claude/agents/d-hl.cwd"
manifest "$KHH" '{"path": "'"$T/dn-15"'", "lane": 15, "agent": "d-hl"}'
hl_out="$(drun "$KHH" down 2>&1)"; hl_rc=$?
eq "headless (cwd:) registration → reported, not killed, non-zero" "1" "$([ "$hl_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…reported headless"             "1" "$(printf '%s\n' "$hl_out" | grep -c 'headless')"
# UNACCOUNTED: an unmarked pane at a target path with NO live registration
KUH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$KUH"
KU_P="$(dwin dku "$T/dn-5")"
manifest "$KUH" '{"path": "'"$T/dn-5"'", "lane": 5, "agent": "d-ua"}'
ua_out="$(drun "$KUH" down 2>&1)"; ua_rc=$?
eq "unregistered pane at a target path → UNACCOUNTED, non-zero" "1" "$([ "$ua_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…reported UNACCOUNTED"          "1" "$(printf '%s\n' "$ua_out" | grep -c 'UNACCOUNTED')"
ok "…and never killed (outside the sanctioned kill set)" "alive '$KU_P'"
# dry-run: prints the kills, mutates nothing, observation neutralized (exit 0, no FAILED)
KDH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$KDH"
KD_P="$(dwin dkq "$T/dn-16")"
dreg "$KDH" d-dry "$KD_P" "$T/dn-16"
manifest "$KDH" '{"path": "'"$T/dn-16"'", "lane": 16, "agent": "d-dry"}'
reg_before="$(ls "$KDH/.claude/running-agents" | sort | tr '\n' ' ')"
dd_out="$(drun "$KDH" down --dry-run 2>&1)"; dd_rc=$?
eq "dry-run exits 0"                "0" "$dd_rc"
ok "dry-run actually emitted commands (so the checks below can fail)" "[ -n \"\$dd_out\" ]"
eq "dry-run prints the kill-pane it would run" "1" "$(printf '%s\n' "$dd_out" | grep -c "kill-pane -t $KD_P")"
eq "dry-run reports zero FAILED (observation neutralized)" "0" "$(printf '%s\n' "$dd_out" | grep -c 'FAILED')"
ok "dry-run killed nothing"         "alive '$KD_P'"
eq "dry-run left the registry byte-identical" "$reg_before" "$(ls "$KDH/.claude/running-agents" | sort | tr '\n' ' ')"

echo; echo "down: the invoking-worktree skip + the missing-worktree state"
# entry path == the invoker's toplevel with NO token match anywhere at that path: the
# safe direction is skip, but the summary must not read as fully down (rc=1, distinct
# report). A second entry whose worktree does not exist reports its own distinct state.
IVH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$IVH"; mkdir -p "$T/dn-20"
manifest "$IVH" \
  '{"path": "'"$T/dn-20"'", "lane": 20, "agent": "d-inv"},' \
  '{"path": "'"$T"'/no-dir-xyz", "lane": 21, "agent": "d-gone"}'
iv_out="$(dlib "$IVH" 'git(){ echo "'"$T/dn-20"'"; }; down_fleet' 2>&1)"; iv_rc=$?
eq "entry path == invoker toplevel (no token match) → non-zero" "1" "$([ "$iv_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…reported as the invoking-worktree skip" "1" "$(printf '%s\n' "$iv_out" | grep -c 'invoking pane is in this worktree')"
eq "…the missing worktree reports its own state" "1" "$(printf '%s\n' "$iv_out" | grep -Ec 'd-gone +not running \(worktree missing\)')"

echo; echo "down: self-hardening (token-keyed primary + the terminal kill-helper backstop)"
# Transient-named SELF: the registration name matches nothing in the manifest and the
# toplevel is misdirected (the harness cwd's repo, not the entry path) — only the TOKEN
# equality can identify self. --force must not change that.
TSH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$TSH"; mkdir -p "$T/dn-19"
TS_P="$(dwin dkt "$T/dn-19")"
printf '%s\n' "$TS_P" > "$TSH/.claude/running-agents/wf-proj-x-yz.$$"
printf '%s\n' "$T/dn-19" > "$TSH/.claude/agents/wf-proj-x-yz.cwd"
manifest "$TSH" '{"path": "'"$T/dn-19"'", "lane": 19, "agent": "d-tself"}'
ts_out="$(DPANE="$TS_P" drun "$TSH" down --force 2>&1)"; ts_rc=$?
eq "transient-named self + misdirected toplevel + --force → skipped (self), exit 0" "0" "$ts_rc"
eq "…reported skipped (self)" "1" "$(printf '%s\n' "$ts_out" | grep -Ec 'd-tself +skipped \(self\)')"
ok "…self's pane survived"    "alive '$TS_P'"
# The backstop's OWNING test: self's pane enters the kill set as another agent's
# COMPANION (parked at the target worktree, unmarked) — upstream self-exclusion cannot
# see it there; only _down_kill_pane's terminal refusal saves it. Deleting the backstop
# reddens exactly this row.
BSH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$BSH"; mkdir -p "$T/dn-18"
BS_C="$(dwin dkbs "$T/dn-18")"          # the target agent's claude pane
BS_ME="$(dsplit dkbs "$T/dn-18")"       # OUR pane, parked in the target's worktree
dreg "$BSH" d-bs "$BS_C" "$T/dn-18"
manifest "$BSH" '{"path": "'"$T/dn-18"'", "lane": 18, "agent": "d-bs"}'
bs_out="$(DPANE="$BS_ME" drun "$BSH" down 2>&1)"; bs_rc=$?
ok "the target's claude pane is dead"                 "! alive '$BS_C'"
ok "OUR pane (attributed as its companion) SURVIVED — the terminal backstop" "alive '$BS_ME'"
eq "…and the run is non-zero (a refused companion kill is not clean)" "1" "$([ "$bs_rc" -ne 0 ] && echo 1 || echo 0)"

echo; echo "down: shared-cwd ambiguity — the exempt pane survives, order-independent"
KAH2="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$KAH2"
A_P1="$(dwin dkg "$T/dn-17")"; A_P2="$(dsplit dkg "$T/dn-17")"; A_PC="$(dsplit dkg "$T/dn-17")"
printf '%s\n' "$A_P1" > "$KAH2/.claude/running-agents/d-sha.$$"
printf '%s\n' "$T/dn-17" > "$KAH2/.claude/agents/d-sha.cwd"
printf '%s\n' "$A_P2" > "$KAH2/.claude/running-agents/d-shb.$$"
printf '%s\n' "$T/dn-17" > "$KAH2/.claude/agents/d-shb.cwd"
manifest "$KAH2" '{"path": "'"$T/dn-17"'", "lane": 17, "agent": "d-sh"}'
sh_out="$(drun "$KAH2" down 2>&1)"; sh_rc=$?
eq "both same-cwd claude panes downed, exit 0" "0" "$sh_rc"
ok "first claude pane dead"         "! alive '$A_P1'"
ok "second claude pane dead"        "! alive '$A_P2'"
ok "the ambiguity-exempt pane SURVIVED (attributed to neither, sanctioned by the probe)" "alive '$A_PC'"

echo; echo "boot hardening (DX-jn-cc-010): cwd corroboration closes the double-launch"
mkdir -p "$T/boot-h1" "$T/boot-h2" "$T/boot-h3"
# a LIVE registration under a TRANSIENT name at the entry path → live, no window, no launch
BHH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$BHH"
H_P1="$(dwin bh1 "$T/boot-h1")"
printf '%s\n' "$H_P1" > "$BHH/.claude/running-agents/wf-proj-9-ab.$$"
printf '%s\n' "$T/boot-h1" > "$BHH/.claude/agents/wf-proj-9-ab.cwd"
manifest "$BHH" '{"path": "'"$T/boot-h1"'", "lane": 1, "agent": "bh-1"}'
: > "$BHH/rec"
hb_out="$(FLEET_BOOT_LAUNCH_RECORDER="$BHH/rec" brun "$BHH" boot 2>&1)"; hb_rc=$?
eq "transient-name live registration at the entry path → reported live-by-path" \
   "1" "$(printf '%s\n' "$hb_out" | grep -Ec 'bh-1 +live \(as wf-proj-9-ab')"
eq "…boot launched nothing (the 2026-07-10 double-launch hazard)" "0" "$(wc -l < "$BHH/rec" | tr -d ' ')"
ok "…and created no bh-1 window" "! t list-windows -t bootsess -F '#{window_name}' | grep -qx bh-1"
# a bare pane at the entry path with NO registration → occupied, no launch
BOH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$BOH"
H_P2="$(dwin bh2 "$T/boot-h2")"
manifest "$BOH" '{"path": "'"$T/boot-h2"'", "lane": 2, "agent": "bh-2"}'
: > "$BOH/rec"
ho_out="$(FLEET_BOOT_LAUNCH_RECORDER="$BOH/rec" brun "$BOH" boot 2>&1)"; ho_rc=$?
eq "bare pane at the entry path → reported occupied" "1" "$(printf '%s\n' "$ho_out" | grep -Ec 'bh-2 +occupied')"
eq "…boot launched nothing"      "0" "$(wc -l < "$BOH/rec" | tr -d ' ')"
# occupancy anti-vacuity: an empty list-panes -a while inside tmux is a contradiction —
# boot must refuse that launch, not read blindness as "unoccupied"
BAH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$BAH"
manifest "$BAH" '{"path": "'"$T/boot-h3"'", "lane": 3, "agent": "bh-3"}'
: > "$BAH/rec"
av_rc=0; HOME="$BAH" WORKFLOW_FLEET_HOME_SESSION=bootsess FLEET_TMUX_SOCKET="$SOCKET" FLEET_BOOT_LAUNCH_RECORDER="$BAH/rec" FLEET_LAYOUT_LIB=1 bash -c "source '$SCRIPT'
  tmux(){ case \"\$1 \$2\" in 'list-panes -a') return 0;; esac; command tmux -L '$SOCKET' \"\$@\"; }
  boot_fleet" >/dev/null 2>&1 || av_rc=$?
eq "blind pane list during occupancy → boot refuses that launch (non-zero)" "1" "$([ "$av_rc" -ne 0 ] && echo 1 || echo 0)"
eq "…and recorded no launch" "0" "$(wc -l < "$BAH/rec" | tr -d ' ')"

# ---------------------------------------------------------------- DX-jn-cc-014: parameterization
# The manifest path, the cell command, and the home session are KNOBS now — this section owns them.
echo
echo "DX-jn-cc-014 — manifest resolver, config load, cell knob, down filter, boot session"

# --- P1: fleet_manifest_path (unit; no tmux needed) --------------------------------------------
RES="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$RES/main/.claude" "$RES/.config"
( cd "$RES/main" && git init -q . && git commit -q --allow-empty -m x ) 2>/dev/null

# env override wins
r_env="$(cd "$RES/main" && HOME="$RES" WORKFLOW_WORKTREES_MANIFEST=/tmp/pinned.json bash -c ". '$here/_fleet.sh'; fleet_manifest_path")"
eq "resolver: WORKFLOW_WORKTREES_MANIFEST wins" "/tmp/pinned.json" "$r_env"

# default derives from the MAIN CLONE's basename
r_def="$(cd "$RES/main" && HOME="$RES" bash -c "unset WORKFLOW_WORKTREES_MANIFEST; . '$here/_fleet.sh'; fleet_manifest_path")"
eq "resolver: default derives <main-basename>-worktrees.json" "$RES/.config/main-worktrees.json" "$r_def"

# worktree-invariant: a LINKED worktree resolves to the SAME path (git common dir, not toplevel)
( cd "$RES/main" && git worktree add -q -b wt "$RES/main-wt" ) 2>/dev/null
r_wt="$(cd "$RES/main-wt" && HOME="$RES" bash -c "unset WORKFLOW_WORKTREES_MANIFEST; . '$here/_fleet.sh'; fleet_manifest_path")"
eq "resolver: a linked worktree resolves to the SAME manifest (worktree-invariant)" "$RES/.config/main-worktrees.json" "$r_wt"

# non-repo → non-zero AND empty output (return status is a contract)
NR="$(cd "$(mktemp -d)" && pwd -P)"
r_nr="$(cd "$NR" && HOME="$RES" bash -c "unset WORKFLOW_WORKTREES_MANIFEST; . '$here/_fleet.sh'; fleet_manifest_path" 2>/dev/null)"; r_nr_rc=$?
eq "resolver: outside a repo refuses (non-zero)" "1" "$([ "$r_nr_rc" -ne 0 ] && echo 1 || echo 0)"
eq "resolver: …and prints nothing" "" "$r_nr"

# --- P2: fleet-layout.sh loads workflow.config (config-file-only path) --------------------------
# BORN-GREEN GUARD: the env knob must be UNSET for this row, else it passes via the env var even
# with the config load entirely absent (rev-b).
CFH="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$CFH/.config" "$CFH/wt"
( cd "$CFH/wt" && git init -q . && git commit -q --allow-empty -m x ) 2>/dev/null
printf '{ "worktrees": [ {"agent":"c-1","active":true,"path":"%s"} ] }\n' "$CFH/wt" > "$CFH/.config/from-config.json"
CFG_REPO="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$CFG_REPO/.claude/scripts"
cp "$SCRIPT" "$here/_fleet.sh" "$CFG_REPO/.claude/scripts/"
cp "$CONFIG_SH" "$CFG_REPO/.claude/scripts/_config.sh"
( cd "$CFG_REPO" && git init -q . && git commit -q --allow-empty -m x ) 2>/dev/null
printf 'WORKFLOW_WORKTREES_MANIFEST="%s"\n' "$CFH/.config/from-config.json" > "$CFG_REPO/.claude/workflow.config"
cfg_out="$(cd "$CFG_REPO" && env -u WORKFLOW_WORKTREES_MANIFEST HOME="$CFH" WORKFLOW_FLEET_HOME_SESSION=bootsess FLEET_TMUX_SOCKET="$SOCKET" bash "$CFG_REPO/.claude/scripts/fleet-layout.sh" boot --dry-run 2>&1 || true)"
eq "config load: a manifest set ONLY in workflow.config reaches boot (env unset)" "1" "$(echo "$cfg_out" | grep -qi 'c-1' && echo 1 || echo 0)"

# --- P3: WORKFLOW_CELL_COMMAND (empty default upstream) ----------------------------------------
CCH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$CCH"; mkdir -p "$CCH/w1"
manifest "$CCH" "$(printf '{"agent":"cc-1","active":true,"path":"%s"}' "$CCH/w1")"
t new-session -d -s bootsess -n placeholder
CELLCMD='' FLEET_BOOT_LAUNCH_RECORDER="$CCH/rec" brun "$CCH" boot >/dev/null 2>&1; cc_rc=$?
eq "cell knob EMPTY: boot still succeeds (rc 0 — the success path is deliberate)" "0" "$cc_rc"
eq "cell knob EMPTY: 3-pane cell is still built" "3" "$(t list-panes -t bootsess:cc-1 -F x 2>/dev/null | wc -l | tr -d ' ')"
eq "cell knob EMPTY: NO companion command is keyed (recorder holds only the claude launch)" "cc-1:claude" "$(sed 's/\t/:/' "$CCH/rec" 2>/dev/null | paste -sd, -)"
eq "cell knob EMPTY: no DEGRADED report" "0" "$(CELLCMD='' brun "$CCH" boot 2>&1 | grep -ci DEGRADED)"
t kill-session -t bootsess 2>/dev/null || true

# --- P4: down <agent...> filter ----------------------------------------------------------------
DFH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$DFH"; mkdir -p "$DFH/.claude/agents" "$DFH/.claude/running-agents" "$DFH/wa" "$DFH/wb"
manifest "$DFH" "$(printf '{"agent":"d-a","active":true,"path":"%s"},{"agent":"d-b","active":true,"path":"%s"}' "$DFH/wa" "$DFH/wb")"
t new-session -d -s bootsess -n keep
pa="$(t new-window -d -P -F '#{pane_id}' -t bootsess -n d-a -c "$DFH/wa")"
pb="$(t new-window -d -P -F '#{pane_id}' -t bootsess -n d-b -c "$DFH/wb")"
wait_path "$pa" "$DFH/wa"; wait_path "$pb" "$DFH/wb"
printf '%s' "$pa" > "$DFH/.claude/running-agents/d-a.$$"; printf '%s' "$DFH/wa" > "$DFH/.claude/agents/d-a.cwd"
printf '%s' "$pb" > "$DFH/.claude/running-agents/d-b.$$"; printf '%s' "$DFH/wb" > "$DFH/.claude/agents/d-b.cwd"

FLEET_DOWN_SETTLE=1 brun "$DFH" down d-a >/dev/null 2>&1; df_rc=$?
eq "down <agent>: the requested agent's pane is dead" "0" "$(t list-panes -a -F '#{pane_id}' 2>/dev/null | grep -cx "$pa")"
eq "down <agent>: the OTHER agent's pane survives" "1" "$(t list-panes -a -F '#{pane_id}' 2>/dev/null | grep -cx "$pb")"
eq "down <agent>: exit 0 when the requested agent is verified down" "0" "$df_rc"

# unknown name → LOUD per-name refusal, nothing killed (empty-enumeration lesson).
# Message-specific: rc≠0 alone is born-green (the arg-parse usage branch already exits non-zero).
un_out="$(FLEET_DOWN_SETTLE=1 brun "$DFH" down no-such-agent 2>&1)"; un_rc=$?
eq "down <unknown>: refuses non-zero" "1" "$([ "$un_rc" -ne 0 ] && echo 1 || echo 0)"
eq "down <unknown>: names the unknown agent in the refusal" "1" "$(echo "$un_out" | grep -qi "no-such-agent" && echo 1 || echo 0)"
eq "down <unknown>: the live agent's pane is untouched" "1" "$(t list-panes -a -F '#{pane_id}' 2>/dev/null | grep -cx "$pb")"

# invalid name syntax → refused BEFORE enumeration
bad_out="$(FLEET_DOWN_SETTLE=1 brun "$DFH" down 'bad;name' 2>&1)"; bad_rc=$?
eq "down <invalid>: refuses non-zero" "1" "$([ "$bad_rc" -ne 0 ] && echo 1 || echo 0)"
eq "down <invalid>: says the name is invalid" "1" "$(echo "$bad_out" | grep -qi 'invalid' && echo 1 || echo 0)"

# a requested SELF is a loud refusal, never a silent skip (an exemption must not satisfy a
# per-request success claim — remove-worktree would read exit 0 as "agent is down")
selfp="$(t new-window -d -P -F '#{pane_id}' -t bootsess -n d-self -c "$DFH/wb")"
wait_path "$selfp" "$DFH/wb"
printf '%s' "$selfp" > "$DFH/.claude/running-agents/d-self.$$"; printf '%s' "$DFH/wb" > "$DFH/.claude/agents/d-self.cwd"
self_out="$(FLEET_DOWN_SETTLE=1 BPANE="$selfp" brun "$DFH" down d-self 2>&1)"; self_rc=$?
eq "down <self>: refuses non-zero (never a silent skip)" "1" "$([ "$self_rc" -ne 0 ] && echo 1 || echo 0)"
eq "down <self>: says so explicitly" "1" "$(echo "$self_out" | grep -qi 'self' && echo 1 || echo 0)"
eq "down <self>: own pane survives" "1" "$(t list-panes -a -F '#{pane_id}' 2>/dev/null | grep -cx "$selfp")"

# MIXED valid + unknown: the unknown name TAINTS the run, but must NOT spare the agent that DID
# match. Refusing everything here would make the run's own message a lie and send the operator
# hunting the wrong agent. (Caught in diff review: the first cut refused all and killed nothing.)
mkdir -p "$DFH/wc"
manifest "$DFH" "$(printf '{"agent":"d-a","active":true,"path":"%s"},{"agent":"d-b","active":true,"path":"%s"},{"agent":"d-c","active":true,"path":"%s"}' "$DFH/wa" "$DFH/wb" "$DFH/wc")"
pc="$(t new-window -d -P -F '#{pane_id}' -t bootsess -n d-c -c "$DFH/wc")"
wait_path "$pc" "$DFH/wc"          # settle the cwd BEFORE down runs — see wait_path
printf '%s' "$pc" > "$DFH/.claude/running-agents/d-c.$$"; printf '%s' "$DFH/wc" > "$DFH/.claude/agents/d-c.cwd"
mix_out="$(FLEET_DOWN_SETTLE=0 brun "$DFH" down d-c nope-agent 2>&1)"; mix_rc=$?
eq "down <valid> <unknown>: the VALID agent is still downed" "0" "$(t list-panes -a -F '#{pane_id}' 2>/dev/null | grep -cx "$pc")"
eq "down <valid> <unknown>: …and the run still exits non-zero (the unknown taints)" "1" "$([ "$mix_rc" -ne 0 ] && echo 1 || echo 0)"
eq "down <valid> <unknown>: …naming the unknown, not a blanket refusal" "1" "$(echo "$mix_out" | grep -qi 'nope-agent' && echo 1 || echo 0)"

# --force overrides the BUSY gate and NOTHING else: an unknown name still taints under --force.
fu_out="$(FLEET_DOWN_SETTLE=1 brun "$DFH" down --force still-not-here 2>&1)"; fu_rc=$?
eq "down --force <unknown>: --force does NOT bulldoze the unknown-name refusal" "1" "$([ "$fu_rc" -ne 0 ] && echo 1 || echo 0)"

# filter + CORRUPT manifest: the whole-file parse/validate guards run BEFORE the filter, so a
# corrupt manifest refuses even when only one agent was requested.
cp "$DFH/$MANIFEST_REL" "$DFH/manifest.bak"
printf '{ not json' > "$DFH/$MANIFEST_REL"
cm_rc=0; FLEET_DOWN_SETTLE=1 brun "$DFH" down d-a >/dev/null 2>&1 || cm_rc=$?
eq "down <agent> + CORRUPT manifest: refuses (the filter never weakens the parse guard)" "1" "$([ "$cm_rc" -ne 0 ] && echo 1 || echo 0)"
cp "$DFH/manifest.bak" "$DFH/$MANIFEST_REL"

t kill-session -t bootsess 2>/dev/null || true

# --- P2b: boot outside tmux refuses LOUDLY (rc 2 — the specific code down uses) -----------------
OTH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$OTH"; mkdir -p "$OTH/w1"
manifest "$OTH" "$(printf '{"agent":"o-1","active":true,"path":"%s"}' "$OTH/w1")"
ot_out="$(HOME="$OTH" WORKFLOW_WORKTREES_MANIFEST="$OTH/$MANIFEST_REL" FLEET_TMUX_SOCKET="$SOCKET" env -u TMUX -u TMUX_PANE bash "$SCRIPT" boot 2>&1)"; ot_rc=$?
eq "boot outside tmux: exits 2 (NOT 0 — 'nothing to do' would read as 'fleet is up')" "2" "$ot_rc"
eq "boot outside tmux: says it cannot launch" "1" "$(echo "$ot_out" | grep -qi 'not inside tmux' && echo 1 || echo 0)"
lay_rc=0; HOME="$OTH" FLEET_TMUX_SOCKET="$SOCKET" env -u TMUX -u TMUX_PANE bash "$SCRIPT" name-windows >/dev/null 2>&1 || lay_rc=$?
eq "…while a cosmetic layout verb still exits 0 outside tmux" "0" "$lay_rc"

# --- P2c layer 2: boot resolves the home session, and REBINDS it --------------------------------
SRH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$SRH"; mkdir -p "$SRH/w1"
manifest "$SRH" "$(printf '{"agent":"s-1","active":true,"path":"%s"}' "$SRH/w1")"
t new-session -d -s notmain -n anchor
anchor_pane="$(t list-panes -t notmain:anchor -F '#{pane_id}' | head -1)"
# configured session 'bootsess' does NOT exist → fall back to the invoking client's session
sr_out="$(HOME="$SRH" WORKFLOW_WORKTREES_MANIFEST="$SRH/$MANIFEST_REL" WORKFLOW_FLEET_HOME_SESSION=bootsess WORKFLOW_CELL_COMMAND='' FLEET_TMUX_SOCKET="$SOCKET" TMUX_PANE="$anchor_pane" bash "$SCRIPT" boot 2>&1)"
eq "boot: reports the session fallback" "1" "$(echo "$sr_out" | grep -qi "using current session" && echo 1 || echo 0)"
eq "boot: creates the window in the FALLBACK session" "1" "$(t list-windows -t notmain -F '#{window_name}' 2>/dev/null | grep -cx 's-1')"
# THE REBIND PROOF: the duplicate-launch guard must follow the resolved session. A window already
# named for the agent → window-exists, NO launch. Under a partial rebind the guard queries the
# nonexistent 'bootsess', matches nothing, and duplicate-launches. (rev-a's mutation-proof)
sr2="$(HOME="$SRH" WORKFLOW_WORKTREES_MANIFEST="$SRH/$MANIFEST_REL" WORKFLOW_FLEET_HOME_SESSION=bootsess WORKFLOW_CELL_COMMAND='' FLEET_BOOT_LAUNCH_RECORDER="$SRH/rec2" FLEET_TMUX_SOCKET="$SOCKET" TMUX_PANE="$anchor_pane" bash "$SCRIPT" boot 2>&1)"
eq "boot re-run: the window-exists guard FOLLOWS the resolved session" "1" "$(echo "$sr2" | grep -qi 'window-exists' && echo 1 || echo 0)"
eq "boot re-run: launches nothing (no duplicate)" "0" "$([ -s "$SRH/rec2" ] && echo 1 || echo 0)"
eq "boot re-run: still exactly ONE window for the agent" "1" "$(t list-windows -t notmain -F '#{window_name}' 2>/dev/null | grep -cx 's-1')"
# resolved session == the EXT session → loud refusal (the preamble's home!=ext guard ran BEFORE
# resolution, so the rebind must re-assert it)
ext_out="$(HOME="$SRH" WORKFLOW_WORKTREES_MANIFEST="$SRH/$MANIFEST_REL" WORKFLOW_FLEET_HOME_SESSION=bootsess WORKFLOW_FLEET_EXT_SESSION=notmain WORKFLOW_CELL_COMMAND='' FLEET_TMUX_SOCKET="$SOCKET" TMUX_PANE="$anchor_pane" bash "$SCRIPT" boot 2>&1)"; ext_rc=$?
eq "boot: resolved session == ext session → refuses (rc 2)" "2" "$ext_rc"
t kill-session -t notmain 2>/dev/null || true

# --- P2c layer 1: the persisted session identity must reach the AGENTS -------------------------
# name-windows runs from each agent's SessionStart, in ITS OWN worktree, as a separate process that
# never executes boot's resolution. So the identity has to be PERSISTED (workflow.config.local) and
# PROPAGATED (add-worktree seeds that file into the worktree). These two rows own that chain.
echo
echo "DX-jn-cc-014 — the persisted session identity reaches a separate process, in a worktree"

PH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$PH"
PMAIN="$(cd "$(mktemp -d)" && pwd -P)"; mkdir -p "$PMAIN/.claude/scripts"
cp "$SCRIPT" "$here/_fleet.sh" "$PMAIN/.claude/scripts/"
cp "$CONFIG_SH" "$PMAIN/.claude/scripts/_config.sh"
# COMMIT them: a linked worktree's checkout contains only TRACKED files. (That is the same fact the
# .local hazard rests on — .local is gitignored, so it never arrives via git at all.)
( cd "$PMAIN" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -q -m x ) 2>/dev/null

t new-session -d -s realsess -n anchor -c "$PMAIN"
p_anchor="$(t list-panes -t realsess:anchor -F '#{pane_id}' | head -1)"

# (e) PRECEDENCE: a STALE value in the COMMITTED config must lose to the machine-local .local.
#     (This is why the writers target .local — a committed session name is one machine's accident,
#      and every other engineer would inherit it.)
#
#     ASSERT THE RESOLVED VALUE, not an exit code: `name-windows` exits 0 whether it ordered
#     anything or not (_order_windows returns 0 on a session that doesn't exist), and a
#     pre-existing window keeps existing regardless — so rc/window-existence rows are BORN-GREEN
#     and stay green in the exact broken state (stale committed value winning) this row exists to
#     reject. The only honest assertion is what the config layer actually resolves to.
printf 'WORKFLOW_FLEET_HOME_SESSION="stale-main"\n' > "$PMAIN/.claude/workflow.config"
printf 'WORKFLOW_FLEET_HOME_SESSION="realsess"\n' >> "$PMAIN/.claude/workflow.config.local"
res_main="$(cd "$PMAIN" && HOME="$PH" bash -c 'source .claude/scripts/_config.sh 2>/dev/null; printf "%s" "${WORKFLOW_FLEET_HOME_SESSION:-UNSET}"')"
eq ".local BEATS a stale committed session value (the resolved identity is the .local one)" "realsess" "$res_main"
# …and the resolved identity is the one name-windows ACTS on. ORDERING is the only discriminator:
# window *renaming* reads `list-panes -a` (server-wide), so it works no matter which session the
# config names — but _order_windows takes the session as an argument and silently returns 0 when
# it doesn't exist. So: put two agents in the session in ANTI-canonical order (feature before the
# coordinator) and assert name-windows reorders them. Under a stale session identity the order
# would stand untouched, and this row reddens.
mkdir -p "$PMAIN/wf" "$PMAIN/wc"
w_f="$(t new-window -d -P -F '#{pane_id}' -t realsess -n wrong-f -c "$PMAIN/wf")"
w_c="$(t new-window -d -P -F '#{pane_id}' -t realsess -n wrong-c -c "$PMAIN/wc")"
printf '%s' "$w_f" > "$PH/.claude/running-agents/feature-1.$$"; printf '%s' "$PMAIN/wf" > "$PH/.claude/agents/feature-1.cwd"
printf '%s' "$w_c" > "$PH/.claude/running-agents/cc.$$";        printf '%s' "$PMAIN/wc" > "$PH/.claude/agents/cc.cwd"
eq "…(setup) the fleet windows start in ANTI-canonical order" "wrong-f,wrong-c" \
   "$(t list-windows -t realsess -F '#{window_name}' | grep -E '^wrong-' | paste -sd, -)"
( cd "$PMAIN" && HOME="$PH" FLEET_TMUX_SOCKET="$SOCKET" TMUX_PANE="$p_anchor" bash "$PMAIN/.claude/scripts/fleet-layout.sh" name-windows >/dev/null 2>&1 )
eq "…and name-windows ORDERED the resolved session (coordinator first — dies silently on a stale one)" "cc,feature-1" \
   "$(t list-windows -t realsess -F '#{window_name}' | grep -E '^(cc|feature-1)$' | paste -sd, -)"

# (f) PROPAGATION across the worktree boundary — the one §7(e) cannot do: a worktree's checkout
#     holds only TRACKED files, .local is untracked (created post-commit), and _config.sh resolves
#     its root to the WORKTREE. So the value only arrives if it is copied into the worktree's
#     .local (inlined here — the shared .local writer was removed as dead code; nothing in
#     production called it).
PWT="$PMAIN-wt"
( cd "$PMAIN" && git worktree add -q -b wtb "$PWT" ) 2>/dev/null
eq "a fresh worktree has NO .local (untracked — this is the whole hazard)" "0" "$([ -f "$PWT/.claude/workflow.config.local" ] && echo 1 || echo 0)"
cp "$PMAIN/.claude/workflow.config.local" "$PWT/.claude/workflow.config.local" 2>/dev/null
eq "…and the worktree now carries the session identity" "1" "$(grep -c 'WORKFLOW_FLEET_HOME_SESSION="realsess"' "$PWT/.claude/workflow.config.local" 2>/dev/null || echo 0)"
# The decisive assertion: name-windows, run as a SEPARATE PROCESS with cwd = the worktree (exactly
# what register-agent.sh does on SessionStart), resolves the session from the SEEDED .local.
# Without the seed it would read the default `main`, _order_windows would silently return 0, and
# canonical ordering would never happen in any project whose session isn't named `main`.
pw2="$(cd "$PWT" && HOME="$PH" FLEET_TMUX_SOCKET="$SOCKET" TMUX_PANE="$p_anchor" bash "$PWT/.claude/scripts/fleet-layout.sh" name-windows 2>&1; echo "rc=$?")"
eq "name-windows from the WORKTREE (separate process) resolves the seeded session" "rc=0" "$(printf '%s' "$pw2" | tail -1)"
seen="$(cd "$PWT" && HOME="$PH" FLEET_TMUX_SOCKET="$SOCKET" TMUX_PANE="$p_anchor" bash -c 'source .claude/scripts/_config.sh 2>/dev/null; printf "%s" "${WORKFLOW_FLEET_HOME_SESSION:-UNSET}"')"
eq "…because the worktree's OWN config resolves it (not the default)" "realsess" "$seen"
t kill-session -t realsess 2>/dev/null || true

# --- NB2: an UNREADABLE pane cwd is UNKNOWN, not "absent" --------------------------------------
# _panes_at_path used to `continue` past a pane whose cwd field came back empty — silently dropping
# it — while treating an empty pane LIST as UNKNOWN (rc 2, refuse). Field-level blindness read as
# "not here"; the same empty-enumeration class, one level down. It is REACHABLE: a pane's cwd is not
# populated the instant tmux creates it (that race is what made this suite flaky at 12%).
# Consequences: boot's occupancy backstop — the direct plug for the double-launch hazard, whose own
# comment says "never read blindness as 'unoccupied'" — would MISS the pane and launch a second
# claude into the worktree; down's UNACCOUNTED probe would report a live pane as "not running".
echo
echo "DX-jn-cc-014 — a blind pane cwd is UNKNOWN (fail closed), never 'absent'"

NBH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$NBH"; mkdir -p "$NBH/w1"
manifest "$NBH" "$(printf '{"agent":"nb-1","active":true,"path":"%s"}' "$NBH/w1")"
t new-session -d -s bootsess -n keep
# A pane IS sitting at the worktree, but tmux reports NO path for it (the stub reproduces the
# not-yet-populated-cwd state exactly). boot must refuse to launch, not launch blind.
occ_pane="$(t new-window -d -P -F '#{pane_id}' -t bootsess -n squatter -c "$NBH/w1")"
nb_out="$(HOME="$NBH" WORKFLOW_WORKTREES_MANIFEST="$NBH/$MANIFEST_REL" WORKFLOW_FLEET_HOME_SESSION=bootsess \
  WORKFLOW_CELL_COMMAND='' FLEET_BOOT_LAUNCH_RECORDER="$NBH/rec" FLEET_TMUX_SOCKET="$SOCKET" \
  bash -c '
    tmux() {
      if [ "$1" = list-panes ]; then
        # every field intact EXCEPT the cwd of the pane at the worktree — i.e. tmux knows the pane
        # exists but cannot say where it is.
        command tmux -L "$FLEET_TMUX_SOCKET" "$@" | awk -F"\t" -v p="'"$occ_pane"'" \
          "BEGIN{OFS=\"\t\"} \$1==p {\$NF=\"\"} {print}"
      else
        command tmux -L "$FLEET_TMUX_SOCKET" "$@"
      fi
    }
    export -f tmux 2>/dev/null || true
    source "'"$SCRIPT"'" 
  ' 2>&1 || true)"
# The stub above only works if the script consults list-panes through the shell function; rather
# than depend on that, assert the PREDICATE directly — it is the one every caller routes through.
nb_rc=0; blib "$NBH" '
  tmux(){
    if [ "$1" = list-panes ]; then
      case "$*" in
        *pane_current_path*) printf "%%99999\tsquatter\t\n" ;;   # in the snapshot, with NO path
        *)                   printf "%%99999\n" ;;                 # …but the pane DOES exist
      esac
    else command tmux -L "$FLEET_TMUX_SOCKET" "$@"; fi
  }
  _panes_at_path "'"$NBH/w1"'" >/dev/null' || nb_rc=$?
eq "_panes_at_path: a pane with an UNREADABLE cwd => rc 2 (UNKNOWN), never rc 1 ('none')" "2" "$nb_rc"
# and the whole-list-empty case still returns 2 (unchanged)
nb2_rc=0; blib "$NBH" '
  tmux(){ if [ "$1" = list-panes ]; then printf ""; else command tmux -L "$FLEET_TMUX_SOCKET" "$@"; fi; }
  _panes_at_path "'"$NBH/w1"'" >/dev/null' || nb2_rc=$?
eq "_panes_at_path: an EMPTY pane list still => rc 2 (unchanged)" "2" "$nb2_rc"
# a readable pane at a DIFFERENT path is still an honest "none" (rc 1) — the fix must not turn
# every miss into UNKNOWN, which would refuse every legitimate boot.
nb3_rc=0; blib "$NBH" '
  tmux(){ if [ "$1" = list-panes ]; then printf "%%99999\tw\t/somewhere/else\n"; else command tmux -L "$FLEET_TMUX_SOCKET" "$@"; fi; }
  _panes_at_path "'"$NBH/w1"'" >/dev/null' || nb3_rc=$?
eq "_panes_at_path: a readable pane elsewhere is still an honest 'none' (rc 1)" "1" "$nb3_rc"
t kill-session -t bootsess 2>/dev/null || true

# --- down: a BLIND path field in the snapshot is not "no pane" ---------------------------------
# THE FLAKE, root-caused 2026-07-11 (12% of runs). down corroborates its kill against a
# `list-panes` snapshot. tmux does not populate pane_current_path the instant a pane is created —
# and `list-panes` and `display-message` settle at different moments — so a LIVE pane can appear in
# the snapshot with an EMPTY path. down read that as "token resolves to no pane" and REFUSED to
# kill a live agent. The refusal is the right instinct (fail closed) but the premise was a race:
# absence and blindness are different, and blindness must be re-read, not concluded from.
echo
echo "DX-jn-cc-014 — down re-reads a blind pane path instead of calling it 'no pane'"

BPH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$BPH"; mkdir -p "$BPH/wx"
manifest "$BPH" "$(printf '{"agent":"bp-1","active":true,"path":"%s"}' "$BPH/wx")"
t new-session -d -s blindsess -n keep 2>/dev/null || true
bp="$(t new-window -d -P -F '#{pane_id}' -t blindsess -n bp-1 -c "$BPH/wx")"
wait_path "$bp" "$BPH/wx"
printf '%s' "$bp" > "$BPH/.claude/running-agents/bp-1.$$"; printf '%s' "$BPH/wx" > "$BPH/.claude/agents/bp-1.cwd"
# Stub tmux so the SNAPSHOT reports this pane with an EMPTY path (exactly the transient state),
# while display-message still resolves it — i.e. reproduce the race deterministically.
dlib "$BPH" '
  tmux(){
    if [ "$1" = list-panes ]; then
      command tmux -L "$FLEET_TMUX_SOCKET" "$@" | awk -F"\t" -v p="'"$bp"'" "BEGIN{OFS=\"\t\"} (NF>=2 && \$1==p){\$NF=\"\"} {print}"
    else
      command tmux -L "$FLEET_TMUX_SOCKET" "$@"
    fi
  }
  down_fleet' >/dev/null 2>&1 || true
eq "down: a live pane whose snapshot path is BLIND is re-read and killed (not refused as 'no pane')" \
   "0" "$(t list-panes -a -F '#{pane_id}' 2>/dev/null | grep -cx "$bp")"

# …and a token that truly resolves to NOTHING is still refused, with nothing killed.
mkdir -p "$BPH/wy"
manifest "$BPH" "$(printf '{"agent":"bp-2","active":true,"path":"%s"}' "$BPH/wy")"
keep_p="$(t new-window -d -P -F '#{pane_id}' -t blindsess -n bystander -c "$BPH/wy")"
wait_path "$keep_p" "$BPH/wy"
printf '%%99999' > "$BPH/.claude/running-agents/bp-2.$$"; printf '%s' "$BPH/wy" > "$BPH/.claude/agents/bp-2.cwd"
gone_rc=0; drun "$BPH" down >/dev/null 2>&1 || gone_rc=$?
eq "down: a token that resolves to NO pane is still refused (rc≠0)" "1" "$([ "$gone_rc" -ne 0 ] && echo 1 || echo 0)"
eq "down: …and the bystander pane at that worktree is NOT killed" "1" "$(t list-panes -a -F '#{pane_id}' 2>/dev/null | grep -cx "$keep_p")"
t kill-session -t downsess 2>/dev/null || true

# --- down's CLOSING probe must fail closed on UNKNOWN ------------------------------------------
# The closing probe is what EARNS the success claim: after the kills, it looks for panes still alive
# at the worktree. rc 2 means "we could not see". Falling through to `downed` + exit 0 on a blind
# probe is a false success on a destructive verb — and `remove-worktree` gates DELETING the worktree
# on exactly that exit code, so it would delete a worktree out from under a possibly-live pane. The
# pre-kill probe already failed closed here; this one did not (the gap was dormant until the blind
# -field fix made rc 2 reachable — widening a status's trigger makes every unhandled consumer live).
echo
echo "DX-jn-cc-014 — a BLIND closing probe never claims 'downed'"

CPH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$CPH"; mkdir -p "$CPH/wz"
manifest "$CPH" "$(printf '{"agent":"cp-1","active":true,"path":"%s"}' "$CPH/wz")"
t new-session -d -s cpsess -n keep 2>/dev/null || true
cp_pane="$(t new-window -d -P -F '#{pane_id}' -t cpsess -n cp-1 -c "$CPH/wz")"
wait_path "$cp_pane" "$CPH/wz"
printf '%s' "$cp_pane" > "$CPH/.claude/running-agents/cp-1.$$"; printf '%s' "$CPH/wz" > "$CPH/.claude/agents/cp-1.cwd"
# Blind the CLOSING probe only: let everything run normally, then make _panes_at_path report UNKNOWN
# once the kill has happened (the pane is gone by then, so this stub is what a blind probe looks like).
cp_out="$(dlib "$CPH" '
  _orig_panes_at_path(){ :; }
  _down_probe_unsanctioned(){ return 2; }   # the probe cannot see
  down_fleet' 2>&1)"; cp_rc=$?
eq "blind closing probe: down does NOT report 'downed'" "0" "$(printf '%s' "$cp_out" | grep -c 'downed')"
eq "blind closing probe: it REFUSES, naming the blindness" "1" "$(printf '%s' "$cp_out" | grep -qi 'cannot enumerate panes to confirm nothing survived' && echo 1 || echo 0)"
eq "blind closing probe: exit is NON-ZERO (remove-worktree gates deletion on this)" "1" "$([ "$cp_rc" -ne 0 ] && echo 1 || echo 0)"
eq "blind closing probe: the success line is NOT printed" "0" "$(printf '%s' "$cp_out" | grep -c 'every non-self entry is downed-and-verified')"
t kill-session -t cpsess 2>/dev/null || true

# A pane that VANISHES between the snapshot and the re-read is ABSENT, not blind: _panes_at_path
# must report an honest "none" (rc 1), not UNKNOWN — otherwise every pane that closes mid-run turns
# into a spurious refusal, which is the class the re-read was introduced to remove.
VPH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$VPH"; mkdir -p "$VPH/wv"
vg_rc=0; blib "$VPH" '
  tmux(){ if [ "$1" = list-panes ]; then printf "%%99998\tw\t\n"; else command tmux -L "$FLEET_TMUX_SOCKET" "$@"; fi; }
  _panes_at_path "'"$VPH/wv"'" >/dev/null' || vg_rc=$?
eq "_panes_at_path: a pane that VANISHED (display-message fails) is an honest 'none' (rc 1), not UNKNOWN" "1" "$vg_rc"

# --- the gone-vs-blind ORACLE must itself fail closed --------------------------------------------
# _pane_path_settled tells "pane gone" from "pane blind" by asking the pane LIST. That query can be
# blind too — and an EMPTY `list-panes -a` reply is tmux contradicting itself by construction (our
# own pane is always in it). Reading it as "the pane is gone" would drop the pane from
# _panes_at_path and let boot's occupancy backstop launch a SECOND claude into the worktree: the
# unknown-is-not-absent bug, re-entering through the fix for that same bug's previous instance.
echo
echo "DX-jn-cc-014 — the gone-vs-blind oracle fails closed on a blind pane list"

OBH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$OBH"
ob_rc=0; blib "$OBH" '
  tmux(){
    case "$1" in
      display-message) printf "" ;;                                  # blind: no location
      list-panes)      printf "" ;;                                  # blind: no pane list either
      *) command tmux -L "$FLEET_TMUX_SOCKET" "$@" ;;
    esac
  }
  _pane_path_settled %7 >/dev/null' || ob_rc=$?
eq "_pane_path_settled: a BLIND pane list => rc 2 (UNKNOWN), never rc 1 ('gone')" "2" "$ob_rc"

# …and a readable list that genuinely lacks the pane is still an honest "gone" (rc 1).
og_rc=0; blib "$OBH" '
  tmux(){
    case "$1" in
      display-message) printf "" ;;
      list-panes)      printf "%%1\n%%2\n" ;;                        # readable; %7 is not in it
      *) command tmux -L "$FLEET_TMUX_SOCKET" "$@" ;;
    esac
  }
  _pane_path_settled %7 >/dev/null' || og_rc=$?
eq "_pane_path_settled: a readable list without the pane => rc 1 (genuinely gone)" "1" "$og_rc"

# --- boot: a blind WINDOW list must not launch ---------------------------------------------------
# The last unguarded oracle on a launch-decision path (reviewer follow-up). _boot_window_exists
# piped `list-windows` straight into grep, so a blind reply matched nothing and read as "no window"
# => boot launches a SECOND claude into the worktree. Note the guard alone was NOT enough: the call
# site tested only zero-vs-nonzero, so a guarded rc 2 still fell through to the launch. Unknown is
# not absent — and a status nobody reads is not a guard.
echo
echo "DX-jn-cc-015 — boot refuses to launch when the window list is blind"

BWH="$(cd "$(mktemp -d)" && pwd -P)"; bmk "$BWH"; mkdir -p "$BWH/w1"
manifest "$BWH" "$(printf '{"agent":"bw-1","active":true,"path":"%s"}' "$BWH/w1")"
t new-session -d -s bootsess -n keep 2>/dev/null || true
bw_out="$(blib "$BWH" '
  tmux(){ if [ "$1" = list-windows ]; then printf ""; else command tmux -L "$FLEET_TMUX_SOCKET" "$@"; fi; }
  FLEET_BOOT_LAUNCH_RECORDER="'"$BWH/rec"'" boot_fleet' 2>&1)"; bw_rc=$?
eq "blind window list: boot REFUSES rather than launching" "1" "$(printf '%s' "$bw_out" | grep -qi 'not launching blind' && echo 1 || echo 0)"
eq "blind window list: nothing is launched" "0" "$([ -s "$BWH/rec" ] && echo 1 || echo 0)"
eq "blind window list: the run exits non-zero" "1" "$([ "$bw_rc" -ne 0 ] && echo 1 || echo 0)"
t kill-session -t bootsess 2>/dev/null || true

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
