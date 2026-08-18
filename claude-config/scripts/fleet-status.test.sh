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
#   - …and beside it, when the AGENT was last active — a transcript mtime nobody maintains,
#     which is what says whether the lead's line still speaks for the present. On a pane too
#     narrow for both, the prose is shortened and the clock is kept whole
#   - status and asks are hard-capped at 60 chars, so one verbose entry cannot own the pane
#   - current-work yields the id only, never the resume prose that follows it
#   - …and it BEATS the branch name, which outlives the work it was cut for; a disagreement
#     is marked rather than resolved silently
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

# ── the branch is the loser of that resolution, and says so ──────────────────────────────
# A lane keeps the branch of work it has FINISHED until someone branches again, so a lane on
# `john/dx-16-…` while actively working FEAT-42 is normal and the branch's id is the stale
# one. The table shows what the agent is doing and marks the disagreement; it used to show
# DX-16 and the reader had no way to see FEAT-42 at all.
mkdir -p "$LANES/alpha/gitdir"
printf 'ref: refs/heads/john/dx-16-move-plans-to-documents\n' > "$LANES/alpha/gitdir/HEAD"
printf 'gitdir: %s\n' "$LANES/alpha/gitdir" > "$LANES/alpha/.git"
has "a branch left on finished work does not displace the current ticket" \
                                                   "FEAT-42" "$(row alpha)"
hasnt "…and the branch's stale id is not in the column" "DX-16" "$(row alpha)"
has "…but the disagreement is marked"              "≠branch" "$(row alpha)"
rm -rf "$LANES/alpha/gitdir" "$LANES/alpha/.git"
hasnt "with the branch gone the marker goes too"   "≠branch" "$(row alpha)"

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

# ── the OTHER clock: when the agent itself was last active ───────────────────────────────
# The age above says when the LEAD last wrote the claim. It cannot say whether the lane is
# still there — which is the half that made the frozen statuses dangerous. This one nobody
# maintains: it is the mtime of the transcript the agent stamps by working, so it is right
# whether or not anyone remembered anything. Both are shown, because a busy lane under a
# Friday status and a fresh status over a dead lane are different problems.
touch -t "$(python3 -c '
import time
print(time.strftime("%Y%m%d%H%M", time.localtime(time.time() - 3*3600)))')" \
      "$FAKEHOME/.claude/projects/$(printf '%s' "$LANES/alpha" | sed 's/[^A-Za-z0-9]/-/g')/session.jsonl"
has "a lane wears its agent's last activity"        "active 3h ago"          "$(row alpha)"
has "…beside the status rather than instead of it"  "PR #124 staged, parked" "$(row alpha)"
# A lane with NO status is exactly where this is the only thing known about it, so it must
# still render — a second line that exists only when the lead wrote one would go dark on the
# rows that need it most.
eq "a lane with no status but a live transcript still reports activity" "1" \
   "$(row alpha | grep -c 'active 3h ago')"
transcript chas "$T/t.jsonl"
has "…and shows it with no status line at all" "active" "$(row chas)"
rm -rf "$FAKEHOME/.claude/projects/$(printf '%s' "$LANES/chas" | sed 's/[^A-Za-z0-9]/-/g')"
hasnt "a lane whose transcript cannot be found claims no activity" "active" "$(row chas)"

# ON A NARROW PANE THE PROSE GIVES WAY, NOT THE CLOCK. Truncation runs from the right, so the
# naive join drops the one part of this line nobody maintains and leaves the human-written
# sentence looking authoritative with nothing to date it — the exact failure the field exists
# to end. The status is shortened instead and the clock survives whole.
status alpha "$(python3 -c 'print("y"*95)')"      # clipped to 60, wider than a 72-col pane
narrow="$(COLUMNS=72 run | grep -F -A2 ' alpha ' | grep -F 'active')"
has  "a narrow pane keeps the activity clock whole" "· active 3h ago" "$narrow"
has  "…and shortens the lead's prose to make room"  "yyy…"            "$narrow"
status alpha "PR #124 staged, parked"

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
# Its cwd sidecar resolves to the SPAWNER's transcript, so a cwd-derived activity time would
# report the lead's keystrokes as the reviewer's. Only a session-exact path may answer here.
hasnt "a subagent does NOT borrow its spawner's activity" "active"                "$sub"
rm -f "$FAKEHOME/.claude/running-agents/rev-a.$$" "$FAKEHOME/.claude/agents/rev-a.cwd"

# ── the lane is not the agent: WORKFLOW_AGENT_NAME_PREFIX ────────────────────────────────
# A lane is a DIRECTORY (`foxtrot`). The agent occupying it is a MACHINE-GLOBAL registry name
# that the prefix prepends to (`g-foxtrot`) — the registry collides between fleets on one
# machine, the lane cannot. Reading the registry under the LANE's name reported every lane of
# a fully live fleet as `down` AND re-emitted each of its agents as a ticketless `subagent`
# row: one outage rendered twice, in two places. Both halves are asserted here, because
# fixing only the first leaves a duplicate row per lane.
#
# EVERY FIXTURE BELOW IS REMOVED AT THE END OF THE SECTION. The lane tally and the --json
# count are asserted against the five lanes above, both before this point and after it.
lane foxtrot
printf 'cwd:%s' "$LANES/foxtrot" > "$FAKEHOME/.claude/running-agents/g-foxtrot.$$"
busy_now g-foxtrot
# NO cwd sidecar for g-foxtrot, deliberately: that isolates step 1 (the configured prefix) as
# the only thing that can resolve this lane, so the assertion cannot be satisfied by the
# cwd-based fallback and silently stop testing the prefix.
runp(){ WORKFLOW_AGENT_NAME_PREFIX=g- run "$@"; }
rowp(){ WORKFLOW_AGENT_NAME_PREFIX=g- row "$@"; }

has  "a prefixed agent occupies its lane"                    " busy "     "$(rowp foxtrot)"
has  "…and the row is still keyed by the LANE name"          " foxtrot "  "$(rowp foxtrot)"
hasnt "…so the agent name never replaces it in the table"    "g-foxtrot"  "$(runp)"
hasnt "…and the lane agent is not ALSO emitted as a subagent" "1 subagent" "$(runp | head -1)"
has  "with no prefix configured the same lane reads down"    " down "     "$(row foxtrot)"

# STEP 3 — attribution with NO prefix configured anywhere. The agent's cwd sidecar names this
# lane and its name ends in the lane name, which is enough to attribute it. This is what keeps
# the view working when the main-clone workflow.config cannot be derived (a WORKFLOW_LANES_DIR
# pointing outside the clone).
lane golf
printf 'cwd:%s' "$LANES/golf" > "$FAKEHOME/.claude/running-agents/z-golf.$$"
printf '%s' "$LANES/golf" > "$FAKEHOME/.claude/agents/z-golf.cwd"
busy_now z-golf
has  "an unconfigured prefix still attributes via the cwd sidecar" " busy "  "$(row golf)"
hasnt "…and that agent is not double-emitted either"              "z-golf"  "$(run)"

# THE SUFFIX TEST IS LOAD-BEARING, and this is the case that proves it. A subagent runs in its
# SPAWNER's cwd, so a lane path is the sidecar value of the lane agent AND of every subagent
# the lane has spawned. Skipping the sweep on "cwd is a lane path" would delete this row —
# retiring the standing tester and every task subagent from the view to fix the lane rows.
printf 'cwd:%s' "$LANES/golf" > "$FAKEHOME/.claude/running-agents/g-tester.$$"
printf '%s' "$LANES/golf" > "$FAKEHOME/.claude/agents/g-tester.cwd"
has  "a subagent sharing a lane's cwd is still listed"   "g-tester"  "$(run)"
has  "…as a subagent, not as that lane"                  " golf "    "$(row golf)"
rm -f "$FAKEHOME/.claude/running-agents/g-tester.$$" "$FAKEHOME/.claude/agents/g-tester.cwd"

# LIVENESS IS PER CANDIDATE, not resolved-then-checked. A stale prefixed entry left by a dead
# agent must not win the lane and report `down` over a live unprefixed one — the failure would
# look exactly like the bug this section fixes, from the opposite direction.
lane hotel
printf 'cwd:%s' "$LANES/hotel" > "$FAKEHOME/.claude/running-agents/g-hotel.$DEADPID"
live hotel; busy_now hotel
has "a stale prefixed entry does not beat a live bare one" " busy " "$(rowp hotel)"

# THE PREFIX COMES FROM THE MAIN CLONE'S workflow.config when the env does not carry it, which
# is how the live fleet actually resolves it — no agent exports the variable. The derivation is
# `<lanes>/../..`, so the fixture has to be clone-shaped rather than a bare directory.
CLONE="$T/clone"; L2="$CLONE/.claude/worktrees"
mkdir -p "$L2/india/.claude" "$CLONE/.claude"
printf 'WORKFLOW_AGENT_NAME_PREFIX="q-"\n' > "$CLONE/.claude/workflow.config"
printf 'cwd:%s' "$L2/india" > "$FAKEHOME/.claude/running-agents/q-india.$$"
busy_now q-india
c2="$(HOME="$FAKEHOME" COLUMNS=160 bash "$SCRIPT" --once --lanes-dir "$L2" </dev/null 2>&1)"
# ROW-SCOPED, not whole-output. Asserted against the full table this reads ` busy ` off ANY
# row — and the registry still holds the live subagents from the sections above, so it passed
# against a deliberately broken build that rendered india itself as `down`. The assertion has
# to name the row it is about.
rowin(){ printf '%s\n' "$2" | awk -v n="$1" '
  $0 ~ ("^ +[^ ]+ +" n " ") {show=1; print; next}
  show && /^      / {print; next}
  show {show=0}'; }
has   "the prefix is read from the main clone's workflow.config" " busy "  "$(rowin india "$c2")"
hasnt "…and that agent is not emitted as a subagent as well"     "q-india" "$c2"
rm -f "$FAKEHOME/.claude/running-agents/q-india.$$" "$FAKEHOME/.claude/agent-busy/q-india"
rm -rf "$CLONE"

rm -rf "$LANES/foxtrot" "$LANES/golf" "$LANES/hotel"
rm -f "$FAKEHOME/.claude/running-agents/g-foxtrot.$$" "$FAKEHOME/.claude/agent-busy/g-foxtrot" \
      "$FAKEHOME/.claude/running-agents/z-golf.$$" "$FAKEHOME/.claude/agents/z-golf.cwd" \
      "$FAKEHOME/.claude/agent-busy/z-golf" \
      "$FAKEHOME/.claude/running-agents/g-hotel.$DEADPID" \
      "$FAKEHOME/.claude/running-agents/hotel.$$" "$FAKEHOME/.claude/agent-busy/hotel"

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

# METADATA TRAILERS ARE NOT FOR THIS VIEW. The lead writes provenance onto these lines —
# ticket, who raised it, when, what it blocks — and this is a one-line column: a `[from:…]`
# tail here would spend the row's width on bookkeeping and push the actual question out of
# sight. The TUI's detail dialog is where they are rendered as fields.
printf 'product: fold MON-10 in? [MON-10] [from:feature-3] [added:2026-08-10]\n' \
  > "$T/needs-input-fleet"
has   "the ask itself survives the trailers"  " 1  💬 fold MON-10 in?"  "$(run)"
hasnt "the ticket trailer is not in the row"  "[MON-10]"                "$(run)"
hasnt "…nor who raised it"                    "from:feature-3"          "$(run)"
hasnt "…nor when it was added"                "added:2026-08-10"        "$(run)"
# THE DEFERRAL STAMP STAYS. It is the answer to "why is this still on the list", so a view
# that hid it would re-ask a question the user has already declined once.
printf 'product: fold MON-10 in? (deferred 2026-08-11 — until SRV-21) [MON-10]\n' \
  > "$T/needs-input-fleet"
has   "the deferral stamp is kept inline, unlike the trailers" "deferred 2026-08-11" "$(run)"
rm -f "$T/needs-input-fleet"
hasnt "with no fleet asks there is no heading" "4ME" "$(run)"

# ── the standing goal ────────────────────────────────────────────────────────────────────
# One objective the whole fleet is pointed at, beside the 4ME list and owned by the lead. It
# rides the header because it is what every other line on this pane is FOR — and it is absent
# entirely when unset, since a permanent "no goal" row spends a line to say nothing.
hasnt "with no goal file there is no goal line" "GOAL" "$(run)"
printf 'ship DX-6 end to end\nneeds: SRV-11 merged\n' > "$T/fleet-goal"
has   "the goal one-liner rides the header" "🎯 GOAL  ship DX-6 end to end" "$(run)"
hasnt "…and the chain under it is not header material" "SRV-11 merged" "$(run)"
rm -f "$T/fleet-goal"

# ── json ─────────────────────────────────────────────────────────────────────────────────
j="$(run --json | python3 -c '
import json,sys
rows=[json.loads(l) for l in sys.stdin if l.strip()]
d={r["name"]:r for r in rows}
print(len(rows), d["alpha"]["state"], d["delta"]["state"], d["alpha"]["issue"],
      d["alpha"]["context_pct"], d["delta"]["context_pct"],
      # Seconds, unformatted — JSON consumers want the number and each renderer picks its own
      # wording. ~3h for the lane whose transcript was aged above; None where there is none.
      10000 < d["alpha"]["last_active"] < 11600, d["delta"]["last_active"])')"
eq "--json emits one object per lane with the same facts" \
   "5 busy down FEAT-42 2 None True None" "$j"

# ── refusals ─────────────────────────────────────────────────────────────────────────────
out="$(HOME="$FAKEHOME" bash "$SCRIPT" --once --lanes-dir "$T/nope" 2>&1)"; rc=$?
eq "a missing lanes directory is a loud refusal, not an empty table" "1" "$rc"
has "and it says which directory"  "$T/nope" "$out"

out="$(HOME="$FAKEHOME" bash "$SCRIPT" --once --bogus 2>&1)"; rc=$?
eq "an unknown argument exits 2 rather than guessing" "2" "$rc"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
