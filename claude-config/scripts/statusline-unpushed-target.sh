#!/bin/bash
# statusline-unpushed-target.sh
#
# ccstatusline `custom-command` widget: prints "o:⇡N⇣M" for the PR TARGET branch itself —
# how far the local target ref has drifted from its published counterpart in both
# directions. Partner to statusline-behind-target.sh's "⇣ N", which measures THIS branch
# against the target. Silent (exit 0, no output) when this isn't a git repo or no target
# is configured — harmless anywhere.
#
# Target = WORKFLOW_PR_TARGET_BRANCH (default `master`). Read-only and offline: it
# compares the local target ref against the CACHED origin/<target> ref. Nothing here
# fetches, so both counts are only as fresh as the last fetch.

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

# origin/<base> may not exist yet (fresh clone, never pushed). Say so rather than
# vanishing — an absent widget is indistinguishable from "in sync".
if ! git rev-parse --verify "origin/$base" >/dev/null 2>&1; then
  printf 'o:?'
  exit 0
fi

# BOTH directions, always printed. `⇡` = the local target ref has commits origin does
# not (unpushed). `⇣` = origin has commits the local target ref does not (someone else
# pushed; this clone needs a fetch). The second direction matters because nothing in the
# fleet auto-fetches, so a stale local target was previously invisible — an agent could
# sit arbitrarily far behind a published master with nothing on screen to say so.
ahead=$(git rev-list --count "origin/$base..$base" 2>/dev/null)
behind=$(git rev-list --count "$base..origin/$base" 2>/dev/null)
printf 'o:⇡%s⇣%s' "${ahead:-0}" "${behind:-0}"
exit 0
