#!/bin/bash
# Self-contained tests for suppress-spent-agent-msg.sh.
# Run: bash .claude/hooks/suppress-spent-agent-msg.test.sh
#
# Hermetic: every scenario uses a throwaway $HOME so it never touches the real registry
# or inbox. Exits non-zero on any failure.
#
# The hook's contract is asymmetric and the tests are weighted to match: exactly ONE
# input shape may be blocked, and every other shape MUST pass through. So the fail-open
# cases are the bulk of the suite — a regression that blocks a real prompt is far worse
# than one that lets a spent pointer waste a turn (which is merely today's behaviour).

set -u
# Captured BEFORE any throwaway-$HOME override: the canonical _fleet.sh now lives in the
# real home (symlinked from dotfiles) and has no repo sibling to fall back to.
REAL_FLEET="$HOME/.claude/scripts/_fleet.sh"
here="$(cd "$(dirname "$0")" && pwd)"
HOOK="$here/suppress-spent-agent-msg.sh"
[ -x "$HOOK" ] || { echo "suppress-spent-agent-msg.sh not executable at $HOOK"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable (hook fails open without it)"; exit 0; }

pass=0; fail=0
ok(){ if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }

MSG='d030826e67854666a8bb16de1c61c5f8.feature-2.rep.txt'

newhome(){ # -> fresh throwaway HOME with 'testself' registered on pane %99
  local h; h="$(mktemp -d)"
  mkdir -p "$h/.claude/running-agents" "$h/.claude/agent-inbox/testself" "$h/.claude/agent-busy"
  mkdir -p "$h/.claude/scripts"
  cp "$REAL_FLEET" "$h/.claude/scripts/_fleet.sh" 2>/dev/null || true
  echo '%99' > "$h/.claude/running-agents/testself.123"
  printf '%s' "$h"
}
run(){ # run $1=HOME $2=prompt -> stdout (empty means "allowed through")
  HOME="$1" TMUX_PANE='%99' bash "$HOOK" <<<"$(jq -n --arg p "$2" '{prompt:$p}')"
}
blocked(){ printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

echo "== the ONE blockable shape: file gone + mailbox empty =="
h="$(newhome)"
out="$(run "$h" "/agent-msg feature-2 testself/$MSG reply")"
ok "spent pointer with empty mailbox is blocked" '[ -n "$out" ] && blocked "$out"'
ok "block reason names the file" 'printf "%s" "$out" | jq -re .reason | grep -q "d030826e"'
rm -rf "$h"

echo "== fail-open: a LIVE message must never be suppressed =="
h="$(newhome)"; printf 'body' > "$h/.claude/agent-inbox/testself/$MSG"
out="$(run "$h" "/agent-msg feature-2 testself/$MSG reply")"
ok "existing message file passes through" '[ -z "$out" ]'
rm -rf "$h"

echo "== fail-open: spent pointer but OTHER mail queued (the drain rule earns its turn) =="
h="$(newhome)"; printf 'body' > "$h/.claude/agent-inbox/testself/aaaa1111.feature-3.req.txt"
out="$(run "$h" "/agent-msg feature-2 testself/$MSG reply")"
ok "spent pointer masking real mail passes through" '[ -z "$out" ]'
rm -rf "$h"

echo "== fail-open: not our mailbox =="
h="$(newhome)"
out="$(run "$h" "/agent-msg feature-2 someoneelse/$MSG reply")"
ok "pointer addressed to another agent passes through" '[ -z "$out" ]'
rm -rf "$h"

echo "== fail-open: self not resolvable =="
h="$(newhome)"; rm -f "$h/.claude/running-agents/testself.123"
out="$(run "$h" "/agent-msg feature-2 testself/$MSG reply")"
ok "unregistered self passes through" '[ -z "$out" ]'
rm -rf "$h"

echo "== fail-open: prompt shapes that are not the machine-generated nudge =="
h="$(newhome)"
for p in \
  "how do I fix the watcher?" \
  "/agent-msg drain" \
  "/agent-msg feature-2 testself/$MSG reply and then do something else" \
  "/agent-msg feature-2 ../../etc/passwd" \
  "/agent-msg feature-2 testself/$MSG bogus-keyword" \
  "please run /agent-msg feature-2 testself/$MSG reply" \
  "/agent-send feature-2 hello"
do
  out="$(run "$h" "$p")"
  ok "passes through: ${p:0:46}" '[ -z "$out" ]'
done
rm -rf "$h"

echo "== fail-open: no prompt field / empty payload =="
h="$(newhome)"
out="$(HOME="$h" TMUX_PANE='%99' bash "$HOOK" <<<'{}')"
ok "payload without .prompt passes through" '[ -z "$out" ]'
out="$(HOME="$h" TMUX_PANE='%99' bash "$HOOK" </dev/null)"
ok "empty payload passes through" '[ -z "$out" ]'
rm -rf "$h"

echo "== blocking clears the busy marker (no Stop hook will run to clear it) =="
# A blocked prompt runs no turn, so drain-inbox.sh's Stop-time clear never fires. Left
# set, the marker would mark us falsely busy for a full stale window and peers would
# suppress live nudges to us — trading a saved turn for a delivery regression.
h="$(newhome)"; : > "$h/.claude/agent-busy/testself"
out="$(run "$h" "/agent-msg feature-2 testself/$MSG reply")"
ok "prompt was blocked (precondition)" 'blocked "$out"'
sleep 3   # the clear is deferred past the unordered mark-busy.sh hook in the same group
ok "busy marker cleared after a block" '[ ! -f "$h/.claude/agent-busy/testself" ]'
rm -rf "$h"

echo "== a PASSED-THROUGH prompt must leave the busy marker alone =="
h="$(newhome)"; printf 'body' > "$h/.claude/agent-inbox/testself/$MSG"; : > "$h/.claude/agent-busy/testself"
run "$h" "/agent-msg feature-2 testself/$MSG reply" >/dev/null
sleep 3
ok "busy marker survives a live delivery" '[ -f "$h/.claude/agent-busy/testself" ]'
rm -rf "$h"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
