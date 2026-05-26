#!/bin/bash
# Send a message to another registered Claude agent on this machine.
#
# Usage: john-send.sh <target> "<body>" [--reply]
#
# - Writes <body> to ~/.claude/agent-inbox/<uuid>.txt
# - Verifies target agent is alive (PID + tmux pane), pruning stale entries
# - Delivers "/john-msg <self> <uuid> [reply]" to target's tmux pane

set -u

usage() {
  echo "usage: $(basename "$0") <target> \"<body>\" [--reply]" >&2
  exit 2
}

[ "$#" -lt 2 ] && usage
target="$1"
body="$2"
flag="${3:-}"

is_reply=0
if [ "$flag" = "--reply" ] || [ "$flag" = "reply" ]; then
  is_reply=1
elif [ -n "$flag" ]; then
  echo "unknown 3rd arg: $flag (expected --reply)" >&2
  exit 2
fi

if [ -z "${TMUX_PANE:-}" ]; then
  echo "not running inside tmux — \$TMUX_PANE unset; cannot identify self" >&2
  exit 1
fi

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || { echo "no registry at $reg — is the SessionStart hook installed?" >&2; exit 1; }

# --- Discover self via $TMUX_PANE (own registry file's content matches own pane) ---
self_name=""
shopt -s nullglob
for f in "$reg"/*; do
  [ -f "$f" ] || continue
  if [ "$(cat "$f" 2>/dev/null)" = "$TMUX_PANE" ]; then
    bn="$(basename "$f")"
    self_name="${bn%.*}"
    break
  fi
done
if [ -z "$self_name" ]; then
  echo "this agent isn't registered (no entry in $reg matches \$TMUX_PANE=$TMUX_PANE)" >&2
  exit 1
fi

# --- Locate target ---
target_files=( "$reg/$target".* )
if [ "${#target_files[@]}" -eq 0 ]; then
  echo "no agent named '$target' (active agents: $(ls "$reg" 2>/dev/null | sed 's/\.[0-9]*$//' | sort -u | tr '\n' ' '))" >&2
  exit 1
fi

target_file="${target_files[0]}"
target_pid="${target_file##*.}"
target_pane="$(cat "$target_file" 2>/dev/null)"

# Liveness: claude pid alive?
if ! kill -0 "$target_pid" 2>/dev/null; then
  rm -f "$target_file"
  echo "agent '$target' (pid $target_pid) is gone — pruned stale registry entry" >&2
  exit 1
fi

# Liveness: tmux pane still around?
if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$target_pane"; then
  rm -f "$target_file"
  echo "agent '$target' tmux pane $target_pane is gone — pruned stale registry entry" >&2
  exit 1
fi

# --- Stage the message file ---
inbox="$HOME/.claude/agent-inbox"
mkdir -p "$inbox"
msg_id="$(uuidgen | tr -d - | tr 'A-Z' 'a-z')"
msg_file="$inbox/$msg_id.txt"
printf '%s' "$body" > "$msg_file"

# --- Deliver ---
slash="/john-msg $self_name $msg_id.txt"
if [ "$is_reply" -eq 1 ]; then
  slash="$slash reply"
fi

# -l = literal; sends the slash command into the target's prompt buffer.
tmux send-keys -t "$target_pane" -l "$slash"
tmux send-keys -t "$target_pane" Enter

echo "sent to $target as $self_name (msg_id=$msg_id.txt$([ "$is_reply" -eq 1 ] && echo ' [reply]'))"
