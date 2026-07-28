#!/bin/bash
# Rename this Claude agent. Updates both the registry file and the tmux window.
#
# Usage: agent-rename.sh <new-name>

set -u

[ "$#" -lt 1 ] && { echo "usage: $(basename "$0") <new-name>" >&2; exit 2; }
new_name="$1"

# Identity is tmux-optional (DX-jn-8-019): the registry/branch/mailbox rename works
# headless; only the tmux title/window + /rename keystroke below need tmux.
fleet_helper="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/_fleet.sh"
# shellcheck disable=SC1090
[ -r "$fleet_helper" ] && . "$fleet_helper"

# Self-heal the registry first (idempotent fast-path no-op if already
# correct). Defends against the case where SessionStart didn't fire on
# `claude --resume` and the existing entry is stale.
hook_dir="$(cd "$(dirname "$0")/../hooks" 2>/dev/null && pwd)"
if [ -x "$hook_dir/register-agent.sh" ]; then
  "$hook_dir/register-agent.sh" rename-selfheal </dev/null >/dev/null 2>&1 || true
fi

# Sanitize new name same as register-agent.sh
new_name=$(printf '%s' "$new_name" | tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')
[ -z "$new_name" ] && { echo "new name sanitized to empty string — pick something with alnum chars" >&2; exit 2; }

reg="$HOME/.claude/running-agents"
[ -d "$reg" ] || { echo "no registry at $reg" >&2; exit 1; }

# Discover self via the identity token (pane in tmux, else cwd-based)
shopt -s nullglob
old_name="$(fleet_find_self "$reg" 2>/dev/null || true)"
if [ -z "$old_name" ]; then
  echo "this agent isn't registered" >&2
  exit 1
fi
self_files=( "$reg/$old_name".* )
self_file="${self_files[0]}"
pid="$(basename "$self_file")"
pid="${pid##*.}"

if [ "$old_name" = "$new_name" ]; then
  echo "already named '$new_name' — nothing to do"
  exit 0
fi

# Wipe any conflicting <new_name>.* entries (overwrite policy)
for f in "$reg/$new_name".*; do
  [ -f "$f" ] && rm -f "$f"
done

mv "$self_file" "$reg/$new_name.$pid"

# --- Rename the base branch + persistent base-branch file ---
# The registry file at ~/.claude/agents/<name> records the agent's
# "home" git branch. Move it to the new name, and try to rename the
# local git branch to match.
agents_dir="$HOME/.claude/agents"
mkdir -p "$agents_dir"
base_branch=""
if [ -f "$agents_dir/$old_name" ]; then
  base_branch=$(cat "$agents_dir/$old_name" 2>/dev/null)
fi

git_rename_result="no-op"
record_branch="$new_name"   # what ~/.claude/agents/<new_name> will record (must be a REAL branch)
current_branch=""
if [ -n "$base_branch" ] && git -C "$PWD" rev-parse --verify "$base_branch" >/dev/null 2>&1; then
  # The recorded base branch exists locally — try to rename it.
  if git -C "$PWD" branch -m "$base_branch" "$new_name" 2>/dev/null; then
    git_rename_result="renamed git branch $base_branch -> $new_name"
  else
    git_rename_result="git branch rename failed ($base_branch -> $new_name); branch may already exist or be checked out elsewhere"
    record_branch="$base_branch"   # rename failed — keep recording the branch that actually exists
  fi
else
  # No recorded base — fall back to renaming whatever we're currently on.
  current_branch=$(git -C "$PWD" branch --show-current 2>/dev/null)
  if [ -n "$current_branch" ] && [ "$current_branch" != "$new_name" ]; then
    if git -C "$PWD" branch -m "$new_name" 2>/dev/null; then
      git_rename_result="renamed current git branch $current_branch -> $new_name"
    else
      git_rename_result="git branch rename failed ($current_branch -> $new_name); branch may already exist"
      record_branch="$current_branch"
    fi
  fi
fi

# Persist the base-branch record under the new agent name. On a FAILED git
# rename this records the branch that actually exists — recording $new_name
# unconditionally made every future SessionStart recommend checking out a
# branch that was never created.
rm -f "$agents_dir/$old_name"
printf '%s\n' "$record_branch" > "$agents_dir/$new_name"

# Migrate the name-keyed SIDECARS too. These live beside the base file as
# ~/.claude/agents/<name>.<ext> — currently `.role` (role override) and `.cwd`
# (cwd→self identity for the statusline widgets and fleet-layout's pane attribution).
# Leaving them under <old_name> means: a `.role` override stops classifying the agent
# after its next SessionStart (register-agent, agent-identity and statusline-role would
# re-derive from <new_name> and could pick the WRONG role), and `.cwd`-based self-id keeps
# showing the OLD name. The dotted glob never matches the extensionless base file (handled
# above), so this only moves sidecars.
for _sc in "$agents_dir/$old_name".*; do
  [ -f "$_sc" ] || continue
  mv -f "$_sc" "$agents_dir/$new_name.${_sc##*.}"
done

# --- Migrate the durable mailbox + clear the stale busy marker ---
# Both are keyed by agent name. After this rename our Stop-drain reads
# ~/.claude/agent-inbox/<new_name>/, so any message a peer already staged under
# <old_name> would be stranded and eventually GC'd UNREAD — the exact silent loss
# the durable mailbox exists to prevent. Move them so nothing INBOUND is lost.
# (uuid-prefixed filenames make collisions with existing <new_name> mail
# impossible.) Only reached because old_name != new_name (guarded above).
#
# We deliberately do NOT touch messages we SENT to other agents: those live under
# the RECIPIENT's inbox as <recipient>/<uuid>.<old_name>.<kind>.txt, may be
# unprocessed, and are the recipient's to drain — deleting them would lose
# information. They aren't under our own old mailbox dir, so this block can't.
inbox="$HOME/.claude/agent-inbox"
migrated=0
if [ -d "$inbox/$old_name" ]; then
  mkdir -p "$inbox/$new_name"
  # Migrate, then re-scan: a message racing into <old_name>/ between a single glob
  # expansion and the rmdir would be missed (stranded → GC'd unread). Re-pass a few
  # times so a straggler is caught; rmdir only succeeds once <old_name>/ is truly
  # empty, which is the loop's exit. Bounded (won't spin on a pathological flood).
  for _ in 1 2 3 4 5; do
    for m in "$inbox/$old_name"/*; do   # nullglob (set above) → skipped if empty
      [ -e "$m" ] || continue
      mv -f "$m" "$inbox/$new_name/" && migrated=$((migrated + 1))
    done
    rmdir "$inbox/$old_name" 2>/dev/null && break   # empty → removed → done
  done
fi
# Busy marker is ephemeral + name-keyed; mark-busy re-stamps <new_name> on our
# next tool call, so just clear the stale leftover.
rm -f "$HOME/.claude/agent-busy/$old_name"

# tmux cosmetics + the built-in /rename keystroke — only when tmux is drivable.
tmux_note="tmux unavailable — registry/branch/mailbox renamed; pane title + /rename skipped"
if fleet_tmux_ok 2>/dev/null; then
  # Set the tmux pane title (right granularity — survives split-pane setups).
  tmux select-pane -t "$TMUX_PANE" -T "$new_name" 2>/dev/null || true

  # Window names belong to fleet-layout.sh (DX-jn-cc-001), which recomputes each label
  # from all of a window's resident agents — so a renamed agent's window updates without
  # this pane stamping its own name over any co-tenants'.
  layout_sh="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/fleet-layout.sh"
  if [ -x "$layout_sh" ]; then
    "$layout_sh" name-windows >/dev/null 2>&1 && window_note="window relabeled" \
      || window_note="window relabel failed (non-fatal)"
  else
    window_note="fleet-layout.sh not found — window name unchanged"
  fi

  # Also rename the Claude session itself via its built-in /rename slash
  # command. We're inside the running session, so just type it into our
  # own prompt — it'll fire on the next turn.
  tmux send-keys -t "$TMUX_PANE" -l "/rename $new_name"
  tmux send-keys -t "$TMUX_PANE" Enter
  tmux_note="tmux + Claude session renamed ($window_note)"
fi

echo "renamed: $old_name -> $new_name (registry + branch; $tmux_note)"
echo "git: $git_rename_result"
echo "base branch tracked at: $agents_dir/$new_name"
echo "mailbox: migrated $migrated inbound message(s) $old_name -> $new_name; stale busy marker cleared (outbound messages to peers left untouched)"
