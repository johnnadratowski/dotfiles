#!/bin/sh
# claude-autoscroll.sh [pane-id]
#
# Flip Claude Code's Auto-scroll for the claude session in a tmux pane, by typing
# `/config autoScrollEnabled=<v>` into it.
#
# WHY TYPE IT RATHER THAN EDIT THE FILE. `autoScrollEnabled` lives in
# ~/.claude/settings.json, but a running session reads settings into memory at startup and
# nothing in the binary watches that file (unlike keybindings.json, which the docs say is
# re-read live). An external edit is therefore a NEXT-LAUNCH change. `/config key=value` is
# Claude Code's own supported shorthand, so it updates the live session AND writes the file.
#
# THE COST OF THAT CHOICE: a slash command typed while a turn is running is QUEUED, so on a
# busy lead the flip lands when the current turn ends, not instantly. There is no key or
# action that toggles this setting -- the full action list carries no autoscroll verb -- so
# queueing is the price of it applying live at all.
#
# Press it with an EMPTY prompt. This appends to whatever is in the input box; it does not
# clear it first, because the clear would be an unverified keystroke sent into a live agent.
#
# The file is the shared record of the last flip anywhere. Two sessions each keep their own
# in-memory value, so a toggle in one does not move the other -- it only decides which way
# the NEXT toggle goes. Self-correcting: every flip rewrites the file.

set -eu

pane=${1:-}
[ -n "$pane" ] || pane=$(tmux display-message -p '#{pane_id}')

cmd=$(tmux display-message -t "$pane" -p '#{pane_current_command}' 2>/dev/null || true)
# A claude pane reports the VERSION as its command name (the binary is
# ~/.local/share/claude/versions/<semver>), not `claude`. Accept the launcher names too.
case "$cmd" in
[0-9]*.[0-9]*.[0-9]*|claude|node|bun) ;;
*) tmux display-message "autoscroll: pane is running '$cmd', not claude"; exit 0 ;;
esac

settings="$HOME/.claude/settings.json"
cur=true
if [ -r "$settings" ]; then
	cur=$(python3 -c "
import json
try: print('true' if json.load(open('$settings')).get('autoScrollEnabled', True) else 'false')
except Exception: print('true')
" 2>/dev/null || echo true)
fi

if [ "$cur" = true ]; then new=false; else new=true; fi

tmux send-keys -t "$pane" "/config autoScrollEnabled=$new" Enter
tmux display-message "autoscroll -> $new"
exit 0
