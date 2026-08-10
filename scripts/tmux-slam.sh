#!/bin/sh
# tmux-slam.sh <h|j|k|l> [pane-id]
#
# Slam a pane along one axis, cycling through three states as you press the same key:
#
#   1st press   maximise this pane on the key's axis (j/k = height, h/l = width)
#   2nd press   already at the limit, so zoom it fullscreen
#   3rd press   in zoom, so unzoom and equalise the window
#
# k / l grow this pane; j / h shrink it to the floor and hand the space to the others.
#
# Two tmux behaviours drive the shape of this script:
#
#   * A saturated `resize-pane` still exits 0, so "already maximised" can only be
#     detected by comparing the pane's size before and after.
#   * Shrinking hands the freed space to the ADJACENT pane, not to the group. The
#     shrink path therefore redistributes explicitly.
#
# `even-vertical` flattens a grid into one column, so equalise picks the layout from
# the window's actual shape rather than from the key that was pressed.

set -eu

dir=${1:?usage: tmux-slam.sh <h|j|k|l> [pane-id]}
pane=${2:-}
[ -n "$pane" ] || pane=$(tmux display-message -p '#{pane_id}')

win=$(tmux display-message -t "$pane" -p '#{window_id}')

q() { tmux display-message -t "$pane" -p "$1"; }
each_pane() { tmux list-panes -t "$win" -F "$1"; }

equalise() {
	# One column -> stack evenly. One row -> spread evenly. Anything else is a grid,
	# and the even-* layouts would flatten it.
	if [ "$(each_pane '#{pane_left}' | sort -u | wc -l)" -eq 1 ]; then
		tmux select-layout -t "$win" even-vertical
	elif [ "$(each_pane '#{pane_top}' | sort -u | wc -l)" -eq 1 ]; then
		tmux select-layout -t "$win" even-horizontal
	else
		tmux select-layout -t "$win" tiled
	fi
}

# From zoom, every direction means the same thing: back to an even window.
if [ "$(q '#{window_zoomed_flag}')" = 1 ]; then
	tmux resize-pane -t "$pane" -Z
	equalise
	exit 0
fi

[ "$(q '#{window_panes}')" -ge 2 ] || exit 0

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

before=$(q "$sz")

if [ "$grow" = 1 ]; then
	tmux resize-pane -t "$pane" "-$axis" 100% || true
else
	tmux resize-pane -t "$pane" "-$axis" 1 || true

	others=$(each_pane '#{pane_id}' | grep -vx "$pane" || true)
	n=$(printf '%s\n' "$others" | grep -c . || true)
	if [ "${n:-0}" -gt 1 ]; then
		total=0
		for p in $others; do
			total=$((total + $(tmux display-message -t "$p" -p "$sz")))
		done
		share=$((total / n))
		# Last pane keeps the remainder; setting it too would just claw back a line.
		for p in $(printf '%s\n' "$others" | sed '$d'); do
			tmux resize-pane -t "$p" "-$axis" "$share" || true
		done
	fi
fi

# Nothing moved, so we were already at the limit: escalate to fullscreen.
if [ "$(q "$sz")" = "$before" ]; then
	tmux resize-pane -t "$pane" -Z
fi

exit 0
