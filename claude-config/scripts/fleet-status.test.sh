#!/bin/bash
# Self-contained tests for fleet-status.sh + _agent_facts.py.
# Run: bash ~/.claude/scripts/fleet-status.test.sh
#
# Hermetic: a throwaway $HOME (its own registry, busy markers and transcript tree) and
# fixture lanes in a temp dir passed via --lanes-dir, so nothing here reads or writes the
# live fleet.
#
# What it locks in — each is a way the view could lie, which is worse than not having it:
#   - the three live states are distinguished by MARKER AGE, not by fleet_busy's 30-minute
#     window (under which a finished agent reads busy for half an hour)
#   - a lane with no live registration reads `down`, and shows no stale context/uptime
#   - a dead pid does not count as live
#   - the last 📌 wins, and is still found when a big tool result pushes it past the first
#     512KB tail (the lead's own row was blank for exactly this reason)
#   - .claude/needs-input outranks the summary for the leftover width
#   - current-work yields the id only, never the resume prose that follows it
#   - emoji-width padding keeps the columns aligned

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$here/fleet-status.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: fleet-status.sh not found at $SCRIPT"; exit 1; }

pass=0; fail=0
eq(){ if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1));
      else echo "  FAIL: $1"; echo "        expected: [$2]"; echo "        actual:   [$3]"; fail=$((fail+1)); fi }
has(){ case "$3" in *"$2"*) echo "  PASS: $1"; pass=$((pass+1));;
       *) echo "  FAIL: $1"; echo "        wanted substring: [$2]"; echo "        in: [$3]"; fail=$((fail+1));; esac }
hasnt(){ case "$3" in *"$2"*) echo "  FAIL: $1"; echo "        unwanted substring: [$2]"; echo "        in: [$3]"; fail=$((fail+1));;
         *) echo "  PASS: $1"; pass=$((pass+1));; esac }

FAKEHOME="$(cd "$(mktemp -d)" && pwd -P)"
T="$(cd "$(mktemp -d)" && pwd -P)"
cleanup(){ rm -rf "$FAKEHOME" "$T"; }
trap cleanup EXIT INT TERM

LANES="$T/lanes"
mkdir -p "$FAKEHOME/.claude/running-agents" "$FAKEHOME/.claude/agent-busy" \
         "$FAKEHOME/.claude/projects" "$LANES"

# A provably dead pid: a subshell already reaped.
( : ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null

# transcript <lane> <jsonl-body-file>  — install a transcript at the munged project path.
transcript(){
  local lane="$1" src="$2" munged
  munged="$(printf '%s' "$LANES/$lane" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$FAKEHOME/.claude/projects/$munged"
  cp "$src" "$FAKEHOME/.claude/projects/$munged/session.jsonl"
}

# assistant_line <pin-text> — one transcript record carrying a 📌 summary.
assistant_line(){
  python3 -c '
import json,sys
print(json.dumps({"type":"assistant","message":{"model":"claude-opus-5","content":[
  {"type":"text","text":"\U0001F4CC "+sys.argv[1]}],
  "usage":{"input_tokens":10,"cache_read_input_tokens":19990,"output_tokens":0}}},
  ensure_ascii=False))' "$1"
}

lane(){ mkdir -p "$LANES/$1/.claude"; }
live(){ printf 'cwd:%s' "$LANES/$1" > "$FAKEHOME/.claude/running-agents/$1.$$"; }
dead(){ printf 'cwd:%s' "$LANES/$1" > "$FAKEHOME/.claude/running-agents/$1.$DEADPID"; }
busy_now(){ : > "$FAKEHOME/.claude/agent-busy/$1"; }
busy_old(){ : > "$FAKEHOME/.claude/agent-busy/$1"; touch -t 202601010000 "$FAKEHOME/.claude/agent-busy/$1"; }

# --once on EVERY invocation: watch is the default now, and a test that omits it hangs the
# suite forever rather than failing. (It did, once — that is why this line says why.)
run(){ HOME="$FAKEHOME" COLUMNS="${COLUMNS:-160}" bash "$SCRIPT" --once --lanes-dir "$LANES" "$@" </dev/null 2>&1; }
row(){ run | grep -E "^ +. +$1 " ; }

echo "fleet-status.sh"

# ── the three live states ────────────────────────────────────────────────────────────────
lane alpha;  live alpha;  busy_now alpha
lane bravo;  live bravo;  busy_old bravo
lane chas;   live chas    # no marker at all
lane delta                # lane on disk, nothing occupying it
lane echo_;  dead echo_

has "a freshly-touched marker reads busy"                       " busy "    "$(row alpha)"
has "an old marker reads waiting, NOT busy (fleet_busy would say busy for 30m)" \
                                                                " waiting " "$(row bravo)"
has "no marker reads idle"                                      " idle "    "$(row chas)"
has "a lane with no live registration reads down"               " down "    "$(row delta)"
has "a dead pid does not count as live"                         " down "    "$(row echo_)"
eq  "down rows show no context or uptime" "- -" \
    "$(row delta | awk '{print $4, $5}')"

# ── the header tally ─────────────────────────────────────────────────────────────────────
has "header counts live lanes"       "3/5 lanes up"      "$(run | head -1)"
has "header counts busy lanes"       "1 busy"            "$(run | head -1)"
has "header counts who wants you"    "1 waiting on you"  "$(run | head -1)"

# ── facts read off the lane ──────────────────────────────────────────────────────────────
printf 'FEAT-42\thttps://example.invalid/FEAT-42\n# a comment\nresume prose that is not an id\n' \
  > "$LANES/alpha/.claude/current-work"
has "current-work yields the tracker id"           "FEAT-42" "$(row alpha)"
hasnt "current-work does not leak the resume prose" "resume prose" "$(row alpha)"

assistant_line "first summary"  >  "$T/t.jsonl"
assistant_line "LAST summary"   >> "$T/t.jsonl"
transcript alpha "$T/t.jsonl"
has "the LAST 📌 wins"        "LAST summary"  "$(row alpha)"
hasnt "an earlier 📌 is not shown" "first summary" "$(row alpha)"
has "context% is derived from the transcript usage" " 2% " "$(row alpha)"

# A big tool result between the summary and EOF: the 512KB tail misses it, the widening
# read finds it. This is the lead's own blank-row bug.
{ assistant_line "BURIED summary"
  python3 -c 'import json;print(json.dumps({"type":"user","message":{"content":"x"*900000}}))'
} > "$T/big.jsonl"
transcript bravo "$T/big.jsonl"
has "a 📌 pushed past the first 512KB tail is still found" "BURIED summary" "$(row bravo)"

# ── needs-input outranks the summary ─────────────────────────────────────────────────────
printf 'park FEAT-6 or rerun once #111 lands?\n' > "$LANES/alpha/.claude/needs-input"
has "needs-input is shown"                   "park FEAT-6"   "$(row alpha)"
hasnt "needs-input displaces the summary"    "LAST summary"  "$(row alpha)"
has "a lane that wrote needs-input counts as waiting on you" "2 waiting on you" "$(run | head -1)"

# ── alignment ────────────────────────────────────────────────────────────────────────────
# ❓ is two cells wide where len() counts one; if that is not accounted for, the rows whose
# icon is ❓ skew one column against the rest.
widths="$(run | tail -n +2 | python3 -c '
import sys
W=[(0x1F300,0x1F64F),(0x2753,0x2755),(0x1F900,0x1F9FF)]
def w(s): return sum(2 if any(a<=ord(c)<=b for a,b in W) else 1 for c in s)
# column of the state word: everything up to and including the name field
print(len({w(l.split(" busy")[0].split(" idle")[0].split(" waiting")[0].split(" down")[0])
           for l in sys.stdin if l.strip()}))')"
eq "every row puts its state column at the same cell" "1" "$widths"

# ── subagents: live agents that occupy no lane ───────────────────────────────────────────
# A reviewer runs in ITS SPAWNER'S cwd, so every per-cwd fact would be the spawner's. The row
# must carry only what is unambiguously the subagent's own.
printf 'cwd:%s' "$LANES/alpha" > "$FAKEHOME/.claude/running-agents/rev-a.$$"
printf '%s' "$LANES/alpha" > "$FAKEHOME/.claude/agents/rev-a.cwd"
has "a live agent with no lane is listed as a subagent" "rev-a"        "$(run)"
has "and it is indented under the lanes"                "└"           "$(run)"
has "the header counts subagents separately"            "1 subagent"  "$(run | head -1)"
sub="$(run | grep -F 'rev-a')"
hasnt "a subagent does NOT borrow its spawner's issue"   "FEAT-42"     "$sub"
hasnt "a subagent does NOT borrow its spawner's summary" "LAST summary" "$sub"
rm -f "$FAKEHOME/.claude/running-agents/rev-a.$$" "$FAKEHOME/.claude/agents/rev-a.cwd"

# ── json ─────────────────────────────────────────────────────────────────────────────────
j="$(run --json | python3 -c '
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip()]
d={r["name"]:r for r in rows}
print(len(rows), d["alpha"]["state"], d["delta"]["state"], d["alpha"]["issue"],
      d["alpha"]["context_pct"], d["delta"]["context_pct"])')"
eq "--json emits one object per lane with the same facts" \
   "5 busy down FEAT-42 2 None" "$j"

# ── refusals ─────────────────────────────────────────────────────────────────────────────
out="$(HOME="$FAKEHOME" bash "$SCRIPT" --once --lanes-dir "$T/nope" 2>&1)"; rc=$?
eq "a missing lanes directory is a loud refusal, not an empty table" "1" "$rc"
has "and it says which directory"  "$T/nope" "$out"

out="$(HOME="$FAKEHOME" bash "$SCRIPT" --once --bogus 2>&1)"; rc=$?
eq "an unknown argument exits 2 rather than guessing" "2" "$rc"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
