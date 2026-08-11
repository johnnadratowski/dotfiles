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


def _find_up(cwd, *rel):
    """Path of the first readable non-empty <ancestor>/<rel...>, walking up from cwd.

    Walked rather than resolved with git: no subprocess, and these run per row per tick.

    Split out from _walk_up because a file's CONTENT is not the only fact worth having about
    it — when it was last written is the other one, and a reader handed only the text cannot
    tell a line written a minute ago from the same line written last week.
    """
    p = cwd if isinstance(cwd, str) and cwd else None
    for _ in range(24):
        if not p:
            break
        f = os.path.join(p, *rel)
        try:
            if os.path.getsize(f) > 0:
                return f
        except OSError:
            pass
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    return ""


def _walk_up(cwd, *rel):
    """Contents of the first readable non-empty <ancestor>/<rel...>, walking up from cwd."""
    f = _find_up(cwd, *rel)
    if not f:
        return ""
    try:
        with open(f) as fh:
            return fh.read()
    except OSError:
        return ""


# A tracker id, and nothing else. Recognising the SHAPE rather than "a short token with no
# spaces" is what lets the reader skip a checkpoint header or a stray word and still find the
# pointer line underneath it -- and what stops a `#` comment ever being rendered as a ticket.
_TICKET = re.compile(r"^[A-Z]{2,5}-\d+$")
# The same id inside a branch name (`john/dx-16-...`, `pr/srv-22-...`). Anchored on a
# separator so `feature-2` is not read as a ticket.
_BRANCH_TICKET = re.compile(r"(?:^|[/_-])([A-Za-z]{2,5}-\d+)(?![A-Za-z0-9])")


def todo_pairs_for(cwd):
    """[(id, url), …] for the worktree this agent works in.

    Tracking lives in Linear, which has no cheap local state to read, so `/todo` mirrors the
    id to a gitignored per-worktree file and every status surface reads that -- the same
    mirror the main bar uses, so the surfaces cannot disagree.

    THE FILE IS AGENT DILIGENCE, SO THE READER IS FORGIVING ABOUT WHERE THE POINTER SITS.
    It used to read line 1 and stop at the first line that did not look like an id, which is
    correct for a tidy file and silently blank for a real one: two live lanes at once had a
    shutdown checkpoint above the pointer, so the column showed nothing at all. Now anything
    before the first ticket-shaped line is a header and is skipped; the run of ticket lines
    that follows is the answer; the first non-ticket line after it is resume prose and ends
    the list, so an id mentioned in a paragraph never becomes a second ticket.

    The URL is validated, not just taken. Field 2 is a URL *by convention* — `/todo` writes
    `<ID>\\t<url>` — but the same file is where agents leave themselves resume prose, and a
    line whose second field is a note would otherwise become a hyperlink to that note. A
    caller that cannot tell a real link from a broken one shows a broken one, so the scheme
    check happens here, once, rather than in each surface.
    """
    pairs, seen = [], set()
    for ln in _walk_up(cwd, ".claude", "current-work").splitlines():
        ln = ln.strip()
        parts = ln.split("\t")
        first = parts[0].strip()
        if not _TICKET.match(first):
            # THE POINTER BLOCK IS CONTIGUOUS, and that is what bounds the search. Skipping
            # comments everywhere would not do: one lane's file carries 370 commented
            # checkpoint lines and then repeats its pointer, so a scan that treated `#` as
            # invisible read the same ticket twice. Above the first ticket anything goes;
            # from the first ticket on, the first line that is not one — blank, comment or
            # prose — is the end of the list.
            if pairs:
                break
            continue
        url = parts[1].strip() if len(parts) > 1 else ""
        if not url.startswith(("http://", "https://")):
            url = ""
        if first not in seen:
            seen.add(first)
            pairs.append((first, url))
    return pairs


def branch_ticket_for(cwd):
    """The tracker id encoded in this worktree's branch name, or "".

    Branch names here are machine-written (`john/dx-16-…`, `pr/srv-22-…`), which is exactly
    what `.claude/current-work` is not.
    """
    m = _BRANCH_TICKET.search(branch_for(cwd) or "")
    return m.group(1).upper() if m else ""


def tickets_for(cwd):
    """([(id, url), …], mismatch) — what this lane is actually on.

    TWO SOURCES, AND THE MACHINE ONE WINS. `current-work` is written by hand and goes stale
    without any signal; the branch is written by the tooling that created it. When they
    disagree the branch's id is reported and `mismatch` is True, so the surfaces can mark the
    row rather than quietly picking a side the reader cannot see. The branch carries no URL —
    callers linkify a bare id from the workspace base.
    """
    pairs = todo_pairs_for(cwd)
    bt = branch_ticket_for(cwd)
    if bt and bt not in [i for i, _ in pairs]:
        return [(bt, "")], True
    return pairs, False


def todo_for(cwd):
    """The in-progress tracker id(s), space-joined. See tickets_for for which source wins."""
    return " ".join(i for i, _ in tickets_for(cwd)[0])


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
# The READ-side ceiling, and the one the write-side max age cannot stand in for. PR_MAX_AGE
# only says when a refresh is due; nothing said when the file stops being worth believing. So
# a `gh` that quietly stops working -- expired auth, no network, a rate limit -- left the last
# good snapshot on disk forever and the panel went on advertising PRs that merged days ago,
# with no symptom anywhere. Past this, an unrefreshed cache reports nothing rather than
# yesterday's truth: a missing PR column is obviously missing, a wrong one is not.
PR_STALE_AFTER = 900


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
        if time.time() - os.path.getmtime(PR_CACHE) > PR_STALE_AFTER:
            return []
        with open(PR_CACHE) as fh:
            prs = json.load(fh)
    except (OSError, ValueError):
        return []
    # A cache written in the OLD shape (dict keyed by head branch) is not merely useless — it is
    # SELF-PERPETUATING if we just return []. `refresh_open_prs` rewrites on AGE alone, so any
    # still-running old process keeps re-writing the old shape inside the refresh window and the
    # panel stays empty forever with nothing looking broken. Delete it instead: an absent cache
    # forces the very next refresh, and the writer that wins is whichever process has new code.
    if not isinstance(prs, list):
        try:
            os.remove(PR_CACHE)
        except OSError:
            pass
        return []

    branch = branch_for(cwd)
    # tickets_for, not todo_pairs_for: when the lane's file has gone stale, matching on the
    # id it still names surfaces the PREVIOUS ticket's PRs on this lane -- the same stale
    # bookkeeping showing up in a second column.
    ids = [i for i, _u in tickets_for(cwd)[0]]
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

    THE CLIP IS THE COLUMN'S CONSTRAINT, NOT THE RECORD'S. A surface with room for the whole
    line must read status_text() instead — widening downstream is impossible, because by the
    time this value reaches the JSON the rest of the sentence no longer exists.
    """
    for ln in status_text(cwd).splitlines():
        return clip(ln)
    return ""


def status_text(cwd):
    """The lane's status file UNCLIPPED — every content line, comments and blanks dropped.

    The counterpart to status_line: same file, same filtering, no 60-char cap and no
    first-line-only. Two functions rather than one with a flag, because the cap belongs to
    the CALLER's layout, and the caller that has a whole dialog to spend must not have to
    remember to opt out of a limit that was never about the data.
    """
    return "\n".join(
        ln.strip() for ln in _walk_up(cwd, ".claude", "status").splitlines()
        if ln.strip() and not ln.strip().startswith("#"))


# WHEN A STATUS STOPS SPEAKING FOR THE PRESENT. The status file has no refresher: a human
# writes it and nothing ever expires it, so the failure mode is silent and total — the panel
# went on advertising four-day-old lines ("PR #130 open; awaiting your merge") as the live
# state of the fleet, long after #130 merged. Every fact around it was correct and moving,
# which is exactly what made the frozen one invisible.
#
# NOT the PR cache's treatment (blank it past PR_STALE_AFTER). That cache refreshes itself
# every three minutes, so silence there means broken. Here silence is normal — a lane can
# legitimately be doing the same thing all afternoon — and blanking would delete the only
# description of the lane the panel has. So the line STAYS and wears its age instead: the
# reader gets both the claim and how old the claim is, and decides.
#
# Two hours: longer than any turn, shorter than a working session. Past it, "now" is a claim
# the file can no longer back.
STATUS_STALE_AFTER = 2 * 3600


def status_age(cwd):
    """Seconds since this lane's status line was last written, or None if there is none.

    mtime of the FILE, not of anything in it: the line carries no timestamp, and asking the
    filesystem costs one stat on a path _find_up already resolved.
    """
    f = _find_up(cwd, ".claude", "status")
    if not f:
        return None
    try:
        return max(0, int(time.time() - os.path.getmtime(f)))
    except OSError:
        return None


def fmt_age(secs):
    """A staleness suffix a reader takes in without parsing — "3h", "4d", "" when fresh.

    Deliberately coarser than fmt_secs, which serves uptime and owes minutes. Nobody acts on
    the difference between a status written 102h07m ago and one written 103h ago; they act on
    "4d". Returns "" below the threshold so the common case — a status that means what it
    says — carries no decoration at all.
    """
    if secs is None or secs < STATUS_STALE_AFTER:
        return ""
    if secs < 86400:
        return "%dh" % (secs // 3600)
    return "%dd" % (secs // 86400)


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


# ── an ask's METADATA TRAILERS ───────────────────────────────────────────────────────────
# An ask line is written for a HUMAN to read in one line, and that line is the product. The
# facts around it — which ticket it is about, who raised it, when, what it is holding up —
# are worth keeping, but every one of them spent inline is a word of the actual question
# pushed off the 60-char list view. So they ride at the TAIL, in brackets, and the one-line
# views drop them: `[SRV-24] [from:feature-3] [added:2026-08-10] [unblocks:vii idle]`.
#
# BRACKETS, AND ONLY AT THE END. Parsing is a repeated bite off the tail, never a scan of the
# whole line, because an ask is prose and prose contains brackets — "the [sic] in their reply"
# is text, not metadata, and a line-wide regex would eat it.
#
# A BARE trailer is a ticket: `[SRV-24]`, `[PR#147]`. Everything else is `key:value`.
#
# UNKNOWN TRAILERS ARE KEPT, NOT REJECTED. A key this reader has never heard of renders
# verbatim in the detail dialog under an empty label. The lead writes this file by hand and
# the format will grow; a parser that errored on the first unrecognised key would make every
# extension a breaking change, and one that silently DROPPED it would lose the fact without
# ever saying so.
ASK_TRAILER_KEYS = ("ticket", "from", "added", "unblocks")

_TRAILER_TAIL = re.compile(r"\s*\[([^\[\]]+)\]\s*$")
_TRAILER_KV = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*)$")
_TRAILER_TICKET = re.compile(r"^(?:[A-Z]{2,5}-\d+|PR#\d+|#\d+)$")


def ask_trailers(line):
    """(text, trailers) — an ask split from the bracket trailers on its tail.

    `trailers` is a list of (key, value) in the order they were WRITTEN, with the key lowered
    for the ones this reader knows. An unrecognised trailer keeps its whole raw body under an
    empty key, which is how every caller spells "render this as-is".
    """
    text = (line or "").rstrip()
    found = []
    while True:
        m = _TRAILER_TAIL.search(text)
        if not m:
            break
        found.append(m.group(1).strip())
        text = text[:m.start()].rstrip()
    trailers = []
    for raw in reversed(found):          # bitten off back-to-front; restore writing order
        kv = _TRAILER_KV.match(raw)
        if kv and kv.group(1).lower() in ASK_TRAILER_KEYS:
            trailers.append((kv.group(1).lower(), kv.group(2).strip()))
        elif _TRAILER_TICKET.match(raw):
            trailers.append(("ticket", raw))
        else:
            trailers.append(("", raw))
    return text, trailers


# The deferral stamp `/whats-next` writes into these lists when the user puts an item off. It
# stays INLINE in the one-line views — "why is this still here" is answered by the stamp, and
# a list that hid it would re-ask a question the user already declined. The dialog has room
# to give it its own labelled field, so there it is lifted out of the prose.
_DEFERRED = re.compile(r"\s*\((deferred\b[^()]*)\)\s*$", re.I)


def ask_deferral(text):
    """(text, stamp) — the trailing `(deferred …)` stamp lifted out of an ask's text."""
    m = _DEFERRED.search(text or "")
    if not m:
        return (text or "").rstrip(), ""
    return text[:m.start()].rstrip(), m.group(1).strip()


def ask_detail(line):
    """Everything one ask line carries, for the surface that has room to show all of it.

    Ordered the way the line is written — kind token, prose, deferral stamp, trailers — and
    each layer peeled by the reader that owns it, so the detail view and the one-line views
    cannot disagree about where the prose ends.
    """
    raw = (line or "").strip()
    m = _ASK_KIND.match(raw)
    if m and m.group(1) in ASK_KINDS:
        kind, icon, body = m.group(1), ASK_KINDS[m.group(1)], raw[m.end():].strip()
    else:
        kind, icon, body = "", ASK_GENERAL, raw
    body, trailers = ask_trailers(body)   # trailers sit AFTER the stamp, so they come off first
    body, deferral = ask_deferral(body)
    return {"kind": kind, "icon": icon, "text": body,
            "deferral": deferral, "trailers": trailers}


# ── the fleet's STANDING GOAL ────────────────────────────────────────────────────────────
# One objective the whole fleet is pointed at, owned by the lead and written by the `/goal`
# skill. It lives BESIDE the lanes dir (`<main clone>/.claude/fleet-goal`), for the same
# reason `needs-input-fleet` does: it belongs to the fleet, not to any one lane, and a file
# named this way inside a lane would be found by that lane's own upward walk.
#
# SHAPE: line 1 is the objective, in one line. Every line after it is the dependency chain or
# the notes — what has to land, in order, for the objective to be reached. Blank lines and
# `#` comments are skipped, so the file can be annotated.
#
# ABSENT FILE MEANS NO GOAL, and every reader must render that as NOTHING — not "no goal set",
# not an empty bar. A fleet with no standing objective is the ordinary case, and a header row
# that is always present would spend a line of screen saying so.
GOAL_FILE = "fleet-goal"


def fleet_goal_path(lanes_dir):
    """Where the goal file sits, given the lanes dir. Empty in, empty out — a caller with no
    lanes has no fleet to have a goal, and joining onto "" would name a path in the cwd."""
    lanes_dir = (lanes_dir or "").rstrip("/")
    return os.path.join(os.path.dirname(lanes_dir), GOAL_FILE) if lanes_dir else ""


def fleet_goal(path):
    """(objective, chain) from the goal file: the one-liner, and the lines under it.

    Missing, unreadable or empty file → ("", []), which is how every caller spells "no goal".
    """
    try:
        with open(path) as f:
            body = f.read()
    except OSError:
        return "", []
    lines = [ln.rstrip() for ln in body.splitlines()
             if ln.strip() and not ln.lstrip().startswith("#")]
    return (lines[0], lines[1:]) if lines else ("", [])


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


def agent_transcript(name, cwd=""):
    """This agent's live transcript, resolved WITHOUT tmux and without the harness.

    Same precedence agent-fanout.sh's _ctx_transcript uses, so the two surfaces cannot
    disagree about which file belongs to an agent:

      1. the recorded `~/.claude/agents/<name>.transcript` sidecar — the exact file the
         session hook wrote for THAT agent, so a cwd hosting several sessions is unambiguous
      2. the recorded `~/.claude/agents/<name>.cwd` sidecar → newest file in its project dir
      3. the caller's own cwd → newest file in its project dir

    A sidecar is written once per session, so after a restart it can point at a file the
    agent has stopped writing. That only ever UNDER-reports activity, and the caller's
    session-exact path (fleet-status.sh's parent_session_for) takes precedence over this
    whenever it has one — so the stale case cannot make a dead lane look alive.
    """
    if not isinstance(name, str) or not name:
        return transcript_for(cwd)
    base = os.path.expanduser("~/.claude/agents")
    try:
        with open(os.path.join(base, name + ".transcript")) as fh:
            p = fh.read().strip()
        if p and os.path.isfile(p):
            return p
    except OSError:
        pass
    try:
        with open(os.path.join(base, name + ".cwd")) as fh:
            rec = fh.read().strip()
    except OSError:
        rec = ""
    return transcript_for(rec) or transcript_for(cwd)


def last_active(path):
    """Seconds since the agent last wrote to `path`, or None when there is no transcript.

    THE ANSWER `.claude/status` CANNOT GIVE. The status line says what a lane is doing; only
    a human writes it, so it says nothing about whether the lane is still there — which is
    how every lane's status came to sit frozen for four days beside numbers that kept moving.
    A transcript's mtime needs nobody to maintain it: the agent stamps it by working.

    The two facts are complementary and BOTH are shown — status age is "when was this claim
    last written", this is "when did the agent last do anything". A fresh-looking status on a
    silent agent, and a stale status on a busy one, are different problems.
    """
    if not path:
        return None
    try:
        return max(0, int(time.time() - os.path.getmtime(path)))
    except OSError:
        return None


def fmt_ago(secs):
    """How long ago, at the coarseness a reader acts on — "<1m", "7m", "3h", "4d".

    Unlike fmt_age this NEVER returns "" for a known value: the point of the field is that it
    is always present, so silence means "no transcript", never "recent enough not to mention".
    """
    if secs is None:
        return ""
    if secs < 60:
        return "<1m"
    if secs < 3600:
        return "%dm" % (secs // 60)
    if secs < 86400:
        return "%dh" % (secs // 3600)
    return "%dd" % (secs // 86400)


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


# Families whose current generations carry a 1M window. NOT a guess about the future: a
# family absent from here resolves to NO window rather than to a default, because the default
# is what produced a 216% gauge -- the lead was running `claude-fable-5`, which matched
# neither `opus` nor `sonnet`, so it fell through to 200k against 357k of real occupancy.
_WIDE_FAMILIES = ("opus", "sonnet", "fable", "mythos")
_NARROW_FAMILIES = ("haiku",)


def window_for(model):
    """Context window for a model name, or None when the name is not recognised.

    NONE IS THE POINT. Every caller divides by this, and a wrong denominator does not
    announce itself: 200k under a 1M model reads 216% at 357k used -- absurd, and therefore
    caught -- but it also reads a perfectly plausible 80% at 128k. A gauge that can be
    silently wrong is worse than one that admits it does not know, so an unknown model
    yields no percentage at all.

    Rules, in order: an explicit [1m] marker wins; a known-narrow family (haiku) is 200k
    whatever its major version; a known-wide family is 1M from major 4 on, 200k before it.
    """
    m = str(model or "").lower()
    if not m:
        return None
    if "1m" in re.findall(r"\[([^\]]*)\]", m) or m.endswith("-1m"):
        return 1_000_000
    if any(f in m for f in _NARROW_FAMILIES):
        return 200_000
    fam = re.search(r"(%s)[-_]?(\d+)" % "|".join(_WIDE_FAMILIES), m)
    if fam:
        return 1_000_000 if int(fam.group(2)) >= 4 else 200_000
    return None


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
