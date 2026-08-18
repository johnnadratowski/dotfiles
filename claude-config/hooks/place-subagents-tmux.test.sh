#!/bin/bash
# Tests for place-subagents-tmux.sh — specifically WHICH PANE IT CALLS THE RESIDENT AGENT.
#
# WHY THIS EXISTS, AND WHY THE NEGATIVE CASE IS THE POINT.
#
# The hook fires on every `after-split-window` on this machine, anywhere, and its one
# decision is "does this window hold a fleet agent". Answer yes and it relocates every live
# subagent pane under that agent. So a FALSE POSITIVE is not a cosmetic mis-label: it drags
# four running teammates out of `g-subagents` and into whatever window the split happened in.
#
# That is exactly what shipped. The predicate was `case "$(ps -o command= …)" in *claude*)`
# — a substring test against the whole command line — and every agent's scratchpad on this
# machine lives under `/private/tmp/claude-501/…`. Running anything out of a scratchpad in a
# fresh pane therefore identified that pane as an agent. Measured twice, reproducibly, with
# four teammate panes moved into a throwaway session both times.
#
# A suite that only asserted "a real claude pane IS the resident agent" passed against that
# bug and would pass against it again — the defect was never a missing yes, it was a yes
# given to everything. So the negative cases are asserted first-class here, and the one that
# reproduces the actual failure (a path CONTAINING the substring) is named as such.
#
# Driven against `claude_exe`, the string half of the decision, which the hook exposes by
# being sourceable with PLACE_SUBAGENTS_LIB=1. That seam is what makes the negative case
# testable at all: fabricating a *process* whose executable path is a lie is not something a
# test can do, while fabricating the path it would report is trivial.

set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/place-subagents-tmux.sh"
[ -f "$HOOK" ] || { echo "FATAL: place-subagents-tmux.sh not found at $HOOK"; exit 1; }

pass=0; fail=0
yes() { # yes <label> <executable path> — must be recognised as a claude session
  if claude_exe "$2"; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s: [%s] should be a claude executable\n' "$1" "$2"; fi
}
no() {  # no <label> <executable path> — must NOT be
  if claude_exe "$2"; then
    fail=$((fail+1)); printf '  FAIL %s: [%s] must NOT be a claude executable\n' "$1" "$2"
  else pass=$((pass+1)); printf '  ok   %s\n' "$1"; fi
}

# Sourcing must not run the hook. If the lib guard ever moves below a side effect this
# assertion is what notices: the log file is the first thing the acting half touches.
LOGF="$HOME/.claude/debug/place-subagents.log"
before="$(wc -c < "$LOGF" 2>/dev/null || echo 0)"
# shellcheck disable=SC1090
PLACE_SUBAGENTS_LIB=1 . "$HOOK"
after="$(wc -c < "$LOGF" 2>/dev/null || echo 0)"
if [ "$before" = "$after" ]; then pass=$((pass+1)); printf '  ok   %s\n' "sourcing the hook runs no side effect"
else fail=$((fail+1)); printf '  FAIL sourcing the hook wrote to the log (%s -> %s bytes)\n' "$before" "$after"; fi

echo "-- the two ways this fleet launches claude"
# The LEAD: team-boot types a bare `claude`, so the executable is the launcher on PATH.
yes "the bare launcher on PATH" "claude"
yes "…and the launcher by absolute path" "/opt/homebrew/bin/claude"
# EVERY TEAMMATE: the launcher execs a versioned binary whose BASENAME IS THE VERSION. This
# is why a basename test alone would have missed every teammate in the fleet — and why
# `pane_current_command` on a teammate pane reads `2.1.233` rather than `claude`.
yes "the versioned binary a teammate actually runs" \
    "/Users/john/.local/share/claude/versions/2.1.233"
yes "…at any version" "/Users/john/.local/share/claude/versions/2.0.9-rc1"

echo "-- THE REGRESSION: a command that merely MENTIONS claude is not a claude process"
# The exact shape that moved four live teammates. An agent's scratchpad path contains
# `claude-501`, so every agent on this machine could trigger it with an ordinary split.
no "a binary under a claude-501 scratchpath" \
   "/private/tmp/claude-501/-Users-john-git-goals-onchain/abc123/scratchpad/fakebin/monocle"
no "…a plain interpreter running a script from one" "/bin/bash"
no "…and the scratchpath's own directory name is not enough" "/private/tmp/claude-501/x/sleep"
# The substring appearing in a DIFFERENT position is the same class of mistake.
no "a project directory called claude" "/Users/john/git/claude-tools/bin/tool"
no "…a sibling binary whose name merely starts with it" "/usr/local/bin/claudia"
no "…and one whose name merely ends with it" "/usr/local/bin/notclaude"

echo "-- the ordinary panes this hook must leave alone"
no "a shell" "/bin/zsh"
no "an editor" "/opt/homebrew/bin/nvim"
no "monocle" "/Users/john/.local/bin/monocle"
no "the TUI's launcher" "/Users/john/.local/bin/uv"
no "nothing at all — an unreadable ps must not become a yes" ""

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
