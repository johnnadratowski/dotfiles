#!/bin/bash
# subagentStatusLine — the per-row status line in the agent panel below the prompt.
#
# THE CONTRACT, read off the harness rather than guessed (v2.1.220, and confirmed against the
# published docs). It is NOT one invocation per row with that row's context on stdin, which is
# what this script assumed for its whole first life and why the panel stayed blank:
#
#   stdin   ONE JSON object for the WHOLE panel:
#             { columns: <int>, tasks: [ { id, name, type, status, description, label,
#                                          startTime, model, effort, contextWindowSize,
#                                          tokenCount, tokenSamples, cwd }, … ] }
#   stdout  ONE JSON LINE PER TASK:  {"id": "<task id>", "content": "<what to render>"}
#           Anything else is dropped with `subagentStatusLine emitted non-JSON line` in the
#           debug log — silently, as far as the panel is concerned.
#
# `content` REPLACES the whole default row (name · description · token count), so the name has
# to be re-emitted here or it disappears. Omit a task's id to keep the default row; emit an
# empty content string to hide the row entirely.
#
# WHAT IT SHOWS, left to right, and why each earns its width:
#   name      you are looking at a list; the row has to say whose it is
#   status    the harness's OWN status string, rendered verbatim rather than interpreted —
#             if the panel's idle/active indicator is lying, this is where you see it lie
#   ctx%      the number you act on: when to /compact, when to hand work over
#   uptime    how long this agent has been at it — a stuck agent looks exactly like a busy
#             one without it
#   ▸ ID      the lane's in-progress Linear issue, from the same mirror the main bar reads
#   📌 …      the agent's own last summary line, so the row says what it is DOING, not just
#             that it is alive
#
# Fields degrade independently: anything unavailable is dropped and the rest still renders.
#
# CONTRACT ON OUR SIDE: always exit 0, always finish fast. The harness kills us at 5s and drops
# the whole panel's decorations if we exit non-zero. Everything here is bounded — the transcript
# is read from the TAIL, never scanned whole, because these files reach hundreds of megabytes.
#
# Set SUBAGENT_STATUSLINE_DEBUG=1, or touch ~/.claude/debug/subagent-statusline.capture, to
# append each raw payload to ~/.claude/debug/subagent-statusline.jsonl. That is how the contract
# above was established; use it again rather than guessing if a future version changes shape.

set -u
payload="$(cat 2>/dev/null || true)"

if [ "${SUBAGENT_STATUSLINE_DEBUG:-0}" = 1 ] || [ -e "$HOME/.claude/debug/subagent-statusline.capture" ]; then
  mkdir -p "$HOME/.claude/debug" 2>/dev/null
  printf '%s\n' "$payload" >> "$HOME/.claude/debug/subagent-statusline.jsonl" 2>/dev/null
fi

[ -n "$payload" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# The program is carried in a quoted heredoc and passed as an ARGUMENT, not inlined in a
# single-quoted `python3 -c '...'`. An apostrophe in any comment or docstring closes that
# quote and the whole script detonates — which it did, at "the agent's transcript".
PROG=$(cat <<'PYEOF'

import json, os, re, sys, glob, time

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tasks = d.get("tasks") or []
if not isinstance(tasks, list):
    sys.exit(0)

try:
    COLUMNS = int(d.get("columns") or 80)
except Exception:
    COLUMNS = 80

MARK = "\U0001F4CC"          # the summary sentinel the Concise output style leads with
TAIL = 512 * 1024            # bytes of transcript to scan; a whole read would blow the 5s budget


def as_int(x):
    try:
        return int(float(x))
    except Exception:
        return None


def window_for(model):
    """Context window when the harness did not supply one — same rule agent-fanout uses:
    an explicit [1m] marker wins, then opus/sonnet major >= 4 means 1M, else 200k."""
    m = str(model or "").lower()
    if "1m" in re.findall(r"\[([^\]]*)\]", m) or m.endswith("-1m"):
        return 1_000_000
    fam = re.search(r"(opus|sonnet)[-_]?(\d+)", m)
    return 1_000_000 if (fam and int(fam.group(2)) >= 4) else 200_000


def uptime(start):
    """startTime is whatever the harness gives — epoch seconds, epoch millis, or ISO."""
    t = None
    n = as_int(start)
    if n:
        t = n / 1000.0 if n > 10_000_000_000 else float(n)
    elif isinstance(start, str) and start:
        try:
            from datetime import datetime
            t = datetime.fromisoformat(start.replace("Z", "+00:00")).timestamp()
        except Exception:
            t = None
    if not t:
        return ""
    s = int(time.time() - t)
    if s < 0 or s > 60 * 60 * 24 * 30:
        return ""
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm" % (s // 60)
    return "%dh%02dm" % (s // 3600, (s % 3600) // 60)


def todo_for(cwd):
    """In-progress Linear id(s) for the worktree this agent works in.

    Tracking lives in Linear, which has no cheap local state to read, so `/todo` mirrors the id
    to a gitignored per-worktree file and every status surface reads that — the same mirror the
    main bar uses, so the panel and the bar cannot disagree. Walked up from the task cwd rather
    than resolved with git: no subprocess, and this runs per row per tick.
    """
    p = cwd if isinstance(cwd, str) and cwd else None
    for _ in range(24):
        if not p:
            break
        try:
            f = os.path.join(p, ".claude", "current-work")
            if os.path.getsize(f) > 0:
                with open(f) as fh:
                    ids = [ln.split("\t")[0].strip() for ln in fh if ln.strip()]
                ids = [i for i in ids if i]
                if ids:
                    return " ".join(ids)
        except OSError:
            pass
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    return ""


def summary_for(cwd):
    """The agent's most recent 📌 summary, from its own transcript.

    Transcripts live at ~/.claude/projects/<cwd with every non-alphanumeric char as - >/*.jsonl.
    Only 📌-led lines qualify, and the LAST one wins, so a trivial reply leaves the previous
    summary standing rather than blanking the row. Read from the tail: these files reach
    hundreds of MB and this runs for every row on every tick.
    """
    if not isinstance(cwd, str) or not cwd:
        return ""
    d = os.path.join(os.path.expanduser("~/.claude/projects"),
                     re.sub(r"[^A-Za-z0-9]", "-", cwd))
    try:
        files = glob.glob(os.path.join(d, "*.jsonl"))
        if not files:
            return ""
        path = max(files, key=os.path.getmtime)
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TAIL:
                fh.seek(size - TAIL)
                fh.readline()            # discard the partial line the seek landed inside
            chunk = fh.read().decode("utf-8", "replace")
    except OSError:
        return ""

    last = ""
    for line in chunk.splitlines():
        if MARK not in line:             # cheap reject before the JSON parse
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") != "assistant":
            continue
        content = (o.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for c in content:
            if c.get("type") != "text":
                continue
            for ln in (c.get("text") or "").splitlines():
                ln = ln.strip()
                if ln.startswith(MARK):
                    last = ln[len(MARK):].strip()
    # Markdown is noise at this width.
    last = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", last)
    last = re.sub(r"\*\*|\*|`|~~|__", "", last)
    return re.sub(r"\s+", " ", last).strip()


# Statuses that mean "running normally" and so say nothing worth a column. Anything else is
# shown VERBATIM — an indicator that misreports idle/active is only visible if we do not
# paper over it with our own vocabulary.
QUIET = {"running", "active", "in_progress", "in-progress", "working", ""}

for t in tasks:
    if not isinstance(t, dict):
        continue
    tid = t.get("id")
    if not tid:
        continue

    parts = []

    name = t.get("name") or t.get("label") or t.get("description") or ""
    if name:
        parts.append(str(name)[:18])

    status = str(t.get("status") or "").strip()
    if status.lower() not in QUIET:
        parts.append(status[:12])

    used = as_int(t.get("tokenCount"))
    win = as_int(t.get("contextWindowSize")) or (window_for(t.get("model")) if used else None)
    if used and win:
        pct = round(100 * used / win)
        # The flags are the point of a percentage: ~ is "hand off soon", ! is "compact now".
        flag = "!" if pct >= 90 else ("~" if pct >= 80 else "")
        parts.append("%s%d%%" % (flag, pct))
        parts.append("%dk" % round(used / 1000) if used >= 1000 else str(used))

    up = uptime(t.get("startTime"))
    if up:
        parts.append(up)

    todo = todo_for(t.get("cwd"))
    if todo:
        parts.append("▸ " + todo)

    head = " ".join(parts)

    # The summary takes whatever width is left and is the first thing dropped — every field
    # before it is a fact you act on; this one is context.
    room = COLUMNS - len(head) - 4
    if room >= 24:
        s = summary_for(t.get("cwd"))
        if s:
            head = head + "  · " + MARK + " " + (s if len(s) <= room else s[:room - 1] + "…")

    if head:
        sys.stdout.write(json.dumps({"id": str(tid), "content": head}) + "\n")
PYEOF
)
printf '%s' "$payload" | python3 -c "$PROG" 2>/dev/null
exit 0
