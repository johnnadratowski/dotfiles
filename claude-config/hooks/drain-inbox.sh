#!/bin/bash
# Stop hook: drain this agent's per-recipient inbox.
#
# Inter-agent messages are delivered two ways (see .claude/docs/inter-agent-comms.md):
#   1. A best-effort `tmux send-keys` nudge of `/agent-msg ...` — low latency,
#      but lost if the recipient is mid-turn / in a permission prompt / scrolled.
#   2. A durable file under ~/.claude/agent-inbox/<recipient>/ — this drain.
#
# This hook runs at the end of every turn. If messages addressed to THIS agent
# are sitting undrained, it blocks the stop and feeds the model the exact
# `/agent-msg` commands to process them. A lost nudge therefore means a delayed
# message, never a lost one.
#
# Loop-safe two ways: (a) the agent-msg skill deletes each file it processes, so
# the next Stop finds an empty mailbox and exits silently; (b) we never re-block
# when `stop_hook_active` is already set — a still-pending message just waits for
# the next natural stop (or the send-keys nudge).
#
# Always exits 0. Silent (no output) in the common empty-mailbox case.
#
# Self-test (drains the CURRENT agent's mailbox):
#   printf '%s' hi > ~/.claude/agent-inbox/$(basename "$(grep -rl "$TMUX_PANE" ~/.claude/running-agents)" | sed 's/\.[0-9]*$//')/x.peer.req.txt
#   echo '{}' | bash .claude/hooks/drain-inbox.sh

set -u

stdin_payload=$(cat 2>/dev/null || true)

# NOTE: the stop_hook_active re-block guard moved BELOW, after the busy-marker clear.
# It used to early-exit HERE, before the clear — so a continuation Stop (the one that
# follows a drain-induced re-block) left the busy marker fresh+uncleared, marking the
# agent falsely busy for up to WORKFLOW_BUSY_STALE_MIN and making peers' agent-send skip its live nudge
# (self-perpetuating on agents processing drained messages). Clear first, then guard.

# Opportunistic GC: remove clearly-abandoned messages (default >7 days). They
# only pile up in mailboxes of agents that never drain (dead / old version) —
# an actively-draining agent empties its own box every turn. Conservative
# threshold so a legitimately-delayed message is never swept. Cheap on a tiny
# tree; runs on any Stop regardless of whether we have mail ourselves.
gc_days="${AGENT_INBOX_GC_DAYS:-7}"
find "$HOME/.claude/agent-inbox" -type f -name '*.txt' -mtime "+$gc_days" -delete 2>/dev/null || true
# GC expired/orphan delivery-claims (agent-msg.sh clears a claim on delivery; this backstops
# claims whose delivery path died). Same conservative threshold.
find "$HOME/.claude/agent-nudge-claim" -type f -mtime "+$gc_days" -delete 2>/dev/null || true

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0

# --- Discover self via the identity token (pane in tmux, else cwd-based) ---
# The drain itself needs NO tmux — it just emits /agent-msg lines into the Stop
# output — so it works headless (DX-jn-8-019).
shopt -s nullglob
hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
# Resolve the fleet helpers from EITHER home (canonical, symlinked from dotfiles) or the
# repo sibling. The sibling form also resolves correctly once this hook itself lives in
# ~/.claude/hooks, so one chain covers every layout.
for _fleet_candidate in "$HOME/.claude/scripts/_fleet.sh" "$hook_dir/../scripts/_fleet.sh"; do
  [ -r "$_fleet_candidate" ] && { . "$_fleet_candidate"; break; }
done
find_self() { fleet_find_self "$reg" 2>/dev/null; }
self_name="$(find_self || true)"
if [ -z "$self_name" ]; then
  # A drifted / missing self-entry would silently mute this drain (the whole
  # point of which is reliability). Repair it the same way agent-send does —
  # lazily, only when the scan came up empty — then retry the lookup.
  hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  [ -x "$hook_dir/register-agent.sh" ] && "$hook_dir/register-agent.sh" send-selfheal </dev/null >/dev/null 2>&1 || true
  self_name="$(find_self || true)"
fi
[ -n "$self_name" ] || exit 0

# Stop = turn ending = this agent is now idle. Clear the busy marker so peers'
# agent-send resumes nudging us live (set by mark-busy.sh on UserPromptSubmit).
# CRITICAL: this runs on EVERY Stop, INCLUDING a stop_hook_active continuation — the
# re-block guard below must not pre-empt it (see the NOTE above), or an agent that just
# processed a drained message stays falsely busy and peers suppress its live nudge.
rm -f "$HOME/.claude/agent-busy/$self_name"
rm -f "$HOME/.claude/agent-error/$self_name"   # a clean Stop = recovered from any prior StopFailure
rm -f "$HOME/.claude/agent-hold/$self_name"    # backstop clear of the Monocle-wait hold (DX-jn-8-031)

# Now that we've marked ourselves idle, guard against re-BLOCKING a Stop that is itself
# a Stop-hook continuation — infinite-drain-loop belt-and-suspenders.
if command -v jq >/dev/null 2>&1 && [ -n "$stdin_payload" ]; then
  if [ "$(printf '%s' "$stdin_payload" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    exit 0
  fi
fi

mailbox="$HOME/.claude/agent-inbox/$self_name"
[ -d "$mailbox" ] || exit 0

# Collect this mailbox's messages. nullglob (set above) means an EMPTY mailbox
# yields an empty array — crucially NOT a bare glob that would make the `ls`
# below fall back to listing the cwd (which would inject repo files as bogus
# messages and block every Stop). Guard on the array BEFORE running ls, then
# pass explicit paths so ls can only ever sort OUR files (oldest-first by
# mtime). Filenames are <uuid>.<sender>.<kind>.txt — no spaces/newlines.
msgs=( "$mailbox"/*.txt )
[ "${#msgs[@]}" -gt 0 ] || exit 0
pending="$(ls -1tr "${msgs[@]}" 2>/dev/null)"
[ -n "$pending" ] || exit 0

lines=""
n=0
while IFS= read -r path; do
  [ -f "$path" ] || continue
  fname="$(basename "$path")"   # <uuid>.<sender>.<kind>.txt
  # A FRESH delivery-claim means a live nudge (agent-send / inbox-watcher) already owns this
  # file — the buffered /agent-msg will deliver it, so don't ALSO inject it here (that double
  # is the "message file gone" duplicate). A STALE claim (>2min: nudge lost or a >2min turn)
  # is reclaimed — fall through and deliver. Never strands: worst case is a ≤2min delay.
  claim="$HOME/.claude/agent-nudge-claim/$fname"
  if [ -f "$claim" ] && [ -n "$(find "$claim" -mmin -2 2>/dev/null)" ]; then
    continue
  fi
  base="${fname%.txt}"
  kind="${base##*.}"            # req | rep | fwd
  rest="${base%.*}"             # <uuid>.<sender>
  sender="${rest#*.}"           # <sender> (uuid has no dots)
  case "$kind" in
    rep) kw=" reply" ;;
    fwd) kw=" followup" ;;
    *)   kw="" ;;
  esac
  n=$((n + 1))
  lines="${lines}  ${n}. /agent-msg ${sender} ${self_name}/${fname}${kw}"$'\n'
done <<< "$pending"

[ "$n" -gt 0 ] || exit 0

reason="You have ${n} undelivered peer-agent message(s) in your inbox (the live tmux nudge was lost or arrived mid-turn). Process each one NOW by invoking the agent-msg skill exactly as listed below — the skill prints the AGENT MESSAGE banner, reads & deletes the file, and replies when appropriate. Handle them oldest-first and do not skip any; each file stays in the inbox until the skill deletes it:
${lines}"

# Emit the Stop-hook block decision so the turn continues into message handling.
if command -v jq >/dev/null 2>&1; then
  jq -n --arg r "$reason" '{"decision":"block","reason":$r}'
else
  esc=${reason//\\/\\\\}; esc=${esc//\"/\\\"}; esc=${esc//$'\n'/\\n}
  printf '{"decision":"block","reason":"%s"}\n' "$esc"
fi
exit 0
