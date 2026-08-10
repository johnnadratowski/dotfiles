#!/bin/sh
# tmux-slam.sh <h|j|k|l> [pane-id]
#
# Maximise or minimise a pane along one axis:
#
#   k   grow this pane to full height      j   shrink it to the floor
#   l   grow this pane to full width       h   shrink it to the floor
#
# Nothing here restructures the window. Only pane sizes on the chosen axis change, so
# working the height can never alter a pane's width. An earlier version escalated to a
# zoom and then to `select-layout`, and that rewrote the whole geometry -- a half-width
# pane came back full width.
#
# tmux hands space freed by a shrink to the ADJACENT pane rather than to the group, so
# the shrink path redistributes explicitly.

set -eu

dir=${1:?usage: tmux-slam.sh <h|j|k|l> [pane-id]}
pane=${2:-}
[ -n "$pane" ] || pane=$(tmux display-message -p '#{pane_id}')

win=$(tmux display-message -t "$pane" -p '#{window_id}')
[ -n "$win" ] || exit 0   # pane went away between the keypress and here

q() { tmux display-message -t "$pane" -p "$1"; }

npanes=$(q '#{window_panes}')
[ "${npanes:-0}" -ge 2 ] || exit 0

case "$dir" in
k) axis=y; grow=1 ;;
j) axis=y; grow=0 ;;
l) axis=x; grow=1 ;;
h) axis=x; grow=0 ;;
*) echo "tmux-slam: unknown direction '$dir' (want h, j, k or l)" >&2; exit 2 ;;
esac

case "$axis" in
y) sz='#{pane_height}' ;;
x) sz='#{pane_width}' ;;
esac

# A zoomed pane has no meaningful size to set, so drop out of zoom first rather than
# letting the key look dead.
if [ "$(q '#{window_zoomed_flag}')" = 1 ]; then
	tmux resize-pane -t "$pane" -Z
fi

if [ "$grow" = 1 ]; then
	tmux resize-pane -t "$pane" "-$axis" 100% || true
	exit 0
fi

tmux resize-pane -t "$pane" "-$axis" 1 || true

others=$(tmux list-panes -t "$win" -F '#{pane_id}' | grep -vx "$pane" || true)
n=$(printf '%s\n' "$others" | grep -c . || true)
if [ "${n:-0}" -gt 1 ]; then
	total=0
	for p in $others; do
		total=$((total + $(tmux display-message -t "$p" -p "$sz")))
	done
	share=$((total / n))
	# The last pane keeps the remainder; setting it too would just claw a line back.
	for p in $(printf '%s\n' "$others" | sed '$d'); do
		tmux resize-pane -t "$p" "-$axis" "$share" || true
	done
fi

exit 0
