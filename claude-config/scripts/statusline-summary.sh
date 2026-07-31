#!/bin/bash
# statusline-summary.sh
#
# ccstatusline `custom-command` widget: prints the MOST RECENT 📌 summary the Concise output style
# leads every non-trivial response with (see ~/.claude/output-styles/concise.md → "Summary").
# Reads the StatusJSON ccstatusline pipes on stdin (for `transcript_path`); pure local read, no
# inference. At-a-glance "what is this agent working on", per-agent (each session's own transcript).
#
# ONLY 📌-led lines qualify — never a stray first line — and it shows the LAST one seen, so a
# trivial reply (no summary) leaves the previous summary standing instead of showing junk or
# blanking. Emits the magenta bar itself (ANSI + the widget's preserveColors), because
# custom-command widgets don't honour ccstatusline's backgroundColor. Silent (exit 0) until the
# transcript holds at least one 📌 summary.
#
# READ FROM THE TAIL, WIDENING. Transcripts reach hundreds of megabytes and this runs on every
# status refresh, per agent; the original read the whole file line by line. A fixed tail would
# be wrong the other way — one turn that dumps a large tool result can push the last summary
# out of a small window and blank the bar (observed on a 7MB transcript). So: read 512KB, and
# only if that finds nothing widen to 2MB, then 8MB. Each step re-reads from the end rather
# than stepping back through fixed chunks, so no record is ever split across a boundary.

input="$(cat)"
transcript="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print((json.load(sys.stdin) or {}).get("transcript_path",""))
except Exception: pass' 2>/dev/null)"

[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

python3 - "$transcript" <<'PY'
import sys, os, json, re

MARK = "\U0001F4CC"   # 📌 — the summary sentinel (the glyph the output style leads with)
path = sys.argv[1]

def strip_md(s):
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)   # [text](url) -> text
    s = re.sub(r"\*\*|\*|`|~~|__", "", s)             # emphasis / inline code
    return re.sub(r"\s+", " ", s).strip()

def tail(nbytes):
    """Last nbytes of the file, starting at a record boundary."""
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        if size > nbytes:
            fh.seek(size - nbytes)
            fh.readline()          # discard the partial line the seek landed inside
        return fh.read().decode("utf-8", "replace"), size


# The most recent 📌-led line ANYWHERE in the window = the current summary. Scanning for the
# marker (not "first line of the last message") is what keeps a stray heading out of the widget.
def scan(chunk):
    found = None
    for line in chunk.splitlines():
        if MARK not in line:                 # cheap reject before the JSON parse
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") != "assistant":
            continue
        for b in ((o.get("message") or {}).get("content") or []):
            if isinstance(b, dict) and b.get("type") == "text":
                for raw in (b.get("text") or "").splitlines():
                    s = raw.strip()
                    if s.startswith(MARK):
                        cand = strip_md(s[len(MARK):])
                        if cand:
                            found = cand
    return found


last_summary = None
try:
    for n in (512 * 1024, 2 * 1024 * 1024, 8 * 1024 * 1024):
        chunk, size = tail(n)
        last_summary = scan(chunk)
        if last_summary or size <= n:        # found it, or already read the whole file
            break
except Exception:
    sys.exit(0)

if not last_summary:
    sys.exit(0)

MAXLEN = 1000
out = last_summary if len(last_summary) <= MAXLEN else last_summary[:MAXLEN - 1].rstrip() + "…"

# 105 = bright-magenta background, 30 = black text. NO leading/trailing pad inside the bar — the
# bar would then carry a magenta space next to ccstatusline's theme-coloured inter-widget padding
# (two adjacent spaces, two colours). Kept via the widget's preserveColors (custom-command widgets
# ignore ccstatusline's backgroundColor).
print("\033[105;30m" + MARK + " " + out + "\033[0m")
PY
