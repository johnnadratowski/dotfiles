#!/bin/bash
# agent-identity.sh — resolve THIS worktree's fleet identity (name + role) and emit the
# human-facing tag prepended to agent-posted PR comments (DX-jn-8-023).
#
# Self is identified by matching $PWD against the ~/.claude/agents/<name>.cwd sidecars
# (tmux-independent — same mechanism as statusline-role.sh / agent-fanout.sh self_name).
# Role: a ~/.claude/agents/<name>.role override file, else derived from the name pattern.
#
#   ⚠ KEEP THE ROLE PATTERNS IN SYNC with resolve_role() (hooks/register-agent.sh),
#     role_of() (agent-fanout.sh), and statusline-role.sh — drift means an agent's
#     tag disagrees with how the fleet classifies it.
#
# Usage:
#   agent-identity.sh name   # agent name  (empty + exit 1 when not a registered agent)
#   agent-identity.sh role   # team-lead | review | test | feature  (exit 1 if no name)
#   agent-identity.sh tag    # the comment prefix — ALWAYS exit 0, callers just prepend it:
#                            #   registered → **[AGENT RESPONSE · <name> / <role>]**
#                            #   otherwise  → **[AGENT RESPONSE]**

self_name() {
  local f
  shopt -s nullglob
  for f in "$HOME"/.claude/agents/*.cwd; do
    [ "$(cat "$f" 2>/dev/null)" = "$PWD" ] && { basename "$f" .cwd; return 0; }
  done
  return 1
}

role_of() {  # KEEP IN SYNC — see header.
  local name="$1"
  if [ -f "$HOME/.claude/agents/$name.role" ]; then
    tr -dc 'A-Za-z0-9_-' < "$HOME/.claude/agents/$name.role"
    return 0
  fi
  # ONE classifier, not a third drifted copy: this block used to carry its own patterns
  # (missing tester/reviewer/planner entirely) with a `feature` fallback — so it called a
  # tester a lane agent. Delegate to fleet_resolve_role, the same source register-agent.sh
  # uses; the minimal fallback below only exists for a machine with no _fleet.sh at all.
  command -v fleet_resolve_role >/dev/null 2>&1 || . "$HOME/.claude/scripts/_fleet.sh" 2>/dev/null || true
  if command -v fleet_resolve_role >/dev/null 2>&1; then
    fleet_resolve_role "$name"
  else
    case "$name" in
      team-lead|*-team-lead|team-lead-*)                               echo team-lead ;;
      cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) echo team-lead ;;
      test|tester|*-test|*-test-*|test-*|tester-*|*-tester)            echo test ;;
      review|reviewer|rev|rev-*|*-rev|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*|planner|plan-*|*-reviewer|*-planner) echo review ;;
      *-[0-9]|*-[0-9][0-9]|*-[0-9][0-9][0-9])                          echo feature ;;
      *)                                                               echo other ;;
    esac
  fi
}

case "${1:-tag}" in
  name)
    name="$(self_name)" || exit 1
    printf '%s\n' "$name"
    ;;
  role)
    name="$(self_name)" || exit 1
    printf '%s\n' "$(role_of "$name")"
    ;;
  tag)
    if name="$(self_name)"; then
      printf '**[AGENT RESPONSE · %s / %s]**\n' "$name" "$(role_of "$name")"
    else
      printf '**[AGENT RESPONSE]**\n'
    fi
    ;;
  *)
    echo "usage: agent-identity.sh {name|role|tag}" >&2
    exit 2
    ;;
esac
