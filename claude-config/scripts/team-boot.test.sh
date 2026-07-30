#!/bin/bash
# Tests for team-boot.sh — specifically `down`, the fleet's only destructive verb.
#
# WHY THIS FILE EXISTS. `down` used to live in fleet-layout.sh with 49 assertions covering
# exactly its refusals ("self's pane SURVIVED", "the skip-marked pane SURVIVED", "pane still
# alive under --force"). When the verb moved here those tests were deleted and never migrated,
# so for a while the one command that kills agents had no behavioural coverage at all — while
# its guards were being rewritten. This file is that debt paid.
#
# THE SHAPE OF THE RISK. Every bug that matters here is a guard failing OPEN: a check that was
# supposed to refuse, and killed instead. A happy-path test cannot see those — it only proves
# the kill works, which was never in doubt. So the assertions below are overwhelmingly
# NEGATIVE: a witness process is left running and the test asserts it is STILL ALIVE. Each one
# is paired with a positive case proving the same code path can kill when it should, because an
# `exit 0` stub would otherwise pass every refusal test in the file.
#
# SCOPE. Sources team-boot.sh in TEAM_BOOT_LIB mode against a scratch LANES_DIR and a scratch
# HOME, and stubs `alive_in` — the one function that reaches into the real process table. Real
# `sleep` processes stand in for agents, so kill/verify paths run for real against pids this
# suite owns. It never touches tmux, never signals anything it did not spawn, and never calls
# boot.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$here/team-boot.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: team-boot.sh not found at $SCRIPT"; exit 1; }

pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
       else fail=$((fail+1)); printf '  FAIL %s\n        expected: [%s]\n        actual:   [%s]\n' "$1" "$2" "$3"; fi; }
ok() { if eval "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
       else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi; }
has() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;;
                     *) fail=$((fail+1)); printf '  FAIL %s\n        output lacked: [%s]\n' "$1" "$3" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail=$((fail+1)); printf '  FAIL %s\n        output contained: [%s]\n' "$1" "$3" ;;
                       *) pass=$((pass+1)); printf '  ok   %s\n' "$1" ;; esac; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
SPAWNED=""
cleanup() { for p in $SPAWNED; do kill -9 "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

LANES="$TMP/lanes";  mkdir -p "$LANES"
FHOME="$TMP/home";   mkdir -p "$FHOME/.claude/agent-busy"
PIDMAP="$TMP/pids";  mkdir -p "$PIDMAP"

# A lane is just a directory here — cmd_down enumerates "$LANES_DIR"/*/ and asks alive_in.
mklane() { mkdir -p "$LANES/$1"; }

# An "agent": a real, killable process. `sleep` is enough — cmd_down only ever kills a pid and
# then watches it. immortal() ignores SIGTERM, standing in for an agent mid-tool-call that does
# not unwind, which is the case down_verify_dead exists for.
#
# The redirects are load-bearing, not tidiness: a background child inherits the stdout of the
# command substitution that spawned it, so `p="$(spawn)"` would block until the *sleep* exited
# — 300 seconds — rather than until spawn returned. Detaching its streams is what lets the
# substitution close.
spawn()    { sleep 300 >/dev/null 2>&1 </dev/null & local p=$!; SPAWNED="$SPAWNED $p"; printf '%s' "$p"; }
#
# immortal() must not return until its trap is actually installed. Signalling a bash that has
# not reached `trap` yet gets the DEFAULT action and the process dies — which showed up as the
# survivor tests failing while the identical case inside cmd_down passed, purely because
# cmd_down does enough work before killing to lose the race. Readiness is signalled by a file,
# not slept on.
immortal() {
  local ready="$TMP/ready.$$.$RANDOM"
  bash -c 'trap "" TERM; : > "$1"; sleep 300' _ "$ready" >/dev/null 2>&1 </dev/null &
  local p=$!; SPAWNED="$SPAWNED $p"
  local i=0; while [ ! -e "$ready" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done
  printf '%s' "$p"
}
occupy()   { printf '%s' "$2" > "$PIDMAP/$1"; }          # lane <- pid
vacate()   { rm -f "$PIDMAP/$1"; }
busy()     { : > "$FHOME/.claude/agent-busy/$1"; }
idle()     { rm -f "$FHOME/.claude/agent-busy/$1"; }
alive()    { kill -0 "$1" 2>/dev/null; }

# Source in library mode, then override alive_in with a stub reading $PIDMAP. Overriding AFTER
# the source is what makes the guards drivable without a real fleet; the stub is the only thing
# faked, so kill / verify / flag parsing all run as shipped.
lib() {  # lib <shell-code>
  env TEAM_BOOT_LIB=1 HOME="$FHOME" WORKFLOW_LANES_DIR="$LANES" DOWN_VERIFY_TRIES=4 \
      PIDMAP="$PIDMAP" bash -c '
    . "'"$SCRIPT"'"
    alive_in() { [ -s "$PIDMAP/$1" ] && cat "$PIDMAP/$1" || return 1; }
    '"$*"
}

echo
echo "down_busy — fail-closed: anything indeterminate counts as BUSY"

marker_dir="$FHOME/.claude/agent-busy"
eq "marker present → busy"            "busy"  "$(busy a;  lib 'down_busy a && echo busy || echo idle')"
eq "marker absent, dir readable → idle" "idle" "$(idle a;  lib 'down_busy a && echo busy || echo idle')"

# The whole point of the rewrite: the plain [ -f ] this replaced failed OPEN on an unreadable
# marker dir — it read a working agent as idle in exactly the case it knew least about.
chmod 000 "$marker_dir"
eq "dir unreadable → UNKNOWN → busy"  "busy"  "$(lib 'down_busy a && echo busy || echo idle')"
chmod 755 "$marker_dir"

mv "$marker_dir" "$TMP/stash-markers"
eq "dir absent (nobody ever marked) → idle" "idle" "$(lib 'down_busy a && echo busy || echo idle')"
mv "$TMP/stash-markers" "$marker_dir"

echo
echo "down_verify_dead — the 'stopped' claim is earned by observation, not by kill's exit"

p="$(spawn)"; kill -9 "$p"; sleep 0.3
eq "a genuinely dead pid verifies dead"   "dead"  "$(lib "down_verify_dead $p && echo dead || echo alive")"

imm="$(immortal)"; kill -TERM "$imm" 2>/dev/null
eq "a pid that survives SIGTERM is NOT claimed dead" "alive" "$(lib "down_verify_dead $imm && echo dead || echo alive")"
ok "…and the survivor really did survive (so the assertion above meant something)" "alive $imm"

echo
echo "cmd_down — SELF IS NEVER A TARGET"

# The lead occupies lane 0. An unguarded sweep over "$LANES_DIR"/*/ kills the process running
# the script, taking itself out partway through and leaving the rest of the fleet up.
mklane team-lead; mklane feature-1
lead="$(spawn)";  occupy team-lead "$lead"
mate="$(spawn)";  occupy feature-1 "$mate"
idle team-lead;   idle feature-1

out="$(lib 'cmd_down')"
has   "self is reported as skipped, by name"  "$out" "SKIPPED (that is me"
ok    "the LEAD's process survived"           "alive $lead"
ok    "…while the teammate was actually killed (the sweep did run)" "! alive $mate"

echo
echo "cmd_down — BUSY is skipped, and --force is the only override"

mklane feature-2
b1="$(spawn)"; occupy feature-2 "$b1"; busy feature-2
vacate feature-1; vacate team-lead        # isolate: only feature-2 in the sweep

out="$(lib 'cmd_down')"
has "busy agent is reported skipped" "$out" "BUSY"
ok  "…and its process SURVIVED"      "alive $b1"

out="$(lib 'cmd_down --force')"
ok  "--force kills the same busy agent" "! alive $b1"

echo
echo "cmd_down — --dry-run kills NOTHING"

b2="$(spawn)"; occupy feature-2 "$b2"; idle feature-2
out="$(lib 'cmd_down --dry-run')"
has   "dry-run names what it would stop"  "$out" "would stop"
hasnt "dry-run does not claim it stopped" "$out" "stopped (pid"
ok    "dry-run left the process alive"    "alive $b2"

# Paired positive: the same lane, same pid, without --dry-run — proving the dry-run assertion
# above is not passing because the sweep silently skipped this lane for some other reason.
lib 'cmd_down' >/dev/null
ok    "…and the identical run WITHOUT --dry-run kills it" "! alive $b2"

echo
echo "cmd_down — reporting and exit status"

vacate feature-2
out="$(lib 'cmd_down')"
has "an unoccupied lane is reported, not silently passed" "$out" "not running"

b3="$(spawn)"; occupy feature-2 "$b3"; idle feature-2
lib 'cmd_down' >/dev/null; rc=$?
eq "a clean sweep exits 0" "0" "$rc"

im2="$(immortal)"; occupy feature-2 "$im2"; idle feature-2
out="$(lib 'cmd_down')"; rc=$?
eq    "a survivor makes the sweep exit non-zero" "1" "$rc"
has   "…and it refuses to claim the survivor is down" "$out" "NOT claiming it is down"
hasnt "…and never prints the success line for it"     "$out" "stopped (pid $im2)"
kill -9 "$im2" 2>/dev/null

echo
echo "cmd_down — flag parsing"

# HERMETIC BY NECESSITY. The first version of this section asserted only on the exit code, and
# a mutant that ignored unknown flags outright SURVIVED it: a stale dead pid left in the map by
# the previous case made `kill` fail, so the sweep exited 1 for an unrelated reason and the
# assertion passed by accident. Clear every lane first, then occupy exactly one with a LIVE
# process, and assert on the message — an exit code alone cannot distinguish "refused" from
# "tried and failed".
for l in "$PIDMAP"/*; do [ -e "$l" ] && rm -f "$l"; done
b4="$(spawn)"; occupy feature-2 "$b4"; idle feature-2

err="$(lib 'cmd_down --bogus' 2>&1 >/dev/null)"; rc=$?
eq  "an unknown flag is fatal, not ignored"        "1" "$rc"
has "…and says which flag it rejected"             "$err" "unknown flag: --bogus"
ok  "…and refused BEFORE killing anything"         "alive $b4"

# The case this really guards: a typo'd --dry-run must not take the fleet down for real.
err="$(lib 'cmd_down --dryrun' 2>&1 >/dev/null)"
has "a typo'd --dry-run is rejected, not ignored"  "$err" "unknown flag: --dryrun"
ok  "…and kills nothing"                           "alive $b4"

# Paired positive: the same lane, same live pid, with a VALID flag — so the three refusals
# above cannot be passing merely because this lane was unreachable.
lib 'cmd_down --force' >/dev/null 2>&1
ok  "…while a valid flag on the same lane does kill it" "! alive $b4"
vacate feature-2

echo
echo "cmd_boot — flags are validated before anything is launched"

# Found by mutation: `cmd_down` and `cmd_boot` carry BYTE-IDENTICAL flag-default lines, so a
# string-replace mutant aimed at down silently landed on boot instead — and survived, because
# boot had no coverage at all. That accident is the only reason this section exists.
#
# boot creates a tmux window and types a `claude` command into it, so every case here stubs
# tmux to a recorder: a regression that lets a bad flag through must be a failed assertion,
# never a real window. EMPTY points at a lane dir with no lane 0, so an ACCEPTED flag stops at
# the lane check — proving acceptance without booting anything.
EMPTY="$TMP/nolanes"; mkdir -p "$EMPTY"
TMUXLOG="$TMP/tmux.log"
bootlib() {  # bootlib <lanes-dir> <shell-code>
  local ld="$1"; shift
  env TEAM_BOOT_LIB=1 HOME="$FHOME" WORKFLOW_LANES_DIR="$ld" PIDMAP="$PIDMAP" \
      TMUXLOG="$TMUXLOG" bash -c '
    . "'"$SCRIPT"'"
    alive_in() { return 1; }
    tmux() { echo "tmux $*" >> "$TMUXLOG"; return 0; }
    '"$*"
}

: > "$TMUXLOG"
err="$(bootlib "$EMPTY" 'cmd_boot --bogus' 2>&1 >/dev/null)"; rc=$?
eq  "boot: an unknown flag is fatal"          "1" "$rc"
has "boot: …and names the flag"               "$err" "unknown flag: --bogus"
eq  "boot: …and nothing was sent to tmux"     "" "$(cat "$TMUXLOG")"

# Acceptance, shown by WHICH error it reaches: past parsing, into the lane check.
err="$(bootlib "$EMPTY" 'cmd_boot --with-team' 2>&1 >/dev/null)"
has   "boot: --with-team is accepted"                    "$err" "no lead lane"
hasnt "boot: …not mistaken for an unknown flag"          "$err" "unknown flag"

err="$(bootlib "$EMPTY" 'cmd_boot --with-team 3' 2>&1 >/dev/null)"
has   "boot: --with-team takes an optional count"        "$err" "no lead lane"
hasnt "boot: …and the count is not read as a flag"       "$err" "unknown flag"

# The subtle one: --with-team's optional argument must not swallow a following FLAG. If the
# `-*` guard goes, `--bogus` becomes the team size and is never validated.
err="$(bootlib "$EMPTY" 'cmd_boot --with-team --bogus' 2>&1 >/dev/null)"
has "boot: an optional count never swallows the next flag" "$err" "unknown flag: --bogus"

eq "boot: no tmux call escaped ANY rejected invocation" "" "$(cat "$TMUXLOG")"

echo
echo "cmd_boot — the lead is launched into a PANE ID, never a window name"

# THE REGRESSION, from a live boot. /shutdown leaves the outgoing lead's window alive at a
# shell still named team-lead, so the next boot makes a SECOND window by that name. boot then
# resolved its pane as "$SESSION:$LEAD_LANE" — a name target, which tmux answers with the
# lowest-index match, the stale window. claude was typed there (cwd $HOME) while the window
# just created sat empty, and the lead came up outside its own worktree.
#
# The stub is that fleet: new-window hands back %99, any name lookup still answers %1. Code
# that goes back to resolving by name gets %1 and fails here.
BOOTL="$TMP/bootlanes"; mkdir -p "$BOOTL/team-lead" "$BOOTL/feature-1"
LEADP="$(cd "$BOOTL/team-lead" && pwd -P)"

# $* rather than $1: the session probe is `display-message -p -t <pane> #{session_name}`, and
# only the FORMAT distinguishes it from a pane-id lookup.
TSTUB='tmux() {
  echo "tmux $*" >> "$TMUXLOG"
  case "$*" in
    new-window*)          echo "%99" ;;
    *"#{session_name}"*)  echo "main" ;;
    display-message*)     echo "%1"  ;;
  esac
  return 0
}'
# TMUX/TMUX_PANE LEAK IN from the terminal running this suite — bootlib uses `env`, which adds
# to the environment rather than clearing it. Left alone, every case below silently takes the
# reuse path and the new-window assertions test nothing.
NOTMUX='unset TMUX TMUX_PANE;'
INFLEET='TMUX=/fake/sock TMUX_PANE=%7;'

: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $NOTMUX cmd_boot" >/dev/null 2>&1
log="$(cat "$TMUXLOG")"
has   "boot: the pane id is asked of new-window itself"        "$log" "-P -F #{pane_id}"
has   "boot: …and the lead is typed into exactly that pane"    "$log" "send-keys -t %99 -l claude"
hasnt "boot: …never into one resolved by window name"          "$log" "-t %1"
has   "boot: the window opens in the lane, not where boot ran" "$log" "-c $LEADP"

# Reuse: no second team-lead window, and the adopted pane is moved to the lane first — a pane
# we did not create keeps its shell's cwd, and cwd is how every fleet lookup identifies an agent.
: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $INFLEET cmd_boot" >/dev/null 2>&1
log="$(cat "$TMUXLOG")"
hasnt "boot from the fleet session: no second team-lead window" "$log" "new-window"
has   "boot from the fleet session: the caller's pane is used"  "$log" "send-keys -t %7 -l cd $LEADP"
has   "boot from the fleet session: …and it is renamed"         "$log" "rename-window -t %7 team-lead"

# Reuse is scoped to the FLEET session — a pane in some unrelated session must not be hijacked.
: > "$TMUXLOG"
bootlib "$BOOTL" "${TSTUB/main/elsewhere}; $INFLEET cmd_boot" >/dev/null 2>&1
log="$(cat "$TMUXLOG")"
has "boot from a pane outside the fleet session: a window is created" "$log" "new-window"

# --with-team must NOT reuse: _boot_request_team polls in the foreground for the lead, and a
# lead launched into this pane cannot start until boot exits. Reuse there is a deadlock.
: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; _boot_request_team() { :; }; $INFLEET cmd_boot --with-team" >/dev/null 2>&1
log="$(cat "$TMUXLOG")"
has "boot --with-team: takes its own window even inside the fleet session" "$log" "new-window"
has "boot --with-team: …so the lead is typed there, not into the caller's" "$log" "send-keys -t %99 -l claude"

echo
echo "resolve_lanes_sh — project content is never a sibling of this script"

# team-boot.sh lives in dotfiles and travels; lanes.sh is one product's. Resolving it as
# "$(dirname $0)/lanes.sh" silently degraded `status` the moment this file left the repo.
mkdir -p "$TMP/proj/.claude/scripts"; : > "$TMP/proj/.claude/scripts/lanes.sh"
mkdir -p "$LANES/team-lead/.claude/scripts"; : > "$LANES/team-lead/.claude/scripts/lanes.sh"

eq "WORKFLOW_LANES_SH wins outright" "$TMP/proj/.claude/scripts/lanes.sh" \
   "$(env WORKFLOW_LANES_SH="$TMP/proj/.claude/scripts/lanes.sh" TEAM_BOOT_LIB=1 HOME="$FHOME" \
        WORKFLOW_LANES_DIR="$LANES" bash -c ". '$SCRIPT'; resolve_lanes_sh")"

eq "CLAUDE_PROJECT_DIR is next" "$TMP/proj/.claude/scripts/lanes.sh" \
   "$(env -u WORKFLOW_LANES_SH CLAUDE_PROJECT_DIR="$TMP/proj" TEAM_BOOT_LIB=1 HOME="$FHOME" \
        WORKFLOW_LANES_DIR="$LANES" bash -c "cd '$TMP'; . '$SCRIPT'; resolve_lanes_sh")"

eq "falls back to lane 0's copy when outside any repo" "$LANES/team-lead/.claude/scripts/lanes.sh" \
   "$(env -u WORKFLOW_LANES_SH -u CLAUDE_PROJECT_DIR TEAM_BOOT_LIB=1 HOME="$FHOME" \
        WORKFLOW_LANES_DIR="$LANES" bash -c "cd /; . '$SCRIPT'; resolve_lanes_sh")"

# An empty CLAUDE_PROJECT_DIR must not resolve to the absolute path /.claude/scripts/lanes.sh.
ok "an empty CLAUDE_PROJECT_DIR is skipped, not treated as /" \
   "[ \"\$(env -u WORKFLOW_LANES_SH CLAUDE_PROJECT_DIR= TEAM_BOOT_LIB=1 HOME='$FHOME' WORKFLOW_LANES_DIR='$TMP/empty' bash -c \"cd /; . '$SCRIPT'; resolve_lanes_sh\" 2>/dev/null)\" != '/.claude/scripts/lanes.sh' ]"

echo
echo "library mode — sourcing must not run a verb"

out="$(env TEAM_BOOT_LIB=1 HOME="$FHOME" WORKFLOW_LANES_DIR="$LANES" bash -c ". '$SCRIPT'" 2>&1)"
hasnt "sourcing does not fall through to status" "$out" "team configs on disk"
eq    "sourcing produces no output at all" "" "$out"

echo
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
