#!/bin/bash
# Tests for mark-busy.sh — the busy marker's only writer.
#
# WHY THIS EXISTS. The marker's lifecycle used to be covered incidentally by
# drain-inbox.test.sh, which asserted the CLEAR side (Stop clears it) and, in doing so,
# exercised the write side too. That suite was deleted with the mailbox transport, leaving
# the writer of a load-bearing signal with no test at all.
#
# The signal is load-bearing because IDLE is what authorises a destructive verb:
# team-boot.sh's `down` stops an agent, and agent-fanout's
# restart/compact kill or type into one. All of them read this marker through fleet_busy.
# A silently-not-writing mark-busy means every one of them sees a working agent as idle.
#
# NON-VACUITY: case 2 must WRITE. If this hook ever degrades to an unconditional `exit 0`
# (the shape it already has on every not-a-fleet-agent path), cases 1/3/4/5 all still pass
# and only case 2 turns red. That is the point of it, so it is asserted first-class.

set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/mark-busy.sh"
[ -f "$HOOK" ] || { echo "FATAL: mark-busy.sh not found at $HOOK"; exit 1; }

pass=0; fail=0
ok() {  # ok <label> <test-expression>
  if eval "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi
}
eqx() { # eqx <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi
}

# A hermetic HOME with a registry entry whose identity token matches the token this hook
# will compute for itself. Headless (no TMUX_PANE) means fleet_self_token returns
# "cwd:<pwd>", so that is what the entry must contain — this is the real self-id path, not
# a stub.
newhome() {  # newhome [token] -> prints the temp HOME
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude/running-agents"
  printf '%s' "${1:-cwd:$PWD}" > "$h/.claude/running-agents/testself.4242"
  printf '%s' "$h"
}

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

run() {  # run <home> [payload] -> exit code, stdin fed like a real hook
  local h="$1" payload="${2:-}"
  printf '%s' "$payload" | env -u TMUX -u TMUX_PANE HOME="$h" bash "$HOOK" >/dev/null 2>&1
  printf '%s' "$?"
}

echo "mark-busy.sh — the busy marker's only writer"

# 1. Never breaks a session. A hook that exits non-zero can fail a tool call, and this one
#    runs on EVERY PreToolUse in every session on the machine.
H1="$(newhome)"
eqx "exits 0 with an empty payload"            "0" "$(run "$H1")"
eqx "exits 0 with a real PreToolUse payload"   "0" "$(run "$H1" '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"

# 1b. THE TURN-START WRITE. The hook is wired on UserPromptSubmit as well as PreToolUse, and a
#     UserPromptSubmit payload carries NO tool_name. That is the mark of the turn's START, and
#     it is the only mark a turn gets if the model thinks before its first tool call or answers
#     in pure text with no tool call at all.
#
#     Found by mutation: a hook that returned early on any payload without a `tool_name` passed
#     all ten of this suite's original assertions, because the ONLY no-tool_name case was the
#     empty payload above — which asserts the exit code and never checks for a marker. The
#     unmarked agent then reads as idle and `down` kills it mid-turn.
H1B="$(newhome)"
run "$H1B" '{"session_id":"abc","prompt":"do the thing"}' >/dev/null
ok  "a UserPromptSubmit payload (NO tool_name) still writes the marker" \
    '[ -f "$H1B/.claude/agent-busy/testself" ]'
H1C="$(newhome)"
run "$H1C" '' >/dev/null
ok  "…and so does a payload-less invocation" '[ -f "$H1C/.claude/agent-busy/testself" ]'

# 2. NON-VACUITY — it actually writes the marker for a registered agent.
H2="$(newhome)"
run "$H2" '{"tool_name":"Read"}' >/dev/null
ok  "writes ~/.claude/agent-busy/<name> for a registered agent" '[ -f "$H2/.claude/agent-busy/testself" ]'
ok  "…named for the REGISTRY name, not the cwd basename"        '[ ! -f "$H2/.claude/agent-busy/$(basename "$PWD")" ] || [ "$(basename "$PWD")" = testself ]'

# 3. A NON-agent session writes nothing. Every human shell and every non-fleet repo hits
#    this path; a marker here would put a phantom agent in front of `down`'s idle gate.
H3="$(mktemp -d)"; mkdir -p "$H3/.claude/running-agents"   # registry exists but is EMPTY
eqx "exits 0 when this session is not a registered agent" "0" "$(run "$H3" '{"tool_name":"Read"}')"
ok  "…and writes no marker"                               '[ ! -d "$H3/.claude/agent-busy" ] || [ -z "$(ls -A "$H3/.claude/agent-busy" 2>/dev/null)" ]'

# 4. No registry at all (fresh machine): the hook must degrade, not error.
H4="$(mktemp -d)"
eqx "exits 0 with no registry directory at all" "0" "$(run "$H4" '{"tool_name":"Read"}')"
ok  "…and creates no agent-busy directory"      '[ ! -d "$H4/.claude/agent-busy" ]'

# 5. Re-touch keeps the marker FRESH. fleet_busy trusts the marker only within
#    WORKFLOW_BUSY_STALE_MIN, so a long turn stays "busy" only because every tool call
#    re-stamps it. If the write became create-only, a long turn would age into "idle" and
#    a destructive verb could act on a working agent.
H5="$(newhome)"
run "$H5" '{"tool_name":"Read"}' >/dev/null
M="$H5/.claude/agent-busy/testself"
# Guarded: if the write side is broken there is no marker to stat, and an unguarded
# `stat` would spray a usage error and an "integer expected" from the comparison —
# turning a clean FAIL into an error cascade that hides which assertion actually broke.
if [ ! -f "$M" ]; then
  fail=$((fail+1)); printf '  FAIL %s (no marker was written — see the write assertion above)\n' \
    "a second tool call RE-TOUCHES the marker"
else
  touch -t 202001010000 "$M" 2>/dev/null || touch "$M"
  old="$(mtime "$M")"
  run "$H5" '{"tool_name":"Bash"}' >/dev/null
  new="$(mtime "$M")"
  ok "a second tool call RE-TOUCHES the marker (freshness, not create-only)" \
     '[ -n "$new" ] && [ -n "$old" ] && [ "$new" -gt "$old" ]'
fi

# 6. The retired HOLD marker must stay retired. Its readers (agent-send, inbox-watcher) are
#    gone, so writing it again would resurrect write-only state that reads as a live signal.
H6="$(newhome)"
run "$H6" '{"tool_name":"mcp__monocle__get_feedback","tool_input":{"wait":true}}' >/dev/null
ok "the blocking-Monocle payload no longer writes an agent-hold marker" '[ ! -e "$H6/.claude/agent-hold" ]'

# 7. MULTI-TENANCY. This hook runs in every agent on a shared ~/.claude, so it touches a
#    directory other agents depend on. It must write EXACTLY its own marker.
#
#    Found by mutation: inserting `rm -f "$HOME/.claude/agent-busy/"*` after the mkdir passed
#    every assertion, because the fixture only ever seeded ONE agent — a single-tenant fixture
#    cannot observe cross-tenant destruction. In a four-agent fleet that mutant makes every
#    agent's tool call clear every other agent's marker, so `down` sees working teammates as
#    idle and kills them. Continuous, and worse than the turn-start hole above.
H7="$(newhome)"
mkdir -p "$H7/.claude/agent-busy"
: > "$H7/.claude/agent-busy/other-agent"
printf 'cwd:/somewhere/else' > "$H7/.claude/running-agents/other-agent.9999"
OTHER_BEFORE="$(mtime "$H7/.claude/agent-busy/other-agent" 2>/dev/null || echo x)"
run "$H7" '{"tool_name":"Read"}' >/dev/null
ok "writes its OWN marker in a multi-agent home"      '[ -f "$H7/.claude/agent-busy/testself" ]'
ok "…and does NOT delete a peer's marker"             '[ -f "$H7/.claude/agent-busy/other-agent" ]'
ok "…and does not even re-touch a peer's marker"      \
   '[ "$(mtime "$H7/.claude/agent-busy/other-agent")" = "$OTHER_BEFORE" ]'
eqx "…leaving exactly two markers"               "2" \
    "$(ls -1 "$H7/.claude/agent-busy" 2>/dev/null | wc -l | tr -d ' ')"

# 8. SELF-ID FAIL-CLOSED. If neither _fleet.sh candidate is readable, `fleet_find_self` is
#    undefined — and this hook used to exit 0 having written nothing, so a registered mid-turn
#    agent was indistinguishable from an idle one at exactly the moment a destroy-guard asks.
#    The inline fallback exists for this, and this case is what keeps it honest.
H8="$(newhome)"
printf '' | env -u TMUX -u TMUX_PANE HOME="$H8" bash -c '
  # Simulate _fleet.sh being unreadable from BOTH candidate paths by pointing HOME at a home
  # with no scripts dir and running the hook from a copy with no sibling scripts/ either.
  d="$(mktemp -d)"; cp "$1" "$d/mark-busy.sh"; bash "$d/mark-busy.sh"
' _ "$HOOK" >/dev/null 2>&1
ok "no readable _fleet.sh → the marker is STILL written (fails closed)" \
   '[ -f "$H8/.claude/agent-busy/testself" ]'

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
