#!/bin/bash
# ~/.claude/scripts/last-msg-ago.sh
#
# ccstatusline `custom-command` widget: prints "⏱ <N>m ago" — how long since the
# most recent message in the current session's transcript. Reads the StatusJSON that
# ccstatusline pipes on stdin (for `transcript_path`); pure local read, no inference.
#
# Refresh cadence is governed by Claude Code's statusLine (event-driven + the
# `refreshInterval` in ~/.claude/settings.json) — set refreshInterval so this stays
# live while the session is idle.

input="$(cat)"
transcript="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print((json.load(sys.stdin) or {}).get("transcript_path",""))
except Exception: pass' 2>/dev/null)"

[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Scan the tail for the last line carrying a `timestamp` (not every line has one),
# parse the ISO-8601 value, and render a compact relative age.
tail -n 80 "$transcript" 2>/dev/null | python3 -c '
import sys, json
from datetime import datetime, timezone

ts = None
for line in sys.stdin:
    try:
        o = json.loads(line)
    except Exception:
        continue
    t = o.get("timestamp")
    if t:
        ts = t          # keep the LAST one seen → most recent message
if not ts:
    sys.exit(0)

try:
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
except Exception:
    sys.exit(0)

secs = int((datetime.now(timezone.utc) - dt).total_seconds())
if secs < 0:
    secs = 0
if secs < 60:
    out = "%ds ago" % secs
elif secs < 3600:
    out = "%dm ago" % (secs // 60)
elif secs < 86400:
    out = "%dh %dm ago" % (secs // 3600, (secs % 3600) // 60)
else:
    out = "%dd ago" % (secs // 86400)
print("⏱ " + out)
'
