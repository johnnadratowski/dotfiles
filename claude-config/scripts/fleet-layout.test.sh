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
lib(){ HOME="$FAKEHOME" FLEET_TMUX_SOCKET="$SOCKET" FLEET_LAYOUT_LIB=1 FAKE_SELF="${FAKE_SELF:-%901}" FAKE_SIB="${FAKE_SIB:-%902}" bash -c "source '$SCRIPT'; $*"; }
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
# A SINGLE-AGENT WINDOW IS NAMED FOR THE AGENT'S LABEL, not its id. `fleet_lane_display_name`
# maps a lane number to a fixed short name (lane 1 -> vii, 2 -> ott, 3 -> woo, 4 -> jaa), and
# the tab bar is the one surface where a one-syllable name beats a precise one — it is read at
# a glance and truncated hard. The id still owns every address (SendMessage, paths, branches).
# These fixtures are `x-N`, which parses as a lane number exactly as `feature-N` does, so they
# get labels too; that is the intended behaviour and not fixture-specific.
eq "one agent -> its lane label"          "vii"         "$(lib 'window_name_from_names x-1')"
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
eq "the window with one claude pane is named for its agent" "vii"         "$(wname "$P_A")"
eq "x-2's window is named for it"                           "ott"         "$(wname "$P_D")"
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
# This file signals NO pid. `down` and its kill -0 liveness probe moved to team-boot.sh, so the
# absence is now total rather than "everything except the probe".
#
# The row it replaces could not fail: `grep -E 'kill +-' | grep -vc 'kill -0'` prints 0 when the
# FIRST grep matches nothing, so it passed on a file with no `kill` in it — and equally on a
# file where the thing it was protecting had been deleted. A bare `grep -c` cannot do that.
eq "the file signals no pid at all" "0" "$(nocom | grep -cE 'kill +-')"
#
# All four rows above are SOURCE GREPS, and they catch a literal only: a mutation that builds
# the verb from parts (`_k=kill; tmux "${_k}-server"`) passes every one of them. They are an
# anti-copy-paste tripwire, not a safety property — the property itself is unpinned.
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

# The tty parse USED TO BE TESTED HERE, and was not: two rows re-implemented _spawn_ext_client's
# parser inside the test body and asserted on that copy, so gutting the real validation left the
# suite green. Deleted rather than left to look like coverage.
#
# The function is also structurally unreachable from this harness — _can_spawn requires
# FLEET_TMUX_SOCKET to be EMPTY and every invocation here sets it — so testing it for real needs
# either an extracted parser helper or a harness that can run without the scratch socket. Neither
# is worth inventing for a parse that only runs when an iTerm window is being spawned; recorded
# as a known gap instead of a fake row.

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
eq "each feature agent is alone in a window named for it" "jaa ott vii woo" \
   "$(for p in $P_A $P_D $P_I $P_K; do win_of "$p"; done | sort | tr '\n' ' ' | sed 's/ $//')"
eq "no feature agent is left in a features* window" "0" \
   "$(for p in $P_A $P_D $P_I $P_K; do win_of "$p"; done | grep -c '^features' || true)"
eq "still 12 panes; nothing destroyed" "12" "$(t list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
eq "the review/test co-tenant window is untouched by single" "1" \
   "$(t list-windows -a -F '#{window_name}' | grep -cx review-test)"


echo; echo "lead-window: the lead's own window is built, not left bare"
# build_cell gives every FEATURE agent a companion column. The lead's window is not a cell, so
# nothing ever created its second pane — and both downstream steps silently no-op on a lone
# pane: _normalize_lead_window only resizes when a second column exists, _seed_companion only
# seeds a pane that is already there. So the lead alone ran without its tool.
t new-window -d -t main -n wlead -c "$T/pr" 'sleep 600'
LEADP="$(t list-panes -t main:wlead -F '#{pane_id}' | head -1)"
lib "ensure_lead_window '$LEADP'" >/dev/null 2>&1
eq "a one-pane lead window gains exactly one companion" "2" \
   "$(t list-panes -t main:wlead -F x | wc -l | tr -d ' ')"
eq "the companion is a SECOND COLUMN, not a stacked row" "yes" \
   "$(t list-panes -t main:wlead -F '#{pane_id} #{pane_left}' | awk -v l="$LEADP" '$1==l{x=$2} $1!=l{y=$2} END{print (y>x)?"yes":"no"}')"
eq "…and focus stays on the lead, which is mid-boot" "$LEADP" \
   "$(t display-message -p -t main:wlead '#{pane_id}')"

# IDEMPOTENT BY COUNT is the whole safety story — boot calls this every time, and a window that
# already has a companion (or a subagent stack) must not gain another pane per boot.
lib "ensure_lead_window '$LEADP'" >/dev/null 2>&1
lib "ensure_lead_window '$LEADP'" >/dev/null 2>&1
eq "re-running never splits the window again" "2" \
   "$(t list-panes -t main:wlead -F x | wc -l | tr -d ' ')"

# THE SEED MUST LAND ON THE FIRST CALL. A pane reports the exec'ing process for a few hundred
# ms after it is created, which _pane_is_shell reads as "busy — hands off". Boot calls this
# ONCE, so without the settle-wait the lead's companion came up at a bare prompt and only ever
# got its tool if someone re-ran a layout verb later. Observed live on 2026-07-30.
t new-window -d -t main -n wlead2 -c "$T/test" 'sleep 600'
LEADP2="$(t list-panes -t main:wlead2 -F '#{pane_id}' | head -1)"
export WORKFLOW_CELL_COMMAND=":"
seedout="$(lib "ensure_lead_window '$LEADP2'" 2>&1)"
unset WORKFLOW_CELL_COMMAND
eq "the companion is seeded on the FIRST call, not on a later re-run" "1" \
   "$(printf '%s' "$seedout" | grep -c 'companion .* started')"

# EVERY agent, not just the lead. Teammates spawn as split panes in the LEAD's window and are
# broken out afterwards; tmux keeps the survivors' geometry rather than reflowing, so staffing
# four agents left the lead's chat at 62 columns of 208 while each teammate sat alone at full
# width. Observed live on 2026-07-30, immediately after a clean staff of four.
#
# STRIP A COMPANION FIRST. After `single` every fixture agent already has one, so asserting
# against that state would pass no matter what the code did. x-4 is reduced to the shape a
# freshly-staffed teammate actually arrives in — alone in its window — and must be rebuilt.
W_K="$(t list-panes -a -F '#{pane_id} #{window_id}' | awk -v p="$P_K" '$1==p{print $2}')"
t list-panes -t "$W_K" -F '#{pane_id}' | grep -vx "$P_K" | while read -r dead; do t kill-pane -t "$dead"; done
eq "fixture: x-4 is alone in its window, as a new teammate is" "1" \
   "$(t list-panes -t "$W_K" -F x | wc -l | tr -d ' ')"
lib "ensure_agent_windows" >/dev/null 2>&1
eq "a lone agent's window gains its companion column back" "2" \
   "$(t list-panes -t "$W_K" -F x | wc -l | tr -d ' ')"
eq "…and the agent's own pane survived it" "1" \
   "$(t list-panes -t "$W_K" -F '#{pane_id}' | grep -cx "$P_K")"
eq "…as a column beside it, not a row beneath" "yes" \
   "$(t list-panes -t "$W_K" -F '#{pane_id} #{pane_left}' | awk -v l="$P_K" '$1==l{x=$2} $1!=l{y=$2} END{print (y>x)?"yes":"no"}')"

# Convergence, not accumulation: the layout verbs call this on EVERY run.
after="$(t list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"
lib "ensure_agent_windows" >/dev/null 2>&1
eq "re-running adds nothing — the shape converges" "$after" \
   "$(t list-panes -a -F '#{pane_id}' | wc -l | tr -d ' ')"

# LANE AGENTS ONLY. A reviewer/tester is task-scoped and belongs stacked under the pane that
# spawned it — `subagents` owns that placement. Without this filter every reviewer got its own
# companion column and then its own window, the exact arrangement the canonical spawn rule
# exists to prevent. Observed live on 2026-07-30 immediately after a staffing.
W_REV="$(t list-panes -a -F '#{pane_id} #{window_id}' | awk -v p="$P_F" '$1==p{print $2}')"
revbefore="$(t list-panes -t "$W_REV" -F x | wc -l | tr -d ' ')"
lib "ensure_agent_windows" >/dev/null 2>&1
eq "a review/test window is left alone" "$revbefore" \
   "$(t list-panes -t "$W_REV" -F x | wc -l | tr -d ' ')"

# A SHARED window is a cell, and cells belong to build_cell/_balance_cell. Everything this verb
# does is a share of the WINDOW, so applied to two agents in one window each demands 60% of the
# full width and the last write wins — the "percentage of the WINDOW, not of the cell" defect
# _balance_cell already records as fixed once.
t new-window -d -t main -n wshared -c "$T/proj-2" 'sleep 600'
SH1="$(t list-panes -t main:wshared -F '#{pane_id}' | head -1)"
t join-pane -h -s "$P_I" -t "$SH1"          # x-3 now co-tenants this window
W_SH="$(t list-panes -a -F '#{pane_id} #{window_id}' | awk -v p="$P_I" '$1==p{print $2}')"
shbefore="$(t list-panes -t "$W_SH" -F x | wc -l | tr -d ' ')"
lib "ensure_agent_windows" >/dev/null 2>&1
eq "an agent sharing a window is left to build_cell" "$shbefore" \
   "$(t list-panes -t "$W_SH" -F x | wc -l | tr -d ' ')"

# A SUBAGENT MUST NOT PLACE ITS SIBLINGS. Selection is by cwd and a subagent never leaves the
# tree it was spawned in, so from one reviewer's pane its sibling matches the same test — and
# the SubagentStart hook fires this verb in EVERY agent's pane. Observed live: `subagents
# --dry-run` from a reviewer emitted `join-pane -v -s %62 -t %61`, %61 being that reviewer.
# Register the fake session, or the not-a-fleet-agent guard returns before the sibling check.
mkdir -p "$FAKEHOME/.claude/running-agents"
printf '%s\n' "%901" > "$FAKEHOME/.claude/running-agents/rev-a.999"
sub_out="$(FLEET_SUBAGENT_ROWS_STUB=1 lib '
  _subagent_panes() { printf "%s\t%s\t%s\n" "$FAKE_SELF" rev-a reviewer; printf "%s\t%s\t%s\n" "$FAKE_SIB" rev-b reviewer; }
  TMUX_PANE="$FAKE_SELF"; fleet_tmux_ok() { return 0; }; layout_subagents' 2>&1)"
case "$sub_out" in
  *"itself a subagent"*) pass=$((pass+1)); echo "  PASS: a subagent declines to place its siblings" ;;
  *) fail=$((fail+1)); printf '  FAIL: a subagent declines to place its siblings\n        got: [%s]\n' "$sub_out" ;;
esac
case "$sub_out" in
  *join-pane*) fail=$((fail+1)); printf '  FAIL: …and proposes no join\n        got: [%s]\n' "$sub_out" ;;
  *) pass=$((pass+1)); echo "  PASS: …and proposes no join" ;;
esac

# NOT A FLEET AGENT ⇒ TOUCH NOTHING. `subagents` is hook-driven: place-subagents.sh runs on
# every SubagentStart in EVERY session on this machine. A plain claude in an unrelated repo,
# in a tmux window of its own, used to reach the bottom of layout_subagents with nothing to
# place and still have its pane resized to the fleet's proportions — and, via the dispatcher,
# `renumber-windows` switched on GLOBALLY, reaching every session on the server.
VHOME="$T/vanilla-home"; mkdir -p "$VHOME/.claude/running-agents"
van_out="$(HOME="$VHOME" FLEET_TMUX_SOCKET="$SOCKET" FLEET_LAYOUT_LIB=1 bash -c "
    source '$SCRIPT'
    TMUX_PANE='%901'; fleet_tmux_ok() { return 0; }
    DRY_RUN=1; layout_subagents" 2>&1)"
case "$van_out" in
  *"not a fleet agent"*) pass=$((pass+1)); echo "  PASS: a non-fleet session is left alone" ;;
  *) fail=$((fail+1)); printf '  FAIL: a non-fleet session is left alone\n        got: [%s]\n' "$van_out" ;;
esac
case "$van_out" in
  *resize-pane*|*join-pane*|*"set-option"*) fail=$((fail+1)); printf '  FAIL: …and no tmux mutation is proposed\n        got: [%s]\n' "$van_out" ;;
  *) pass=$((pass+1)); echo "  PASS: …and no tmux mutation is proposed" ;;
esac

# The global -g options belong to the window-MOVING verbs only, never to the hook-driven one.
eq "subagents proposes no global tmux option" "0" \
   "$(HOME="$VHOME" run subagents --dry-run 2>&1 | grep -c ' -g ')"
ok "…while a layout verb still sets them" \
   '[ "$(run single --dry-run 2>&1 | grep -c " -g ")" -ge 2 ]'

# A pane id that is not live is a caller error, not something to guess at: splitting "the
# current window" would build the column in whatever window happened to be active.
lib "ensure_lead_window '%99999'" >/dev/null 2>&1
eq "a dead pane id is refused, not guessed at" "2" "$?"
lib "ensure_lead_window ''" >/dev/null 2>&1
eq "an empty pane id is refused too" "2" "$?"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
