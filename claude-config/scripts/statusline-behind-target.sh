#!/bin/bash
# statusline-behind-target.sh
#
# ccstatusline `custom-command` widget: prints "⇣ N" = commits this branch is behind the
# PR target branch (time to sync down). Silent (exit 0, no output) when this isn't a git
# repo or no target is configured — harmless in non-fleet repos.
#
# Target = WORKFLOW_PR_TARGET_BRANCH, default `master`: the branch a lane syncs DOWN from
# and opens PRs UP to, so it is what a lane measures itself against. NB: this is NOT the
# per-agent recorded branch in ~/.claude/agents/<name> — that is the agent's OWN branch,
# which would always give "behind 0".

cat >/dev/null 2>&1 || true   # drain the StatusJSON ccstatusline pipes in (unused)

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

base=""
if [ -f "$root/.claude/scripts/_config.sh" ]; then
  # Source _config.sh (not workflow.config directly) so the per-clone override in
  # workflow.config.local is honoured, and so the documented default applies when
  # neither file sets the value.
  # shellcheck disable=SC1090
  base="$(. "$root/.claude/scripts/_config.sh" 2>/dev/null; printf '%s' "${WORKFLOW_PR_TARGET_BRANCH:-master}")"
fi
[ -n "$base" ] || exit 0

git rev-parse --verify "$base" >/dev/null 2>&1 || exit 0
behind=$(git rev-list --count "HEAD..$base" 2>/dev/null)

# ALWAYS print in a fleet repo, including "⇣0". Hiding at zero made the widget
# ambiguous: a missing "⇣" could mean "in sync" OR "the check didn't run" (not a
# git repo, no base configured, ref missing), and those need opposite reactions.
# A visible ⇣0 is a positive assertion that the comparison ran and came back clean.
# Non-fleet repos still hide entirely — the `[ -n "$base" ]` gate above exits first.
printf '⇣%s' "${behind:-0}"
exit 0
