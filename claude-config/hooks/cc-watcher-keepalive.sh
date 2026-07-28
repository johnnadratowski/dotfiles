#!/bin/bash
# SessionStart + Stop hook — COORDINATOR ONLY: keep the fleet's inbox-watcher daemon
# alive. The watcher (scripts/inbox-watcher.sh) is the SINGLE engine that nudges parked
# messages + errored/rate-limited agents (script-only, no model calls); the coordinator
# owns its lifecycle. `inbox-watcher.sh start` is single-instance + idempotent — a no-op
# if one is already running, a restart if the daemon died — so running it on the cc's
# SessionStart (initial launch) AND every Stop (self-heal) keeps exactly one instance up.
#
# This REPLACES cc-resume-errored.sh: the errored-agent nudge SWEEP moved INTO the watcher
# (its continuous poll strictly supersets a turn-gated Stop sweep), so the hook no longer
# duplicates that logic — it just ensures the daemon is running.
#
# No-op for non-coordinator agents (runs in every agent's hook chains but gates on role ==
# coordinator; one cc per machine → one watcher). Needs nothing but the script; silent,
# always exits 0 (never blocks the coordinator's turn).

set -u
cat >/dev/null 2>&1 || true   # drain hook stdin

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || exit 0

hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
# Resolve the fleet helpers from EITHER home (canonical, symlinked from dotfiles) or the
# repo sibling. The sibling form also resolves correctly once this hook itself lives in
# ~/.claude/hooks, so one chain covers every layout.
for _fleet_candidate in "$HOME/.claude/scripts/_fleet.sh" "$hook_dir/../scripts/_fleet.sh"; do
  [ -r "$_fleet_candidate" ] && { . "$_fleet_candidate"; break; }
done
self_name="$(fleet_find_self "$reg" 2>/dev/null || true)"
[ -n "$self_name" ] || exit 0   # not yet registered (SessionStart race) — a later Stop gets it

# Coordinator-only. Role: explicit override file, else name pattern (keep in sync with
# resolve_role()/role_of()/statusline-role.sh).
role=""
[ -f "$HOME/.claude/agents/$self_name.role" ] && role="$(tr -dc 'A-Za-z0-9_-' < "$HOME/.claude/agents/$self_name.role")"
if [ -z "$role" ]; then
  case "$self_name" in
    cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) role=coordinator ;;
    *) role=other ;;
  esac
fi
[ "$role" = coordinator ] || exit 0

# Keep exactly one watcher alive (single-instance + idempotent; no-op if already running).
watcher="$HOME/.claude/scripts/inbox-watcher.sh"
[ -x "$watcher" ] || watcher="$hook_dir/../scripts/inbox-watcher.sh"
"$watcher" start >/dev/null 2>&1 || true
exit 0
