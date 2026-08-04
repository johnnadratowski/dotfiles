"""Facts about a running agent that the harness will not tell you.

Two surfaces need the same five answers about an agent, and they must not drift:

  subagent-statusline.sh   decorates the rows in the agent panel below the prompt
  fleet-status.sh          the lead's per-lane view of the whole team

Every fact here is read from DISK, never from the harness, because the two surfaces
have different access to it and one of them has none at all. See fleet-status.sh's
header for why the panel cannot carry this for teammates.

CONTRACT: nothing here raises, nothing here blocks. Every function returns a falsy
value when the fact is unavailable, so a caller can render whatever it did get. The
transcript is always read from the TAIL -- these files reach hundreds of megabytes and
both callers run on a timer.
"""

import glob
import json
import os
import re
import time

MARK = "\U0001F4CC"        # the summary sentinel the Concise output style leads with
TAIL = 512 * 1024          # bytes of transcript to scan; a whole read blows the time budget


def as_int(x):
    try:
        return int(float(x))
    except Exception:
        return None


def _walk_up(cwd, *rel):
    """First readable non-empty <ancestor>/<rel...>, walking up from cwd.

    Walked rather than resolved with git: no subprocess, and these run per row per tick.
    """
    p = cwd if isinstance(cwd, str) and cwd else None
    for _ in range(24):
        if not p:
            break
        f = os.path.join(p, *rel)
        try:
            if os.path.getsize(f) > 0:
                with open(f) as fh:
                    return fh.read()
        except OSError:
            pass
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    return ""


def todo_for(cwd):
    """In-progress tracker id(s) for the worktree this agent works in.

    Tracking lives in Linear, which has no cheap local state to read, so `/todo` mirrors
    the id to a gitignored per-worktree file and every status surface reads that -- the
    same mirror the main bar uses, so the surfaces cannot disagree. Everything after the
    first TAB on a line is a URL or resume prose; only the id is wanted here.
    """
    body = _walk_up(cwd, ".claude", "current-work")
    ids = []
    for ln in body.splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        first = ln.split("\t")[0].strip()
        # Resume prose lives in the same file below the pointer line; an id is short and
        # has no spaces, which is what separates it from a paragraph.
        if first and " " not in first and len(first) <= 24:
            ids.append(first)
        else:
            break
    return " ".join(ids)


def todo_pairs_for(cwd):
    """(id, url) per in-progress tracker line -- todo_for plus the URL it discards.

    Same file and the SAME stop rules as todo_for, deliberately: two surfaces reading one
    mirror by different rules is how they end up disagreeing about what a lane is working on.

    The URL is validated, not just taken. Field 2 is a URL *by convention* — `/todo` writes
    `<ID>\\t<url>` — but the same file is where agents leave themselves resume prose, and a
    line whose second field is a note would otherwise become a hyperlink to that note. A
    caller that cannot tell a real link from a broken one shows a broken one, so the scheme
    check happens here, once, rather than in each surface.
    """
    pairs = []
    for ln in _walk_up(cwd, ".claude", "current-work").splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        parts = ln.split("\t")
        first = parts[0].strip()
        if not (first and " " not in first and len(first) <= 24):
            break
        url = parts[1].strip() if len(parts) > 1 else ""
        if not url.startswith(("http://", "https://")):
            url = ""
        pairs.append((first, url))
    return pairs


def needs_input(cwd):
    """Does this agent want the human? THE HARNESS CANNOT TELL US.

    Measured across 294 live payloads, a task's `status` only ever takes two values --
    `running` and `completed`. There is no waiting-for-input state to read, and an agent
    that has asked a question and gone idle is indistinguishable from one simply between
    turns. So the signal has to be one the agent writes: a one-line reason in
    <lane>/.claude/needs-input, created when it needs an answer and removed once it has one.
    """
    body = _walk_up(cwd, ".claude", "needs-input").strip()
    return body.splitlines()[0].strip() if body else ""


def transcript_for(cwd):
    """Newest transcript file for a working directory, or "".

    Transcripts live at ~/.claude/projects/<cwd with every non-alphanumeric char as ->/*.jsonl.
    """
    if not isinstance(cwd, str) or not cwd:
        return ""
    d = os.path.join(os.path.expanduser("~/.claude/projects"),
                     re.sub(r"[^A-Za-z0-9]", "-", cwd))
    try:
        files = glob.glob(os.path.join(d, "*.jsonl"))
        return max(files, key=os.path.getmtime) if files else ""
    except OSError:
        return ""


def _tail(path, nbytes=TAIL):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > nbytes:
                fh.seek(size - nbytes)
                fh.readline()          # discard the partial line the seek landed inside
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


def summary_for(cwd, path=None):
    """The agent's most recent 📌 summary, from its own transcript.

    Only 📌-led lines qualify and the LAST one wins, so a trivial reply leaves the previous
    summary standing rather than blanking the row.

    Widening reads, not one big one. A single 512KB tail is the right size almost always,
    but one turn that dumped a large tool result can push the last summary out of it — a
    lead reading a 7MB transcript saw its own row blank for exactly that reason. So the
    window grows only when the small read came up empty; the common case still reads 512KB.
    Each step re-reads from the tail rather than stepping backwards through fixed chunks,
    so no record is ever split across the boundary and lost.
    """
    path = path or transcript_for(cwd)
    if not path:
        return ""
    for n in (TAIL, 4 * TAIL, 16 * TAIL):
        found = _scan_summary(_tail(path, n))
        if found:
            return found
        try:
            if os.path.getsize(path) <= n:   # already read the whole file; widening is futile
                break
        except OSError:
            break
    return ""


def _scan_summary(chunk):
    last = ""
    for line in chunk.splitlines():
        if MARK not in line:               # cheap reject before the JSON parse
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
    last = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", last)   # markdown is noise at this width
    last = re.sub(r"\*\*|\*|`|~~|__", "", last)
    return re.sub(r"\s+", " ", last).strip()


def window_for(model):
    """Context window when nothing supplied one -- the same rule agent-fanout uses:
    an explicit [1m] marker wins, then opus/sonnet major >= 4 means 1M, else 200k."""
    m = str(model or "").lower()
    if "1m" in re.findall(r"\[([^\]]*)\]", m) or m.endswith("-1m"):
        return 1_000_000
    fam = re.search(r"(opus|sonnet)[-_]?(\d+)", m)
    return 1_000_000 if (fam and int(fam.group(2)) >= 4) else 200_000


def context_for(cwd, path=None):
    """(used_tokens, window) for an agent whose token count we cannot ask the harness for.

    A teammate is a separate process; the lead has no handle on its context. What it does
    leave behind is its transcript, and every assistant turn there records the usage the
    API charged -- input + both cache halves + output IS the context that turn occupied.
    The LAST such record is the current occupancy.

    Returns (None, None) when there is no usable record, never a guess.
    """
    path = path or transcript_for(cwd)
    if not path:
        return (None, None)
    used = None
    model = None
    for line in _tail(path).splitlines():
        if '"usage"' not in line:          # cheap reject before the JSON parse
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") != "assistant":
            continue
        msg = o.get("message") or {}
        u = msg.get("usage")
        if not isinstance(u, dict):
            continue
        total = 0
        for k in ("input_tokens", "cache_creation_input_tokens",
                  "cache_read_input_tokens", "output_tokens"):
            n = as_int(u.get(k))
            if n:
                total += n
        if total:
            used, model = total, msg.get("model")
    if not used:
        return (None, None)
    return (used, window_for(model))


def uptime(start):
    """startTime is whatever the caller has -- epoch seconds, epoch millis, or ISO."""
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
    return fmt_secs(int(time.time() - t))


def fmt_secs(s):
    if s < 0 or s > 60 * 60 * 24 * 30:
        return ""
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm" % (s // 60)
    return "%dh%02dm" % (s // 3600, (s % 3600) // 60)
