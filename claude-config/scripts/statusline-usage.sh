#!/bin/sh
# Compact usage widgets for ccstatusline.
#
# ccstatusline's built-in Context %/Session/Weekly widgets hardcode toFixed(1)
# and their "Ctx(u) Used:"/"Session:"/"Weekly:" labels, so this replaces them
# with rounded, single-letter equivalents: C:12% S:24% W:41%
#
# Reads the Claude Code status line JSON on stdin.
# Usage: statusline-usage.sh ctx|session|weekly

json=$(cat)

# Prints nothing when the source field is absent, which hides the widget.
case "$1" in
  ctx)
    # Percent of the *usable* window (80% of max, the auto-compact threshold),
    # matching ccstatusline's context-percentage-usable widget.
    printf '%s' "$json" | jq -r '
      ((.context_window.context_window_size // 200000) * 0.8 | floor) as $usable
      | (.context_window.current_usage // {}) as $u
      | (($u.input_tokens // 0) + ($u.output_tokens // 0)
         + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) as $used
      | if $usable > 0 and $used > 0
        then "C:\([$used / $usable * 100, 100] | min | round)%"
        else "C:0%" end'
    # ALWAYS emits, never "". $used is 0 immediately after a /clear or /compact and
    # on the first turn of a session, which used to blank the widget entirely — so
    # context disappeared exactly when it had just been reset, i.e. when confirming
    # the reset was the point. "C:0%" is a real reading, not a placeholder; a widget
    # that vanishes is indistinguishable from one that is broken.
    ;;
  session)
    printf '%s' "$json" | jq -r '
      if .rate_limits.five_hour.used_percentage != null
      then "S:\(.rate_limits.five_hour.used_percentage | round)%"
      else "" end'
    ;;
  weekly)
    printf '%s' "$json" | jq -r '
      if .rate_limits.seven_day.used_percentage != null
      then "W:\(.rate_limits.seven_day.used_percentage | round)%"
      else "" end'
    ;;
esac
