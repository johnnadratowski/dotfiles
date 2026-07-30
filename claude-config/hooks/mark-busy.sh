#!/bin/bash
# UserPromptSubmit + PreToolUse hook: mark this agent BUSY.
#
# UserPromptSubmit marks the turn START; PreToolUse re-touches the marker on
# every tool call so it stays FRESH through turns that never had a prompt
# submit at all — background-task notifications and Stop-hook continuations
# start turns without UserPromptSubmit, and were invisible to the idle-guard.
#
# WHO READS THIS. `fleet_busy` (_fleet.sh), and through it:
#   - fleet-layout.sh's `down` verb, which is IDLE-GATED — it refuses to stop an
#     agent that is mid-turn. This is the load-bearing consumer: delete the marker
#     and `down` reads every agent as idle and kills one that is working.
#   - agent-fanout.sh's `restart` / `compact` skip lists, and `status`.
# The marker's ORIGINAL reader — a peer's agent-send, gating the live tmux nudge —
# died with the mailbox transport. The marker did not: idleness is still the thing
# every destructive fleet verb gates on.
#
# Keyed by agent name (mirrors the registry). Shared ~/.claude so other tools can
# read it. Silent, always exits 0. A missing marker means "treat as idle".

set -u
cat >/dev/null 2>&1 || true   # drain the hook payload on stdin (unused)

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0

# Self-id via the identity token (pane in tmux, else cwd-based) — works headless (DX-jn-8-019).
hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
# Resolve the fleet helpers from EITHER home (canonical, symlinked from dotfiles) or the
# repo sibling. The sibling form also resolves correctly once this hook itself lives in
# ~/.claude/hooks, so one chain covers every layout.
for _fleet_candidate in "$HOME/.claude/scripts/_fleet.sh" "$hook_dir/../scripts/_fleet.sh"; do
  [ -r "$_fleet_candidate" ] && { . "$_fleet_candidate"; break; }
done
self_name="$(fleet_find_self "$reg" 2>/dev/null || true)"
if [ -n "$self_name" ]; then
  mkdir -p "$HOME/.claude/agent-busy"
  : > "$HOME/.claude/agent-busy/$self_name"
fi

# There was also a HOLD marker here (DX-jn-8-031), set while this agent entered the
# blocking Monocle verdict wait — a single long tool call that emits no further
# PreToolUse, so the busy marker went stale mid-review and peers re-nudged every 30s
# for the whole human review. Its only readers were agent-send and the inbox-watcher.
# Both are gone, nothing reads ~/.claude/agent-hold, and write-only state is worse
# than no state: it looks like a live signal to the next reader of this file.
exit 0
