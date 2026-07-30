#!/bin/bash
# SessionEnd hook — removes this Claude session from ~/.claude/running-agents.
# Best-effort cleanup; senders also prune stale entries on send (PID-not-alive
# check), so this hook missing or failing isn't load-bearing.

set -u

cat >/dev/null 2>&1 || true

# Match our registry entry by IDENTITY TOKEN first (tmux pane, else cwd token —
# the same key registration uses), falling back to the .<PPID> filename match.
# PPID alone is the least-reliable signal (hooks may run under an intermediate
# shell — see register-agent.sh's PID ladder), and trusting only it made this
# cleanup silently no-op, accumulating stale registry twins.
shopt -s nullglob 2>/dev/null || true
hook_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# shellcheck disable=SC1090
# Resolve the fleet helpers from EITHER home (canonical, symlinked from dotfiles) or the
# repo sibling. The sibling form also resolves correctly once this hook itself lives in
# ~/.claude/hooks, so one chain covers every layout.
for _fleet_candidate in "$HOME/.claude/scripts/_fleet.sh" "$hook_dir/../scripts/_fleet.sh"; do
  [ -r "$_fleet_candidate" ] && { . "$_fleet_candidate"; break; }
done
tok=""
type fleet_self_token >/dev/null 2>&1 && tok="$(fleet_self_token)"
for f in "$HOME/.claude/running-agents/"*; do
  [ -f "$f" ] || continue
  bn="$(basename "$f")"
  match=0
  [ -n "$tok" ] && [ "$(cat "$f" 2>/dev/null)" = "$tok" ] && match=1
  [ "${bn##*.}" = "$PPID" ] && match=1
  [ "$match" = 1 ] || continue
  rm -f "$HOME/.claude/agent-busy/${bn%.*}"    # clear the busy marker too
  rm -f "$f"
done

# --- Non-blocking work-loss warning on session end (best-effort) ---
# The most relevant exit-time loss surface: ending a session with uncommitted
# changes, or with commits that never reached the branch this lane ships to, gets
# no warning anywhere else. Surface it (stderr) so nothing is silently stranded.
# Always exits 0; any git/array edge case is swallowed.
#
# This read WORKFLOW_BASE_BRANCH, which was DELETED with the base-* abstraction —
# so `base` was always empty and this entire warning silently never fired. The
# signal is now "not yet in the branch we open PRs against", i.e. the remote
# target: a lane ships through a PR, so local master proves nothing.
repo="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
if [ -n "$repo" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  base=""
  cfg="$repo/.claude/scripts/_config.sh"
  [ -r "$cfg" ] && base="$( . "$cfg" >/dev/null 2>&1; printf '%s' "${WORKFLOW_PR_TARGET_BRANCH:-}" )"
  # Prefer the remote ref; fall back to the local branch if origin isn't fetched.
  if [ -n "$base" ] && git -C "$repo" rev-parse --verify "origin/$base" >/dev/null 2>&1; then
    base="origin/$base"
  fi
  warns=()
  dirty="$(git -C "$repo" status --porcelain 2>/dev/null || true)"
  [ -n "$dirty" ] && warns+=("uncommitted changes ($(printf '%s\n' "$dirty" | grep -c . || true) file(s))")
  branch="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  if [ -n "$base" ] && [ -n "$branch" ] && [ "$branch" != "$base" ] \
     && git -C "$repo" rev-parse --verify "$base" >/dev/null 2>&1; then
    ahead="$(git -C "$repo" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null \
      && warns+=("$ahead commit(s) on '$branch' not yet in '$base' (unshipped)")
  fi
  if [ "${#warns[@]}" -gt 0 ]; then
    {
      printf '\n[session-end] ⚠ possible unsaved work in %s:\n' "$repo"
      for w in "${warns[@]}"; do printf '  - %s\n' "$w"; done
      printf '  Commit, then ship with /open-pr, so nothing is lost.\n'
    } >&2
  fi
fi

exit 0
