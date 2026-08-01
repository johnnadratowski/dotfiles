#!/bin/bash
# ~/.claude/scripts/statusline-todo.sh (dotfiles)
#
# ccstatusline `custom-command` widget: prints "▸ <ID> <ID> …" = every in-progress
# Linear issue THIS worktree is working. Task tracking moved to Linear, which has no
# cheap local state to read, so the `/todo` skill mirrors the in-progress issue(s) to
# a gitignored per-worktree file, `.claude/current-work` — one `<ID>\t<url>` line each
# (`start` appends, `done`/`cancel` clears). Each <ID> is wrapped in an OSC 8 terminal
# hyperlink to its Linear URL, so it's ⌘-clickable in iTerm2 (OSC 8 opens on ⌘-click).
# Requires the widget's `preserveColors: true` (so ccstatusline keeps the escape) and
# tmux `terminal-features *:hyperlinks` (so tmux forwards it).
# Prints "▸ <none>" whenever nothing is in progress in THIS worktree — whether the
# mirror is empty OR absent. Silent only in a repo that does not use `/todo` at all.

cat >/dev/null 2>&1 || true   # drain the StatusJSON ccstatusline pipes in (unused)

root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
# The path is a knob (WORKFLOW_CURRENT_WORK, default .claude/current-work) so this widget
# knows nothing about any particular project — which is what let it move out of the product
# repo into dotfiles. Resolved relative to the worktree root, because the file is per-lane
# state: each worktree has its own in-progress set.
cw="$root/${WORKFLOW_CURRENT_WORK:-.claude/current-work}"

# An ABSENT mirror used to exit silently, on the theory that "empty" and "absent" are
# distinct signals worth distinguishing. In practice they are not: the mirror is
# gitignored and per-worktree, so a fresh agent that has simply never run `/todo start`
# has no file, and the widget vanished for it — which is the SAME state as an agent that
# started and finished something ("empty"). Three of four agents showed nothing while one
# showed "<none>", for no reason a reader could act on. Both now render "<none>".
#
# The repo-level gate is what actually distinguishes a non-/todo repo: this script only
# exists in a repo that uses the skill, so reaching it at all means the widget belongs.
if [ ! -f "$cw" ]; then
  printf '▸ <none>'
  exit 0
fi

# Read "<ID>\t<url>" lines; tolerate an ID-only line (no URL ⇒ plain text, no link).
#
# ONLY the machine-readable head of the file. Agents also use this file to leave themselves
# resume context — feature-3 wrote a 60-line checkpoint under its pointer line before a
# restart, and the bar duly rendered `▸ FEAT-6 # -----------------------------------…`,
# eating the status line. So: blank and `#` lines are skipped, and the first line whose first
# field is not id-shaped ENDS the list — which makes prose-below-the-pointer a supported
# convention rather than a corruption. The agent panel's own status line
# (~/.claude/scripts/subagent-statusline.sh, in dotfiles) applies the same rule to the same
# file; keep the two in step.
ids=(); urls=()
# `|| [ -n "$id" ]` processes a final line with NO trailing newline. Without it `read`
# returns non-zero before the body runs and the whole file yields ZERO ids — the bar shows
# "<none>" with work in progress, which is the one failure mode worse than showing junk.
while IFS=$'\t' read -r id url || [ -n "$id" ]; do
  id="${id%$'\r'}"; url="${url%$'\r'}"          # tolerate a CRLF-authored file
  id="${id#"${id%%[![:space:]]*}"}"             # ...and an indented comment or prose line
  case "$id" in ''|'#'*) continue ;; esac
  # An id is short and has no whitespace; a sentence is neither.
  case "$id" in *[[:space:]]*) break ;; esac
  [ "${#id}" -le 24 ] || break
  ids+=("$id"); urls+=("$url")
done < "$cw"

# Mirror present but EMPTY ⇒ "▸ <none>" — deliberate, not a placeholder to optimize away.
# The widget stays visible so you can tell at a glance that this worktree has nothing in
# progress (the normal state after `block`/`done`/`cancel` removes the last line). That is
# a DIFFERENT signal from the mirror being ABSENT (handled above, silent), which means the
# repo may not use `/todo` at all — there, showing a widget would be noise.
[ ${#ids[@]} -gt 0 ] || { printf '▸ <none>'; exit 0; }

# OSC 8 hyperlink, byte-identical to ccstatusline's own `link` widget: ESC ] 8 ;; <url>
# ST  <label>  ESC ] 8 ;; ST  (ST = ESC \). ST — NOT BEL — is the terminator ccstatusline's
# width-stripper (getVisibleWidth) treats as zero visible width; with BEL it counts the URL
# bytes and truncates the widget mid-URL. iTerm2 honors it on ⌘-click.
emit_id() {  # emit_id <id> <url>
  if [ -n "$2" ]; then
    printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$2" "$1"
  else
    printf '%s' "$1"
  fi
}

printf '▸ '
sep=""; i=0
for id in "${ids[@]}"; do
  printf '%s' "$sep"
  emit_id "$id" "${urls[$i]}"
  sep=" "; i=$((i + 1))
done
