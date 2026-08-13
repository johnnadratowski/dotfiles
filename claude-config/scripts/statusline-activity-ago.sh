#!/bin/bash
# .claude/scripts/statusline-activity-ago.sh
#
# ccstatusline `custom-command` widget: prints "⏱ 42s ago" — how long since ANYTHING was
# written to this session's transcript. Restores the widget that was `last-msg-ago.sh` until
# 22f841c deleted it as collateral: that commit removed the hand-rolled mailbox transport and
# this file was in the same directory, so it went out with the transport it had nothing to do
# with. Nothing replaced it, and the bar has had no elapsed-time field since 2026-07-29.
#
# ANY record counts — an assistant turn, a user message, a tool result. That is deliberate,
# and it is what makes this DIFFERENT from statusline-lastmsg.sh rather than a second format
# for the same fact:
#
#   🕐 15:40      the last time the agent SPOKE          (statusline-lastmsg.sh)
#   ⏱ 12s ago    the last time anything happened at all  (this)
#
# Read together they separate the two failures that look identical in a quiet pane: spoke 8m
# ago / active 12s ago is an agent deep in a tool run, spoke 8m ago / active 8m ago is an
# agent that has stopped.
#
# Session-exact: the transcript comes from the StatusJSON on stdin, so a cwd hosting several
# sessions reports each one's own elapsed time.
#
# Granularity is bounded by the bar's own repaint rate — `statusLine.refreshInterval` in
# ~/.claude/settings.json — not by anything here. At 30s an idle pane's "Ns ago" advances in
# 30s steps.
#
# Silent (exit 0, no output) when there is no transcript or no timestamp in it.

# No jq: this renders on every repaint, and a transcript path holds no escaped quotes.
transcript="$(cat 2>/dev/null |
  sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$transcript" <<'PY' 2>/dev/null
import json, os, sys
from datetime import datetime, timezone

path = sys.argv[1]


def tail(nbytes):
    """Last nbytes of the file, starting at a record boundary. Byte-bounded rather than
    `tail -n`: one turn can write a single multi-megabyte line, and a line count puts no
    ceiling on how much of it gets read."""
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        if size > nbytes:
            fh.seek(size - nbytes)
            fh.readline()              # discard the partial line the seek landed inside
        return fh.read().decode("utf-8", "replace"), size


def last_stamp(chunk):
    ts = None
    for line in chunk.splitlines():
        if '"timestamp"' not in line:  # not every record carries one
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("timestamp"):
            ts = o["timestamp"]        # keep the LAST seen → the most recent record
    return ts


stamp = None
try:
    for n in (256 * 1024, 2 * 1024 * 1024):
        chunk, size = tail(n)
        stamp = last_stamp(chunk)
        if stamp or size <= n:
            break
except OSError:
    sys.exit(0)

if not stamp:
    sys.exit(0)

try:
    dt = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
except Exception:
    sys.exit(0)

secs = max(0, int((datetime.now(timezone.utc) - dt).total_seconds()))
if secs < 60:
    out = "%ds ago" % secs
elif secs < 3600:
    out = "%dm ago" % (secs // 60)
elif secs < 86400:
    out = "%dh%02dm ago" % (secs // 3600, (secs % 3600) // 60)
else:
    out = "%dd ago" % (secs // 86400)

print("⏱ " + out)
PY
exit 0
