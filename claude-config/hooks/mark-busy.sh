#!/bin/bash
# UserPromptSubmit + PreToolUse hook: mark this agent BUSY.
#
# UserPromptSubmit marks the turn START; PreToolUse re-touches the marker on
# every tool call so it stays FRESH through turns that never had a prompt
# submit at all — background-task notifications and Stop-hook continuations
# start turns without UserPromptSubmit, and were invisible to the idle-guard
# (senders nudged a working agent; the buffered nudge always loses to the
# Stop-drain and replays as a duplicate).
#
# A peer's agent-send reads this marker and SKIPS the live tmux nudge when the
# target is busy — the target's Stop-drain (drain-inbox.sh) will deliver the
# staged message at the end of its current turn anyway, so the nudge would only
# buffer and replay as a duplicate. Marker is cleared on Stop (drain-inbox.sh)
# and SessionEnd (unregister-agent.sh).
#
# Keyed by agent name (mirrors the registry). Shared ~/.claude so peers can read
# it. Silent, always exits 0. A missing marker just means "treat as idle" — a
# safe degradation (worst case: a duplicate nudge, which the agent-msg file-gone
# guard absorbs).

set -u
payload="$(cat 2>/dev/null || true)"   # tool-call / prompt JSON on stdin

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
  rm -f "$HOME/.claude/agent-error/$self_name"   # activity = recovered from any prior StopFailure

  # HOLD marker (DX-jn-8-031): the Monocle verdict wait is a SINGLE long tool call
  # (mcp__monocle__get_feedback with wait=true) that emits no further PreToolUse, so the
  # busy marker above goes stale after 5m and peers + the inbox-watcher start re-nudging a
  # message every 30s for the whole human review. While THIS agent is entering that
  # blocking wait, publish a hold so agent-send + the watcher suppress nudges entirely
  # (the message stays durably staged and drains ONCE at the next Stop). Set on the
  # get_feedback(wait) PreToolUse; ANY other tool call — or a UserPromptSubmit, whose
  # payload has no tool_name — clears it (the wait is over). Stop (drain-inbox) and
  # SessionEnd (unregister-agent) clear it too as backstops.
  # Anchor on the tool_name FIELD (not a bare substring): a loose grep for the tool name
  # anywhere in the blob false-positives when a DIFFERENT tool's input carries the string —
  # e.g. an Edit to THIS hook / the comms doc whose text contains it, or an agent-send body
  # quoting it — spuriously holding for one tool window. The field-anchored match + the
  # wait:true gate (so a non-blocking get_feedback doesn't hold) removes that class.
  hold="$HOME/.claude/agent-hold/$self_name"
  if printf '%s' "$payload" | grep -Eq '"tool_name"[[:space:]]*:[[:space:]]*"mcp__monocle__get_feedback"' \
     && printf '%s' "$payload" | grep -Eq '"wait"[[:space:]]*:[[:space:]]*true'; then
    mkdir -p "$HOME/.claude/agent-hold"
    : > "$hold"
  else
    rm -f "$hold"
  fi
fi
exit 0
