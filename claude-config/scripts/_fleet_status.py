"""Renderer for fleet-status.sh. Reads TAB records on stdin, writes the table.

Kept out of the shell script because every interesting field is a file parse (see
_agent_facts.py), and out of _agent_facts.py because that module is shared with the
agent-panel status line, which renders one row rather than a table.

stdin   name<TAB>path<TAB>state<TAB>uptime   (one per lane)
stdout  aligned table, or one JSON object per lane under FLEET_JSON=1
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _agent_facts import (  # type: ignore[import-not-found]  # noqa: E402  (sibling, via sys.path above)
    MARK, context_for, fmt_secs, needs_input, summary_for, todo_for,
)

STATE_ICON = {"busy": "●", "waiting": "❓", "idle": "○", "down": "·"}

# Emoji occupy two terminal cells while len() counts them as one, so a column padded with
# %-*s containing ❓ lands one cell right of its neighbours and the whole table skews. These
# ranges cover the emoji actually used here (and any the agents put in their summaries);
# they are not a general wcwidth.
_WIDE = ((0x1100, 0x115F), (0x2E80, 0xA4CF), (0xAC00, 0xD7A3), (0xF900, 0xFAFF),
         (0xFE30, 0xFE6F), (0xFF00, 0xFF60), (0xFFE0, 0xFFE6),
         (0x1F300, 0x1F64F), (0x1F900, 0x1F9FF), (0x2753, 0x2755), (0x1F680, 0x1F6FF))


def dwidth(s):
    w = 0
    for ch in s:
        o = ord(ch)
        w += 2 if any(lo <= o <= hi for lo, hi in _WIDE) else 1
    return w


def pad(s, n, right=False):
    fill = " " * max(0, n - dwidth(s))
    return fill + s if right else s + fill


def fmt_uptime(etime):
    """`ps -o etime=` gives [[DD-]HH:]MM:SS — unreadable at a glance, and 43:17 is
    ambiguous between 43 minutes and 43 hours. Normalise to the same shape the agent
    panel uses."""
    etime = (etime or "").strip()
    if not etime:
        return ""
    days = 0
    if "-" in etime:
        d, etime = etime.split("-", 1)
        days = int(d) if d.isdigit() else 0
    bits = [int(x) if x.isdigit() else 0 for x in etime.split(":")]
    while len(bits) < 3:
        bits.insert(0, 0)
    h, m, s = bits[-3], bits[-2], bits[-1]
    return fmt_secs(((days * 24 + h) * 60 + m) * 60 + s)


def rows():
    for line in sys.stdin:
        f = line.rstrip("\n").split("\t")
        if len(f) < 4 or not f[0]:
            continue
        name, path, state, up = f[0], f[1], f[2], f[3]
        used, win = context_for(path)
        yield {
            "name": name,
            "path": path,
            "state": state,
            "uptime": fmt_uptime(up),
            "tokens": used,
            "context_pct": round(100 * used / win) if used and win else None,
            "issue": todo_for(path),
            "needs_input": needs_input(path),
            "summary": summary_for(path),
        }


def main():
    data = sorted(rows(), key=lambda r: r["name"])
    if os.environ.get("FLEET_JSON") == "1":
        for r in data:
            sys.stdout.write(json.dumps(r) + "\n")
        return

    try:
        cols = int(os.environ.get("COLUMNS") or 100)
    except ValueError:
        cols = 100
    cols = max(60, cols)

    live = sum(1 for r in data if r["state"] != "down")
    busy = sum(1 for r in data if r["state"] == "busy")
    # Two independent ways an agent says it needs you: it wrote the reason down, or its turn
    # is open with nothing happening. Counted once either way.
    ask = [r for r in data if r["needs_input"] or r["state"] == "waiting"]
    head = "FLEET  %d live  %d busy" % (live, busy)
    if ask:
        head += "  ❓ %d waiting on you" % len(ask)
    sys.stdout.write(head + "\n")

    if not data:
        sys.stdout.write("  (no lanes under %s)\n" % os.environ.get("FLEET_LANES", "?"))
        return

    wn = max(len(r["name"]) for r in data)
    wi = max([len(r["issue"]) for r in data] + [1])
    for r in data:
        pct = "%d%%" % r["context_pct"] if r["context_pct"] is not None else "-"
        # A lane that is down has no live context or uptime; showing the last known values
        # would read as current.
        if r["state"] == "down":
            pct, up = "-", "-"
        else:
            up = r["uptime"] or "-"
        left = "  " + pad(STATE_ICON.get(r["state"], "?"), 2) + " " + \
            pad(r["name"], wn) + "  " + pad(r["state"], 7) + " " + \
            pad(pct, 4, right=True) + " " + pad(up, 6, right=True) + "  " + \
            pad(r["issue"] or "-", wi)
        room = cols - dwidth(left) - 3
        tail = ""
        # A question outranks the summary for the leftover width: one is addressed to you,
        # the other is background.
        if r["needs_input"] and room >= 12:
            q = r["needs_input"]
            tail = "  ❓ " + (q if len(q) <= room else q[:room - 1] + "…")
        elif r["summary"] and room >= 20:
            s = r["summary"]
            tail = "  " + MARK + " " + (s if len(s) <= room else s[:room - 1] + "…")
        sys.stdout.write((left + tail).rstrip() + "\n")


if __name__ == "__main__":
    main()
