#!/bin/bash
# .claude/scripts/statusline-role.sh
#
# ccstatusline `custom-command` widget: prints a compact fleet-identity badge for THIS
# SESSION — "<role>·L<lane>" (e.g. "lead·L8", "feat·L2") so each terminal is identifiable at
# a glance. A session with no role of its own — a teammate, a Task-tool subagent — is badged
# with its own NAME instead ("goal-mach·L2"), because that is what distinguishes it from the
# lane it is running inside. Falls back to just the label when no lane is known. Silent
# (exit 0, no output) when this session isn't a registered fleet agent.
#
# Self is identified in three passes (tmux-independent).
#
# SESSION-EXACT pass first: the StatusJSON on stdin carries THIS session's transcript_path,
# and register-agent.sh recorded the same path in ~/.claude/agents/<name>.transcript, so the
# two match on a value that is unique per session. Every other pass keys on $PWD, and a cwd
# is NOT unique: a teammate or Task-tool subagent runs in its lane's worktree, so a
# $PWD-keyed badge pins to the LANE and a subagent console cannot say whose it is. Only this
# pass can tell the two apart.
#
# LIVE pass second: a name with a live-pid ~/.claude/running-agents entry whose
# ~/.claude/agents/<name>.cwd sidecar matches $PWD — crash debris (dead entries, stale
# sidecars) can never shadow a live registration (DX-jn-cc-007; a stale alphabetically-earlier
# sidecar once mislabeled the coordinator `feat`). Fallback: first $PWD-matching .cwd sidecar,
# which keeps headless / unregistered sessions working. Plain `kill -0` liveness only — this
# widget renders on every statusline tick and must stay dependency-free (no _fleet.sh source).
# Role comes from a ~/.claude/agents/<name>.role override, else the name pattern (matches
# resolve_role in register-agent.sh / role_of in agent-fanout.sh). Lane comes from
# the worktrees manifest resolved by fleet_manifest_path (worktree path → lane).

# No jq: this renders on every repaint, and a transcript path holds no escaped quotes.
transcript="$(cat 2>/dev/null |
  sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

shopt -s nullglob
self=""
if [ -n "$transcript" ]; then
  for f in "$HOME"/.claude/agents/*.transcript; do
    [ "$(cat "$f" 2>/dev/null)" = "$transcript" ] || continue
    self="$(basename "$f" .transcript)"; break
  done
fi
if [ -z "$self" ]; then
  for f in "$HOME"/.claude/running-agents/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"; pid="${base##*.}"; name="${base%.*}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$(cat "$HOME/.claude/agents/$name.cwd" 2>/dev/null)" = "$PWD" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    self="$name"; break
  done
fi
if [ -z "$self" ]; then
  for f in "$HOME"/.claude/agents/*.cwd; do
    [ "$(cat "$f" 2>/dev/null)" = "$PWD" ] && { self="$(basename "$f" .cwd)"; break; }
  done
fi
[ -n "$self" ] || exit 0

# Role: explicit override file, else derive from the name (keep patterns in sync with
# resolve_role()/role_of()).
role=""
[ -f "$HOME/.claude/agents/$self.role" ] && role="$(tr -dc 'A-Za-z0-9_-' < "$HOME/.claude/agents/$self.role")"
if [ -z "$role" ]; then
  # ONE classifier — this was the third drifted copy of the role patterns (it did not know
  # tester/reviewer/planner). Delegate to fleet_resolve_role; minimal fallback only for a
  # machine with no _fleet.sh.
  command -v fleet_resolve_role >/dev/null 2>&1 || . "$HOME/.claude/scripts/_fleet.sh" 2>/dev/null || true
  if command -v fleet_resolve_role >/dev/null 2>&1; then
    role="$(fleet_resolve_role "$self")"
  else
    case "$self" in
      team-lead|*-team-lead|team-lead-*)                               role=team-lead ;;
      cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) role=team-lead ;;
      test|tester|*-test|*-test-*|test-*|tester-*|*-tester)            role=test ;;
      review|reviewer|rev|rev-*|*-rev|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*|planner|plan-*|*-reviewer|*-planner) role=review ;;
      *-[0-9]|*-[0-9][0-9]|*-[0-9][0-9][0-9])                          role=feature ;;
      *)                                                               role=other ;;
    esac
  fi
fi

# Short label.
#
# `other` is the ABSENCE of a role, not a role, so printing it says nothing — and it is
# exactly what a teammate or Task-tool subagent resolves to, because its name is its task
# ("goal-machinery") rather than a lane shape. For those the NAME is the information: it is
# the only thing that says which of several sessions sharing this worktree you are looking
# at. Any other value is a real role (including a .role override) and is printed as-is.
case "$role" in
  team-lead) label=lead ;;
  feature)     label=feat ;;
  review)      label=rev ;;
  test)        label=test ;;
  other)       label="${self:0:9}" ;;
  *)           label="$role" ;;
esac

# Lane (best-effort; blank if unavailable). Two sources, in priority order:
#   1. config-driven — WORKFLOW_TODO_LANE / WORKFLOW_LANE in .claude/workflow.config[.local]
#   2. a path→lane worktrees manifest, whose location comes from the ONE resolver
#      (fleet_manifest_path in _fleet.sh — WORKFLOW_WORKTREES_MANIFEST, else derived from the
#      main clone's basename). No hardcoded per-project filename.
lane=""
root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$root" ] && [ -f "$root/.claude/workflow.config" ]; then
  # shellcheck disable=SC1090
  lane="$(. "$root/.claude/workflow.config" 2>/dev/null; . "$root/.claude/workflow.config.local" 2>/dev/null; printf '%s' "${WORKFLOW_TODO_LANE:-${WORKFLOW_LANE:-}}")"
fi
# The manifest read runs in a subshell of its OWN, entered UNCONDITIONALLY — the config subshell
# above is gated on workflow.config existing, and nesting this inside it would lose the lane in a
# repo that has no workflow.config (the resolver's whole promise is that a fresh project needs no
# config). The subshell sources the config (so a manifest path pinned there is visible — the
# statusline process env carries no WORKFLOW_* knobs) and _fleet.sh, both guarded; anything
# missing → blank lane. Display-only: fail-soft by design, never a broken statusline.
if [ -z "$lane" ] && [ -n "$root" ] && command -v python3 >/dev/null 2>&1; then
  lane="$(
    # ENV WINS. The config files assign with `=`, so sourcing them would clobber an exported
    # override — snapshot it first and re-apply after, exactly as _config.sh does.
    _env_mf="${WORKFLOW_WORKTREES_MANIFEST:-}"
    # shellcheck disable=SC1090,SC1091
    { [ -f "$root/.claude/workflow.config" ] && . "$root/.claude/workflow.config"; } 2>/dev/null
    # shellcheck disable=SC1090,SC1091
    { [ -f "$root/.claude/workflow.config.local" ] && . "$root/.claude/workflow.config.local"; } 2>/dev/null
    # shellcheck disable=SC1090,SC1091
    { [ -r "$(dirname "$0")/_fleet.sh" ] && . "$(dirname "$0")/_fleet.sh"; } 2>/dev/null
    [ -n "$_env_mf" ] && WORKFLOW_WORKTREES_MANIFEST="$_env_mf"
    command -v fleet_manifest_path >/dev/null 2>&1 || exit 0
    mf="$(fleet_manifest_path 2>/dev/null)" || exit 0
    [ -r "$mf" ] || exit 0
    python3 -c "import json
try:
    d=json.load(open('$mf'))
    print(next((w.get('lane','') for w in d.get('worktrees',[]) if w.get('path')=='$root'),''))
except Exception: pass" 2>/dev/null
  )"
fi

if [ -n "$lane" ]; then printf '%s·L%s' "$label" "$lane"; else printf '%s' "$label"; fi
exit 0
