#!/bin/bash
# StopFailure hook: this turn ended on an API ERROR (rate_limit 429 / overloaded 529 /
# auth / billing / server_error / …) — NOT a normal Stop. Two side-effects:
#
#   1. Write an error marker (~/.claude/agent-error/<name>, category inside) so the
#      fleet can SEE a stuck/errored agent (statusline + agent-fanout status show ⚠ ERR)
#      instead of it masquerading as a healthy idle agent.
#   2. CLEAR the busy marker — a stopped agent is NOT busy. This is the functional fix:
#      a StopFailure leaves claude idle at its prompt (alive), but the stale busy marker
#      made peers' agent-send SKIP the live nudge ("busy → drain delivers at its Stop").
#      A stopped agent never gets a next Stop on its own, so the message stranded. With
#      busy cleared, the next nudge LANDS at the idle prompt and the agent recovers.
#
# StopFailure output/exit are ignored by Claude Code, so this is side-effect only.
# The error marker is cleared on recovery: normal Stop (drain-inbox.sh) + activity
# (mark-busy.sh) + SessionEnd (unregister-agent.sh). (DX — fleet error indicator.)
#
# Keyed by agent name (mirrors the registry); shared ~/.claude so peers can read it.
# Silent, always exits 0.

set -u
payload="$(cat 2>/dev/null || true)"

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0

# Self-id via the identity token (pane in tmux, else cwd-based) — works headless.
hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
# Resolve the fleet helpers from EITHER home (canonical, symlinked from dotfiles) or the
# repo sibling. The sibling form also resolves correctly once this hook itself lives in
# ~/.claude/hooks, so one chain covers every layout.
for _fleet_candidate in "$HOME/.claude/scripts/_fleet.sh" "$hook_dir/../scripts/_fleet.sh"; do
  [ -r "$_fleet_candidate" ] && { . "$_fleet_candidate"; break; }
done
self_name="$(fleet_find_self "$reg" 2>/dev/null || true)"
[ -n "$self_name" ] || exit 0

# Best-effort error category from the payload (the exact field is not a stable contract,
# so try the likely keys and fall back to "error"); sanitized to one short token.
cat=""
if command -v jq >/dev/null 2>&1 && [ -n "$payload" ]; then
  cat="$(printf '%s' "$payload" | jq -r '.error // .error_type // .error_status // .reason // .stop_failure // empty' 2>/dev/null | head -1)"
fi
cat="$(printf '%s' "${cat:-error}" | tr -cd 'A-Za-z0-9_-' | cut -c1-32)"
[ -n "$cat" ] || cat="error"

mkdir -p "$HOME/.claude/agent-error"
printf '%s\n' "$cat" > "$HOME/.claude/agent-error/$self_name"
rm -f "$HOME/.claude/agent-busy/$self_name"   # a stopped agent is NOT busy — see header
exit 0
