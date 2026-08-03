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
echo "cmd_down — a harness worktree in the lanes dir is NOT a target"

# THE LANES DIR IS SHARED WITH THE HARNESS, which drops an `agent-<hex>` checkout there for
# every isolation:"worktree" subagent — a live reviewer's tree, mid-review. `down` sweeping it
# would kill an agent that occupies no lane and is nobody's to stop, and `status` would print it
# as a lane with a port block parsed off its hex (one really did resolve to lane 0 and claim
# team-lead's 8080/3000).
#
# The witness is a REAL process, and the assertion is that it SURVIVES — same shape as every
# other refusal in this file, because a filter that silently does nothing looks identical to one
# that works until you leave something alive for it to wrongly kill.
mklane agent-deadbeefcafe0001
harness="$(spawn)"; occupy agent-deadbeefcafe0001 "$harness"; idle agent-deadbeefcafe0001

out="$(lib 'cmd_down --force')"
ok    "the harness worktree's process SURVIVED --force"  "alive $harness"
hasnt "…and it is never even named in the report"        "$out" "agent-deadbeefcafe0001"
vacate agent-deadbeefcafe0001

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
echo "cmd_boot — the lead comes back to its own conversation"

# THE REGRESSION, from a live cycle. `boot` never passed --continue, so every /shutdown was
# followed by a lead that came up knowing nothing of the work it had just been doing. The
# symptom reads as a worktree problem ("new lane, nothing to resume") and is not one: the
# transcript was sitting in ~/.claude/projects the whole time, unasked for.
: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $NOTMUX cmd_boot" >/dev/null 2>&1
hasnt "boot: a lane with no transcript starts clean" "$(cat "$TMUXLOG")" "--continue"

# ...and that guard is load-bearing, not decoration: `claude --continue` with nothing to
# continue EXITS on the spot, which would leave a first boot into a fresh lane staring at an
# empty pane. The negative case above is the only thing standing between here and that.
PROJD="$FHOME/.claude/projects/$(printf '%s' "$LEADP" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$PROJD"; : > "$PROJD/session.jsonl"
: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $NOTMUX cmd_boot" >/dev/null 2>&1
has "boot: a lane with a transcript resumes it" "$(cat "$TMUXLOG")" "--name team-lead --continue"

echo
echo "cmd_boot — --fresh opts out of resuming"

# A context worth abandoning is a real state — wedged, poisoned, or just a new line of work.
# Without the flag the only way out was deleting a transcript by hand.
: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $NOTMUX cmd_boot --fresh" >/dev/null 2>&1
log="$(cat "$TMUXLOG")"
hasnt "boot --fresh: the transcript is ignored"  "$log" "--continue"
has   "boot --fresh: …but the lead still launches" "$log" "send-keys -t %99 -l claude"

err="$(bootlib "$EMPTY" 'cmd_boot --fresh --bogus' 2>&1 >/dev/null)"
has "boot: --fresh does not swallow the next flag" "$err" "unknown flag: --bogus"

echo
echo "cmd_boot — --debug is passed through to the harness"

# The one way to see WHY the harness declines something it was configured to do. Passed
# through rather than interpreted: what it enables is the harness's business.
: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $NOTMUX cmd_boot --debug" >/dev/null 2>&1
has "boot --debug: the flag reaches the launch line" "$(cat "$TMUXLOG")" "--debug"

: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $NOTMUX cmd_boot" >/dev/null 2>&1
hasnt "boot: …and only when asked for" "$(cat "$TMUXLOG")" "--debug"

err="$(bootlib "$EMPTY" 'cmd_boot --debug --bogus' 2>&1 >/dev/null)"
has "boot: --debug does not swallow the next flag" "$err" "unknown flag: --bogus"

echo
echo "cmd_boot — --session picks the fleet's tmux session, and creates it if absent"

# boot used to `die` when the session was missing, which made it unusable as the FIRST thing
# you run: a fresh terminal, or any session name that is not `main`, was a hard stop. Creating
# it is what lets one fleet own one terminal window — `--session goals-b` on a second monitor
# instead of two fleets interleaving windows in `main`.
#
# NOSESSION is the stub that distinguishes the two paths: `has-session` FAILS, everything else
# behaves as before. The suite's default stub returns 0 for every subcommand, so under it
# has-session always succeeds — which is why the other 70-odd cases never see this branch.
NOSESSION='tmux() {
  echo "tmux $*" >> "$TMUXLOG"
  case "$*" in
    has-session*)         return 1 ;;
    new-window*)          echo "%99" ;;
    *"#{session_name}"*)  echo "main" ;;
    display-message*)     echo "%1"  ;;
  esac
  return 0
}'

: > "$TMUXLOG"
bootlib "$BOOTL" "$NOSESSION; $NOTMUX cmd_boot --session goals-b" >/dev/null 2>&1
log="$(cat "$TMUXLOG")"
has "boot --session: the named session is the one probed"   "$log" "has-session -t goals-b"
has "boot --session: an absent session is created detached" "$log" "new-session -d -s goals-b"

# Idempotent: a session that exists is probed and left alone. Without this, booting into the
# session you are already sitting in would try to create it every time.
: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $NOTMUX cmd_boot --session goals-b" >/dev/null 2>&1
hasnt "boot --session: an existing session is NOT re-created" "$(cat "$TMUXLOG")" "new-session"

# The default is unchanged when the flag is absent — this adds a choice, it does not move one.
: > "$TMUXLOG"
bootlib "$BOOTL" "$NOSESSION; $NOTMUX cmd_boot" >/dev/null 2>&1
has "boot: without --session the default session is used" "$(cat "$TMUXLOG")" "has-session -t main"

err="$(bootlib "$EMPTY" 'cmd_boot --session' 2>&1 >/dev/null)"
has "boot: --session with no name is refused" "$err" "--session needs a name"

echo
echo "cmd_boot — the lead's window is built before the lead starts"

# The lead's window is not a cell, so build_cell never gave it a companion column and it came
# up as one bare pane. fleet-layout owns pane topology, so boot ASKS rather than splitting here.
#
# The stub logs into $TMUXLOG, the same file the tmux stub writes — one interleaved transcript
# is what makes the ORDER assertion below able to fail. Two logs concatenated would put
# lead-window first no matter what the code did.
FLSTUB="$TMP/fleet-layout-stub.sh"
cat > "$FLSTUB" <<'STUB'
#!/bin/bash
echo "fleet-layout $*" >> "$TMUXLOG"
STUB
chmod +x "$FLSTUB"
export WORKFLOW_FLEET_LAYOUT_SH="$FLSTUB"
: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $NOTMUX cmd_boot" >/dev/null 2>&1
log="$(cat "$TMUXLOG")"
has "boot: fleet-layout is asked to build the lead's window" "$log" "fleet-layout lead-window --pane=%99"
# The LANE, explicitly. boot reuses a pane whose shell is wherever it was left and prefixes the
# `cd` to the LAUNCH command, which runs afterwards — so a companion that reads the pane's own
# cwd opens in $HOME. Observed live: the lead's companion sat in /Users/john, not the lane.
has "boot: …with the lane pinned, not the pane's transient cwd" "$log" "--cwd=$LEADP"

# ORDER IS THE POINT: the split resizes the pane, and a TUI started at its final size never
# reflows. Both calls succeed in either order, so only position can catch a regression.
ok "boot: …before the launch keystrokes, not after" \
   '[ "$(printf %s "$log" | grep -n "fleet-layout lead-window" | cut -d: -f1)" -lt "$(printf %s "$log" | grep -n "send-keys -t %99 -l claude" | cut -d: -f1)" ]'

# A machine without fleet-layout gets a bare-pane lead — which is what every boot produced
# before this existed — and must still boot.
export WORKFLOW_FLEET_LAYOUT_SH="$TMP/does-not-exist.sh"
: > "$TMUXLOG"
bootlib "$BOOTL" "$TSTUB; $NOTMUX cmd_boot" >/dev/null 2>&1
has "boot: a missing fleet-layout never blocks the lead" "$(cat "$TMUXLOG")" "send-keys -t %99 -l claude"
unset WORKFLOW_FLEET_LAYOUT_SH

echo
echo "alive_in — the function every kill is gated on, unstubbed"

# ZERO COVERAGE until now: both lib() and bootlib() blanket-override alive_in, so replacing its
# whole body with `return 1` left the suite 67/0 — while `down` gates every kill on it and
# `boot` gates its double-boot refusal on it. Here it runs as shipped, against a real process
# this suite owns, with only fleet_agent_in_dir (the _fleet.sh primitive that reaches into the
# process table) stubbed.
mkdir -p "$LANES/av-lane"
AVP="$(cd "$LANES/av-lane" && pwd -P)"

# The contract is a PHYSICAL path: lane_path is logical, and on macOS /var symlinks to
# /private/var, so a lane resolved logically matches no process and every lookup silently
# reports an empty lane.
eq "resolves the lane to its physical path before matching" "$AVP" \
   "$(env TEAM_BOOT_LIB=1 HOME="$FHOME" WORKFLOW_LANES_DIR="$LANES" bash -c '
        . "'"$SCRIPT"'"; fleet_agent_in_dir() { printf %s "$1"; }; alive_in av-lane')"

eq "a lane with nobody in it returns non-zero and prints nothing" "1:" \
   "$(env TEAM_BOOT_LIB=1 HOME="$FHOME" WORKFLOW_LANES_DIR="$LANES" bash -c '
        . "'"$SCRIPT"'"; fleet_agent_in_dir() { return 1; }
        out="$(alive_in av-lane)"; printf "%s:%s" "$?" "$out"')"

eq "a lane that does not exist is not-running, never an error" "1" \
   "$(env TEAM_BOOT_LIB=1 HOME="$FHOME" WORKFLOW_LANES_DIR="$LANES" bash -c '
        . "'"$SCRIPT"'"; fleet_agent_in_dir() { printf 999; }; alive_in no-such-lane >/dev/null 2>&1; echo $?')"

eq "the pid comes back verbatim, so down kills what alive_in named" "4242" \
   "$(env TEAM_BOOT_LIB=1 HOME="$FHOME" WORKFLOW_LANES_DIR="$LANES" bash -c '
        . "'"$SCRIPT"'"; fleet_agent_in_dir() { printf 4242; }; alive_in av-lane')"

echo
echo "LANES_DIR — derived from the repo, never a hardcoded project"

# This file ships in dotfiles and runs in every repo. It used to fall back to one product's
# worktree directory by name, so any OTHER project's fleet silently resolved to that product's
# lanes — a path that exists on this machine, so nothing ever complained.
SCRATCH="$TMP/scratchrepo"; mkdir -p "$SCRATCH/myproj"
# GIT_DIR leaks in from the hook environment and would point every scratch git call at the real
# repo. Unset it for the whole block.
( unset GIT_DIR GIT_WORK_TREE; cd "$SCRATCH/myproj" && git init -q . ) >/dev/null 2>&1
PHOME="$TMP/ptrhome"; mkdir -p "$PHOME/.claude"

lanes_from() {  # <cwd>
  ( unset GIT_DIR GIT_WORK_TREE WORKFLOW_LANES_DIR; cd "$1" 2>/dev/null || return 1
    env HOME="$PHOME" TEAM_BOOT_LIB=1 bash -c '. "'"$SCRIPT"'"; printf "%s" "$LANES_DIR"' )
}

# THE DERIVATION MUST NAME WHERE LANES ACTUALLY LIVE. This assertion used to pin the sibling
# <parent>/<basename>-worktrees and kept passing after the lanes moved into the main clone's
# .claude/worktrees/ — a test that could not fail for the real defect. The cost was not
# cosmetic: lane-guard.sh reads a non-existent lanes dir as "I cannot say where this agent
# belongs" and exits 0, so a stale derivation turned the guard silently OFF for every agent on
# any machine without ~/.claude/fleet.env.
eq "derives <main-clone>/.claude/worktrees" "$SCRATCH/myproj/.claude/worktrees" \
   "$(lanes_from "$SCRATCH/myproj")"

# The pointer is what lets `boot` run from $HOME, which is how it is actually invoked — the
# hardcoded path used to cover that up. Written on a successful resolve, read when there is no
# repo to derive from.
mkdir -p "$SCRATCH/myproj/.claude/worktrees"
( unset GIT_DIR GIT_WORK_TREE WORKFLOW_LANES_DIR; cd "$SCRATCH/myproj" && \
  env HOME="$PHOME" bash "$SCRIPT" status ) >/dev/null 2>&1
eq "…and caches it machine-locally, outside dotfiles" "$SCRATCH/myproj/.claude/worktrees" \
   "$(cat "$PHOME/.claude/fleet-lanes-dir" 2>/dev/null)"
eq "the cache answers when there is no repo to derive from" "$SCRATCH/myproj/.claude/worktrees" \
   "$(lanes_from "$TMP")"

# THE FAILURE THAT MATTERS: an empty LANES_DIR globs "$LANES_DIR"/*/ as /*/ — every top-level
# directory on the machine — which `status` would print as a fleet and `down` would walk.
rm -f "$PHOME/.claude/fleet-lanes-dir"
out="$( ( unset GIT_DIR GIT_WORK_TREE WORKFLOW_LANES_DIR; cd "$TMP" && \
          env HOME="$PHOME" bash "$SCRIPT" status ) 2>&1 )"
has   "unresolvable refuses outright"        "$out" "cannot resolve the lanes directory"
hasnt "…and never enumerates the filesystem" "$out" "Applications"

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
echo "fleet_not_a_lane — the duplicated copies must not drift"

# THE HOUSE CONVENTION IS A CANONICAL DEFINITION PLUS PER-SCRIPT FALLBACKS, and the convention
# has no guard. `fleet_not_a_lane` lives in _fleet.sh and is repeated as a `command -v … ||`
# fallback in team-boot.sh, fleet-status.sh and (in the goals-onchain clone) lanes.sh, so a
# machine with no _fleet.sh still filters. The failure mode is silent and asymmetric: edit the
# canonical copy alone and the fallbacks keep the OLD rule, so the same directory is a lane to
# one script and not to another — and only on the machines using the fallback, which are by
# definition the ones nobody is testing on.
#
# Same discipline as the review-lessons entry on config values only some readers can see: when
# a value is duplicated on purpose, the test is what makes "on purpose" survive an edit.
#
# The predicate is compared by BEHAVIOUR, not by string. A textual comparison would redden on
# reformatting and, worse, would pass two copies that differ only in a `case` arm's order.
# Scoped to the three DOTFILES sites. The fourth copy lives in a consuming project's lanes.sh,
# in a different repo that may be on any branch — reaching across for it made this suite's
# result depend on what a sibling checkout happened to have checked out. That copy is asserted
# against the canonical one by that project's own suite, where the dependency is local.
DOTS="$(cd "$here" && pwd)"
# Brace-depth extraction, because the canonical definition is multi-line while the fallbacks are
# one-liners. A `sed` one-liner captured only `fleet_not_a_lane() {` from _fleet.sh and silently
# probed an empty function — which reported the sites as AGREEING, the exact false green this
# test exists to prevent.
extract_fnl() {
  awk '/fleet_not_a_lane\(\) \{/ && !f { f = 1 }
       f { print; d += gsub(/\{/, "{") - gsub(/\}/, "}"); if (d <= 0) exit }' "$1"
}
probe_sites() {
  for f in "$DOTS/_fleet.sh" "$DOTS/team-boot.sh" "$DOTS/fleet-status.sh"; do
    [ -r "$f" ] || continue
    def="$(extract_fnl "$f")"
    [ -n "$def" ] || continue
    printf '%s:' "$(basename "$f")"
    for probe in agent-deadbeef .hidden '' feature-3 team-lead ui-2 agentic-2; do
      printf '%s' "$(bash -c "$def"$'\n'"fleet_not_a_lane '$probe' && echo 1 || echo 0")"
    done
    printf '\n'
  done
}
# A BEHAVIOURAL COMPARISON ALONE IS BLIND TO AN ADDED `case` ARM, which is the likeliest future
# edit ("also filter worktree-*"). The probe set below is fixed, so drift OUTSIDE it produces
# identical answers from copies that genuinely disagree — demonstrated by adding `scratch-*` to
# the canonical only: `scratch-9` classified differently in each copy and the agreement
# assertion still read "all agree".
#
# So both comparisons run. Textual alone was rejected because it reddens on reformatting and
# passes two copies differing only in arm ORDER — but "insufficient" argues for adding it
# alongside, not for dropping it. Normalised to the pattern list itself, so indentation, the
# `command -v` guard prefix and comment placement cannot redden it.
norm_arms() {  # <file> — the case-arm patterns, whitespace-normalised, order preserved
  extract_fnl "$1" | tr '\n' ' ' | sed -e 's/.*in *//' -e 's/esac.*//' \
                                       -e 's/) *return [01] *;;/|/g' -e 's/[[:space:]]\{1,\}//g'
}
ARMS_CANON="$(norm_arms "$DOTS/_fleet.sh")"
eq "the fallbacks' case arms are textually identical to the canonical (catches an ADDED arm)" \
   "$ARMS_CANON|$ARMS_CANON" \
   "$(norm_arms "$DOTS/team-boot.sh")|$(norm_arms "$DOTS/fleet-status.sh")"
ok "…and that comparison is not vacuously empty" '[ -n "$ARMS_CANON" ]'

SITES="$(probe_sites)"
eq "all three dotfiles sites are present" "3" "$(printf '%s\n' "$SITES" | grep -c ':')"
eq "…and answer identically for every probe" "1" \
   "$(printf '%s\n' "$SITES" | sed 's/^[^:]*://' | sort -u | grep -c .)"
# Pin the ANSWER too, so three copies agreeing on a WRONG rule cannot pass. `agentic-2` is the
# probe that matters: `agent-*` must not swallow a real lane whose name merely starts that way.
eq "…on the right answer (agent-*/dot/empty are not lanes; agentic-2 is)" "1110000" \
   "$(printf '%s\n' "$SITES" | head -1 | cut -d: -f2)"

echo
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
