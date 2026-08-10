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
#   - the status line is the LEAD-WRITTEN .claude/status, never the agent's own transcript
#   - status and asks are hard-capped at 60 chars, so one verbose entry cannot own the pane
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
         "$FAKEHOME/.claude/agents" "$FAKEHOME/.claude/projects" "$LANES"

# A provably dead pid: a subshell already reaped.
( : ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null

# transcript <lane> <jsonl-body-file>  — install a transcript at the munged project path.
transcript(){
  local lane="$1" src="$2" munged
  munged="$(printf '%s' "$LANES/$lane" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$FAKEHOME/.claude/projects/$munged"
  cp "$src" "$FAKEHOME/.claude/projects/$munged/session.jsonl"
}

# assistant_line <text> — one transcript record. The text is carried as a 📌 summary because
# that is what the panel USED to render; these tests now assert it is NOT rendered. The record
# also carries the token usage that context% is still legitimately derived from.
assistant_line(){
  python3 -c '
import json,sys
print(json.dumps({"type":"assistant","message":{"model":"claude-opus-5","content":[
  {"type":"text","text":"\U0001F4CC "+sys.argv[1]}],
  "usage":{"input_tokens":10,"cache_read_input_tokens":19990,"output_tokens":0}}},
  ensure_ascii=False))' "$1"
}

lane(){ mkdir -p "$LANES/$1/.claude"; }
status(){ printf '%s\n' "$2" > "$LANES/$1/.claude/status"; }
live(){ printf 'cwd:%s' "$LANES/$1" > "$FAKEHOME/.claude/running-agents/$1.$$"; }
dead(){ printf 'cwd:%s' "$LANES/$1" > "$FAKEHOME/.claude/running-agents/$1.$DEADPID"; }
busy_now(){ : > "$FAKEHOME/.claude/agent-busy/$1"; }
busy_old(){ : > "$FAKEHOME/.claude/agent-busy/$1"; touch -t 202601010000 "$FAKEHOME/.claude/agent-busy/$1"; }

# --once on EVERY invocation: watch is the default now, and a test that omits it hangs the
# suite forever rather than failing. (It did, once — that is why this line says why.)
run(){ HOME="$FAKEHOME" COLUMNS="${COLUMNS:-160}" bash "$SCRIPT" --once --lanes-dir "$LANES" "$@" </dev/null 2>&1; }
# A row is now MULTI-LINE: the agent line plus its indented 📌 / ❓ continuations. grep for
# the name, then take every following indented continuation until the next agent line.
row(){ run | awk -v n="$1" '
  $0 ~ ("^ +[^ ]+ +" n " ") {show=1; print; next}
  show && /^      / {print; next}
  show {show=0}
'; }

echo "fleet-status.sh"

# ── the three live states ────────────────────────────────────────────────────────────────
lane alpha;  live alpha;  busy_now alpha
lane bravo;  live bravo;  busy_old bravo
lane chas;   live chas    # no marker at all
lane delta                # lane on disk, nothing occupying it
lane echo_;  dead echo_

# NOT A LANE: the harness's throwaway isolation-worktree checkout, which now shares this
# directory with the real lanes. Made LIVE deliberately — an unfiltered enumerator would render
# it as a running agent, which is the loudest possible wrong answer, and a dead one would be
# indistinguishable from correctly-filtered.
lane agent-deadbeefcafe0001; live agent-deadbeefcafe0001; busy_now agent-deadbeefcafe0001

has "a freshly-touched marker reads busy"                       " busy "    "$(row alpha)"
has "an old marker reads quiet, NOT busy (fleet_busy would say busy for 30m)" \
                                                                " quiet " "$(row bravo)"
has "no marker reads idle"                                      " idle "    "$(row chas)"
has "a lane with no live registration reads down"               " down "    "$(row delta)"
has "a dead pid does not count as live"                         " down "    "$(row echo_)"
eq  "down rows show no context or uptime" "- -" \
    "$(row delta | awk '{print $4, $5}')"

# ── the header tally ─────────────────────────────────────────────────────────────────────
# 3/5, not 4/6: the live `agent-deadbeefcafe0001` above is a harness worktree, not a lane, and
# must not inflate either half of this count. Filter it out and this exact assertion reddens —
# which is the point of making that fixture live rather than merely present.
has "header counts live lanes"       "3/5 lanes up"      "$(run | head -1)"
hasnt "a harness isolation worktree is not rendered as an agent" \
                                     "agent-deadbeefcafe0001" "$(run)"
has "header counts busy lanes"       "1 busy"            "$(run | head -1)"
hasnt "a stale busy marker does NOT wear a question mark" "needs you" "$(run | head -1)"

# ── facts read off the lane ──────────────────────────────────────────────────────────────
printf 'FEAT-42\thttps://example.invalid/FEAT-42\n# a comment\nresume prose that is not an id\n' \
  > "$LANES/alpha/.claude/current-work"
has "current-work yields the tracker id"           "FEAT-42" "$(row alpha)"
hasnt "current-work does not leak the resume prose" "resume prose" "$(row alpha)"

assistant_line "TRANSCRIPT PIN" > "$T/t.jsonl"
transcript alpha "$T/t.jsonl"
has "context% is derived from the transcript usage" " 2% " "$(row alpha)"

# ── the status line is the LEAD's, not the agent's ───────────────────────────────────────
# The panel used to scrape the agent's own last 📌 out of its transcript. That reports the
# last thing the agent SAID, which for a parked lane is whatever it was mid-thought about
# hours ago. This assertion is the whole point of the rework: a live transcript pin sits on
# disk for alpha and must NOT appear.
status alpha "PR #124 staged, parked"
has  "the lead-written status is shown"              "PR #124 staged, parked" "$(row alpha)"
hasnt "the agent's own transcript pin is NOT shown"  "TRANSCRIPT PIN"         "$(row alpha)"
hasnt "and no pin glyph is rendered at all"          "📌"                      "$(run)"
# Counted, not string-compared against "": an empty second line is also what a BROKEN row()
# produces, so the negative has to be stated as "alpha grew a line and chas did not".
eq   "a lane with a status owns two lines"        "2" "$(row alpha | wc -l | tr -d ' ')"
eq   "a lane with no status file owns just one"   "1" "$(row chas  | wc -l | tr -d ' ')"

# ── the 60-char cap ──────────────────────────────────────────────────────────────────────
# Uncapped, one verbose entry owns the pane and the column stops being scannable — which is
# what happened to the free-text asks. The cap is enforced at READ so JSON sees it too.
status bravo "$(python3 -c 'print("x"*95)')"
has "an over-long status is clipped"          "…" "$(row bravo)"
eq  "…to exactly 60 cells"  "60" \
    "$(row bravo | sed -n '2p' | python3 -c 'import sys;print(len(sys.stdin.readline().strip()))')"

# ── a status that stopped being maintained says so ───────────────────────────────────────
# THE REGRESSION. Nothing refreshes this file — a human writes it — so a lane the lead stopped
# updating went on advertising its last line as the live state of the fleet, indefinitely and
# with no symptom: every number beside it (uptime, context%, PRs) kept moving correctly, which
# is exactly what made the frozen one invisible. Worse, ids inside it stay clickable, so a
# four-day-old "PR #130 open; awaiting your merge" rendered like PR data fetched a second ago.
# The line is kept — it is the only description of the lane there is — and wears its age.
status chas "FEAT-6 PR #130 open; awaiting your merge"
has   "a fresh status carries no age suffix" "awaiting your merge" "$(row chas)"
hasnt "…and nothing about being old"         "old"                 "$(row chas)"
touch -t "$(python3 -c '
import time
print(time.strftime("%Y%m%d%H%M", time.localtime(time.time() - 4*86400)))')" \
      "$LANES/chas/.claude/status"
has "a four-day-old status is marked as old"     "(4d old)" "$(row chas)"
has "…and the line itself is kept, not blanked"  "PR #130"  "$(row chas)"
# One hour is inside a working session; the line still means "now" and must stay undecorated.
touch -t "$(python3 -c '
import time
print(time.strftime("%Y%m%d%H%M", time.localtime(time.time() - 3600)))')" \
      "$LANES/chas/.claude/status"
hasnt "an hour-old status is NOT marked" "old" "$(row chas)"
rm -f "$LANES/chas/.claude/status"

# ── needs-input renders under the status ─────────────────────────────────────────────────
printf 'park FEAT-6 or rerun once #111 lands?\n' > "$LANES/alpha/.claude/needs-input"
has "needs-input is shown"                   "park FEAT-6"   "$(row alpha)"
has "the status is still shown alongside the ask" "PR #124 staged, parked" "$(row alpha)"
has "only an explicit needs-input counts as needing you" "⚠️ 1 needs you" "$(run | head -1)"

printf '%s\n' "$(python3 -c 'print("q"*95)')" > "$LANES/chas/.claude/needs-input"
eq "an over-long ask is clipped to 60 too" "60" \
   "$(row chas | sed -n '2p' | python3 -c '
import sys
# the icon + space lead-in is 2 codepoints the cap does not count
print(len(sys.stdin.readline().strip()) - 2)')"
rm -f "$LANES/chas/.claude/needs-input"

# ── typed asks ───────────────────────────────────────────────────────────────────────────
# Nine identical markers tell you only that there are nine. The kind is what lets the reader
# batch — reviews in one sitting, product calls in another — so it has to survive to the row.
printf 'review: the DX-6 diff\nproduct: fold MON-10 in?\nship: merge #124\ntriage: whose is this?\nsomething else\n' \
  > "$LANES/chas/.claude/needs-input"
has "a review: ask carries the review glyph"    "🔍 the DX-6 diff"      "$(row chas)"
has "a product: ask carries the product glyph"  "💬 fold MON-10 in?"    "$(row chas)"
has "a ship: ask carries the ship glyph"        "🚀 merge #124"         "$(row chas)"
has "a triage: ask carries the triage glyph"    "🏷️ whose is this?"     "$(row chas)"
has "an untyped ask is a general action item"   "✅ something else"     "$(row chas)"
hasnt "the kind token itself is consumed, not printed" "review:"        "$(row chas)"
has "the umbrella glyph still counts them all"  "⚠️ 6 needs you"        "$(run | head -1)"
has  "a lane owing answers wears the umbrella"          "⚠️ chas" "$(row chas | head -1)"
hasnt "…not the kind of its first ask"                  "🔍 chas" "$(row chas | head -1)"
rm -f "$LANES/chas/.claude/needs-input"

# ── alignment ────────────────────────────────────────────────────────────────────────────
# ⚠️ is two cells wide where len() counts two codepoints as two; if neither the width nor the
# zero-width variation selector is accounted for, the rows whose icon is ⚠️ skew against the rest.
widths="$(run | python3 -c '
import sys, re
# NOT the geometric shapes (U+25CB/CF/D4 — ○ ● ◔): terminals render those single-width,
# and inventing a wide range for them made this probe disagree with a correctly aligned
# table. Only true wide/emoji ranges belong here.
W=[(0x1F300,0x1F64F),(0x2753,0x2755),(0x1F900,0x1F9FF),(0x2600,0x27BF)]
Z=[(0xFE00,0xFE0F)]
def w(s):
    return sum(0 if any(a<=ord(c)<=b for a,b in Z)
               else 2 if any(a<=ord(c)<=b for a,b in W) else 1 for c in s)
# agent lines only: two leading spaces, an icon, the name, then a state word.
rows=[l for l in sys.stdin if re.match(r"^  \S+ +\S+ +(busy|idle|quiet|down) ", l)]
print(len({w(re.split(r" (busy|idle|quiet|down) ", l)[0]) for l in rows}) if rows else 0)')"
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
hasnt "a subagent does NOT borrow its spawner's issue"  "FEAT-42"                "$sub"
hasnt "a subagent does NOT borrow its spawner's status" "PR #124 staged, parked" "$sub"
rm -f "$FAKEHOME/.claude/running-agents/rev-a.$$" "$FAKEHOME/.claude/agents/rev-a.cwd"

# ── 4ME, the fleet-level list ────────────────────────────────────────────────────────────
# It belongs to no lane, so it renders last under its own heading. The label and the row
# NUMBERS are one contract with the TUI: the user says "4me 2", and a reference that resolves
# to a different item depending on which of the two views happens to be open is worse than no
# numbering at all.
printf 'ship: merge #124\nproduct: fold MON-10 in?\n' > "$T/needs-input-fleet"
has   "the fleet-level list is headed 4ME"  "4ME  (not lane-specific)"  "$(run)"
has   "its first item is numbered 1"        " 1  🚀 merge #124"         "$(run)"
has   "…and its second is numbered 2"       " 2  💬 fold MON-10 in?"    "$(run)"
hasnt "the old label is gone from the table" "NEEDS YOU"                "$(run)"
rm -f "$T/needs-input-fleet"
hasnt "with no fleet asks there is no heading" "4ME" "$(run)"

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
