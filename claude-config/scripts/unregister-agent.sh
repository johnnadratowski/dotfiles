#!/bin/bash
# SessionEnd hook — removes this Claude session from ~/.claude/running-agents.
# Best-effort cleanup; senders also prune stale entries on send.

set -u

cat >/dev/null 2>&1 || true

# Hook runs as a direct child of claude, so $PPID is the claude pid.
# Remove any registry file whose filename ends in .<PPID>.
shopt -s nullglob 2>/dev/null || true
for f in "$HOME/.claude/running-agents/"*."$PPID"; do
  rm -f "$f"
done

exit 0
