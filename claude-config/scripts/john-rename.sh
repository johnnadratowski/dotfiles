#!/bin/bash
# Rename this Claude agent. Updates both the registry file and the tmux window.
#
# Usage: john-rename.sh <new-name>

set -u

[ "$#" -lt 1 ] && { echo "usage: $(basename "$0") <new-name>" >&2; exit 2; }
new_name="$1"

if [ -z "${TMUX_PANE:-}" ]; then
  echo "not running inside tmux — \$TMUX_PANE unset; cannot identify self" >&2
  exit 1
fi

# Sanitize new name same as register-agent.sh
new_name=$(printf '%s' "$new_name" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')
[ -z "$new_name" ] && { echo "new name sanitized to empty string — pick something with alnum chars" >&2; exit 2; }

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || { echo "no registry at $reg" >&2; exit 1; }

# Discover self via $TMUX_PANE
self_file=""
shopt -s nullglob
for f in "$reg"/*; do
  [ -f "$f" ] || continue
  if [ "$(cat "$f" 2>/dev/null)" = "$TMUX_PANE" ]; then
    self_file="$f"
    break
  fi
done
if [ -z "$self_file" ]; then
  echo "this agent isn't registered" >&2
  exit 1
fi

old_name=$(basename "$self_file")
old_name="${old_name%.*}"
pid="$(basename "$self_file")"
pid="${pid##*.}"

if [ "$old_name" = "$new_name" ]; then
  echo "already named '$new_name' — nothing to do"
  exit 0
fi

# Wipe any conflicting <new_name>.* entries (overwrite policy)
for f in "$reg/$new_name".*; do
  [ -f "$f" ] && rm -f "$f"
done

mv "$self_file" "$reg/$new_name.$pid"

# Set the tmux pane title (right granularity — survives split-pane setups).
tmux select-pane -t "$TMUX_PANE" -T "$new_name" 2>/dev/null || true

# Also rename the window for convenience on single-pane windows.
if window_id=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null); then
  tmux set-window-option -t "$window_id" automatic-rename off 2>/dev/null || true
  tmux rename-window -t "$window_id" "$new_name" 2>/dev/null || true
fi

# Also rename the Claude session itself via its built-in /rename slash
# command. We're inside the running session, so just type it into our
# own prompt — it'll fire on the next turn.
tmux send-keys -t "$TMUX_PANE" -l "/rename $new_name"
tmux send-keys -t "$TMUX_PANE" Enter

echo "renamed: $old_name -> $new_name (both tmux window and Claude session)"
