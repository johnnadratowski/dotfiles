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

# Set the tmux PANE title — this is the right granularity since two
# Claudes can share a window via splits. Pane titles are per-pane,
# always visible at least via `tmux display-message`, and become visible
# in pane borders when the user sets `pane-border-status top|bottom`.
tmux select-pane -t "$TMUX_PANE" -T "$name" 2>/dev/null || true

# Also rename the tmux window for convenience (most windows are single-
# pane, so the window name in the tab list will track too). Disable
# automatic-rename first so it sticks against foreground-process churn.
# For multi-pane windows, the window name will reflect the most recent
# pane to rename — that's expected; pane titles are the source of truth.
if window_id=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null); then
  tmux set-window-option -t "$window_id" automatic-rename off 2>/dev/null || true
  tmux rename-window -t "$window_id" "$name" 2>/dev/null || true
fi

# Tell Claude itself to take on this name via its built-in /rename command.
# The hook fires before Claude is ready to accept input, so schedule a
# detached send-keys after a short delay. nohup + & + redirected fds means
# this survives the hook's exit cleanly.
nohup bash -c "
  sleep 2
  tmux send-keys -t '$TMUX_PANE' -l '/rename $name'
  tmux send-keys -t '$TMUX_PANE' Enter
" </dev/null >/dev/null 2>&1 &

exit 0
