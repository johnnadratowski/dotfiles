#!/bin/bash
# .claude/scripts/statusline-fleet.sh
#
# ccstatusline `custom-command` widget: prints "🤖 N 💤 M" = N live fleet agents, M of
# them idle (live and NOT busy). Idle agents are the fanout/compact candidates the
# team lead acts on. Silent (exit 0, no output) when no agents are registered — so
# it's harmless in a non-fleet repo.
#
# There was an "⚠ N errored" count here, off the StopFailure marker written by
# mark-error.sh. Both are gone: Claude Code's own retry (300 attempts under
# CLAUDE_CODE_RETRY_WATCHDOG) is what survives a rate limit now, so the marker had
# no writer and the count could only ever render 0.
#
# Live   = registry entry ~/.claude/running-agents/<name>.<pid> whose pid is alive
#          (and, for a tmux-pane token, whose pane still exists — via _fleet.sh when
#          available; plain pid liveness otherwise).
# Busy   = a fresh busy-marker ~/.claude/agent-busy/<name> touched within
#          WORKFLOW_BUSY_STALE_MIN minutes (default 30)
#          (same definition as agent-fanout.sh's is_busy).

cat >/dev/null 2>&1 || true   # drain the StatusJSON ccstatusline pipes in (unused)

registry="$HOME/.claude/running-agents"
[ -d "$registry" ] || exit 0

# Prefer the shared liveness helper (matches the fleet's own definition); fall back to
# a plain pid check if it isn't reachable from here.
root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$root" ] && [ -r "$root/.claude/scripts/_fleet.sh" ]; then
  # shellcheck disable=SC1090
  . "$root/.claude/scripts/_fleet.sh"
fi

is_alive() {  # pid token
  if command -v fleet_alive >/dev/null 2>&1; then fleet_alive "$1" "$2"; else kill -0 "$1" 2>/dev/null; fi
}
is_busy() {  # canonical predicate when sourced, inline fallback otherwise (same shape as is_alive)
  if command -v fleet_busy >/dev/null 2>&1; then fleet_busy "$1"
  else local m="$HOME/.claude/agent-busy/$1"; [ -f "$m" ] && [ -n "$(find "$m" -mmin "-${WORKFLOW_BUSY_STALE_MIN:-30}" 2>/dev/null)" ]; fi
}

shopt -s nullglob
live=0 idle=0
for f in "$registry"/*; do
  [ -f "$f" ] || continue
  bn="$(basename "$f")"
  name="${bn%.*}"; pid="${bn##*.}"
  case "$pid" in ''|*[!0-9]*) continue ;; esac   # skip non-pid sidecars
  token="$(cat "$f" 2>/dev/null)"
  if is_alive "$pid" "$token"; then
    live=$((live + 1))
    is_busy "$name" || idle=$((idle + 1))
  fi
done

if [ "$live" -gt 0 ]; then
  printf '🤖 %s 💤 %s' "$live" "$idle"
fi
exit 0
