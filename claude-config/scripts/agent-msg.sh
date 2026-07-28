#!/bin/bash
# Backing script for the /agent-msg receiver skill: atomically read + delete a peer
# message from THIS agent's inbox (so the skill never needs ad-hoc `cat … && rm` — the
# `rm` prompts), AND emit the AGENT MESSAGE banner itself. Emitting the banner here
# (rather than having the model reproduce a ~40-line ASCII template from the skill on
# every call) is what keeps the skill body small: the skill is injected + re-billed on
# every invocation, including spent-duplicate no-ops, so moving fixed output into the
# script directly cuts per-call cost (DX-jn-8-032). Only ever touches ~/.claude/agent-inbox/.
#
#   agent-msg.sh <relpath>   Emit the banner + body of ~/.claude/agent-inbox/<relpath>, then
#                            delete it. Sender + kind are parsed from the filename
#                            (<uuid>.<sender>.<kind>.txt), so the banner needs no extra args.
#   agent-msg.sh drain       Same, for EVERY message in THIS agent's mailbox, oldest-first.
#                            Use when the Stop-drain lists several at once.

set -u
inbox="$HOME/.claude/agent-inbox"
claims="$HOME/.claude/agent-nudge-claim"   # delivery-claim markers (see agent-send.sh / drain-inbox.sh)

RULE='════════════════════════════════════════════════════════════════'

# emit_banner <sender> <kind> — the human-facing header. kind ∈ req|rep|fwd. A double
# rule (top) marks a peer message vs human input; the type + reply-expectation come from
# the kind, so no width-fragile boxed alignment (Unicode byte-vs-column math) is needed.
emit_banner() {
  local sender="$1" kind="$2" type
  case "$kind" in
    rep) type='REPLY  (integrate only — no auto-response)' ;;
    fwd) type='FOLLOWUP  (a response IS expected)' ;;
    *)   type='REQUEST' ;;
  esac
  printf '%s\n  AGENT MESSAGE — from: %s   ·   %s\n%s\n\n' "$RULE" "$sender" "$type" "$RULE"
}

# emit_one <path> — banner + body + trailing blank, then delete the file + release its claim.
emit_one() {
  local p="$1" fn base kind rest sender
  fn="$(basename "$p")"; base="${fn%.txt}"; kind="${base##*.}"; rest="${base%.*}"; sender="${rest#*.}"
  emit_banner "$sender" "$kind"
  cat "$p"; printf '\n'
  rm -f "$p"; rm -f "$claims/$fn"   # delivered → release the delivery-claim
}

case "${1:-}" in
  drain)
    reg="$HOME/.claude/running-agents"
    shopt -s nullglob
    # Self-id via the shared identity-token helper (tmux pane OR cwd token) so drain works
    # headless too — matching ${TMUX_PANE:-} directly broke headless agents (DX-jn-8-019 parity).
    fleet_helper="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/_fleet.sh"
    # shellcheck disable=SC1090
    [ -r "$fleet_helper" ] && . "$fleet_helper"
    self="$(fleet_find_self "$reg" 2>/dev/null || true)"
    [ -n "$self" ] || { echo "not registered (can't find own mailbox)"; exit 1; }
    mb="$inbox/$self"; [ -d "$mb" ] || { echo "(empty mailbox)"; exit 0; }
    msgs=( "$mb"/*.txt ); [ "${#msgs[@]}" -gt 0 ] || { echo "(empty mailbox)"; exit 0; }
    while IFS= read -r p; do
      [ -f "$p" ] || continue   # consumed by a live nudge between glob + now → skip
      emit_one "$p"
    done < <(ls -1tr "${msgs[@]}")
    ;;
  ""|-h|--help)
    echo "usage: agent-msg.sh <relpath> | drain" >&2; exit 2;;
  *)
    rel="$1"
    case "$rel" in *..*) echo "refusing path containing '..': $rel" >&2; exit 2;; esac
    p="$inbox/$rel"
    # Gone already = a spent duplicate nudge (the drain or an earlier /agent-msg delivered it).
    # Release any orphan claim and signal exit 3 so the skill ends the turn SILENTLY (no banner).
    [ -f "$p" ] || { rm -f "$claims/$(basename "$rel")" 2>/dev/null; echo "message file gone — duplicate delivery? ($rel)" >&2; exit 3; }
    rp="$(cd "$(dirname "$p")" 2>/dev/null && pwd)/$(basename "$p")"
    case "$rp" in "$inbox"/*) ;; *) echo "refusing path outside inbox: $rp" >&2; exit 2;; esac
    emit_one "$p"
    ;;
esac
