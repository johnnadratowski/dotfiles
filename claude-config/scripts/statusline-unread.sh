#!/bin/bash
# .claude/scripts/statusline-unread.sh
#
# ccstatusline `custom-command` widget: prints "📬 N" = count of undrained peer
# messages in THIS agent's mailbox (~/.claude/agent-inbox/<self>/). Silent (exit 0,
# no output) outside a fleet worktree, so it's harmless in non-fleet repos.
#
# Self is identified by matching the current worktree ($PWD) against the
# ~/.claude/agents/<name>.cwd sidecars that register-agent.sh writes — this works
# whether the agent is tmux-backed or headless (it does not depend on $TMUX_PANE,
# which the statusLine subprocess may not inherit).

cat >/dev/null 2>&1 || true   # drain the StatusJSON ccstatusline pipes in (unused)

shopt -s nullglob
self=""
for f in "$HOME"/.claude/agents/*.cwd; do
  [ "$(cat "$f" 2>/dev/null)" = "$PWD" ] && { self="$(basename "$f" .cwd)"; break; }
done
[ -n "$self" ] || exit 0

mailbox="$HOME/.claude/agent-inbox/$self"
# In a fleet (self identified), always show the count — including 0 — so the indicator
# is a persistent gauge rather than appearing only when messages arrive.
if [ -d "$mailbox" ]; then
  n=$(find "$mailbox" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
else
  n=0
fi
printf '📬 %s' "${n:-0}"
exit 0
