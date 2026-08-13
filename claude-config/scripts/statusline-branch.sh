#!/bin/bash
# .claude/scripts/statusline-branch.sh
#
# ccstatusline `custom-command` widget: the git branch, capped at 12 columns —
# "⎇ feat/DX-jn-cc-021-statusline-identity" renders as "⎇ feat/..ntity".
#
# REPLACES the built-in `git-branch` widget, whose maxWidth truncates from the TAIL. On a
# laptop the bar has no room for a full branch name, and a tail-truncated one loses exactly
# the half that identifies the work — every branch here opens with the same few prefixes.
# Keeping both ends keeps the name recognisable at a glance.
#
# 12 = 5 + ".." + 5, the shape asked for. It is a HARD cap, not a hint: this widget sits
# left of the flex separator, so overrunning it does not truncate the branch, it pushes the
# fields to its right off the end of the line.
#
# A detached HEAD prints its short sha rather than the built-in's "no git", which was a
# plain lie in a repo — worktree churn detaches HEAD routinely.

max=12
head_keep=5
tail_keep=5

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '⎇ no git'; exit 0; }

b="$(git symbolic-ref --short HEAD 2>/dev/null)"
[ -n "$b" ] || b="$(git rev-parse --short HEAD 2>/dev/null)"
[ -n "$b" ] || { printf '⎇ no git'; exit 0; }

if [ "${#b}" -gt "$max" ]; then
	b="${b:0:$head_keep}..${b: -$tail_keep}"
fi

printf '⎇ %s' "$b"
exit 0
