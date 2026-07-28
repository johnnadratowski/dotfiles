#!/bin/bash
# Broadcast a message to ALL live peer agents on this machine.
#
# Usage:
#   agent-broadcast.sh --stdin [--followup] [--exclude a,b] [--dry-run] <<'BODY'
#   ...body (no escaping needed)...
#   BODY
#
#   agent-broadcast.sh "<body>" [--followup] [--exclude a,b] [--dry-run]
#
# Sends the same body to every registered agent whose claude PID and tmux pane
# are still alive, except yourself and any --exclude names. Reuses agent-send.sh
# per recipient (durable per-recipient mailbox + nudge + drain), so delivery is
# the same at-least-once as a direct send. Prefer --stdin/heredoc for the body.
#
# A broadcast is high-blast-radius. The /agent-broadcast SKILL requires explicit
# user authorization before you invoke this — see .claude/skills/agent-broadcast.

set -u

usage() {
  cat >&2 <<'USAGE'
usage: agent-broadcast.sh --stdin [--followup] [--exclude a,b] [--dry-run]   # body on stdin (heredoc-safe)
       agent-broadcast.sh "<body>" [--followup] [--exclude a,b] [--dry-run]
USAGE
  exit 2
}

script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
send="$script_dir/agent-send.sh"
[ -x "$send" ] || { echo "agent-send.sh not found at $send" >&2; exit 1; }

body=""; have_body=0; use_stdin=0; followup=0; dry_run=0; exclude_csv=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stdin|-)   use_stdin=1 ;;
    --followup)  followup=1 ;;
    --dry-run)   dry_run=1 ;;
    --exclude)   shift; exclude_csv="${1:-}" ;;
    --exclude=*) exclude_csv="${1#--exclude=}" ;;
    --*)         echo "unknown flag: $1" >&2; usage ;;
    *)           if [ "$have_body" -eq 0 ]; then body="$1"; have_body=1
                 else echo "unexpected extra arg: $1" >&2; usage; fi ;;
  esac
  shift
done

if [ "$use_stdin" -eq 1 ]; then
  body="$(cat)"
elif [ "$have_body" -eq 0 ] && [ "$dry_run" -eq 0 ]; then
  echo "no message body (pass a quoted body, or --stdin with a heredoc)" >&2
  usage
fi

# Identity is tmux-optional (DX-jn-8-019); delivery is via agent-send (which itself
# degrades to the durable mailbox when tmux can't nudge).
fleet_helper="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/_fleet.sh"
# shellcheck disable=SC1090
[ -r "$fleet_helper" ] && . "$fleet_helper"
reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || { echo "no registry at $reg" >&2; exit 1; }

# --- self (so we never broadcast to ourselves) ---
shopt -s nullglob
self_name="$(fleet_find_self "$reg" 2>/dev/null || true)"

# --- exclude set: self + caller-supplied ---
is_excluded() {
  local name="$1"
  [ "$name" = "$self_name" ] && return 0
  local IFS=,; local e
  for e in $exclude_csv; do [ "$name" = "$e" ] && return 0; done
  return 1
}

# --- enumerate live peers (dedup by name; verify pid + pane) ---
recipients=()
seen=" "
for f in "$reg"/*; do
  [ -f "$f" ] || continue
  bn="$(basename "$f")"; name="${bn%.*}"; pid="${bn##*.}"; pane="$(cat "$f" 2>/dev/null)"
  case "$seen" in *" $name "*) continue ;; esac
  is_excluded "$name" && continue
  fleet_alive "$pid" "$pane" || continue
  recipients+=("$name"); seen="$seen$name "
done

if [ "${#recipients[@]}" -eq 0 ]; then
  echo "no live peers to broadcast to (self=${self_name:-?}, excluded='$exclude_csv')" >&2
  exit 1
fi

kindflag=""; [ "$followup" -eq 1 ] && kindflag="--followup"

if [ "$dry_run" -eq 1 ]; then
  echo "DRY RUN — would broadcast ${kindflag:-(request)} to ${#recipients[@]} peer(s): ${recipients[*]}"
  exit 0
fi

ok=0; failed=()
for peer in "${recipients[@]}"; do
  if printf '%s' "$body" | "$send" "$peer" --stdin $kindflag >/dev/null 2>/tmp/agent-bcast.$$.$peer; then
    ok=$((ok + 1)); echo "  -> $peer: sent"
  else
    failed+=("$peer"); echo "  -> $peer: FAILED ($(cat /tmp/agent-bcast.$$.$peer 2>/dev/null | head -1))"
  fi
  rm -f "/tmp/agent-bcast.$$.$peer"
done

echo "broadcast as ${self_name:-?}: $ok/${#recipients[@]} delivered${kindflag:+ ($kindflag)}${failed:+; failed: ${failed[*]}}"
[ "${#failed[@]}" -eq 0 ]
