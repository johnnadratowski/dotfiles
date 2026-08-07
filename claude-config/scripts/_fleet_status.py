"""Renderer for fleet-status.sh. Reads TAB records on stdin, writes the table.

Kept out of the shell script because every interesting field is a file parse (see
_agent_facts.py), and out of _agent_facts.py because that module is shared with the
agent-panel status line, which renders one row rather than a table.

stdin   name<TAB>path<TAB>state<TAB>uptime   (one per lane)
stdout  aligned table, or one JSON object per lane under FLEET_JSON=1
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _agent_facts import (  # noqa: E402
    ASK, ask_kind, clip, context_for, fmt_secs, needs_input, needs_input_items, open_prs_for,
    status_line, todo_for, todo_pairs_for,
)


def osc8(label, url):
    """Render `label` as a terminal hyperlink to `url` (plain label when there is no URL).

    ST (ESC \\) terminates, never BEL: width-strippers treat ST as zero-width but count the
    bytes of a BEL-terminated URL, which truncates the line mid-escape and leaves the raw URL
    on screen. Safe here only because the ▸ field is appended AFTER every pad() and is never
    itself wrapped -- put a link inside a padded column and the column math breaks, since
    len() counts the escape bytes that the terminal does not draw.
    """
    return "\033]8;;%s\033\\%s\033]8;;\033\\" % (url, label) if url else label

STATE_ICON = {"busy": "●", "quiet": "◔", "idle": "○", "down": "·"}


def general_asks():
    """Asks that belong to the FLEET rather than to any one lane.

    Lives beside the lanes dir (`<main-clone>/.claude/needs-input`) rather than inside a lane,
    because a lane's file renders under that lane — and an item like "merge PR #124" or "decide
    who owns X" is not any lane's to hold. Written and cleared by the LEAD, same as the per-lane
    files: the agents no longer maintain their own.
    """
    lanes = os.environ.get("FLEET_LANES", "")
    if not lanes:
        return []
    # NOT `needs-input`: the per-lane reader walks UP from a lane, so a file with that name in
    # the main clone's .claude/ is found by the lead's own lane and rendered as its asks. The
    # distinct name is what keeps the fleet list out of any lane.
    path = os.path.join(os.path.dirname(lanes.rstrip("/")), "needs-input-fleet")
    try:
        with open(path) as f:
            body = f.read().strip()
    except OSError:
        return []
    out = []
    for ln in body.splitlines():
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        icon, text = ask_kind(ln)
        out.append((icon, clip(text)))
    return out

# Emoji occupy two terminal cells while len() counts them as one, so a column padded with
# %-*s containing ❓ lands one cell right of its neighbours and the whole table skews. These
# ranges cover the emoji actually used here (and any the agents put in their summaries);
# they are not a general wcwidth.
_WIDE = ((0x1100, 0x115F), (0x2E80, 0xA4CF), (0xAC00, 0xD7A3), (0xF900, 0xFAFF),
         (0xFE30, 0xFE6F), (0xFF00, 0xFF60), (0xFFE0, 0xFFE6),
         (0x1F300, 0x1F64F), (0x1F900, 0x1F9FF), (0x2753, 0x2755), (0x1F680, 0x1F6FF),
         # ⚠ and its neighbours. U+26A0 is nominally narrow, but terminals render it wide when
         # it carries VS16 — which ⚠️ does. Omitting it skews every column to its right.
         (0x2600, 0x27BF))

# Zero-width: a variation selector is a modifier on the preceding glyph, not a cell of its own.
# Counting it as 1 happened to give ⚠️ the right total only because U+26A0 was being undercounted
# — two errors cancelling. Both are fixed rather than left to keep cancelling.
_ZERO = ((0xFE00, 0xFE0F), (0x200D, 0x200D))


def dwidth(s):
    w = 0
    for ch in s:
        o = ord(ch)
        if any(lo <= o <= hi for lo, hi in _ZERO):
            continue
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
        kind = f[4] if len(f) > 4 else "lane"
        session = f[5] if len(f) > 5 else ""
        # A short speakable label for the lane (`ott`), empty for anything that is not one.
        # Rendered BESIDE the id rather than instead of it: the id is what you type into
        # SendMessage and what every path on disk is named for, so hiding it would make the
        # console the one place the fleet is described in a vocabulary nothing else accepts.
        label = f[6] if len(f) > 6 else ""
        # A label equal to the id is not a label. fleet_lane_display_name degrades to the
        # agent's own name for anything that is not a lane, so passing that through would
        # render `rev-a  rev-a` — a column of duplicates that costs width and says nothing.
        if label == name:
            label = ""
        # An exact transcript beats "newest file in the project dir" whenever a cwd hosts more
        # than one live session — see parent_session_for in fleet-status.sh.
        tpath = ""
        if session and path:
            cand = os.path.join(os.path.expanduser("~/.claude/projects"),
                                re.sub(r"[^A-Za-z0-9]", "-", path), session + ".jsonl")
            if os.path.exists(cand):
                tpath = cand

        # A SUBAGENT SHARES ITS SPAWNER'S cwd, and every per-cwd fact would therefore be its
        # spawner's. Reporting the lead's context and the lead's summary on a reviewer's row
        # is worse than reporting nothing: it reads as fact and is wrong on every field. So a
        # subagent row carries only what is unambiguously its own — name, state, uptime — and
        # the columns that cannot be attributed are left empty.
        if kind == "subagent":
            yield {"name": name, "path": path, "state": state, "uptime": fmt_uptime(up),
                   "kind": kind, "label": label, "tokens": None, "context_pct": None,
                   "issue": "", "needs_input": "", "status": ""}
            continue

        used, win = context_for(path, tpath or None)
        yield {
            "name": name,
            "path": path,
            "state": state,
            "uptime": fmt_uptime(up),
            "kind": kind,
            "label": label,
            "tokens": used,
            # Percent of the USABLE window (80% of max — the auto-compact threshold), which
            # is what ccstatusline's context widget and every other surface here report.
            # Dividing by the full window instead read 57% where the agent's own status line
            # said 70%, and a number that disagrees with the one beside it is worse than no
            # number: you cannot tell which lied.
            "context_pct": round(100 * used / (win * 0.8)) if used and win else None,
            "issue": todo_for(path),
            # Kept alongside "issue" rather than replacing it: JSON consumers want the bare
            # ids, the terminal wants them clickable, and one field cannot be both.
            "issue_links": todo_pairs_for(path),
            # [(number, url, is_draft), …] — a LIST like the tracker ids, because a lane can
            # have more than one PR in flight. The only fact here that lives off this machine,
            # so it comes from a cache a long-running caller refreshes — never a fetch on the
            # render path. See refresh_open_prs().
            "open_prs": open_prs_for(path),
            "needs_input": needs_input(path),
            # One element per ask. "needs_input" stays a string for JSON consumers; the panel
            # renders these, because a lane routinely owes the human more than one answer.
            "asks": needs_input_items(path),
            # Lead-written, not scraped. See status_line() for why the transcript could not
            # be the source: it reports the last thing an agent SAID, not what is true now.
            "status": status_line(path),
        }


def main():
    data = sorted(rows(), key=lambda r: (r.get("kind") == "subagent", r["name"]))
    if os.environ.get("FLEET_JSON") == "1":
        for r in data:
            sys.stdout.write(json.dumps(r) + "\n")
        return

    try:
        cols = int(os.environ.get("COLUMNS") or 100)
    except ValueError:
        cols = 100
    cols = max(60, cols)

    lanes = [r for r in data if r.get("kind") != "subagent"]
    subs = [r for r in data if r.get("kind") == "subagent"]
    live = sum(1 for r in lanes if r["state"] != "down")
    busy = sum(1 for r in data if r["state"] == "busy")

    # ⚠ MEANS "A HUMAN OWES AN ANSWER HERE", AND NOTHING ELSE. It used to also mean `quiet` —
    # turn open, no tool activity — which is a guess about an agent, not a request from one.
    # Two lanes wore the marker for hours with nothing to answer, which is how an attention
    # marker stops being worth looking at.
    ask = [r for r in data if r["needs_input"]]
    general = general_asks()
    n_ask = sum(len(r.get("asks") or []) for r in data) + len(general)
    head = "FLEET  %d/%d lanes up  %d busy" % (live, len(lanes), busy)
    if subs:
        head += "  %d subagent%s" % (len(subs), "" if len(subs) == 1 else "s")
    if n_ask:
        # Count ASKS, not lanes. One lane owing three answers is three things to do, and the
        # header is the number the user plans their next few minutes around.
        head += "  %s %d needs you" % (ASK, n_ask)
    # The clock is what tells you the view is live rather than a frozen pane you left open.
    head += "  ·  " + os.environ.get("FLEET_NOW", "")
    sys.stdout.write(head.rstrip() + "\n")

    if not data:
        sys.stdout.write("  (no lanes under %s)\n" % os.environ.get("FLEET_LANES", "?"))
        return

    wn = max(len(r["name"]) for r in data)
    wl = max((len(r.get("label") or "") for r in data), default=0)

    def wrap(text, indent):
        """One line, hard-truncated. A backstop only — every entry is already clipped to 60
        at read, so this fires only on a genuinely narrow pane."""
        room = cols - indent - 1
        if room < 12:
            return ""
        return " " * indent + (text if dwidth(text) <= room else text[:room - 1] + "…")

    for r in data:
        # A BLANK LINE BEFORE EVERY BLOCK, including the first. Each agent now owns two or
        # three lines, so without a separator the table reads as one wall of text and the eye
        # cannot tell where one agent ends and the next begins. Leading rather than trailing,
        # so the pane never ends on empty space.
        sys.stdout.write("\n")
        pct = "%d%%" % r["context_pct"] if r["context_pct"] is not None else "-"
        # A lane that is down has no live context or uptime; showing the last known values
        # would read as current.
        if r["state"] == "down":
            pct, up = "-", "-"
        else:
            up = r["uptime"] or "-"
        icon = ASK if r["needs_input"] else STATE_ICON.get(r["state"], "?")
        # Subagents are guests of whoever spawned them, so they are indented rather than
        # listed as peers of the lanes.
        sub = r.get("kind") == "subagent"
        lead_in = "   └ " if sub else "  "
        lbl = (pad(r.get("label") or "", wl) + "  ") if wl else ""
        line = lead_in + pad(icon, 2) + " " + lbl + pad(r["name"], wn) + "  " + \
            pad(r["state"], 7) + " " + pad(pct, 5, right=True) + " " + \
            pad(up, 7, right=True)
        if not sub:
            links = r.get("issue_links") or []
            line += "  ▸ " + (" ".join(osc8(i, u) for i, u in links) if links
                              else (r["issue"] or "—"))
            # Its own column, beside the tickets: together they answer one question — what is
            # this lane on, and has the work left the lane yet. A lane with an open PR is
            # waiting on review rather than working, which the ticket alone cannot say.
            prs = r.get("open_prs") or []
            if prs:
                line += "  " + " ".join(
                    osc8("#%s%s" % (num, "…" if draft else ""), url) for num, url, draft in prs)
        sys.stdout.write(line.rstrip() + "\n")

        # SECOND LINE: what this lane is doing, now. It leads and it is unmarked — a glyph in
        # front of every single row is decoration, not signal, and the only glyph the panel
        # should spend is the one meaning "you". Indentation already says it belongs to the row
        # above. The ⚠ asks nest UNDER it: an ask without its context reads as an interruption
        # rather than a next step. (This order is the user's; the reverse was tried and put the
        # question above the thing it was about.)
        if r["status"]:
            out = wrap(r["status"], 6)
            if out:
                sys.stdout.write(out + "\n")
        # One typed glyph per ask. The lane's label, name and ticket are already on the row
        # above, so the ask carries its kind and the question, and nothing else.
        for icon, text in (r.get("asks") or []):
            out = wrap(icon + " " + text, 8)
            if out:
                sys.stdout.write(out + "\n")

    # Fleet-level asks last, under their own heading — they are real work for the user but
    # belong to no lane, and hanging them off an arbitrary agent would misattribute them.
    #
    # 4ME, THE SAME NAME THE TUI GIVES THIS LIST, and numbered the way the TUI numbers it. The
    # user refers to these rows by position — "4me 2" — so the two renderers have to agree on
    # both the label and the numbers, or the reference resolves differently depending on which
    # view they happened to be looking at.
    if general:
        sys.stdout.write("\n  4ME  (not lane-specific)\n")
        for n, (icon, text) in enumerate(general, 1):
            out = wrap("%2d  %s %s" % (n, icon, text), 4)
            if out:
                sys.stdout.write(out + "\n")


if __name__ == "__main__":
    main()
