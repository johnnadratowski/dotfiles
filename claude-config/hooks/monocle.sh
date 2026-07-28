#!/bin/bash
# Resilient wrapper for the Monocle review binary, so the four Monocle hooks in the committed
# settings.json NEVER break a machine that doesn't have Monocle installed (a new engineer, CI, any
# non-author clone). The hooks used to hardcode an absolute path (/Users/<author>/bin/monocle),
# which exits 127 ("command not found") on every edit / turn / plan-mode toggle for everyone else.
#
# Resolution order (first hit wins): MONOCLE_BIN env override → `monocle` on PATH → $HOME/bin/monocle
# (the common install location — hook subprocesses often don't inherit an interactive PATH, so we
# probe it explicitly). If none resolve, exit 0 — a machine without Monocle simply gets no review
# hooks, silently. The four hooks are all notification-style (enter-plan / exit-plan / mark-activity /
# on-stop); exit 0 is the correct no-op for every one (a non-zero PreToolUse could otherwise block).
set -u
bin="${MONOCLE_BIN:-}"
[ -n "$bin" ] || bin="$(command -v monocle 2>/dev/null || true)"
[ -n "$bin" ] || { [ -x "$HOME/bin/monocle" ] && bin="$HOME/bin/monocle"; }
[ -n "$bin" ] || exit 0
exec "$bin" "$@"
