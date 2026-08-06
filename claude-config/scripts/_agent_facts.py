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

TAIL = 512 * 1024          # bytes of transcript to scan; a whole read blows the time budget

# One shorthand line, hard cap. Enforced HERE rather than in the renderer so every surface —
# terminal, JSON, a future one — agrees on what the record says, and so an over-long entry is
# visibly clipped in the place it is authored rather than looking fine until something wraps.
LINE_MAX = 60


def clip(s, n=LINE_MAX):
    s = re.sub(r"\s+", " ", s or "").strip()
    return s if len(s) <= n else s[:n - 1].rstrip() + "…"


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


def branch_for(cwd):
    """The checked-out branch, read from git's own files. No subprocess.

    A worktree's `.git` is a FILE holding `gitdir: <path>`, not a directory — so the naive
    `<cwd>/.git/HEAD` finds nothing in exactly the layout this fleet runs in.
    """
    p = os.path.join(cwd or "", ".git")
    try:
        if os.path.isfile(p):
            with open(p) as fh:
                line = fh.read().strip()
            if not line.startswith("gitdir:"):
                return ""
            p = line.split(":", 1)[1].strip()
            if not os.path.isabs(p):
                p = os.path.normpath(os.path.join(cwd, p))
        with open(os.path.join(p, "HEAD")) as fh:
            head = fh.read().strip()
    except OSError:
        return ""
    return head[16:] if head.startswith("ref: refs/heads/") else ""


# Open PRs are the one fact here that is NOT on disk — it lives on GitHub. So it is split in
# two: `refresh_open_prs` is the ONLY blocking function in this module and is called by a
# long-running caller on its own schedule, while `open_pr_for` is a plain cache read that
# obeys the module contract like everything else. Putting the network call on the per-row
# path would have every surface pay a round trip per lane per tick.
PR_CACHE = os.path.expanduser("~/.claude/cache/fleet-prs.json")
PR_MAX_AGE = 180


def refresh_open_prs(repo_dir, max_age=PR_MAX_AGE):
    """BLOCKING. Re-fetch open PRs into the cache when it is older than max_age."""
    import subprocess
    try:
        if time.time() - os.path.getmtime(PR_CACHE) < max_age:
            return
    except OSError:
        pass
    try:
        out = subprocess.run(
            ["gh", "pr", "list", "--state", "open", "--limit", "100",
             "--json", "number,url,title,headRefName,isDraft"],
            cwd=repo_dir, capture_output=True, text=True, timeout=20,
        )
        if out.returncode != 0:
            return
        # A LIST, not a dict keyed by head branch. Keying by branch made the lookup a single
        # equality test, which is wrong for this workflow: a PR ships from a DEDICATED branch
        # (`pr/dx-16-…`, `john/feat-6-…`) and the lane returns to its own branch immediately
        # after `gh pr create`, so the lane's checked-out branch stops matching the moment the
        # PR exists. Both live PRs were invisible in the panel for exactly that reason.
        prs = json.loads(out.stdout or "[]")
        os.makedirs(os.path.dirname(PR_CACHE), exist_ok=True)
        tmp = PR_CACHE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(prs, fh)
        os.replace(tmp, PR_CACHE)   # atomic: a reader never sees a half-written cache
    except Exception:
        return


def open_prs_for(cwd):
    """[(number, url, is_draft), …] — every open PR belonging to this lane.

    A LIST, like the tracker ids beside it, because a lane routinely has more than one PR in
    flight and showing only the first is a lie that looks like a fact.

    MATCHED TWO WAYS, and the second is the one that works:

      1. head branch == the lane's checked-out branch — true only before a PR exists.
      2. an in-progress ISSUE ID from `.claude/current-work` appearing in the PR's title or
         its head branch name.

    (2) exists because the branch match is dead on arrival here: PRs ship from a dedicated
    branch and the lane switches back to its own immediately after create, so from the moment
    a PR is openable the lane's branch no longer names it. The id is what survives — it is in
    the branch name (`john/feat-6-…`, `pr/dx-16-…`) AND in the title (`(Fixes FEAT-6)`), by
    the same conventions that make the tracker close the issue on merge.
    """
    try:
        with open(PR_CACHE) as fh:
            prs = json.load(fh)
    except (OSError, ValueError):
        return []
    if isinstance(prs, dict):        # pre-2026-08-06 cache shape; treat as empty, not as a crash
        return []

    branch = branch_for(cwd)
    ids = [i for i, _u in todo_pairs_for(cwd)]
    out, seen = [], set()
    for pr in prs:
        head = pr.get("headRefName") or ""
        title = pr.get("title") or ""
        hit = bool(branch) and head == branch
        if not hit:
            hit = any(i.lower() in head.lower() or i in title for i in ids)
        num = pr.get("number")
        if hit and num not in seen:
            seen.add(num)
            out.append((num, pr.get("url") or "", bool(pr.get("isDraft"))))
    return out


def status_line(cwd):
    """What this lane is doing right now — ONE shorthand line, written by the LEAD.

    This replaced scraping the agent's own last 📌 summary out of its transcript. That was
    self-maintaining and it was wrong in the way that matters: a summary is the agent's
    last *utterance*, so a lane that spoke three hours ago and has been parked ever since
    still advertised whatever it was mid-thought about, and a lane whose last turn was a
    trivial reply advertised the turn before that. The panel is a coordination surface, so
    it has to say what is TRUE NOW, which only the coordinator knows.

    Prose is not wanted here. Sixty characters of shorthand that a reader can scan down a
    column beats a sentence that pushes the next lane off the screen.
    """
    for ln in _walk_up(cwd, ".claude", "status").splitlines():
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            return clip(ln)
    return ""


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


# `<label> (<name>) · <TICKET>:` — the row above already shows all three, so repeating them
# inside the ask is noise the reader has to skip past to reach the actual question.
_ASK_PREFIX = re.compile(r"^\s*\S+\s*\([^)]*\)\s*·\s*[A-Z]{2,5}-\d+\s*:\s*")
# A legacy single-line ask numbering its parts "(1) … (2) …". Split so each gets its own marker.
_ASK_ENUM = re.compile(r"\s*\(\d+\)\s*")

# WHAT KIND OF ATTENTION THIS WANTS, as a glyph. A list of nine identical markers tells the
# reader only that there are nine; the kind is what lets them batch — reviews in one sitting,
# product calls in another — and what tells them at a glance whether the next item is ten
# minutes of reading or a decision they have been putting off.
#
# An ask is typed by a leading `<kind>:` token, which is stripped before display. An untyped
# ask is a general action item; that is the honest default, not a fallback to apologise for.
ASK_KINDS = {
    "review":  "🔍",   # a diff, a PR, a bundle — something to read and green-light
    "plan":    "📋",   # a plan awaiting its gate, before any code exists
    "product": "💬",   # a product / business / scoping call only the user can make
    "triage":  "🏷️",   # a tracker question — is this an issue, whose is it, what priority
    "ship":    "🚀",   # a merge, deploy or publish gate
    "todo":    "✅",   # explicit general action — same as untyped, spelled out
}
ASK_GENERAL = "✅"
# The UMBRELLA, and deliberately NOT one of the kinds above: it means "a human owes something
# here" wherever a count or a whole lane is being marked — the header, a lane's row icon, and
# the lead's chat updates. Double-booking it as a kind too would make "⚠️ 9 needs you" read as
# nine general items rather than nine items of assorted kinds.
ASK = "⚠️"

_ASK_KIND = re.compile(r"^([a-z]+)\s*:\s*")


def ask_kind(line):
    """(icon, text) for one ask line, with any `<kind>:` token consumed."""
    line = (line or "").strip()
    m = _ASK_KIND.match(line)
    if m and m.group(1) in ASK_KINDS:
        return ASK_KINDS[m.group(1)], line[m.end():].strip()
    return ASK_GENERAL, line


def needs_input_items(cwd):
    """The asks blocking this agent on a HUMAN as (icon, text), one pair per element.

    Returns a list rather than a string because an agent routinely has more than one, and the
    previous reader took `splitlines()[0]` — so a second question was silently invisible. A
    truncated ask looks exactly like a complete one, which is the worst shape for a signal whose
    whole job is to say what the human still owes.
    """
    body = _walk_up(cwd, ".claude", "needs-input").strip()
    if not body:
        return []
    items = []
    for ln in body.splitlines():
        ln = _ASK_PREFIX.sub("", ln.strip())
        if not ln or ln.startswith("#"):
            continue
        parts = [p.strip(" ;") for p in _ASK_ENUM.split(ln)] if _ASK_ENUM.search(ln) else [ln]
        for p in parts:
            if not p:
                continue
            icon, text = ask_kind(p)
            # Clipped AFTER the kind token is consumed, so typing an ask costs it no width.
            items.append((icon, clip(text)))
    return items


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
