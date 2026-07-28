#!/bin/bash
# UserPromptSubmit hook: drop an `/agent-msg` prompt that is provably a no-op.
#
# WHY THIS EXISTS
# A peer's nudge is `tmux send-keys` of `/agent-msg <sender> <recipient>/<file> [kw]`.
# If it lands while the recipient is mid-turn, Claude Code BUFFERS the keystrokes and
# submits them at the next prompt boundary. By then the first delivery to actually run
# has consumed (deleted) the message file, so every buffered copy is a pointer to a file
# that no longer exists.
#
# The senders already re-check existence immediately before send-keys
# (inbox-watcher.sh's pre-send check; drain-inbox.sh enumerates the real mailbox). Neither
# can close THIS window: the file existed at send time and was consumed afterwards. The
# check has to happen where the prompt is consumed, which is here.
#
# Without this, each spent pointer costs a full turn — load the agent-msg skill, run the
# script, get exit 3, run `drain`, find nothing, end. Observed 4x in one session for a
# single message (1 agent-send nudge + 3 watcher re-nudges, all buffered against a busy
# pane). That is the entire cost being removed; no message is delivered differently.
#
# WHAT IT DOES *NOT* DO
# It never suppresses a prompt whose file still exists, and never when OTHER mail is
# waiting — in that case the agent-msg skill's "on exit 3, always drain" rule is doing
# real work (a stale pointer correlates with mail sitting behind it), so the turn is
# earned and the prompt goes through untouched.
#
# FAIL OPEN, ALWAYS. Every uncertainty — no jq, unparseable prompt, self not resolved,
# a recipient that isn't us — exits 0 and lets the prompt through. The only path that
# blocks is: exact `/agent-msg` form + the named file is gone + our mailbox is empty.
# A bug here must degrade to today's behaviour (a wasted turn), never to a swallowed
# prompt.
#
# Self-test: .claude/hooks/suppress-spent-agent-msg.test.sh

set -u

# NOTE ON THE EARLY EXITS BELOW: the payload/prompt/registry checks are FAST-PATH exits,
# not correctness guards — this runs on every prompt submit, so it bails before sourcing
# helpers or scanning directories. Each is subsumed by a later check (an empty prompt
# fails the regex; a missing registry yields an empty self_name that cannot match the
# regex-guaranteed-non-empty recipient), so deleting one changes cost, never the outcome,
# and no test can falsify it. Do not mistake them for the guards that decide.
payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

prompt="$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null)" || exit 0
[ -n "$prompt" ] || exit 0

# Strict form only — exactly what agent-send.sh / inbox-watcher.sh type. Anything else
# (a human typing /agent-msg by hand, extra prose, a different verb like `drain`) falls
# through untouched.
prompt="${prompt#"${prompt%%[![:space:]]*}"}"   # ltrim
if [[ ! "$prompt" =~ ^/agent-msg[[:space:]]+[A-Za-z0-9_-]+[[:space:]]+([A-Za-z0-9_-]+)/([A-Za-z0-9._-]+\.txt)([[:space:]]+(reply|followup))?[[:space:]]*$ ]]; then
  exit 0
fi
recipient="${BASH_REMATCH[1]}"
fname="${BASH_REMATCH[2]}"

# The pointer names its own recipient. Only ever act on our OWN mailbox: acting on a path
# addressed to someone else would be reasoning about a mailbox we don't own.
reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0
hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
# Resolve the fleet helpers from EITHER home (canonical, symlinked from dotfiles) or the
# repo sibling. The sibling form also resolves correctly once this hook itself lives in
# ~/.claude/hooks, so one chain covers every layout.
for _fleet_candidate in "$HOME/.claude/scripts/_fleet.sh" "$hook_dir/../scripts/_fleet.sh"; do
  [ -r "$_fleet_candidate" ] && { . "$_fleet_candidate"; break; }
done
command -v fleet_find_self >/dev/null 2>&1 || exit 0
self_name="$(fleet_find_self "$reg" 2>/dev/null || true)"
# No separate "did self resolve?" check: the regex guarantees $recipient is non-empty, so
# an unresolved (empty) $self_name can never match and this same line rejects it. A guard
# whose failure is unreachable is one no test can falsify — see the note above `queued`.
[ "$recipient" = "$self_name" ] || exit 0

mailbox="$HOME/.claude/agent-inbox/$self_name"

# ONE predicate decides everything: is the mailbox empty?
#
# It covers both reasons to pass a prompt through, which is why there is no separate
# "is the named file still live?" check — such a check cannot fail independently, and a
# branch no test can falsify is precisely the vacuous guard this file is trying to avoid:
#   - the named file is LIVE  -> it is itself a *.txt in this mailbox -> not empty -> pass
#   - the named file is spent but OTHER mail is queued -> not empty -> pass, and the
#     agent-msg skill's "on exit 3, always drain" rule collects it (turn well spent)
# Only "nothing at all is queued" makes the prompt a provable no-op.
#
# Enumerate the mailbox rather than trusting the pointer — the pointer is the one thing
# already known to be unreliable here.
shopt -s nullglob
queued=( "$mailbox"/*.txt )
[ "${#queued[@]}" -gt 0 ] && exit 0

# Provably a no-op: nothing is queued, so this pointer can only be spent. Suppress it
# before it reaches the model.
#
# Blocking means no turn runs, so no Stop hook fires — and Stop is what clears the busy
# marker that mark-busy.sh sets for this very prompt. Left set, it would mark us falsely
# busy for a full WORKFLOW_BUSY_STALE_MIN window, during which peers suppress their live
# nudges to us: a delivery regression traded for a saved turn. So clear it. The clear is
# deferred to a detached subshell because hooks in a UserPromptSubmit group are not
# ordered — a bare rm here can race mark-busy.sh's write and lose.
( sleep 2; rm -f "$HOME/.claude/agent-busy/$self_name" ) >/dev/null 2>&1 &

jq -n --arg f "$fname" '{
  "decision": "block",
  "reason": ("Suppressed a spent /agent-msg pointer (" + $f + "): the message was already delivered and the inbox is empty. No action needed.")
}'
exit 0
