#!/bin/bash
# SessionStart hook — registers this Claude session in ~/.claude/running-agents
# and renames the tmux window to the agent name.
#
# Registry: ~/.claude/running-agents/<name>.<pid>  (content: $TMUX_PANE)
# Name:     current git branch (sanitized), fallback to cwd basename.

set -u

# Drain hook stdin (we don't need it).
cat >/dev/null 2>&1 || true

# Not inside tmux? Nothing to do.
if [ -z "${TMUX_PANE:-}" ]; then
  exit 0
fi

# --- Determine agent name ---
name=""
if branch=$(git -C "$PWD" branch --show-current 2>/dev/null); then
  name="$branch"
fi
if [ -z "$name" ]; then
  name="$(basename "$PWD")"
fi
# Sanitize: keep alnum, dash, underscore. Collapse repeats. No leading/trailing dashes.
name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')
if [ -z "$name" ]; then
  name="agent"
fi

mkdir -p "$HOME/.claude/running-agents"

# Overwrite policy: remove any prior <name>.* entries.
# shellcheck disable=SC2086
rm -f "$HOME/.claude/running-agents/$name".*

# Write registry file: filename carries pid, content carries pane id.
printf '%s\n' "$TMUX_PANE" > "$HOME/.claude/running-agents/$name.$PPID"

# Rename the tmux window so the tab shows the agent name.
if window_id=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null); then
  tmux rename-window -t "$window_id" "$name" 2>/dev/null || true
fi

exit 0
