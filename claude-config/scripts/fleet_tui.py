# /// script
# requires-python = ">=3.11"
# dependencies = ["textual>=8,<9"]
# ///
"""fleet-tui — the lead's fleet view, as a real TUI.

Run it with `fleet-tui.sh`, which hands it to `uv run` so textual is fetched into a cached
env rather than installed anywhere.

WHY THIS EXISTS ALONGSIDE fleet-status.sh. The table renderer packs six columns, a status
line and a variable number of asks into a fixed-width grid, and past about four lanes it
reads as one wall of text — the user's word was "not readable". A grid is the wrong shape
for this data: the lanes are cards with a variable tail, and the asks are a to-do list, and
those two want different layouts on the same screen.

WHAT IT DOES NOT DO: it invents no facts. Every lane field comes from `fleet-status.sh
--json`, so the TUI and the table cannot disagree about who is up — and the table stays the
fallback for anywhere textual cannot run (a hook, a CI check, a pipe).

NO STATUS PROSE ON A ROW (John, 2026-08-14). The status line was written by an agent, so it
was only ever as current as that agent's memory — every lane's froze for four days once,
beside numbers that kept moving, and the fix by decoration (an age marker, a transcript-mtime
`active 2m ago`) still spent two lines per lane on a claim nobody maintained. The row is now
one line of facts that maintain themselves — state, ctx%, uptime, tickets, PRs — and 4ME
carries what needs a person. The prose is still read, and still shown IN FULL by the detail
overlay, which is a surface the reader chose to open.

THE HEADER SAYS WHEN IT LAST HEARD ANYTHING (`refreshed 14:32:07`). Every number on this
screen can sit unchanged for a perfectly good reason, so a view that has STOPPED refreshing
looks exactly like a fleet with nothing to say, and the reader is left pressing a key unable
to tell whether it does anything. The stamp moving is the answer; past three ticks with
nothing arriving it stops being a stamp and says NOT REFRESHING, in yellow, on a clock of its
own — the state "no data is coming" cannot be drawn by the arrival of data.

THE HEADER ALSO CARRIES THE FLEET'S STANDING GOAL, when one is set (`<main clone>/.claude/
fleet-goal`, line 1). It is the one line that says what everything else on the screen is FOR,
so it rides above the lanes rather than behind a keypress — and it is re-read on the same tick
as everything else, so a goal the lead rewrites mid-session lands without a restart. No goal
file means no line at all: a fleet with no standing objective is the ordinary case, and a
permanent "no goal" row would spend a row to say nothing.

`r` IS NOT THE TICK. The timer is allowed to serve a three-minute-old PR list, because the
render must never wait on the network. A keypress is a person saying they do not believe what
they are reading, so `r` re-fetches that too, before the snapshot, and pays the round trip.

WHAT IT WRITES, and nothing else. Deletions from the lead's own ask files (ticking an item
off, undoable in-session), and the per-lane tuning knobs in a lane's GITIGNORED
`.claude/workflow.config.local` — never the committed `workflow.config`, which belongs to the
project rather than to this machine. Every value it can write comes from a fixed vocabulary,
because agent-tune.sh later types those strings into a live agent's pane.

ENTER ON A 4ME ROW opens that ask IN FULL, for the same reason: the list is a column and clips
at sixty characters, so the rest of the question was unreachable. The dialog also renders the
ask's bracket TRAILERS — ticket, who raised it, when, what it unblocks — as labelled fields,
marks it when its ticket is one the standing goal names, and hides those trailers from the row.

ENTER ON AN AGENT ROW opens the detail overlay: that lane's status IN FULL — the row shows
none of it, and this is the surface with room for the whole thing — its
branch and distance from the base (local and origin, unfetched), what its session is running
right now, and the config knobs, editable in place. It re-reads itself on the same tick the
panel does, so it is a live view rather than a snapshot of the moment Enter was pressed. The
overlay is the only part of this view that shells out, and it does so on a worker thread — the
five-second tick must never grow a subprocess while no overlay is open.
"""

import io
import json
import os
import re
import subprocess
import sys
import time
from urllib.parse import quote as _urlquote, unquote as _urlunquote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# One definition of the 60-char cap and of the ask vocabulary, shared with the table renderer
# so the two views cannot type the same item differently.
from _agent_facts import (ASK, ASK_GENERAL, ASK_KINDS, LINE_MAX,  # noqa: E402
                          ASK_SORTS, ask_detail, ask_kind, ask_mark_done, ask_short,
                          ask_sort_key,
                          fold_ask_context, goal_mentions,
                          ask_trailers, branch_for, branch_ticket_for, clip, fleet_goal,
                          fleet_goal_path, fmt_age, fmt_ago, refresh_open_prs, status_text,
                          tickets_for)

from rich.console import Console  # noqa: E402
from rich.markup import escape  # noqa: E402
from rich.text import Text  # noqa: E402
from textual.app import App, ComposeResult  # noqa: E402
from textual.binding import Binding  # noqa: E402
from textual.containers import Vertical, VerticalScroll  # noqa: E402
from textual.css.query import NoMatches  # noqa: E402
from textual.widget import MountError  # noqa: E402
from textual.widgets import Footer, Input, ListItem, ListView, Static  # noqa: E402
from textual.worker import get_current_worker  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
STATUS_SH = os.path.join(HERE, "fleet-status.sh")

STATE_ICON = {"busy": "●", "quiet": "◔", "idle": "○", "down": "·"}
STATE_STYLE = {"busy": "green", "quiet": "yellow", "idle": "dim", "down": "red"}

# The lane-row umbrella, in TEXT presentation (U+26A0 with no variation selector) rather than
# the emoji ⚠️ the table and the chat use. Same meaning, and the divergence is deliberate: with
# VS16 the terminal picks an emoji font, which on this machine drew an unrecognisable grey box
# beside exactly the three lanes that owed an answer — a marker nobody can read is worse than
# no marker. The text form takes the surrounding style, so it is coloured rather than drawn.
LANE_ASK = "⚠"


# ── A REVIEW STAGED FOR THE HUMAN ────────────────────────────────────────────────────────
# A lane that has staged a diff or a plan in the Monocle engine is BLOCKED ON A PERSON, and
# nothing on the row said so: it renders `idle`, which is what a lane with nothing to do also
# renders. The two are opposite facts about whose turn it is.
#
# READ FROM A FLAG FILE THE LANE WRITES, never by probing an engine. `review_status` answers
# "no feedback pending" whether or not an engine is even up, so a TUI that polled it would
# report "nothing staged" identically for a quiet fleet and a dead one — an instrument that
# cannot say "I don't know" is worse here than no instrument, because this row is what the
# user checks INSTEAD of looking.
#
# THE TIMESTAMP IS THE FILE'S MTIME rather than a line inside it. A stamp written into the
# body is a second thing to keep true, and it goes stale silently the first time a lane
# rewrites the file without touching it; mtime is maintained by the act of writing. Same
# reasoning as the transcript mtime the `active Xm ago` clock already rides on.
REVIEW_FILE = "monocle-staged"   # <lane>/.claude/monocle-staged
REVIEW = "🔍"                    # already this TUI's word for review — `review:` asks wear it


def staged_review(path):
    """{"name", "age"} for a lane with a review staged, else None.

    An EMPTY file still means staged. The name is a courtesy for the dialog; the fact the
    user acts on is the file's existence, so a lane that writes nothing into it must not
    thereby report that it is waiting on nobody.
    """
    if not path:
        return None
    try:
        st = os.stat(path)
        with open(path) as f:
            name = f.readline().strip()
    except OSError:
        return None
    return {"name": name, "age": max(0, _now() - st.st_mtime)}


def _ask_lines(path):
    """Raw ask lines from a needs-input file — RAW, deliberately.

    The renderer's needs_input_items() clips to 60 and may split a legacy inline enumeration,
    so its output cannot be matched back against the file it came from. This view deletes
    lines, so it needs the bytes that are actually on disk; clipping happens at display time.
    """
    try:
        with open(path) as f:
            body = f.read()
    except OSError:
        return []
    kept = [ln.rstrip() for ln in body.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]
    # Folded by the SHARED reader in _agent_facts, because `fleet-status.sh` reads these same
    # files — see fold_ask_context for why a folder in only one of them corrupts the other.
    return fold_ask_context(kept)


def _drop_line(path, raw):
    """Remove the first occurrence of `raw` — WITH ITS CONTEXT BLOCK.

    Returns THE BYTES IT REMOVED, `""` when nothing matched — truthy exactly where the old
    `True` was, so `if _drop_line(...)` still reads as "it changed", but the text is what
    makes `u` an actual inverse. Returning a bare True is what broke it.

    UNDO MUST BE GIVEN THE FILE'S OWN BYTES, NOT THE FOLDED FORM. `raw` comes from
    `fold_ask_context`, which STRIPS each continuation line's indent to join a block into one
    string. Restoring that text wrote the context back FLUSH LEFT, and the next read then
    parsed those lines as top-level asks: one item silently became N, the count in the panel
    title was wrong, and `x` on a stray deleted prose. Measured — a 2-ask file came back as 5
    asks after one `x` then `u`. Nothing raised, which is why it survived; the undo test's
    fixture was a single-line ask, so it had no continuation lines to lose.

    Rewrites rather than truncates: another line may have been added since the snapshot, and
    a to-do list that loses an entry nobody ticked off is worse than one that fails to tick.

    MATCHED ON THE FIRST LINE, DELETED AS A BLOCK. Matching the whole folded string would
    depend on reproducing the exact indentation the file used. The first line is the ask's
    identity; the indented lines under it are by definition part of it, and leaving them
    behind would orphan a paragraph under an unrelated item.
    """
    head = (raw or "").split("\n", 1)[0].rstrip()
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return ""
    for i, ln in enumerate(lines):
        if ln.rstrip() != head:
            continue
        # A BLANK LINE INSIDE A CONTEXT BLOCK MUST NOT END IT. `_ask_lines` drops blanks
        # before folding, so a paragraph break reads as ONE item — but this scan used to stop
        # at the first blank, delete only the half above it, and leave the rest behind as an
        # indented orphan that the next read renders as its own bogus ask. Measured on
        # `head / "  ctx one" / "" / "  ctx two"`: the head went, `  ctx two` survived as a
        # phantom row, and the count never moved. With bytes now round-tripping through undo
        # it also meant `u` restored half an item.
        #
        # SO BLANKS ARE TAKEN TENTATIVELY. `pending` counts the run of them; a genuine
        # continuation line proves the block carried on and confirms them, while anything
        # else ends the block and hands them back. That last part is the half worth stating:
        # the blank line BETWEEN two asks is the file's own spacing, and swallowing it would
        # reformat a human's list every time something above it was ticked off.
        j = i + 1
        pending = 0
        while j < len(lines):
            if not lines[j].strip():
                pending += 1
                j += 1
            elif lines[j][:1].isspace():
                j += 1
                pending = 0
            else:
                break
        j -= pending
        removed = "\n".join(lines[i:j])
        del lines[i:j]
        with open(path, "w") as f:
            f.write("\n".join(lines) + ("\n" if lines else ""))
        return removed
    return ""


def _mark_line_done(path, raw, note=""):
    """Tick an ask off IN PLACE — `✅` onto its head line, an optional `[note:]` on the tail.

    Returns the line it wrote, `""` when nothing matched — the same truthiness contract as
    `_drop_line`, whose head-line matching this shares and for the same reason: `raw` arrives
    folded, so its first line is the only part of it that exists in the file verbatim.

    THE ROW STAYS. That is the entire point of the key. `x` removes an item and takes with it
    the fact that anyone dealt with it, so on the lead's next sync a handled ask and an ask
    nobody had opened looked identical — and both looked identical to a mis-keyed `x`. A
    marked row is a POSITIVE statement, left standing until the lead's own sweep removes it.

    ONLY THE HEAD LINE IS REWRITTEN. The indented lines under an ask are the reasoning that
    made it answerable; they are still worth reading after it has been answered, and they are
    not where a marker belongs.
    """
    head = (raw or "").split("\n", 1)[0].rstrip()
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return ""
    for i, ln in enumerate(lines):
        if ln.rstrip() != head:
            continue
        lines[i] = ask_mark_done(ln.rstrip(), note)
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
        return lines[i]
    return ""


_TICKET = re.compile(r"\b([A-Z]{2,5}-\d+)\b")
_PR = re.compile(r"#(\d+)\b")


def esc(s):
    """Escape EVERY bracket, not just the tag-shaped ones `rich.markup.escape` catches.

    Used for free text this file renders into markup — an ask's deferral stamp, a trailer
    value — where the content is prose a human typed and any `[` in it is a literal. See
    `linkify` for the failure this prevents.
    """
    return (s or "").replace("[", "\\[")


def linkify(text, ctx):
    """Make every ticket id and PR number in a string clickable, wherever it appears.

    The table renderer only ever linked the ▸ column, so an id mentioned in a status or an ask
    was dead text — and those are where most of them are. Textual emits OSC-8 for `[link=…]`,
    so this is the same mechanism the table used, applied to the whole line.

    PASS IT RAW — it escapes the text itself, and it has to be the one that does.

    This used to be called as `linkify(escape(text))`, on the reasoning that "neither an id nor
    a `#123` contains a bracket, so the order is safe". The claim was about the ID and the
    hazard was in the TEXT AROUND IT. `rich.markup.escape` only escapes a `[` that already
    looks like a tag, so `[PR#124]` — capital P, not tag-shaped — came through untouched; this
    function then inserted a link INSIDE it, and the renderer read `[PR…]` as an opening tag
    with a stray `[/link]` after it and raised MarkupError. A fleet ask, a lane status or a
    goal line mentioning a bracketed PR was enough to take the whole TUI down.

    So every `[` is escaped here, unconditionally, and the links are inserted afterwards —
    the one ordering in which no input can be mistaken for markup.

    A base URL is only ever LEARNED, never assembled from a guess about the workspace — a
    hyperlink that 404s is worse than plain text, because it looks authoritative.
    """
    text = (text or "").replace("[", "\\[")
    base, repo = ctx.get("linear_base"), ctx.get("repo")
    if base:
        text = _TICKET.sub(
            lambda m: "[link='%s']%s[/link]" % (
                linear_uri("%s/issue/%s" % (base, m.group(1))), m.group(1)), text)
    if repo:
        text = _PR.sub(
            lambda m: "[link='%s/pull/%s']#%s[/link]" % (repo, m.group(1), m.group(1)), text)
    return text


# ── A DOC REFERENCE IN AN ASK ────────────────────────────────────────────────────────────
# An ask that points at a written artefact — a findings doc, a plan — carries its whole
# absolute path, and the path is longer than the 60-char row: `triage: CONSOLIDATED FINDINGS
# — file:///Users/john/git/goals-onchain/.claude/worktrees/team-lead/.claude/plans/…` spent
# the entire column on a location and clipped away the question. So the ROW shows one
# clickable page glyph instead; the dialog, which has room, shows the path itself — and
# links THAT, so the location is readable, copyable and openable on the one surface that
# has room for all three.
#
# THE GLYPH RIDES THE END OF THE LINE, ALWAYS (John 2026-08-18). It used to sit where the
# path had stood, which put it mid-sentence on a short ask and at the tail on a long one —
# two positions for one meaning, and on a row near its budget the in-place glyph pushed the
# prose past the column and wrapped the item onto a second line. One position, always the
# last thing on the row, and the prose is clipped to leave room for it.
#
# THE MARK IS SUBSTITUTED BEFORE CLIPPING AND LINKED AFTER. Clipping first would cut the path
# mid-way and leave a broken link; linking first would hand `linkify` a bracket to escape (and
# a `.../SRV-24.md` path an id to insert a link INSIDE). One char stands in during both, and
# U+FFFC is the character whose meaning is exactly that — a human writing an ask cannot type
# it, so nothing in prose can be mistaken for one. The marks are dropped from the prose at
# render time (with the whitespace that fenced them), because the glyph they stood for is no
# longer rendered in their place.
DOC = "\U0001F4C4"
_DOC_MARK = "\ufffc"
# A `file://` URL of any kind, or a bare absolute path to a .md. Bounded by whitespace and by
# the bracket/quote characters that fence a path in prose, so a trailing `]` or `"` is not
# eaten into the href.
_DOC_REF = re.compile(r"file://(?:localhost)?(/[^\s\]\[<>\"']+)"
                      r"|(?<![\w/])(/[^\s\]\[<>\"']+\.md)\b")
# A mark and the whitespace that fenced it, collapsed to one space: the path is gone from the
# prose, and the two spaces and the dangling em-dash that surrounded it should not stay behind.
_DOC_GAP = re.compile(r"\s*\ufffc\s*")


def doc_spans(text):
    """(text with every doc reference replaced by one mark, [(url, as-written) per mark])."""
    spans = []

    def take(m):
        spans.append(("file://" + (m.group(1) or m.group(2)), m.group(0)))
        return _DOC_MARK

    return _DOC_REF.sub(take, text or ""), spans


def doc_refs(text):
    """(text with every doc reference replaced by one mark, [file:// url per mark])."""
    marked, spans = doc_spans(text)
    return marked, [url for url, _raw in spans]


# What one tail badge costs the prose: the glyph's two display cells plus the space before
# it. Spent BEFORE clipping — a badge appended to a row already filling its column wraps the
# list item onto a second line, which costs a whole row of the panel to say one glyph.
_DOC_COST = 3


def fit_ask(text, urls, width=LINE_MAX):
    """Clip an ask's prose, leaving room for the badges that will ride its tail.

    EVERY ref is a badge now, not just the ones the clip drops, so the budget is known up
    front rather than settled against the clip. The floor keeps a row of nothing but
    references from clipping the prose out of existence.
    """
    return clip(text, max(8, width - _DOC_COST * len(urls)))


def _doc_link(url):
    return "[link='%s']%s[/link]" % (url, DOC) if url else DOC


def doc_markup(markup, urls):
    """Drop the marks from the prose and hang one clickable page glyph per ref off the end.

    Pure, and text carrying no mark passes through untouched.
    """
    out = _DOC_GAP.sub(" ", markup or "").strip()
    for url in urls:
        out += " " + _doc_link(url)
    return out


def doc_text_markup(text, link_text):
    """The ask IN FULL with each doc reference linked IN PLACE — the dialog's rendering.

    `link_text` renders the surviving prose (escaping, ticket links); it is applied to the
    marked text so it can neither eat a path nor put a ticket link inside one, exactly as on
    the row. The path is then written back as the link's LABEL, so the dialog stays the
    surface where the location is readable and copyable as well as clickable.
    """
    marked, spans = doc_spans(text)
    parts = link_text(marked).split(_DOC_MARK)
    out = parts[0]
    for i, part in enumerate(parts[1:]):
        url, raw = spans[i] if i < len(spans) else ("", "")
        out += ("[link='%s']%s[/link]" % (url, escape(raw)) if url else "") + part
    return out


_LINEAR_URL = re.compile(r"https?://linear\.app/([^/]+)/issue/([A-Za-z]{2,5}-\d+)")


def linear_uri(url):
    """Rewrite a Linear https URL to `linear://` so the desktop app opens it, not a browser.

    Only the SCHEME is swapped — the workspace and the identifier still come from a URL the
    tracker itself produced. A URL that does not match the expected Linear shape is returned
    untouched rather than coerced: opening a browser is a mild disappointment, opening the
    wrong ticket is not.

    PR links stay https on purpose. GitHub's desktop app registers no comparable scheme, so a
    `github://` URI would simply fail to open.
    """
    m = _LINEAR_URL.match(url or "")
    return "linear://%s/issue/%s" % (m.group(1), m.group(2)) if m else url


_ASK_TICKET_PR = re.compile(r"^(?:PR)?#(\d+)$")
_ASK_TICKET_ID = re.compile(r"^[A-Z]{2,5}-\d+$")


def ask_ticket_url(tid, ctx):
    """The URL an ask's `[TICKET]` trailer resolves to, or "" when it cannot be derived.

    Same rule as linkify's, and for the same reason: a base URL is LEARNED from the fleet, never
    assembled from a guess about the workspace. No base learned ⇒ the detail view shows the id
    as plain text, which is honest, rather than a link that 404s while looking authoritative.
    """
    tid = (tid or "").strip()
    base, repo = (ctx or {}).get("linear_base"), (ctx or {}).get("repo")
    m = _ASK_TICKET_PR.match(tid)
    if m:
        return "%s/pull/%s" % (repo, m.group(1)) if repo else ""
    if _ASK_TICKET_ID.match(tid) and base:
        return linear_uri("%s/issue/%s" % (base, tid))
    return ""


_ASK_ADDED = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")


def ask_age(added):
    """"3d" for an `[added:YYYY-MM-DD]` stamp, or "" — the same shape `fmt_age` gives a lane.

    A DATE IS NOT AN AGE. "added 2026-08-10" makes the reader do the subtraction against a
    today they have to recall, which is exactly the arithmetic that let items sit for weeks
    looking recent. Both are shown: the date is the fact, the age is what it means.

    An unparseable stamp yields "" rather than a guess — the lead writes this file by hand.

    PARSED BY REGEX, NOT `time.strptime`, and that is a CRASH FIX rather than a preference.
    `strptime` imports `_strptime` LAZILY, on its first call. A Homebrew python upgrade
    replaces the Cellar directory a running interpreter was resolved from, so every
    not-yet-imported module vanishes underneath a live process — and the first click on a
    dated ask then died with `ModuleNotFoundError: No module named '_strptime'` inside a
    message handler, which took the whole app down (2026-08-19). The format here is three
    integers; deriving them with a regex needs no import and therefore has no such window.

    THE GENERAL RULE, since this file is long-lived and the next one will not be `strptime`:
    a lazily-imported stdlib module is a dependency that is resolved LATER THAN THE PROCESS
    IT RUNS IN. Prefer what is already imported at module scope inside anything a keypress
    can reach.
    """
    m = _ASK_ADDED.match((added or "").strip())
    if not m:
        return ""
    y, mo, d = (int(g) for g in m.groups())
    try:
        # `mktime` is a C function on the already-imported `time` module — no lazy import.
        # `-1` for isdst lets it resolve the offset; the weekday/yearday fields are ignored.
        then = time.mktime((y, mo, d, 0, 0, 0, 0, 1, -1))
    except (ValueError, OverflowError, OSError):
        return ""
    return fmt_age(max(0, time.time() - then))



def _repo_url(path):
    """The origin remote as a browsable https URL, or "" — never a guess."""
    try:
        out = subprocess.run(["git", "-C", path, "remote", "get-url", "origin"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""
    m = re.match(r"(?:git@([^:]+):|https?://(?:[^@/]*@)?([^/]+)/)(.+?)(?:\.git)?$", out)
    return "https://%s/%s" % (m.group(1) or m.group(2), m.group(3)) if m else ""


# ── the detail view's data: git, the live session, the lane's config ─────────────────────
# Everything below is called OFF the render path, from a worker thread — a git read is tens
# of milliseconds and a tmux capture is a round trip to another process, and the main panel
# already refreshes on a five-second tick that must not grow either cost.

VALID_EFFORT = ("low", "medium", "high", "xhigh", "max")
VALID_MODEL = ("sonnet", "opus", "haiku", "fable")

# The knobs the overlay shows and edits, in reading order. `scope` is the half the user
# cannot infer from the name and MUST be told: a lane knob changes a session that is already
# running (so saving the file alone changes nothing until agent-tune types it in), while a
# subagent knob is read when that subagent is SPAWNED, so the file IS the whole story.
CFG_SPEC = (
    ("WORKFLOW_LANE_EFFORT", "effort", "live"),
    ("WORKFLOW_LANE_MODEL", "model", "live"),
    ("WORKFLOW_PLAN_EFFORT", "effort", "spawn"),
    ("WORKFLOW_PLAN_MODEL", "model", "spawn"),
    ("WORKFLOW_REVIEW_EFFORT_A", "effort", "spawn"),
    ("WORKFLOW_REVIEW_MODEL_A", "model", "spawn"),
    ("WORKFLOW_REVIEW_EFFORT_B", "effort", "spawn"),
    ("WORKFLOW_REVIEW_MODEL_B", "model", "spawn"),
    ("WORKFLOW_TEST_EFFORT", "effort", "spawn"),
    ("WORKFLOW_TEST_MODEL", "model", "spawn"),
)

_ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def lane_num_of(name):
    """team-lead=0, feature-N=N, anything else None — the same mapping agent-tune.sh uses,
    so the per-lane override the TUI shows is the one that script would actually read."""
    if name == "team-lead":
        return 0
    m = re.fullmatch(r"feature-(\d+)", name or "")
    return int(m.group(1)) if m else None


def _split_value(rest):
    """The value token of a shell assignment, and whatever trailed it — a comment, usually.

    Returned as a PAIR so a rewrite can put the trailing comment back. The committed config
    carries an explanation on the same line as several of these knobs, and an edit that ate
    the reason for a setting would be a worse loss than the setting itself.
    """
    if rest[:1] in ('"', "'"):
        end = rest.find(rest[0], 1)
        return (rest[:end + 1], rest[end + 1:]) if end != -1 else (rest, "")
    m = re.match(r"[^\s#]*", rest)
    return m.group(0), rest[m.end():]


def _unquote(tok):
    return tok[1:-1] if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "\"'" else tok


def read_shell_config(path):
    """`KEY=value` pairs from a shell config file. COMMENTED-OUT LINES ARE NOT VALUES.

    The committed config parks unset knobs as `#   WORKFLOW_TEST_MODEL=""`, and reading those
    as set would show a value the shell never assigns — the file would disagree with itself.
    """
    out = {}
    try:
        with open(path) as f:
            body = f.read()
    except OSError:
        return out
    for ln in body.splitlines():
        if ln.lstrip().startswith("#"):
            continue
        m = _ASSIGN.match(ln)
        if m:
            out[m.group(1)] = _unquote(_split_value(m.group(2))[0])
    return out


def valid_value(kind, value):
    """Empty means INHERIT and is always allowed; anything else must be a known word.

    Enforced at input time rather than at write time because these strings are interpolated
    into a shell config that agent-tune.sh then TYPES INTO A LIVE AGENT'S PANE. A free-text
    field here would be a keystroke-injection surface, so the field is not free text.
    """
    if value == "":
        return True
    return value in (VALID_EFFORT if kind == "effort" else VALID_MODEL)


def config_rows(lane_path, name):
    """Every knob for this lane, with the file each effective value actually came from.

    Layered the way _config.sh layers them: the gitignored `.local` wins over the committed
    file. The ORIGIN is shown rather than just the value, because "medium" tells you nothing
    about whether you are looking at a project default or at something set on this machine —
    and the edit only ever writes one of the two files.
    """
    committed = read_shell_config(os.path.join(lane_path, ".claude", "workflow.config"))
    local = read_shell_config(os.path.join(lane_path, ".claude", "workflow.config.local"))
    n = lane_num_of(name)
    spec = list(CFG_SPEC)
    if n is not None:
        # The per-lane override sits ABOVE its fleet-wide fallback, which is the order it wins in.
        spec = ([("WORKFLOW_LANE_EFFORT_%d" % n, "effort", "live"),
                 ("WORKFLOW_LANE_MODEL_%d" % n, "model", "live")] + spec)
    rows = []
    for key, kind, scope in spec:
        if key in local:
            value, origin = local[key], "local"
        elif key in committed:
            value, origin = committed[key], "committed"
        else:
            value, origin = "", "unset"
        rows.append({"key": key, "value": value, "kind": kind,
                     "scope": scope, "origin": origin})
    return rows


LOCAL_HEADER = (
    "# Per-clone workflow overrides — gitignored, per-machine, NEVER shared/committed.\n"
    "# Created by fleet-tui's agent detail view.\n"
)


def write_config_value(path, key, kind, value):
    """Set `key` in the LOCAL config, in place, preserving everything else in the file.

    Writes only ever land here — never in the committed `workflow.config`, which is shared
    with every other clone and whose values are the project's, not this machine's.

    Replaces the FIRST active assignment and appends when there is none, so a knob that only
    exists as a commented-out example in the committed file gains a real line rather than
    silently editing the comment.
    """
    if not valid_value(kind, value):
        raise ValueError("%s is not a valid %s" % (value, kind))
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        lines = LOCAL_HEADER.splitlines()
    new = '%s="%s"' % (key, value)
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith("#"):
            continue
        m = _ASSIGN.match(ln)
        if m and m.group(1) == key:
            lines[i] = new + _split_value(m.group(2))[1]
            break
    else:
        lines.append(new)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return True


def _git(path, *args, timeout=5):
    try:
        p = subprocess.run(["git", "-C", path] + list(args),
                           capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def _counts(path, base):
    """(ahead, behind) against `base`, or None when the ref does not exist here.

    `--left-right --count base...HEAD` prints "<only in base>\t<only in HEAD>", so the left
    number is how far BEHIND this lane is and the right is how far ahead. None rather than
    (0, 0) on a missing ref: a lane with no `origin/master` yet and a lane exactly level with
    it are different facts, and zeros would render them identically.
    """
    out = _git(path, "rev-list", "--left-right", "--count", "%s...HEAD" % base)
    if not out:
        return None
    parts = out.split()
    if len(parts) != 2:
        return None
    try:
        return int(parts[1]), int(parts[0])
    except ValueError:
        return None


def git_state(path, base="master"):
    """Branch, dirt, and distance from the base — locally and at the last-known origin.

    NO FETCH. `origin/master` is read exactly as the local ref has it, and the view says so:
    a network call on a keypress would block the UI for as long as the network felt like it,
    and a number that is a few minutes old is far better than a view that hangs.
    """
    porcelain = _git(path, "status", "--porcelain")
    return {
        "base": base,
        "branch": branch_for(path),
        "dirty": (len([ln for ln in porcelain.splitlines() if ln.strip()])
                  if porcelain is not None else None),
        "local": _counts(path, base),
        "origin": _counts(path, "origin/" + base),
    }


def parse_status_text(text):
    """(model, effort) out of an agent's status line — "?" for whatever is not there.

    THE PADDING IS U+00A0, not a space. agent-tune.sh learned this the expensive way: every
    shell-native match against a captured pane returns empty, which a caller renders as a
    confident "?" that never once verified anything. Normalise, then match.
    """
    txt = (text or "").replace(" ", " ")
    m = re.findall(r"Model:\s*([A-Za-z][A-Za-z0-9]*)", txt)
    e = re.findall(r"Thinking:\s*([a-z]+)", txt)
    return (m[-1] if m else "?"), (e[-1] if e else "?")


def _team_panes():
    """name -> tmux pane, for every team member the harness has placed in a live pane.

    The team config is authoritative, exactly as it is for agent-tune.sh: a pane title is
    whatever the agent renamed itself to, and `ps` cannot see the pane's claude because it is
    a grandchild. Panes the config still lists but tmux no longer has are dropped.
    """
    try:
        live = set(subprocess.run(["tmux", "list-panes", "-a", "-F", "#{pane_id}"],
                                  capture_output=True, text=True, timeout=5).stdout.split())
    except (OSError, subprocess.SubprocessError):
        return {}
    out = {}
    root = os.path.expanduser("~/.claude/teams")
    try:
        dirs = sorted(os.listdir(root))
    except OSError:
        return {}
    for d in dirs:
        try:
            with open(os.path.join(root, d, "config.json")) as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            continue
        for m in cfg.get("members") or []:
            pane, nm = m.get("tmuxPaneId") or "", m.get("name") or ""
            if nm and pane.startswith("%") and pane in live:
                out[nm] = pane
    return out


# ── JUMPING TO A LANE'S MONOCLE ─────────────────────────────────────────────────────────
# The 🔍 on a row says a review is staged for the user; the review itself is in the lane's
# Monocle pane, in another tmux window. Ctrl+click on the row takes them there.
#
# THE WINDOW IS DERIVED FROM THE AGENT'S OWN PANE, never from a lane -> window table. A lane's
# window is NAMED for its nickname ("vii (1)"), which is a human label the harness renames at
# will; the pane id in the team config is the one identifier this view and tmux already agree
# on, and it is the same one `live_tuning` reads the model out of.
MONOCLE_CMD = "monocle"


def monocle_pane(name):
    """The pane running Monocle in the window that holds this agent's pane, or "".

    "" for every honest failure — no pane in the config, the window gone, no Monocle running
    in it. The caller SAYS so rather than jumping somewhere plausible: this action moves the
    user's eyes to another window, and landing on the wrong one is worse than not moving.
    """
    pane = _team_panes().get(name)
    if not pane:
        return ""
    try:
        win = subprocess.run(["tmux", "display-message", "-p", "-t", pane, "#{window_id}"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        if not win:
            return ""
        out = subprocess.run(["tmux", "list-panes", "-t", win, "-F",
                              "#{pane_id} #{pane_current_command}"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.splitlines():
        pid, _, cmd = line.partition(" ")
        if MONOCLE_CMD in cmd and pid.startswith("%"):
            return pid
    return ""


# ── CTRL+HJKL: ONE MOVEMENT, WHETHER THE NEXT THING IS A PANEL OR A PANE ─────────────────
# John navigates tmux with ctrl+hjkl under the vim-tmux-navigator contract: the key moves
# inside the focused APPLICATION first, and only hands off to tmux when there is nothing
# further in that direction. Before this the TUI was never asked — tmux's root-table binding
# forwards these keys only to vim-like commands and navigated for everything else, so moving
# between the FLEET and 4ME panels needed `tab` while moving out of the pane needed ctrl+hjkl.
# One gesture, two rules, decided by which thing you happened to be looking at.
#
# THIS HALF DOES NOT WORK ALONE, AND MUST NOT BE MISTAKEN FOR WORKING. Until the tmux
# condition is extended to forward these keys to this pane, tmux still swallows them and
# nothing here is reachable. The two changes ship together; landing the tmux side FIRST would
# break moving out of the pane entirely, because tmux would stop navigating and this code
# would not yet exist to do it instead.
NAV_FLAG = {"L": "-L", "D": "-D", "U": "-U", "R": "-R"}

# THE NAME TMUX WILL MATCH THIS PANE BY, and the reason it is a TITLE rather than a command.
# The tmux side has to recognise "this pane forwards ctrl+hjkl instead of navigating", and
# the only thing it can see is `pane_current_command` — which for this app is `uv`, because
# it is launched through `uv run`. Matching `uv` would forward the keys to EVERY `uv run`
# pane, and an app that does not implement the hand-off traps the cursor inside it: the same
# swallowed-key failure this feature exists to remove, just moved somewhere else.
#
# `pane_title` is settable and specific. Textual's own `TITLE` does not reach the terminal
# (measured: the pane title stayed the hostname), so the escape is written directly, before
# Textual takes the screen — measured to survive its startup.
TMUX_TITLE = "fleet-tui"


def set_pane_title(name=TMUX_TITLE, stream=None):
    """Name this pane for tmux. Silent no-op anywhere the name could not be used or seen."""
    stream = stream or sys.stdout
    if not os.environ.get("TMUX"):
        return False
    try:
        if not stream.isatty():
            return False
        stream.write("\033]2;%s\007" % name)
        stream.flush()
    except (OSError, ValueError, AttributeError):
        return False
    return True


def select_pane(direction):
    """Hand the movement to tmux. False when there is no tmux to hand it to.

    INLINE, NOT ON A WORKER, unlike the monocle jump beside it: that is three round trips
    plus a config read, this is one, and it sits on the keystroke path where a worker's
    scheduling delay would be felt as a sticky key. The timeout is the guard instead.

    `TMUX_PANE` rather than tmux's own idea of the current pane: they agree today, and
    naming the pane we are actually in costs nothing to be certain of.
    """
    pane = os.environ.get("TMUX_PANE") or ""
    if not os.environ.get("TMUX") or not pane or direction not in NAV_FLAG:
        return False
    try:
        return subprocess.run(["tmux", "select-pane", NAV_FLAG[direction], "-t", pane],
                              capture_output=True, timeout=2).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def focus_pane(pane):
    """Put `pane` in front of the client: window selected, pane selected, zoomed. True on OK.

    UNTESTED: nothing asserts what this returns when tmux REFUSES. Both callers now branch
    on it — ctrl+click and the 🔎 badge — and the suite drives them through a stub that always
    succeeds, so a regression that made this return True on a dead pane id would be caught by
    no test. Covering it means faking a non-zero tmux exit, which nothing here does yet.

    THE ZOOM IS CONDITIONAL ON THE WINDOW NOT ALREADY BEING ZOOMED, because `resize-pane -Z`
    TOGGLES — run unconditionally it would un-zoom the very pane it was asked to enlarge on
    every second press. `select-pane` inside an already-zoomed window un-zooms tmux-side, so
    the flag is read AFTER the selection rather than before it.
    """
    try:
        for args in (["select-window", "-t", pane], ["select-pane", "-t", pane]):
            if subprocess.run(["tmux"] + args, capture_output=True, timeout=5).returncode:
                return False
        zoomed = subprocess.run(["tmux", "display-message", "-p", "-t", pane,
                                 "#{window_zoomed_flag}"],
                                capture_output=True, text=True, timeout=5).stdout.strip()
        if zoomed != "1":
            subprocess.run(["tmux", "resize-pane", "-Z", "-t", pane],
                           capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return False
    return True


def live_tuning(name):
    """What the named agent's session is running RIGHT NOW, or None when it cannot be read.

    None, never a guess. The status line is the session's own render of the setting it will
    use next, so when the pane is gone or unreadable the honest answer is to say nothing —
    a stale model name beside a live agent is the one thing this line could get wrong.
    """
    pane = _team_panes().get(name)
    if not pane:
        return None
    try:
        txt = subprocess.run(["tmux", "capture-pane", "-p", "-t", pane],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    model, effort = parse_status_text(txt)
    if model == "?" and effort == "?":
        return None
    return {"pane": pane, "model": model, "effort": effort}


def detail_data(row):
    """Everything the overlay shows, assembled fresh. Runs OFF the UI thread.

    RE-READ ON EVERY OPEN, and never cached: the config files are edited by hooks, by other
    agents and by the user's own editor, and an overlay showing what the file said when the
    TUI started would be a confident lie in exactly the moment the user is about to act on it.
    """
    path = row.get("path") or ""
    name = row.get("name") or ""
    cfg = read_shell_config(os.path.join(path, ".claude", "workflow.config"))
    cfg.update(read_shell_config(os.path.join(path, ".claude", "workflow.config.local")))
    base = cfg.get("WORKFLOW_PR_TARGET_BRANCH") or "master"
    tpairs, tmismatch = tickets_for(path) if path else ([], False)
    # THE UNCLIPPED STATUS, READ FROM THE FILE — not row["status"], which fleet-status.sh has
    # already cut to 60 characters for its column. That cut is why the overlay looked
    # truncated no matter how wide the terminal got: the missing words were gone before the
    # TUI ever saw them, so no amount of reflow could bring them back. The row's copy is the
    # fallback for a row with no path (a subagent), where there is no file to read.
    return {
        "name": name,
        "label": row.get("label") or "",
        "kind": row.get("kind") or "lane",
        "path": path,
        "state": row.get("state") or "?",
        "status": (status_text(path) if path else "") or (row.get("status") or ""),
        "status_age": row.get("status_age"),
        "last_active": row.get("last_active"),
        "context_pct": row.get("context_pct"),
        "git": git_state(path, base) if path else None,
        # BOTH SIDES OF THE TICKET RESOLUTION, re-read here for the same reason as the status
        # text: the row was assembled by a previous poll, and this dialog is where the reader
        # goes when the row's `≠branch` marker made them doubt it. The column shows the work
        # id alone; here the branch's leftover id gets its own labelled line, which is the
        # only place the reader can see WHICH branch-vs-file disagreement they have.
        "tickets": tpairs,
        "ticket_mismatch": tmismatch,
        "branch_ticket": branch_ticket_for(path) if path else "",
        # The row can only afford the glyph; the reader who opens this dialog gets the
        # review's name and how long it has been waiting on them.
        "review": staged_review(os.path.join(path, ".claude", REVIEW_FILE)) if path else None,
        "live": live_tuning(name),
        "cfg": config_rows(path, name),
        "local_path": os.path.join(path, ".claude", "workflow.config.local"),
        "tune_sh": os.path.join(path, ".claude", "scripts", "agent-tune.sh"),
    }


def apply_now(tune_sh, name):
    """Hand the live knobs to agent-tune.sh and return what IT said, unedited.

    NOT WRAPPED. That script serializes itself against other runs and restores the
    machine-global settings file it is forced to write through; re-implementing any part of
    that here would give the fleet a second, unlocked path to the same shared file.
    """
    if not os.path.isfile(tune_sh):
        return "agent-tune.sh not found in this lane"
    try:
        p = subprocess.run([tune_sh, "apply", name], capture_output=True, text=True,
                           timeout=180)
    except subprocess.TimeoutExpired:
        return "agent-tune.sh timed out — check the lane's pane"
    except OSError as e:
        return "could not run agent-tune.sh: %s" % e
    lines = [ln.strip() for ln in (p.stdout + p.stderr).splitlines() if name in ln]
    return lines[-1] if lines else (p.stdout.strip().splitlines() or ["no output"])[-1]


def _restore_line(path, raw):
    """Append `raw` back, VERBATIM — so the caller must hand it the file's own bytes.

    It deliberately does not re-indent or otherwise tidy what it is given: this file is
    hand-written prose and normalising it here would be a second, invisible author. The one
    caller (`action_undo`) is fed `_drop_line`'s return value for exactly that reason.

    APPENDED, NOT PUT BACK WHERE IT WAS. The list is ordered by `[added:]` at render time
    (see ASK_SORTS), so a restored item shows in the same place either way; recording an
    index would only be right until the next writer touched the file.
    """
    try:
        with open(path) as f:
            body = f.read()
    except OSError:
        body = ""
    if body and not body.endswith("\n"):
        body += "\n"
    with open(path, "w") as f:
        f.write(body + raw + "\n")


# DERIVED, NOT WRITTEN. These rows are computed from the staged-review flag files every tick,
# so they appear the moment a lane stages one and vanish the moment it is answered — no lead
# has to remember to write them and, more to the point, none has to remember to clear them.
# That is the whole reason they are synthesized: every hand-maintained signal in this fleet
# has gone stale at least once, and a stale "review waiting" is worse than none.
#
# `[derived:…]` is what stops `x` pretending to delete one. See action_clear_ask.
def _review_asks(rows):
    """One `review:` ask line per agent with a review staged, newest first."""
    out = []
    for r in rows or []:
        rv, path = r.get("review"), r.get("path")
        if not rv or not path:
            continue
        who = r.get("label") or r.get("name") or "an agent"
        name = (rv.get("name") or "").strip()
        # The stamp is the FLAG FILE'S OWN AGE, not today: a review staged three days ago
        # must sort and read as three days old, which is exactly the fact that makes it
        # urgent. `age` is seconds-since, so subtract rather than stat again.
        added = time.strftime("%Y-%m-%d",
                              time.localtime(time.time() - (rv.get("age") or 0)))
        subject = " — %s" % name if name else ""
        out.append(
            "review: %s has a review staged for you%s [from:%s] [added:%s] "
            "[review:%s] [derived:staged-review] [short:%s — review staged]"
            % (who, subject, r.get("name") or who, added, path, who))
    return out


# THE ONLY WAY TO CLEAR ONE, and it is deliberately the flag itself rather than a record
# kept beside it. See retire_staged_review.
_DERIVED_TRAILERS = re.compile(r"\s*\[(?:derived|review):[^\[\]]*\]")


def retire_staged_review(flag, note):
    """Retire a staged-review flag, keeping what it said. "" on success, else why.

    Takes the FLAG PATH, like `staged_review` it undoes — the two are a pair and a function
    that took the lane instead would be the only one on this surface composing that path.

    THE FLAG'S EXISTENCE IS THE SIGNAL, so retiring the file is the only clearing mechanism
    that cannot rot. The alternatives — a dismissed-ids list, a stored mtime, a content hash
    — all have to be invalidated by whatever stages the NEXT review, and the write contract
    for this file is documented NOWHERE: `grep -rnF monocle-staged` over this repo returns
    only the constant that reads it, the Monocle skills never mention it, and no role doc
    describes writing one. It is a convention carried by whichever agent last staged a
    review. A suppression record that guessed wrong about that writer would hide a REAL
    review — and an invisible staged review is the one failure worse than the stale row this
    exists to clear. Removing the file needs no assumption about the writer at all: anything
    that stages a review must create it, because its existence is the only thing that has
    ever made the row appear.

    THE CONTENT IS APPENDED, NEVER DISCARDED. These files are hand-authored and can be
    substantial — the one that prompted this carried the base_ref reasoning, a diff stat and
    the provenance of five review rounds — so it is folded into a `.cleared` log beside it,
    with the user's note, rather than deleted. A second clear appends; it never clobbers.

    IT FAILS TOWARD THE ROW STAYING UP. If the log cannot be written, the flag is left
    exactly where it is and the panel goes on showing the review. The alternative is clearing
    a signal we just failed to record, which is the same silence this feature is fixing.

    NOTHING CALLS THIS ON RESOLUTION YET, and that absence is the defect underneath the key.
    The flag is not cleared when the review is answered, so a shipped review leaves its row
    standing until a person notices and force-clears it — which is the whole reason `t` had
    to learn this at all. Whatever observes the resolution (a verdict returned, a PR merged)
    should call THIS function rather than removing the file itself: a bare `rm` is what
    happened the first time and it left no record of what was cleared or why, which is the
    failure the `.cleared` log exists to prevent. Manual and automatic want identical
    behaviour, so there is one place to be right about it. Recorded here, beside the code,
    because this repo keeps its reasoning in docstrings and carries no TODO comments.
    """
    try:
        with open(flag or "") as f:
            body = f.read()
    except OSError as e:
        return "no staged-review flag to clear (%s)" % e.strerror
    stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(_now()))
    try:
        with open(flag + ".cleared", "a") as f:
            f.write("\n=== cleared %s ===\n%s\n%s\n" % (stamp, note, body.rstrip()))
    except OSError as e:
        return "could not record the clear, so the flag is still up (%s)" % e.strerror
    try:
        os.remove(flag)
    except OSError as e:
        return "recorded, but the flag could not be removed (%s)" % e.strerror
    return ""


def _append_ask_line(path, line):
    """Add one line to an ask file, keeping what is already there. True when it landed.

    A sibling of `_restore_line` rather than a call to it: that one puts back bytes the view
    took OUT of this file and says so, and this one MATERIALISES a row that was never in it.
    Same three lines, two different things to be right about.
    """
    try:
        with open(path) as f:
            body = f.read()
    except OSError:
        body = ""
    if body and not body.endswith("\n"):
        body += "\n"
    try:
        with open(path, "w") as f:
            f.write(body + line + "\n")
    except OSError:
        return False
    return True


def snapshot():
    """Everything on screen, as plain data. Runs OFF the UI thread."""
    try:
        out = subprocess.run([STATUS_SH, "--json"], capture_output=True, text=True,
                             timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return {"lanes": [], "subs": [], "fleet": [], "error": "fleet-status.sh did not run"}

    rows = []
    for ln in out.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            rows.append(json.loads(ln))
        except ValueError:
            continue

    lanes = [r for r in rows if r.get("kind") != "subagent"]
    subs = [r for r in rows if r.get("kind") == "subagent"]

    # The lanes dir is dirname of any lane's path — no second subprocess, and no guess: the
    # fleet ask file sits beside the lanes dir, exactly where general_asks() looks for it.
    lanes_dir = os.path.dirname(lanes[0]["path"].rstrip("/")) if lanes else ""
    fleet_path = os.path.join(os.path.dirname(lanes_dir.rstrip("/")), "needs-input-fleet") \
        if lanes_dir else ""
    # The standing goal sits beside that list and is re-read on this same tick — a goal the
    # lead changed mid-session must not need a restart to stop pointing at the old objective.
    goal, goal_chain = fleet_goal(fleet_goal_path(lanes_dir))

    for r in lanes:
        r["ask_path"] = os.path.join(r["path"], ".claude", "needs-input")
        r["raw_asks"] = _ask_lines(r["ask_path"])

    # LANES AND SUBS ALIKE. A subagent staging a review is the same fact about whose turn it
    # is, and it is the row the user is least likely to go looking at unprompted.
    for r in lanes + subs:
        if r.get("path"):
            r["review"] = staged_review(os.path.join(r["path"], ".claude", REVIEW_FILE))

    # The tracker's base URL is LEARNED from a real link the tracker itself produced, so ids
    # that have no recorded URL of their own still resolve — and if the fleet has no tracked
    # work at all, nothing is linked rather than linked to a guess.
    linear_base = ""
    for r in lanes:
        for _id, url in r.get("issue_links") or []:
            if "/issue/" in url:
                linear_base = url.split("/issue/")[0]
                break
        if linear_base:
            break

    return {
        "lanes": lanes,
        "subs": subs,
        # UNSORTED HERE — the ORDER IS UI STATE, chosen with `s` and applied in `_fleet()`.
        # Baking it into the snapshot would make changing the order require a re-fetch, and
        # would put the choice on the thread that reads the disk rather than the one that
        # knows what the reader asked for.
        #
        # A STAGED REVIEW IS AN ASK, so it joins the list rather than living only on its
        # lane's row (John, 2026-08-19: "I would expect reviews from agents to show up there
        # with the magnifying glass icon"). It is the single most time-critical thing an
        # agent asks of a human — a lane is stopped while it waits — and it was the one class
        # of ask 4ME did not show, so the panel's count was answering "how much do I owe"
        # with the wrong number.
        "fleet": (_ask_lines(fleet_path) if fleet_path else []) + _review_asks(lanes + subs),
        "fleet_path": fleet_path,
        "goal": goal,
        "goal_chain": goal_chain,
        # The goal travels in `ctx` as well as at top level: `ctx` is what reaches the row
        # renderers, and the 🎯 marker is now drawn on the ROW, not only in the dialog.
        "ctx": {"linear_base": linear_base,
                "goal": goal,
                "goal_chain": goal_chain,
                "repo": _repo_url(lanes[0]["path"]) if lanes else ""},
        "error": "",
    }


# ── how much room the agent list needs, in rows ──────────────────────────────────────────
# Lane.compose draws one line — the head — plus one per ask, and the ListItem rule leaves a
# blank row under each item. (The status line is gone; see the note by head_markup.)
#
# COUNTED, NOT MEASURED. A widget's real height only exists after a layout pass, so sizing
# from the measurement means drawing the panel at the wrong height once per change to learn
# the right one — and, once the panel is clamped, a scrollbar narrowing the content can change
# the measurement that set the width, which is a loop.
#
# BUT A COUNTED LINE STILL WRAPS. Counting one row per line is true only while every line
# fits its column: a head line carrying several ticket links, or a long ask, overruns the 64
# columns a lane row gets in a 72-column pane. When that happened on the old status line every
# lane drew four rows where the arithmetic counted three, so `=` sized the panel six rows short
# of a five-lane fleet and reported "all 5 visible" over a list that scrolled.
#
# So the count is now WIDTH-AWARE: each line is wrapped by rich's own algorithm — the one
# Static uses — at the width that line will actually get.
#
# THE WIDTH COMES FROM THE PANEL'S OUTER EDGE, never from its content box. The content box
# loses two columns the moment a scrollbar appears, and a scrollbar appears when the fit came
# out short — so sizing off it would let the fit change the width the fit was computed at,
# which is the loop the paragraph above warns about. The outer width is set by the container
# and is the same number whether the list overflows or not.
#
# TWO ANSWERS, BECAUSE THE PANEL IS IN ONE OF TWO STATES. A list that FITS has no scrollbar,
# so its lines get the full column and the fit is exact — reserving a scrollbar there would
# leave the panel a row taller than its content, i.e. dead space stolen from 4ME. A list that
# was CLIPPED has one, plus the cursor's gutter on whichever row it sits on, so the note that
# says how much of it landed reserves both: that number must undercount rather than promise a
# row the reader has to scroll to reach. Neither reservation feeds back into the width.
ITEM_ROWS = 2         # an UNWRAPPED card: head + the blank the ListItem rule leaves
ASK_ROWS = 2          # a 4ME row is one line, plus the blank the same ListItem rule leaves
ITEM_BLANK = 1        # that blank row, on its own — the part of ITEM_ROWS that cannot wrap
PANEL_BORDER = 2      # the round border takes a row off the top and one off the bottom
PANEL_MIN = 3         # border + a row: a fleet with nothing in it still shows a titled box
FLEET_MIN = 4         # rows 4ME keeps however many lanes there are — its border + one ask
PANEL_PAD = 2         # `#lanes, #fleet { padding: 0 1 }` — a column either side
SCROLLBAR = 2         # taken only once the list overflows, which is when the note is drawn
CURSOR_GUTTER = 2     # the highlighted row's `border-left: thick` + `padding-left: 1`
LANE_INDENT = 4       # `.lane-ask` — `padding-left: 4`
# What a CLIPPED list has taken off its lines that a fitting one has not. See above: the fit
# reserves nothing, the "how much of it landed" note reserves this.
CLIPPED_RESERVE = SCROLLBAR + CURSOR_GUTTER

# Rich needs a console to wrap against. It renders nothing: only its wrapping is used, and
# the width is passed per call, so this one instance is safe to share and cheap to keep.
_WRAP_CONSOLE = Console(file=io.StringIO(), width=200, no_color=True)


def text_width(panel_width, reserve=0):
    """Columns a row's lines get inside a panel `panel_width` columns wide, OUTER.

    `reserve` is what the panel's state has already taken off them — nothing while the list
    fits, CLIPPED_RESERVE once it does not.

    Zero when the panel has not been laid out yet, which every caller reads as "no width is
    known" and falls back to the unwrapped count — a first frame that is one row short is
    corrected by the fit that follows it, and guessing a width would be wrong for longer.
    """
    if not panel_width:
        return 0
    return max(1, panel_width - PANEL_BORDER - PANEL_PAD - reserve)


def wrapped_rows(markup, width):
    """Rows `markup` occupies once wrapped to `width` columns — 1 when no width is known.

    Wrapped by rich rather than by dividing the length: Static word-wraps, so a line of 65
    characters in 64 columns can break at column 40 and a character count would still say
    two. It is the row COUNT that has to match, and only the real algorithm gives it.
    """
    if width <= 0:
        return 1
    return max(1, len(Text.from_markup(markup).wrap(_WRAP_CONSOLE, width)))


def lane_rows(row, width=0, ctx=None, reserve=0):
    """Rows one agent card occupies: its head, one per ask — each of them wrappable — plus the
    blank the ListItem rule leaves under the item."""
    body = text_width(width, reserve)
    indented = max(1, body - LANE_INDENT) if body else 0
    n = wrapped_rows(head_markup(row, ctx), body)
    for raw in row.get("raw_asks") or []:
        n += wrapped_rows(lane_ask_markup(raw, ctx), indented)
    return n + ITEM_BLANK


def fit_height(rows, width=0, ctx=None, reserve=0):
    """Rows the FLEET panel needs to show every agent in `rows` without scrolling."""
    return PANEL_BORDER + sum(lane_rows(r, width, ctx, reserve) for r in rows)


def ask_rows(n, raw, width=0, ctx=None, reserve=0):
    """Rows one 4ME item occupies — its line, wrapped, plus the ListItem blank."""
    return wrapped_rows(ask_row_markup(n, raw, ctx),
                        text_width(width, reserve)) + ITEM_BLANK


def asks_fit_height(asks, width=0, ctx=None, reserve=0):
    """Rows the 4ME panel needs to show `asks` without scrolling.

    `asks` is the list of raw lines, so the items can be wrapped at the panel's width the way
    the lanes are. An int is still accepted for the caller that only knows a count, and gets
    the old unwrapped arithmetic.

    Never below FLEET_MIN, which is the same floor every other path respects: an empty list
    is still a titled box, and a panel that vanished would read as a broken view rather than
    an empty one.
    """
    if isinstance(asks, int):
        return max(FLEET_MIN, PANEL_BORDER + asks * ASK_ROWS)
    need = sum(ask_rows(i, raw, width, ctx, reserve) for i, raw in enumerate(asks, 1))
    return max(FLEET_MIN, PANEL_BORDER + need)


def visible_items(heights, room):
    """How many items, in order, are WHOLLY visible in `room` content rows.

    Counted the same way the fit is, off the same row arithmetic, because this number exists
    to contradict it: when a list is taller than the terminal the panel stops at the other
    one's floor, and a stop that says nothing is indistinguishable from a successful fit.
    A partly-drawn row does not count — "8 of 20 visible" should undercount rather than
    promise a line the reader has to scroll to finish.
    """
    n = 0
    for h in heights:
        if h > room:
            break
        room -= h
        n += 1
    return n


def fit_note(mode, shown, total):
    """What `=` actually managed, in one line."""
    if not total:
        return ("4ME is empty — the agents keep the rows" if mode == "4ME"
                else "no agents to fit")
    if shown >= total:
        return "fit %s · all %d visible" % (mode, total)
    return "fit %s · %d of %d visible, the rest scroll" % (mode, shown, total)


def _now():
    """Wall clock, as one seam. Named so a test can hold it still — every assertion about the
    refresh indicator is an assertion about a clock, and a test that reads the real one can
    only check that SOMETHING is printed."""
    return time.time()


def refresh_markup(refreshed_at, refreshing, interval, now=None):
    """The refresh indicator: when the panel last actually LANDED data, and whether it is
    still trying.

    IT EXISTS TO MAKE A BROKEN REFRESH DIFFERENT FROM A QUIET FLEET. Every number here can sit
    unchanged for a legitimate reason — nobody typed, no lane moved — so a view that has
    stopped refreshing looks exactly like one with nothing to say, and the user is left
    pressing a key that may or may not be doing anything. A timestamp that moves is the proof
    the key worked; a timestamp that does not move is the bug, visible.

    Three states, because they need three different responses: in flight (wait), landed
    (believe it), and OVERDUE — past three ticks with nothing arriving, which is not staleness
    but a broken view, and is the one that shouts.
    """
    now = _now() if now is None else now
    stamp = ("" if refreshed_at is None
             else time.strftime("%H:%M:%S", time.localtime(refreshed_at)))
    if refreshed_at is None:
        return "[dim]refreshing…[/]" if refreshing else "[dim]no data yet[/]"
    if refreshing:
        return "[dim]refreshing… (last %s)[/]" % stamp
    # Three ticks, floored at 30s: one missed tick is a slow `gh`, three is a view that has
    # stopped. The floor keeps a fast --interval from crying wolf on ordinary jitter.
    if now - refreshed_at > max(3 * interval, 30):
        return "[b yellow]NOT REFRESHING — last %s[/]" % stamp
    return "[dim]refreshed %s[/]" % stamp


def context_markup(pct, state=None):
    """(text, colour) for a context gauge. ONE implementation, wherever a gauge is drawn.

    OVER 100% IS AN ADMISSION, NOT A NUMBER. A gauge read 216% for a lane on a 1M-token model
    because the denominator defaulted to 200k. That denominator is fixed, but the visible
    absurdity was luck: the same class of error reads a believable 80% at half the occupancy.
    Anything out of range is rendered as out of range, so the next wrong denominator is caught
    by the panel rather than by a reader who happened to look.

    A SECOND COPY OF THESE RULES IS THE FAILURE MODE THIS FUNCTION EXISTS TO PREVENT. The fix
    above lives in window_for(); a surface that re-derives its own percentage re-earns the bug
    the day someone tunes it, and re-earns it silently, because both surfaces render a number
    either way.
    """
    if pct is None or state == "down":
        return "—", "dim"
    if pct > 100:
        return ">100%", "b red"
    return "%d%%" % pct, ("red" if pct >= 90 else "yellow" if pct >= 80 else "dim")


# ── what a lane row SAYS, as free functions ──────────────────────────────────────────────
# They live outside the widget because the fit has to know how wide each line is BEFORE any
# widget exists — a card's height is now the number of rows its lines wrap to, and a builder
# reachable only through an instantiated ListItem would force the sizing path to construct
# widgets in order to measure them. Lane keeps the methods as one-line delegates so every
# call site reads unchanged.


def pr_markup(row):
    """This lane's open PRs — its own column, beside the tickets.

        A LIST like the tickets, because a lane can have more than one in flight and showing
        only the first is a lie that looks like a fact.

        They sit together because they answer one question jointly: what is this lane on, and
        has the work left the lane yet. A lane with an open PR is waiting on review rather
        than working, and nothing about the ticket alone says so.

        A draft is DIM and marked, never green — colour is the whole signal at a glance, and a
        draft rendered like a ready PR is the one way this field could mislead.

    The URL stays https: GitHub registers no custom scheme, unlike Linear's `linear://`.
    """
    prs = row.get("open_prs") or []
    if not prs:
        return ""
    out = []
    for num, url, draft in prs:
        label = "#%s%s" % (num, "…" if draft else "")
        body = "[link='%s']%s[/link]" % (url, label) if url else label
        out.append("[%s]%s[/]" % ("dim" if draft else "b green", body))
    return "  " + " ".join(out)


# ── FIXED COLUMN WIDTHS ──────────────────────────────────────────────────────────────────
# The head line is a TABLE, and until now only its minimums were pinned (`:<11` pads a short
# name but a long one just pushes everything right). So every column after the widest name on
# screen sat at a different offset per row, and the columns appeared to resize as agents came
# and went — `manual-test-audit` alone shifted state, context and uptime six columns right on
# its row only. Each cell is now CUT to its width as well as padded to it, so a column starts
# at the same offset on every row of the panel whatever is in it.
#
# NAMES ARE CUT IN THE MIDDLE, not at the end. Fleet names share long prefixes AND long
# suffixes (`g-feature-1` / `g-feature-2`, `manual-test-audit` / `machinery-ship`), so a
# trailing cut is exactly the cut that makes two rows read the same. `manua..audit` keeps
# both ends, which is what a reader identifies the agent by.
NAME_W = 12           # `manual-test-audit` -> `manua..audit`; `g-feature-1` fits whole.
                      # The CELL is one wider — see the separator space in the f-string.
LABEL_W = 4
STATE_W = 7
CTX_W = 5             # ">100%", the widest context_markup() returns
UP_W = 6
TICKETS_W = 14        # "SRV-24 ≠branch" exactly, or two plain ids.
                      # MEASURED AGAINST THE REAL PANE, not chosen for headroom. The
                      # fleet runs in a 70-column panel and this column is padded, so
                      # every column of slack here is one the PR badges spend: at 22
                      # a lane with one ticket and one PR wrapped onto a second row —
                      # a line per lane, paid to align a column nobody was misreading.
NAME_CUT = ".."       # not "…": one glyph would leave an odd budget to split
REVIEW_W = 2          # DISPLAY columns of the magnifier, which is not len(REVIEW):
                      # the glyph is emoji-presentation and the terminal draws it two
                      # cells wide, so padding it by character count would push every
                      # column right of it one place on staged rows only — the exact
                      # drift the fixed widths exist to remove.


def fit_name(name, width=NAME_W):
    """`name` in at most `width` columns, cut in the MIDDLE — `prefix..suffix`.

    The head half takes the odd column, because the leading characters are what the eye scans
    a column of names by.
    """
    name = name or ""
    if len(name) <= width:
        return name
    if width <= len(NAME_CUT):
        return name[:width]
    keep = width - len(NAME_CUT)
    head = (keep + 1) // 2
    return name[:head] + NAME_CUT + name[len(name) - (keep - head):]


def fit_cell(text, width):
    """A plain cell cut to `width`, with a trailing … so the cut is visible."""
    text = text or ""
    if len(text) <= width:
        return text
    return text[:max(0, width - 1)] + "…" if width else ""


def fit_ids(cells, width=TICKETS_W):
    """`(markup, visible width)` for as many `(visible, markup)` ticket cells as fit.

    WHOLE CELLS ARE DROPPED, never cut: half a ticket id is a different id that still looks
    like one, and this column is read for exactly that string. What was dropped is counted
    (`+2`) rather than left to be inferred from an absence.

    The single-cell case is the exception — with nothing to count it cuts, because "+1" alone
    would tell the reader less than a clipped id does.
    """
    if not cells:
        return "", 0
    vis = [v for v, _ in cells]
    taken = len(cells)
    while taken:
        more = "" if taken == len(cells) else "+%d" % (len(cells) - taken)
        w = (sum(len(v) for v in vis[:taken]) + max(0, taken - 1)
             + (len(more) + 1 if more else 0))
        if w <= width:
            parts = [m for _, m in cells[:taken]] + ([more] if more else [])
            return " ".join(parts), w
        taken -= 1
    one = fit_cell(vis[0], width)
    return one, len(one)


# ── THE ORDER OF THE AGENT LIST ─────────────────────────────────────────────────────────────
# FIXED, NOT DISCOVERED (John 2026-08-17). fleet-status sorts by name, so the list read
# `feature-1 … merge-fst, team-lead` — the lead last, and an ad-hoc lane wedged between the
# numbered ones. The reader's model of this fleet is positional: the lead is where decisions
# land, the numbered lanes are the standing staff, everything else is transient. A list whose
# order changes as lanes are created and retired makes that model something you re-derive on
# every glance.
#
# RANK, NOT A SORTED NAME LIST. The rank is the CLASS an agent belongs to, which is what
# item 8's aggregate row also needs — "the subagents" is rank 4 by the same function that
# puts the lead first, so grouping by class costs a `groupby`, not a second ordering.
LEAD_NAME = "team-lead"
TESTER_NAME = "tester"
_FEATURE_LANE = re.compile(r"feature-(\d+)\Z")

RANK_LEAD, RANK_FEATURE, RANK_TESTER, RANK_LANE, RANK_SUB = 0, 1, 2, 3, 4


def agent_rank(row):
    """(class, ordinal, name) — the sort key, and the class is the useful half.

    Ad-hoc lanes keep their alphabetical order among themselves rather than being ranked
    against each other: they are named for whatever they were spun up to do, so any ordering
    of THEM would be a claim about importance that nothing on the row supports.
    """
    name = row.get("name") or ""
    if row.get("kind") == "subagent":
        return (RANK_SUB, 0, name)
    if name == LEAD_NAME:
        return (RANK_LEAD, 0, "")
    m = _FEATURE_LANE.match(name)
    if m:
        return (RANK_FEATURE, int(m.group(1)), "")
    if name == TESTER_NAME:
        return (RANK_TESTER, 0, "")
    return (RANK_LANE, 0, name)


def order_agents(rows):
    return sorted(rows or [], key=agent_rank)


# ── THE SUBAGENTS, AS ONE ROW ───────────────────────────────────────────────────────────────
# COLLAPSED BY DEFAULT (John 2026-08-18). A per-subagent row cost a line of a short panel to
# say almost nothing: a subagent shares its spawner's cwd, so tickets, PRs and status are all
# blank by construction (see _fleet_status.rows) — the columns that made a LANE row worth its
# height are structurally empty here. What the rows did carry, across all of them, is one
# signal: a subagent quietly burning its context. That is a MAX, so one row says it.
#
# EXCEPTIONS BUBBLE, because a collapsed list that hides a problem is worse than the rows it
# replaced. Anything that would have made an individual row shout — it owes you an answer, it
# is dead, it has a review staged — is counted on the aggregate, so the collapse can never be
# the reason you did not see it.
#
# "FAILED" IS NOT A STATE THIS FLEET HAS. The states are busy/quiet/idle/down, so the failure
# that bubbles is `down`; there is nothing upstream to read a stuck-vs-crashed distinction
# from, and inventing one on this row would be the surface asserting past its evidence.
SUBAGG_KIND = "subagg"
SUBAGG_NAME = "subagents"
# Single-codepoint, no variation selector — the same rule the kind icons follow, and the
# reason `triage:` stopped being a grey box. Ambiguous-width like the ⚠ already on these
# rows, which is safe here because this line is prose, not a padded column.
CARET_SHUT, CARET_OPEN = "▸", "▾"


def subagg_row(subs, expanded=False):
    """The one row that stands for every subagent. Carries them, so nothing is re-fetched."""
    return {"kind": SUBAGG_KIND, "name": SUBAGG_NAME,
            "subs": list(subs or []), "expanded": bool(expanded)}


def subagg_markup(r):
    subs = r.get("subs") or []
    live = sum(1 for s in subs if s.get("state") != "down")
    facts = ["%d running" % live]
    pcts = [s.get("context_pct") for s in subs
            if isinstance(s.get("context_pct"), (int, float))]
    # OMITTED, NEVER ZEROED, when no subagent reports one: "max ctx 0%" is a measurement and
    # "we could not attribute a transcript to any of them" is the absence of one.
    if pcts:
        facts.append("max ctx %d%%" % max(pcts))
    out = "[dim]%s  %s[/]" % (CARET_OPEN if r.get("expanded") else CARET_SHUT,
                              escape(" · ".join(facts)))
    asks = sum(1 for s in subs if s.get("needs_input"))
    if asks:
        out += "[b yellow] · %d %s[/]" % (asks, LANE_ASK)
    dead = sum(1 for s in subs if s.get("state") == "down")
    if dead:
        out += "[red] · %d down[/]" % dead
    revs = sum(1 for s in subs if s.get("review"))
    if revs:
        out += "[b cyan] · %d %s[/]" % (revs, REVIEW)
    return "[b]%-*s[/] %s" % (NAME_W + LABEL_W + 2, SUBAGG_NAME, out)


def display_rows(lanes, subs, expanded=False):
    """Every row of the agent list, in the order it is drawn — the one place that decides.

    Pure and total: `apply` rebuilds from it, `_rows` measures the panel from it, and the two
    cannot disagree about how many rows there are, which is what the in-place refresh zips
    children against.
    """
    rows = order_agents(lanes)
    subs = order_agents(subs)
    if subs:
        rows.append(subagg_row(subs, expanded))
        if expanded:
            rows.extend(subs)
    return rows



def head_markup(r, ctx=None):
    """The identity line: state, label, name, context gauge, uptime, tickets, PRs."""
    if r.get("kind") == SUBAGG_KIND:
        return subagg_markup(r)
    ctx = ctx or {}
    state = r.get("state", "?")
    icon = LANE_ASK if r.get("raw_asks") else STATE_ICON.get(state, "?")
    icolor = "b yellow" if r.get("raw_asks") else STATE_STYLE.get(state, "white")
    pcs, pcolor = context_markup(r.get("context_pct"), state)
    up = "—" if state == "down" else (r.get("uptime") or "—")
    # The recorded URL wins over the learned base — it is what the tracker actually
    # returned, slug and all. linkify() is the fallback for ids that have none.
    links = r.get("issue_links") or []
    # (visible, markup) per id, so the column can be measured before it is joined — the
    # markup carries link tags whose length is not what the reader sees.
    cells = [(i, "[link='%s']%s[/link]" % (linear_uri(u), i) if u else linkify(i, ctx))
             for i, u in links]
    if not cells:
        one = r.get("issue") or "—"
        cells = [(one, linkify(one, ctx))]
    # ≠branch MEANS "THIS IS `.claude/current-work`'S ANSWER AND THE BRANCH NAMES ANOTHER
    # TICKET". The id shown is the one the agent is working; the marker is there because the
    # branch has been left behind on finished work and someone may want to fix it. It TRAILS
    # the id — it is a note about the id, not part of it — and the branch's own id is in the
    # detail dialog rather than the column, which has one line and a job already.
    if r.get("ticket_mismatch"):
        cells.append(("≠branch", "[b yellow]≠branch[/]"))
    ids, ids_w = fit_ids(cells)
    prs = pr_markup(r)
    # Padded ONLY when something follows it. A trailing pad would widen the line for the
    # wrapper (a card's height is the rows its lines wrap to) to buy an alignment nobody can
    # see, and every lane without a PR would get a taller card in a narrow panel.
    if prs and ids_w < TICKETS_W:
        ids += " " * (TICKETS_W - ids_w)
    return (
        f"[{icolor}]{icon}[/] "
        f"[b]{escape(fit_cell(r.get('label') or '', LABEL_W)):<{LABEL_W}}[/]"
        # The trailing space is the column SEPARATOR: a name that fills its budget
        # exactly (`manua..audit`) would otherwise run straight into the state word.
        f"[dim]{escape(fit_name(r.get('name') or '')):<{NAME_W}}[/] "
        f"[{STATE_STYLE.get(state, 'white')}]{fit_cell(state, STATE_W):<{STATE_W}}[/]"
        f"[{pcolor}]{fit_cell(pcs, CTX_W):>{CTX_W}}[/]  "
        f"[dim]{fit_cell(up, UP_W):>{UP_W}}[/] "
        f"[b cyan]{REVIEW if r.get('review') else ' ' * REVIEW_W}[/] "
        f"[cyan]{ids}[/]"
        f"{prs}"
    )


# PER-LANE STATUS PROSE REMOVED (John 2026-08-14) — stale agent-written text; 4ME + the
# ticket column carry the truth. `status` / `status_age` / `last_active` are still read
# and still rendered by the detail dialog (`detail_status_markup`), which is where the
# full text now lives.


def lane_ask_markup(raw, ctx=None):
    """One of a lane's own asks, as it appears under the lane's head line."""
    icon, text = ask_kind(raw)
    return f"{icon} {linkify(clip(text), ctx or {})}"


# The two action glyphs. Single Emoji_Presentation codepoints, for the reason ASK_KINDS
# records: a codepoint needing U+FE0F draws as a grey box in this terminal AND measures two
# cells while drawing one, which shifts every column after it.
REVIEW_BADGE = "🔎"   # deliberately NOT the 🔍 kind icon — one says what the row IS, the
                      # other is a button. Two identical glyphs on one row, one clickable
                      # and one not, is a worse puzzle than two similar ones.
CMD_BADGE = "📋"      # copies the command to the clipboard


def _aesc(s):
    """Percent-encode a value so it survives a single-quoted `@click` markup argument.

    NOT a hand-rolled backslash escape, and that was measured, not assumed. Textual 8.2.8
    tokenizes a markup expression's string with `single_string=r"\'.*?\'"` — non-greedy and
    with NO escape rule at all (`textual/markup.py`, `expect_markup_expression`). So a `'`
    inside the value ends the string early and the row raises MarkupError from inside
    `Ask.compose`, which is the crash class the `linkify` docstring above already records
    taking the whole app down. A `[` was separately being rewritten to `(`, corrupting the
    command it was supposed to copy and leaving a stray `]` behind.

    Percent-encoding has no such hole: the output alphabet is `A-Za-z0-9-_.~%`, none of which
    the markup grammar treats as special, and it is exactly reversible. Verified against
    textual 8.2.8 over quotes, brackets, backslashes, pipes, unicode and the empty string.
    """
    return _urlquote(s or "", safe="")


def _adec(s):
    """Inverse of `_aesc`. Values arriving from `@click` markup pass through here first."""
    return _urlunquote(s or "")


def ask_row_markup(n, raw, ctx=None):
    """One 4ME row: its number, its kind icon, and the ask clipped to the column.

    THE TRAILERS COME OFF HERE, not at the source. The caller keeps the file's bytes because
    `x` deletes by exact line match and the detail overlay reads the whole thing — this row
    is one line in a column, so it shows the question and the deferral stamp, and leaves
    provenance to the surface with room for it.
    """
    ctx = ctx or {}
    d = ask_detail(raw)
    text, urls = doc_refs(ask_short(d) + (" (%s)" % d["deferral"] if d["deferral"] else ""))

    # A DOC REFERENCE IN THE **CONTEXT** STILL EARNS ITS BADGE ON THE ROW. Moving the ask's
    # detail into a context block moved its links there too, and the row silently lost the
    # page glyph it used to carry — the one thing on the row that is *clicked* rather than
    # read. The prose is unchanged (`_ctx` is discarded); only the URLs travel up, so the
    # badge marks "this item has a document" wherever in the item the link happens to sit.
    # Deduped, in first-seen order: one link cited in both halves is one document.
    _ctx, ctx_urls = doc_refs(d.get("context") or "")
    for u in ctx_urls:
        if u not in urls:
            urls.append(u)

    body = doc_markup(linkify(fit_ask(text, urls), ctx), urls)

    # ACTION BADGES, after the doc glyphs and before the age. Each is CLICKABLE via Textual's
    # `@click` markup — which dispatches inside this app, unlike `[link=]`, which hands a URL
    # to the terminal. That distinction is the whole reason these are not links: focusing a
    # tmux pane and writing the clipboard are things only this process can do.
    #
    # The keyboard reaches the same two actions on the highlighted row (`m` and `y`), because
    # a badge you can only click is unreachable from the keys every other row action uses.
    t = dict(d["trailers"])
    if t.get("review"):
        body += " [@click=app.open_review('%s')]%s[/]" % (_aesc(t["review"]), REVIEW_BADGE)
    if t.get("cmd"):
        body += " [@click=app.copy_cmd('%s')]%s[/]" % (_aesc(t["cmd"]), CMD_BADGE)

    # THE GOAL MARKER, PROMOTED FROM THE DIALOG TO THE ROW (2026-08-19). It was only visible
    # after opening an ask, which is the wrong way round: whether an item gates the standing
    # objective is exactly the fact that decides WHICH item to open. Ticket-scoped, like the
    # dialog's — a whole-id match against `fleet-goal`, never a substring.
    tid = dict(d["trailers"]).get("ticket", "")
    on_goal = goal_mentions(tid, ctx.get("goal") or "", ctx.get("goal_chain") or [])
    if on_goal:
        body = "[b yellow]🎯[/] " + body

    # THE AGE, NOT THE DATE, and at the tail where it cannot push the question out of the
    # column. A date makes the reader subtract against a today they have to recall — the
    # arithmetic nobody does, which is how items sat for weeks looking recent.
    age = ask_age(dict(d["trailers"]).get("added", ""))
    return "[dim]%2d[/]  %s %s%s" % (
        n, d["icon"], body, "  [dim]%s[/]" % escape(age) if age else "")


# ── the 4ME category filter ──────────────────────────────────────────────────────────────
# `todo` COVERS THE UNTYPED ROWS TOO, and that is not a shortcut. ASK_KINDS already defines
# `todo` as "explicit general action — same as untyped, spelled out": an untyped ask, a
# `todo:` ask and a `✅ …RESOLVED` line all parse to the same ✅ and mean the same thing to a
# reader. The Enter dialog has always labelled an untyped ask `todo`, so filtering under that
# name keeps ONE vocabulary on screen — a second word for the same category ("general") would
# be a distinction only this filter believed in.
#
# The filter's spelling of ALL is "", which is why the untyped rows cannot simply be "" here.
FILTER_ALL = ""
FILTER_TODO = "todo"


def ask_kind_of(raw):
    """The kind token of one ask line, or "" when it carries none. Pure."""
    return (ask_detail(raw) or {}).get("kind", "")


def filter_asks(raws, kind=FILTER_ALL):
    """[(n, raw)] for the rows a filter shows — NUMBERED AS THEY ARE IN THE FILE.

    THE NUMBER IS AN ADDRESS, NOT A POSITION. The user says "4me 3" to the lead and the lead
    reads line 3 of the file; `x` deletes by exact line match but the eye picks the row by its
    number. Renumbering a filtered list would make `4me 3` mean a different ask depending on a
    filter the lead cannot see — so the numbers keep their gaps, and a gap is also the honest
    signal that rows are hidden.
    """
    pairs = list(enumerate(raws or [], 1))
    if not kind:
        return pairs
    want = {"", FILTER_TODO} if kind == FILTER_TODO else {kind}
    return [(n, r) for n, r in pairs if ask_kind_of(r) in want]


def ask_kinds_present(raws):
    """The filter's cycle, in ASK_KINDS' declared order.

    ONLY KINDS ACTUALLY PRESENT. A cycle that steps through empty categories makes the user
    press a key repeatedly to reach nothing, and every press repaints the panel. An untyped
    row puts `todo` in the cycle, since that is the category it belongs to.
    """
    kinds = {ask_kind_of(r) for r in (raws or [])}
    if "" in kinds:
        kinds.add(FILTER_TODO)
    return [k for k in ASK_KINDS if k in kinds]


def filter_label(kind):
    """What the panel title says about the active filter. Empty for ALL — an unfiltered list
    is the ordinary state and must not spend title width announcing itself.

    An UNKNOWN kind still renders, under the neutral icon: the lead writes this file by hand
    and may type a kind this build has never heard of, and a filter that crashed (or silently
    showed everything) on one would be worse than one that says what it is showing."""
    if not kind:
        return ""
    return " [%s %s]" % (ASK_KINDS.get(kind, ASK_GENERAL), kind)


class Lane(ListItem):
    """One lane: the identity row, then its asks. Selectable as a unit.

    Per-lane status prose removed (John 2026-08-14) — stale agent-written text; 4ME + the
    ticket column carry the truth; the data is still available to the detail dialog.
    """

    def __init__(self, row, ctx=None):
        super().__init__()
        self.row = row
        self.ctx = ctx or {}

    def head_markup(self):
        return head_markup(self.row, self.ctx)

    def compose(self):
        yield Static(self.head_markup(), classes="lane-head")
        for raw in self.row.get("raw_asks") or []:
            yield Static(lane_ask_markup(raw, self.ctx), classes="lane-ask")

    def refresh_volatile(self, row):
        """Update everything that is CONFINED TO A LINE, in place — never a rebuild.

        Uptime, context%, the state word and its icon all live on the head line. None of them
        changes the shape of this item, so none of them needs the list torn down. Folding them
        into the redraw signature is what produced the
        periodic full repaint: uptime moves every tick and `state` flips whenever any lane
        starts or finishes a turn, so on a working fleet the signature was rarely stable for
        two consecutive refreshes.

        **Each Static is written only when its markup actually differs.** `Static.update()`
        repaints unconditionally, so calling it every five seconds with an identical string is
        itself a visible flicker — the cheap equality check is the difference between a quiet
        panel and one that twitches.
        """
        self.row = row
        for sel, markup in ((".lane-head", self.head_markup()),):
            try:
                w = self.query_one(sel, Static)
            except Exception:
                continue
            if str(w.content) != markup:
                w.update(markup)


class Ask(ListItem):
    """One fleet-level to-do. Belongs to no lane, so it lives in its own panel."""

    def __init__(self, n, raw, path, ctx=None):
        super().__init__()
        self.n = n
        self.raw = raw
        self.path = path
        self.ctx = ctx or {}

    def compose(self):
        """A ROW THAT CANNOT RENDER MUST STILL RENDER. `Static` parses markup during compose,
        so a MarkupError here escapes into the mount and takes the whole app down — the exact
        failure the `linkify` docstring records, and the one `_aesc` just closed one source of.
        The fallback is deliberately markup-free (escaped, no tags, no badges): it loses the
        row's affordances, never the user's item."""
        try:
            yield Static(ask_row_markup(self.n, self.raw, self.ctx))
        except Exception:
            # A rich `Text` is handed to the renderer as-is; it is never markup-parsed, so
            # the fallback cannot fail the same way the thing it is catching just did.
            yield Static(Text("%2d  %s" % (self.n, clip(self.raw, LINE_MAX))))


DETAIL_HINT = ("[dim]j/k move · enter edits the highlighted knob · a applies the live knobs "
               "to the running agent · o opens the ticket · esc closes[/]")

ASK_HINT = "[dim]o opens the ticket · esc closes[/]"


class CfgRow(ListItem):
    """One editable knob. Carries its own spec, so the editor never has to look it up."""

    def __init__(self, entry):
        super().__init__()
        self.entry = entry

    def markup(self):
        e = self.entry
        value = e["value"] or "—"
        colour = "b" if e["value"] else "dim"
        scope = "live agent" if e["scope"] == "live" else "next spawn"
        return ("[cyan]%-28s[/] [%s]%-8s[/] [dim]%-9s · %s[/]"
                % (escape(e["key"]), colour, escape(value), e["origin"], scope))

    def compose(self):
        yield Static(self.markup())


class EmacsInput(Input):
    """`Input`, plus the two emacs motions Textual does not already ship.

    MOST OF THE LAYER IS ALREADY THERE and rebinding it would be noise: textual 8.2.8 binds
    ctrl+a home, ctrl+e end, ctrl+d delete-right, ctrl+w delete-word-left, ctrl+u
    delete-all-left and ctrl+k kill-to-end — measured off `Input.BINDINGS`, not assumed. Only
    the two character motions are missing, so only those are added.

    ctrl+n / ctrl+p ARE DELIBERATELY NOT BOUND. These fields are single-line, so "next line"
    and "previous line" have nothing to move to; the nearest emacs meaning is minibuffer
    history, which does not exist here. Binding them to the list BEHIND the dialog was the
    other option and is worse — it would move the cursor off the row the note is about while
    the note is being typed, and the row a mark lands on is captured when `t` is pressed, so
    the panel would disagree with what is about to be written.

    THE APP'S ctrl+k IS NOT A COLLISION, though it looks like one: `ctrl+k` is bound at app
    level to the tmux pane move. A focused Input consumes it first and the app action never
    runs — measured, not reasoned about, and there is a test that fails if that stops being
    true. ctrl+j and ctrl+l DO reach the app from inside a field, which is left alone: their
    emacs meanings (newline-and-indent, recenter) are meaningless in one line of text.
    """

    BINDINGS = [
        Binding("ctrl+f", "cursor_right", "", show=False),
        Binding("ctrl+b", "cursor_left", "", show=False),
    ]


class Detail(Vertical):
    """The overlay Enter opens on an agent row: its git state, its live session, its config.

    A PANEL, LIKE THE LEGEND — not a screen. The fleet panel behind it stays live and keeps
    ticking, which is the point: the numbers you are about to act on and the fleet you are
    acting on are visible at once.
    """


class AskDetail(Vertical):
    """The overlay Enter opens on a 4ME row: the ask IN FULL, and what is known about it.

    A SIBLING OF `Detail`, NOT A COPY. It shares that dialog's layer, its `-show` toggle, its
    blank-line-between-sections rhythm, its scrolling text box and its refresh-on-the-tick —
    the conventions are the same because the reader's job is the same. What differs is the
    subject: a lane has git state and knobs, an ask has provenance and a question.

    IT EXISTS BECAUSE THE LIST CLIPS AT SIXTY CHARACTERS. That cut happens in `Ask.compose`,
    the same way a lane's status is cut for its column, so the only way to see the whole ask
    was to open the file. This is the surface with room for it — the exact problem
    `status_text()` solves for a lane, solved once more for the list beside it.
    """


class Panels(Vertical):
    """The box the two panels share.

    It is a class at all so that the fit can follow a terminal resize. The App's own Resize
    event lands BEFORE this container has been re-measured — `self.size` there is still the
    size the terminal just stopped being, so a fit from that handler clamps the panel against
    the old screen and then has nothing to trigger a correction. The event delivered HERE
    carries the new measurement with it.
    """

    def on_resize(self, event):
        self.app._fit_lanes(avail=event.size.height)


class FleetTUI(App):
    CSS = """
    /* CENTRED OVERLAYS, AND THE BASE LAYER UNMOVED. Textual arranges each LAYER
       separately, so an `align` on the screen centres the overlay dialogs without touching
       the header/panels/footer stack — those fill the width and end in a `1fr` panel, so
       there is no slack for the alignment to take. Every dialog was pinned to the TOP-LEFT
       before this: they are `height: auto`, and a fixed `margin` is an offset from the
       corner, not a position. Each one therefore needs an explicit width (below) — a
       dialog left at the default `1fr` fills the row and centring it is a no-op. */
    Screen { background: $surface; layers: base overlay; align: center middle; }
    #head { padding: 0 1; height: 1; color: $text-muted; }
    /* The standing goal. Absent file ⇒ no widget on screen at all: a fleet with no goal is
       the ordinary case, and a permanent row saying "no goal" would cost a line to say
       nothing. Height 1 and no wrap — the objective is a ONE-LINER by contract, and a goal
       that reflowed the header on every edit would move the panel under it. */
    #goal { display: none; padding: 0 1; height: 1; color: $text; }
    #goal.-show { display: block; }

    /* A PANEL, NOT A TOAST. As a notification each `?` stacked another copy — press it three
       times, get three legends — because notifications queue by design and only expire on a
       timer. A legend is reference material you hold open while you read the screen behind
       it, so it toggles. */
    #legend {
        layer: overlay;
        display: none;
        width: 90%;
        padding: 1 2;
        height: auto;
        border: heavy $accent;
        background: $panel;
    }
    #legend.-show { display: block; }

    /* The detail overlay. Same layer and the same toggle as the legend, and for the same
       reason: it is something you hold open while reading the fleet behind it. Wider and
       taller, because it carries a list you move a cursor through rather than a fixed card. */
    #detail {
        layer: overlay;
        display: none;
        width: 90%;
        padding: 1 2;
        height: auto;
        max-height: 100%;
        border: heavy $accent;
        background: $panel;
    }
    #detail.-show { display: block; }
    /* ONE BLANK LINE BETWEEN SECTIONS. Head, status, git and config are four different
       subjects, and run together they read as one paragraph of facts with no seams — the
       eye has to parse the sentences to find the boundaries. The rest of the view already
       spends a row per item for exactly this reason (`ListItem { padding: 0 0 1 0 }`), so
       this is the dialog rejoining the rhythm rather than inventing one. */
    #detail > Static, #detail > ListView, #detail > VerticalScroll { margin-bottom: 1; }
    /* Auto up to a ceiling, then scrolls — a long update must not push the knobs off the
       bottom. `width: 100%` is what makes the text WRAP to the dialog rather than run off
       its edge, and it is re-measured on every resize, so widening the terminal reflows it. */
    #detail-status-box {
        height: auto;
        max-height: 10;
        width: 100%;
        background: transparent;
        scrollbar-size-vertical: 1;
    }
    #detail-status { height: auto; width: 100%; }
    #detail-cfg { height: auto; max-height: 14; background: transparent; }
    #detail-cfg > ListItem { padding: 0; }
    #detail-input { display: none; margin: 0; }
    #detail-input.-show { display: block; }
    #detail-msg { height: auto; color: $text-muted; }

    /* The 4ME overlay. Every rule here is the agent dialog's, restated for a different id
       rather than shared through a class — the two are the same KIND of surface and are
       meant to stay that way, so when one grows a convention the other is next to it in the
       file. Narrower than the lane dialog: an ask is prose, and prose wants a column. */
    #ask-detail {
        layer: overlay;
        display: none;
        width: 84%;
        padding: 1 2;
        height: auto;
        max-height: 100%;
        border: heavy $accent;
        background: $panel;
    }
    #ask-detail.-show { display: block; }
    #ask-detail > Static, #ask-detail > VerticalScroll { margin-bottom: 1; }
    /* THE WHOLE ASK, WRAPPED AND SCROLLING. `width: 100%` is what wraps it to the dialog
       instead of running off the edge, and it is re-measured on resize so widening the
       terminal reflows the text. Taller ceiling than the lane dialog's status box because
       this text IS the dialog rather than one section of four. */
    #ask-detail-box {
        height: auto;
        max-height: 14;
        width: 100%;
        background: transparent;
        scrollbar-size-vertical: 1;
    }
    #ask-detail-text { height: auto; width: 100%; }
    #ask-detail-fields { height: auto; width: 100%; }
    #ask-detail-msg { height: auto; color: $text-muted; }

    /* THE NOTE FIELD `t` OPENS, one row above the footer — on the BASE layer, not inside a
       dialog. `t` acts on the row under the cursor whether or not the 4ME overlay is up, so a
       field that lived in that overlay would be unreachable in the common case. Hidden
       entirely when idle: it is a prompt, not a row the panel pays for permanently. The
       panels absorb its two rows because #fleet is `1fr` and the fit measures #panels. */
    #note-input { display: none; margin: 0; }
    #note-input.-show { display: block; }
    #note-msg { display: none; height: auto; padding: 0 1; color: $text-muted; }
    #note-msg.-show { display: block; }

    /* THE FOCUSED PANEL HAS TO BE UNMISTAKABLE. Both panels carrying the same quiet border
       left the reader guessing which one `x` was about to act on — and `x` deletes. So the
       unfocused panel is dimmed to a plain grey hairline and the focused one takes a heavy
       accent border and a coloured title. */
    #lanes, #fleet { border: round $panel-darken-2; padding: 0 1; }
    #lanes:focus-within, #fleet:focus-within {
        border: heavy $accent;
        border-title-color: $accent;
        border-title-style: bold;
    }
    /* The FLEET panel is sized to the agents in it by _fit_lanes(); 4ME takes the rest.
       `auto` is only what it looks like for the one frame before the first fit. */
    #lanes { height: auto; }
    #fleet { height: 1fr; }

    ListView { background: transparent; }
    ListItem { padding: 0 0 1 0; background: transparent; }
    /* A selected row in an UNfocused panel stays legible but recessive... */
    ListItem.--highlight { background: $panel; }
    /* ...and the live cursor gets a solid block plus a bar down its left edge, which reads
       from across the room in a way a subtle tint does not. */
    ListView:focus > ListItem.--highlight {
        background: $accent 40%;
        border-left: thick $accent;
        padding-left: 1;
    }
    .lane-ask { padding-left: 4; }
    """

    BINDINGS = [
        Binding("q", "quit", "quit"),
        Binding("r", "reload", "reload"),
        # ENTER GAINED A SECOND MEANING RATHER THAN LOSING ITS FIRST. On an agent row it now
        # opens the detail overlay — the row is a card about a lane, and "show me this lane"
        # is what pressing it on one should do. The ticket it used to open moved to `o`, is
        # still a link inside the overlay, and is still what enter does on a 4ME row.
        Binding("enter", "enter", "details"),
        Binding("o", "open_ticket", "open ticket"),
        Binding("a", "apply_now", "", show=False),
        Binding("x", "clear_ask", "clear ask"),
        # `t` TICKS A ROW OFF WITHOUT DELETING IT — the other half of `x`, and the half the
        # lead can actually see. `k` is the obvious mnemonic for "kept" and is TAKEN: it is
        # the vim cursor pair (`j`/`k`), the most-pressed key on this panel, so rebinding it
        # would trade a new feature for the navigation. `t` is free, and "tick" is already the
        # word this file uses for the gesture (see action_clear_ask) and for the ✅ it writes.
        Binding("t", "mark_done", "mark done"),
        Binding("p", "approve_review", "approve"),
        Binding("M", "close_merged", "merged"),
        Binding("u", "undo", "undo"),
        Binding("f", "fullscreen", "fullscreen"),
        # `c` CYCLES THE 4ME CATEGORY FILTER. Chosen because every other letter on this screen
        # was taken (q r o a x u f j k) and `c` is the initial of the thing it filters. It
        # never DELETES — a filtered-out ask is hidden, and the panel title says so, because a
        # list that silently shows a subset is indistinguishable from a list that shrank.
        Binding("c", "cycle_category", "category"),
        # `s` CYCLES THE 4ME ORDER — latest, earliest, goal. A sibling of `c` in every way:
        # it changes how the list READS, never what is in it, and the panel title names the
        # state so the top row never means something the reader cannot see.
        Binding("s", "cycle_sort", "sort"),
        # THE THREE THINGS A ROW CAN OPEN, on the keyboard as well as on their badges. A
        # badge that is only clickable is unreachable from the keys every other row action
        # uses, and this panel is driven from the keyboard.
        Binding("m", "open_review", "monocle"),   # focus the lane's Monocle pane
        Binding("d", "open_doc", "doc"),          # open the row's document
        Binding("y", "copy_cmd", "copy cmd"),     # yank the row's command to the clipboard
        Binding("question_mark", "legend", "legend"),
        # `=` USED TO BE an unshifted alias for `+`. It is the coarse version of the same
        # gesture now — one press shows a whole list instead of one more row of one — and a
        # key cannot be both. `+` keeps the fine adjustment; `-` was already unshifted.
        Binding("equals_sign", "autofit", "autofit"),
        Binding("plus", "grow", "grow panel"),
        Binding("minus", "shrink", "shrink panel"),
        Binding("underscore", "shrink", "", show=False),
        Binding("escape", "unfullscreen", "", show=False),
        Binding("tab", "focus_next", "switch panel", show=False),
        # ctrl+h is ABSENT FROM THIS LIST ON PURPOSE — see on_key. Textual reports the byte
        # tmux forwards for it (0x08) as `backspace` with no ctrl+h alias, so there is no
        # binding to declare; it is separated from a real Backspace (0x7F) by character.
        Binding("ctrl+j", "nav('D')", "", show=False),
        Binding("ctrl+k", "nav('U')", "", show=False),
        Binding("ctrl+l", "nav('R')", "", show=False),
        Binding("j", "cursor_down", "", show=False),
        Binding("k", "cursor_up", "", show=False),
    ]

    def __init__(self, interval=5.0):
        super().__init__()
        self.interval = interval
        self.data = {"lanes": [], "subs": [], "fleet": [], "error": ""}
        self.sig = None            # last STRUCTURAL snapshot, to skip no-op rebuilds
        self.undo = None           # (path, THE FILE'S OWN BYTES) of the last cleared ask
        self.nudge = 0             # rows the user has added to the fit with + / -
        self.full = None           # id of the panel currently fullscreened, or None
        self.fit_mode = "agents"   # which list `=` is currently fitting: "agents" or "4ME"
        self.detail = None         # the open overlay's assembled data, or None
        self.ask = None            # the open 4ME overlay's {raw, n}, or None
        self.ask_filter = ""       # 4ME category filter: "" = every kind, else a kind name
        # 4ME ORDER, cycled with `s`. DEFAULTS TO `latest` at the user's instruction: the
        # list is opened most often to see what arrived since last time, so the newest ask
        # is the one that should not need scrolling to. It is deliberately NOT remembered
        # across restarts — like `subs_open`, it answers a question you have now.
        self.ask_sort = ASK_SORTS[0]
        self._ctrl_lane = None     # the Lane a ctrl+click just acted on; see on_mouse_down
        # Collapsed on boot: the aggregate exists BECAUSE the individual rows were
        # costing more panel than they said. Opening it is a deliberate act, and it
        # is not remembered across restarts — the drill-down answers a question you
        # have now, not a preference.
        self.subs_open = False
        self.editing = None        # the cfg entry currently being edited, or None
        self.marking = None        # (path, raw, list) the note field is open for, or None
        self._fitted_want = None   # rows the cards wanted at the last fit, clamp aside
        self.refreshed_at = None   # when the last snapshot LANDED, epoch seconds
        self.refreshing = False    # a request is in flight right now

    def _fleet(self):
        """The 4ME asks in the READER'S chosen order. The single place the sort is applied.

        Every surface that touches this list — the panel, the title's count, the fit
        arithmetic — goes through here, because a row NUMBER is what the user says out loud
        ("take #2") and two call sites ordering differently would give one number two
        meanings. See ask_sort_key for the orderings and why deferred is last in all of them.
        """
        ctx = self.data.get("ctx") or {}
        return sorted(self.data.get("fleet") or [],
                      key=lambda ln: ask_sort_key(ln, self.ask_sort,
                                                  ctx.get("goal") or "",
                                                  ctx.get("goal_chain") or []))

    def compose(self) -> ComposeResult:
        yield Static("", id="head")
        # THE STANDING GOAL, directly under the refresh stamp. It is the one line on this
        # screen that says what all the others are FOR, so it sits above the lanes rather
        # than in a panel you have to open. It is hidden entirely when no goal is set —
        # `display: none`, not an empty string, so the row is given back to the fleet.
        yield Static("", id="goal")
        with Panels(id="panels"):
            yield ListView(id="lanes")
            yield ListView(id="fleet")
        # The note field `t` opens, between the panels and the footer. Its two rows come
        # out of the `1fr` panel while it is up and go straight back when it closes.
        yield EmacsInput(id="note-input")
        yield Static("", id="note-msg")
        yield Static(self.legend_markup(), id="legend")
        with Detail(id="detail"):
            yield Static("", id="detail-head")
            # The status gets its own SCROLL BOX rather than growing the dialog without
            # limit: an update can be a paragraph, and a dialog that pushes its own config
            # list off the bottom of the screen has traded one unreadable thing for another.
            with VerticalScroll(id="detail-status-box"):
                yield Static("", id="detail-status")
            yield Static("", id="detail-git")
            yield ListView(id="detail-cfg")
            yield EmacsInput(id="detail-input")
            yield Static("", id="detail-msg")
        with AskDetail(id="ask-detail"):
            yield Static("", id="ask-detail-head")
            # THE ASK ITSELF, in its own scroll box for the reason the lane's status has one:
            # these lines are written to be read, some of them run long, and a dialog that
            # grew without limit would push its own labelled fields off the bottom.
            with VerticalScroll(id="ask-detail-box"):
                yield Static("", id="ask-detail-text")
            yield Static("", id="ask-detail-fields")
            yield Static("", id="ask-detail-msg")
        yield Footer()

    def on_mount(self):
        self.query_one("#lanes").border_title = "FLEET"
        self.query_one("#fleet").border_title = "4ME"
        self._fit_lanes()
        self.reload()
        self.set_interval(self.interval, self.reload)
        # A SECOND TIMER, FOR THE INDICATOR ALONE. The header is otherwise repainted only when
        # data arrives — so "nothing has arrived for a minute", the single state the indicator
        # exists to report, is the one state that could never draw itself. This tick owns no
        # data and shells out to nothing; update_head writes only when the markup changes, so
        # on a healthy fleet it is a string comparison once a second and no repaint at all.
        self.set_interval(1.0, self.update_head)

    # ── data ─────────────────────────────────────────────────────────────────────────────
    def action_reload(self):
        """`r` — an EXPLICIT refresh, which is not the same event as the timer's.

        The tick is the fleet's own heartbeat and is allowed to serve a three-minute-old PR
        list. A keypress is a person saying "I do not believe what I am reading", and the one
        field that would have answered them from cache is the one that costs a network call.
        So `r` forces it, and pays the round trip.
        """
        self.load(force=True)

    def reload(self):
        self.load()

    def load(self, force=False):
        # The stamp turns over the moment the request is MADE, not when it lands: a refresh
        # that never returns is exactly the failure this indicator exists to show, and it can
        # only show it by first admitting that a refresh is in flight.
        self.refreshing = True
        self.update_head()
        self.run_worker(lambda: self._load(force), thread=True, exclusive=True, group="load")

    def _load(self, force=False):
        # A FORCED refresh re-fetches the PRs BEFORE the snapshot reads them, so the number on
        # screen when the key finishes is the number the key asked for. The tick keeps the
        # opposite order (below) on purpose — there the render must never wait on the network.
        # The repo directory comes from the PREVIOUS snapshot rather than a guess; on the very
        # first load there is none, and the after-the-fact refresh already covers that case.
        if force:
            prev = next((r.get("path") for r in
                         (self.data.get("lanes") or []) if r.get("path")), "")
            if prev:
                try:
                    refresh_open_prs(prev, max_age=0)
                except Exception:
                    pass
        data = snapshot()
        if not get_current_worker().is_cancelled:
            self.call_from_thread(self.apply, data)
        # Then refresh the PR cache, on this same worker thread and AFTER the screen is
        # already updated. It is the one fact in the panel that costs a network round trip.
        # Refreshing after rather than before costs one tick of latency on a newly-opened PR
        # and buys two things: the render never waits on the network, and the repo directory
        # comes from a lane we just saw rather than from a guess about where the repo is.
        # `refresh_open_prs` is itself a no-op until the cache ages out, so most ticks pay
        # nothing at all.
        lanes = data.get("lanes") or []
        path = next((r.get("path") for r in lanes if r.get("path")), "")
        if path and not force:      # a forced load already fetched, above
            try:
                refresh_open_prs(path)
            except Exception:
                pass

    @staticmethod
    def structure_sig(data):
        """What a rebuild is actually FOR — everything except the per-tick counters.

        SHAPE ONLY — which rows exist, in what order, each with how many asks. Everything a
        row can say without changing shape (uptime, context%, state, status) is deliberately
        absent: those are updated in place by refresh_volatile, and including them is what made
        the panel repaint on a timer. `state` was the subtle one — it flips whenever any lane
        starts or ends a turn, so on a working fleet it alone kept the signature unstable.
        """
        rows = [[r.get("name"), r.get("kind"), r.get("label"),
                 r.get("raw_asks"), r.get("issue_links")]
                for r in data["lanes"] + data["subs"]]
        return json.dumps([rows, data["fleet"]], sort_keys=True, default=str)

    def _display_rows(self, data=None):
        """The agent list as drawn — ordering (item 7) and the subagent collapse (item 8).

        The expansion is UI state, not fleet state, which is why it is threaded in HERE and
        not built into the snapshot: nothing on disk changes when the row is opened.
        """
        data = self.data if data is None else data
        return display_rows(data.get("lanes") or [], data.get("subs") or [], self.subs_open)

    def apply(self, data):
        """Rebuild only on a STRUCTURAL change; otherwise update the moving numbers in place.

        A ListView rebuilt on a timer throws away the cursor and repaints the screen, which
        makes the view unusable exactly while you are reading it.
        """
        # APPLY CAN RUN WHEN THE PANELS ARE NOT IN THE TREE, and appending a row then kills
        # the app outright: `MountError: Can't mount widget(s) before ListView(id='lanes') is
        # mounted`. The case actually caught in the wild was a rebuild during SHUTDOWN — the
        # `c` filter key arriving as the app tore down, which `action_cycle_category` turns
        # into a full rebuild — and the same hole is open at the other end, since `load()` runs
        # on a worker thread and its result is handed back by `call_from_thread`.
        #
        # `is_attached` IS THE PROPERTY, because it is the precondition Textual's own
        # `Widget.mount` tests. `is_mounted` is a different one and reads True here while the
        # mount still raises, so a guard written on it passes and the app dies anyway.
        #
        # RE-QUEUED, NEVER DROPPED: this may be the load that draws the first frame, and
        # skipping it would leave both panels empty for a whole tick.
        try:
            ready = (self.query_one("#lanes").is_attached
                     and self.query_one("#fleet").is_attached)
        except NoMatches:
            ready = False
        if not ready:
            self.call_after_refresh(self.apply, data)
            return
        sig = self.structure_sig(data)
        self.data = data
        self.refreshed_at = _now()
        self.refreshing = False
        self.update_head()
        self.refresh_detail()
        self.refresh_ask()

        rows = self._display_rows(data)
        lanes = self.query_one("#lanes", ListView)
        if sig == self.sig:
            for item, r in zip(lanes.children, rows):
                if isinstance(item, Lane):
                    item.refresh_volatile(r)
            # A STATUS CAN NOW CHANGE A CARD'S HEIGHT, which it never could before the count
            # became width-aware: a line that grows past its column takes a second row. The
            # text is deliberately absent from the signature — it moves on ticks nobody wants
            # a rebuild for — so the HEIGHT is what is compared instead. Unchanged on almost
            # every tick, and when it does change the panel is the thing that has to move.
            self._refit_if_taller()
            return
        self.sig = sig

        ctx = data.get("ctx") or {}
        try:
            keep = lanes.index
            lanes.clear()
            for r in rows:
                lanes.append(Lane(r, ctx))
            if keep is not None and 0 <= keep < len(rows):
                lanes.index = keep

            fleet = self.query_one("#fleet", ListView)
            keepf = fleet.index
            fleet.clear()
            shown = filter_asks(self._fleet(), self.ask_filter)
            for i, raw in shown:
                fleet.append(Ask(i, raw, data.get("fleet_path", ""), ctx))
            if keepf is not None and 0 <= keepf < len(shown):
                fleet.index = keepf
        except MountError:
            # THE SAME HAZARD, CAUGHT AT THE CALL THAT ACTUALLY RAISES. The probe above closes
            # the window it can SEE; nothing stops a widget detaching between that probe and
            # this mount, which is precisely what a teardown does.
            #
            # THE SIGNATURE IS CLEARED, and that is the load-bearing half: it was set above,
            # so a retry would otherwise take the nothing-changed path and leave both panels
            # permanently empty — a silent version of the same failure.
            self.sig = None
            self.call_after_refresh(self.apply, data)
            return

        # The roster just changed shape — an agent came or went, or one grew an ask — which is
        # the only thing the panel's height depends on. Nothing here runs on the tick that
        # merely moves uptime, so the fit costs nothing on a steady fleet.
        self._fit_lanes()

    def update_goal(self):
        """The standing-goal line — shown only while a goal file exists.

        Written through the same changed-only guard as the header, and toggled by CLASS
        rather than by writing an empty string: an empty Static still occupies its row, and
        the whole contract here is that no goal costs no space.
        """
        goal = (self.data.get("goal") or "").strip()
        w = self.query_one("#goal", Static)
        markup = "  [b yellow]🎯 GOAL[/]  [b]%s[/]" % linkify(
            goal, self.data.get("ctx") or {}) if goal else ""
        if str(w.content) != markup:
            w.update(markup)
        w.set_class(bool(goal), "-show")

    def update_head(self):
        self.update_goal()
        d = self.data
        # The indicator rides along even on the error path — an error IS a refresh result, and
        # the question "is this view still alive" is exactly the one the reader has when the
        # header has gone red.
        mark = refresh_markup(self.refreshed_at, self.refreshing, self.interval)
        if d.get("error"):
            head, markup = (self.query_one("#head", Static),
                            f"  [red]{escape(d['error'])}[/]  ·  {mark}")
            if str(head.content) != markup:
                head.update(markup)
            return
        lanes = d["lanes"]
        live = sum(1 for r in lanes if r.get("state") != "down")
        busy = sum(1 for r in lanes + d["subs"] if r.get("state") == "busy")
        n_ask = sum(len(r.get("raw_asks") or []) for r in lanes) + len(d["fleet"])
        bits = [f"[b]{live}/{len(lanes)}[/] up", f"{busy} busy"]
        if d["subs"]:
            bits.append(f"{len(d['subs'])} sub")
        if n_ask:
            # TWO SPACES after the umbrella, and they are not a typo. ASK is the VS16
            # emoji form, which the terminal draws double-width in a single cell — so
            # one space renders as none and the glyph reads as part of the number.
            bits.append(f"[b yellow]{ASK}  {n_ask} needs you[/]")
        # MONOCLE DRIFT, IN THE HEADER RATHER THAN ON A ROW. It is a fleet-wide operation to
        # fix — restarting one lane's monocle and leaving the others is exactly how four
        # lanes came to run four different builds — and it is absent on every day but the one
        # after a rebuild, so it earns a place in the header precisely because it is rare.
        # The columns below are fixed-width by design and this would have cost one of them a
        # marker that is blank ~always.
        #
        # "old", not a version: what is known is that the process predates the binary on
        # disk. `fleet-status` names the lanes; this says the job exists.
        stale = sum(1 for r in lanes if r.get("monocle_stale"))
        if stale:
            bits.append("[b yellow]%d old monocle%s[/]" % (stale, "" if stale == 1 else "s"))
        bits.append(mark)
        # Written only when changed, for the same reason the lane lines are: an unconditional
        # update() on a timer repaints, and a repaint of the header is as visible as any other.
        head, markup = self.query_one("#head", Static), "  " + "  ·  ".join(bits)
        if str(head.content) != markup:
            head.update(markup)
        # 4ME, and the count is part of the label: the user refers to these rows by number
        # ("4me 1"), so the panel says how many numbers there are.
        # WITH A FILTER UP THE COUNT IS `shown/total`, never `shown` alone: the count is what
        # tells the user whether the list is everything, and a bare "3" on a filtered panel
        # says the fleet has three asks when it has eleven.
        shown = len(filter_asks(self._fleet(), self.ask_filter))
        total = len(d["fleet"])
        count = f"{shown}" if not self.ask_filter else f"{shown}/{total}"
        # THE ORDER IS NAMED IN THE TITLE, always — not only when it is not the default.
        # A list whose order is invisible is a list whose top row means something different
        # depending on state the reader cannot see, and "why is this one first" is exactly
        # the question a sorted list invites. It costs one word.
        title = f"4ME  ({count})  ↓{self.ask_sort}{filter_label(self.ask_filter)}"
        fleet = self.query_one("#fleet")
        if fleet.border_title != title:
            fleet.border_title = title

    # ── actions ──────────────────────────────────────────────────────────────────────────
    def _overlay_owns_keys(self):
        """True while the detail overlay is up.

        The panel keys — `=`, `+`, `-`, `f` — and `x` all act on widgets the overlay is
        covering. Letting them through would resize or DELETE something the user cannot see
        while they are reading a different thing entirely, so the overlay swallows them
        rather than acting at a distance.

        The 4ME overlay counts too, and `x` is the reason it has to: it deletes the very ask
        the dialog is showing, from a list the dialog is covering.
        """
        return self.detail is not None or self.ask is not None

    def _focused_list(self):
        for wid in ("#lanes", "#fleet"):
            w = self.query_one(wid, ListView)
            if w.has_focus:
                return w
        return self.query_one("#lanes", ListView)

    def on_key(self, event):
        """CTRL+H, which does not arrive as a key of its own.

        MEASURED, NOT ASSUMED. A probe app fed the four bytes tmux forwards reported
        `ctrl+j` (with a `newline` alias), `ctrl+k` and `ctrl+l` cleanly — and 0x08 as
        **`backspace`, carrying no ctrl+h alias at all**. So three of the four are ordinary
        bindings and the fourth has to be recognised here, by the character: 0x08 is ctrl+h,
        0x7F is the Backspace key. The same probe confirmed Enter arrives as 0x0D
        (`enter`/`ctrl+m`), so ctrl+j is NOT the Enter collision it looks like — the two are
        distinct events and binding one cannot fire the other.

        THE FIELD KEEPS IT WHILE YOU ARE TYPING. During a knob edit the Input has focus and
        consumes backspace before this handler ever runs, so ctrl+h deletes a character —
        which is the reflex a vim user brings to a text field anyway.

        A terminal configured to send 0x08 for its Backspace key would navigate instead of
        deleting. John's does not (measured: 0x7F), and this is the only signal there is —
        the byte is all that distinguishes them.
        """
        if event.key == "backspace" and event.character == "\x08":
            event.stop()
            event.prevent_default()
            self.action_nav("L")

    def _nav_regions(self):
        """The panels a ctrl-move travels between, top to bottom.

        EMPTY WHILE AN OVERLAY IS UP, and while a panel is fullscreened there is only one.
        A dialog is a single region: the user opened it to read one thing, and "moving
        within" it would mean moving inside something they are holding still. Both cases
        therefore hand straight off to tmux, which is the behaviour that keeps the gesture
        meaning one thing everywhere.
        """
        if self._overlay_owns_keys():
            return []
        return [w for wid in ("#lanes", "#fleet")
                for w in (self.query_one(wid, ListView),) if w.display]

    def action_nav(self, direction):
        """Move within the TUI if there is somewhere to go; otherwise hand off to tmux.

        NEVER SWALLOWED. Every path that does not move focus inside this app ends in the
        tmux call — no region in that direction, an overlay open, a panel fullscreened, an
        edit in progress. A key that silently does nothing is the one failure the user
        cannot tell from a terminal eating it, and it is indistinguishable from this
        feature being broken.

        Left and right never move internally because the panels are stacked, not columned.
        """
        if self.editing is None and self.marking is None and direction in ("U", "D"):
            regions = self._nav_regions()
            here = self._focused_list()
            if here in regions:
                i = regions.index(here) + (1 if direction == "D" else -1)
                if 0 <= i < len(regions):
                    regions[i].focus()
                    return
        select_pane(direction)

    def action_cursor_down(self):
        if self._ask_scroll("down"):
            return
        self._cursor_list().action_cursor_down()

    def action_cursor_up(self):
        if self._ask_scroll("up"):
            return
        self._cursor_list().action_cursor_up()

    def _ask_scroll(self, direction):
        """j/k SCROLL the 4ME overlay rather than moving a cursor — it holds no list.

        Returns True when it handled the key. Without this the keys would fall through to
        `_cursor_list`, which hands them to the lane dialog's config list: a widget that is
        not on screen, whose cursor silently re-aims the editor the user opens next.
        """
        if self.ask is None:
            return False
        box = self.query_one("#ask-detail-box", VerticalScroll)
        box.scroll_down() if direction == "down" else box.scroll_up()
        return True

    def _scroll_top(self, selector):
        """Put a dialog's scroll box back to the top. CALLED ON OPEN, AND ONLY ON OPEN.

        A dialog is ONE WIDGET REUSED FOR EVERY SUBJECT, so the offset it opens at is the
        last reader's rather than this one's: read a long ask to the bottom, close it, open a
        short one, and it renders scrolled past its own first line. The offset survives
        because the widget is never remounted — `-show` only stops it being displayed —
        which is measurable: an offset of 20 is still 20 after a hide/show cycle.

        NEVER FROM THE TICK. `refresh_ask` and `refresh_detail` repaint this same box every
        few seconds while somebody is reading it, and resetting there would drag them back to
        the top mid-sentence — a worse bug than the one this fixes, and a much more annoying
        one. There is a test that scrolls, refreshes, and asserts the offset did not move.
        """
        try:
            self.query_one(selector, VerticalScroll).scroll_home(animate=False)
        except NoMatches:
            pass

    def _cursor_list(self):
        """j/k move the list the reader is actually looking at — the overlay's, when it is up.
        Moving the hidden lane cursor instead would silently re-aim `x` and `enter`."""
        return (self.query_one("#detail-cfg", ListView) if self.detail is not None
                else self._focused_list())

    # ── the agent detail overlay ─────────────────────────────────────────────────────────
    def action_enter(self):
        """One key, dispatched by what is on screen — never two meanings at once.

        Inside the overlay it edits the highlighted knob. On an agent row it opens the lane
        overlay; on a 4ME row, the ask overlay. Anywhere else it opens the ticket.
        """
        w = self._focused_list()
        self._enter(w.id, w.highlighted_child)

    def on_list_view_selected(self, event):
        """Enter is delivered as a ListView SELECTION, not as an app binding.

        The focused ListView binds `enter` itself, and a focused widget's binding wins — so
        an app-level `enter` binding is only ever reached when neither list has focus, which
        is almost never. Routing the Selected message is what actually makes the key work,
        and it makes a mouse click do the same thing for free.
        """
        self._enter(event.list_view.id, event.item)

    # ── ctrl+click: from the 🔍 to the review itself ──────────────────────────────────────
    def on_mouse_down(self, event):
        """CTRL+CLICK ON AN AGENT ROW JUMPS TO THAT LANE'S MONOCLE, zoomed.

        THE WHOLE ROW IS THE TARGET, not the two cells the glyph occupies. Asking for a hit
        on a 2-cell emoji makes the feature a game of aim, and the row already IS the lane —
        every other key on this screen acts on the row under the cursor, not on a character
        within it. A row with nothing staged says so instead of doing nothing, because a
        silent no-op is indistinguishable from a click the terminal ate.

        A modified click still selects the row underneath, and that selection is NOT a request
        for the lane dialog — it is the same gesture, counted twice. `_enter` drops exactly the
        one it belongs to.

        THE TMUX WORK GOES TO A WORKER. It is three round trips plus a config read, which is
        far too much to do on the UI thread of a view that repaints on a five-second tick.
        """
        if not event.ctrl:
            return
        lane = self._lane_of(event.widget)
        if lane is None:
            return
        self._ctrl_lane, row = lane, lane.row
        name = row.get("name") or "?"
        # THE AGGREGATE HAS NO PANE. It stands for a group, and `monocle_pane` resolves a
        # NAME to a tmux pane — handed "subagents" it would search a window that does not
        # exist and report a failure the user cannot act on. Expanding is the useful answer:
        # the rows underneath are the ones that can have a review staged.
        if row.get("kind") == SUBAGG_KIND:
            self.toggle_subs()
            return
        if not row.get("review"):
            self.notify("%s has no review staged" % name, severity="warning")
            return
        self.run_worker(lambda: self._to_monocle(name), thread=True, group="monocle")

    @staticmethod
    def _lane_of(widget):
        """The agent row a clicked widget sits inside, or None — the click was elsewhere."""
        while widget is not None:
            if isinstance(widget, Lane):
                return widget
            widget = getattr(widget, "parent", None)
        return None

    def _to_monocle(self, name):
        """Off the UI thread. Every failure is REPORTED — see monocle_pane on why not guess."""
        pane = monocle_pane(name)
        if not pane:
            self.call_from_thread(
                self.notify, "%s: no monocle pane in its window" % name, severity="warning")
            return
        if not focus_pane(pane):
            self.call_from_thread(
                self.notify, "%s: tmux refused to focus %s" % (name, pane), severity="warning")

    def _enter(self, list_id, item):
        # THE CTRL+CLICK'S OWN SELECTION, dropped. It lives exactly one call: a flag that
        # outlived its gesture would swallow a later keyboard enter on the same row, which is
        # the one failure a user cannot tell from a broken key.
        ctrl_lane, self._ctrl_lane = self._ctrl_lane, None
        if ctrl_lane is not None and item is ctrl_lane:
            return
        if list_id == "detail-cfg":
            self.edit_start()
            return
        # ENTER TOGGLES — the key that opened a dialog closes it. It used to open only, so
        # the reflex of pressing it again did nothing and `esc` was the only way out. This
        # climbs the SAME ladder escape does rather than a second one beside it, so the two
        # keys cannot come to disagree about which dialog is "the open one".
        #
        # The cfg list above is the one exception, and it is checked first: inside the lane
        # dialog enter edits the knob under the cursor, which is that dialog's whole purpose.
        # The lists behind an overlay are never the target either way.
        if self.close_top_overlay():
            return
        if list_id == "lanes" and isinstance(item, Lane):
            # THE AGGREGATE IS NOT AN AGENT, so enter cannot open a detail dialog on it —
            # there is no path, no branch and no config behind the row. It opens the list it
            # stands for instead, which is the same promise enter makes everywhere else here:
            # show me what this row is summarising.
            if item.row.get("kind") == SUBAGG_KIND:
                self.toggle_subs()
                return
            self.open_detail(item.row)
            return
        # A 4ME ROW IS A CARD ABOUT AN ASK, exactly as a lane row is a card about a lane, so
        # enter opens it. It used to fall through to `action_open_ticket`, which read the
        # LANES list no matter which panel was focused — so pressing enter here inspected
        # whichever lane happened to be highlighted and reported "no ticket on this lane"
        # about a row the user was not looking at. The ticket still opens, from `o`, which is
        # now aimed at the focused panel like every other key.
        if list_id == "fleet" and isinstance(item, Ask):
            self.open_ask(item)
            return
        self.action_open_ticket()

    def toggle_subs(self):
        """Expand or collapse the subagent list under its aggregate row.

        `self.sig = None` FORCES the rebuild. The signature is a function of the SNAPSHOT, and
        nothing in the snapshot moved — so without this the next apply would take the in-place
        branch and zip the fresh row list against the children of the old one.
        """
        self.subs_open = not self.subs_open
        self.sig = None
        if self.data:
            self.apply(self.data)
        self._fit_lanes()

    def open_detail(self, row):
        """Show the overlay at once, fill it from a WORKER.

        The git reads and the pane capture are subprocesses. Doing them here would freeze the
        whole app — including the tick behind the overlay — for as long as git took, so the
        panel opens saying it is loading and gains its numbers a beat later.
        """
        self.detail = {"row": row, "data": None}
        self.query_one("#detail").add_class("-show")
        self.query_one("#detail-head", Static).update(
            "[b]%s[/]  [dim]loading…[/]" % escape(row.get("name") or "?"))
        self.query_one("#detail-status", Static).update("")
        self.query_one("#detail-git", Static).update("")
        self.query_one("#detail-msg", Static).update(DETAIL_HINT)
        self.query_one("#detail-cfg", ListView).clear()
        self._scroll_top("#detail-status-box")
        self.run_worker(lambda: self._load_detail(row), thread=True, group="detail")

    def refresh_detail(self):
        """Re-read the open overlay on the same tick the panel behind it refreshes.

        THE OVERLAY USED TO BE A SNAPSHOT taken the instant it opened, and nothing ever
        re-took it — so `r` reloaded the fleet underneath a dialog that went on showing what
        was true when Enter was pressed. Its status aged, its git numbers stopped moving, and
        a terminal resized behind it never re-laid out its text.

        Skipped while an edit is open: the input carries text the user has not committed, and
        the message beside it may be a validation error about that text. Neither survives a
        repaint, and neither is the tick's to discard.

        This does put git reads and a tmux capture on the five-second tick — but ONLY while
        the overlay is open, on the same worker thread they already used, and for a dialog the
        user is looking at right now. The rule the module states is about the panel's steady
        state, which is unchanged: close the overlay and the tick shells out to nothing again.
        """
        if self.detail is None or self.editing:
            return
        name = (self.detail.get("row") or {}).get("name")
        # Re-aim at the row from THIS snapshot, not the one captured at open: status age and
        # context% live on the row, so refreshing against the stale copy would repaint the
        # same frozen numbers and look exactly like the bug it is meant to fix.
        fresh = next((r for r in self.data["lanes"] + self.data["subs"]
                      if r.get("name") == name), None)
        if fresh is not None:
            self.detail["row"] = fresh
        row = self.detail["row"]
        self.run_worker(lambda: self._load_detail(row), thread=True, group="detail")

    def _load_detail(self, row):
        data = detail_data(row)
        if not get_current_worker().is_cancelled:
            self.call_from_thread(self.show_detail, data)

    def show_detail(self, data, msg=None, keep=None):
        """Paint the overlay. `keep` restores the cursor across the reload a save triggers."""
        if self.detail is None:
            return                 # closed while the worker was still reading
        first_paint = self.detail["data"] is None
        self.detail["data"] = data
        # Written only when the markup actually differs, for the same reason the lane rows are:
        # a refresh that repaints identical text is itself a visible flicker, and this now runs
        # on the five-second tick rather than only when the overlay opens.
        for wid, markup in (("#detail-head", self.detail_head_markup(data)),
                            ("#detail-status", self.detail_status_markup(data)),
                            ("#detail-git", self.detail_git_markup(data))):
            w = self.query_one(wid, Static)
            if str(w.content) != markup:
                w.update(markup)
        cfg = self.query_one("#detail-cfg", ListView)
        if keep is None:
            keep = cfg.index
        cfg.clear()
        for e in data["cfg"]:
            cfg.append(CfgRow(e))
        if keep is not None and 0 <= keep < len(data["cfg"]):
            cfg.index = keep
        if msg is not None:
            self.query_one("#detail-msg", Static).update(msg)
        if not self.editing:
            # NEVER steal focus back from an open editor. A tick-driven refresh lands while the
            # user may be mid-typing in the value field, and moving focus there would eat the
            # keystroke that followed it.
            cfg.focus()
        if first_paint:
            # `open_detail` already reset the scroll box, but before ANY real content existed
            # — it was still showing "loading…", so the box had nothing to be scrolled past.
            # `cfg.focus()` above can pull the scroll position back down to bring the list
            # into view once it is populated, which is the actual mechanism behind "opens
            # scrolled past its own first line": the box was at the top, then focus moved it.
            # Reset AFTER focus, and ONLY on the paint that follows an open — never on a
            # tick-driven refresh, which is exactly the case the docstring below warns about.
            self._scroll_top("#detail-status-box")

    def detail_head_markup(self, data):
        live = data.get("live")
        # EVERY VALUE ON THIS LINE WEARS ITS OWN LABEL, and the tmux pane id wears one twice
        # over. `%182` printed bare after `effort=medium` was read as "182%" — a percentage
        # beside a field whose values are words, which sent a reader looking for a context
        # bug that did not exist. A pane id is not a number about the agent, so it says
        # `pane`, and it is separated from the knobs rather than trailing them.
        pcs, pcolor = context_markup(data.get("context_pct"), data.get("state"))
        ctx = "[dim]context[/] [%s]%s[/]" % (pcolor, pcs)
        # The live line is OMITTED, not filled with a guess, when the pane cannot be read —
        # a lane with no agent in it still has git state and config worth looking at.
        if live:
            line = ("  [dim]running[/] model=[b]%s[/] effort=[b]%s[/]  ·  %s  ·  "
                    "[dim]pane %s[/]"
                    % (escape(live["model"]), escape(live["effort"]), ctx,
                       escape(live["pane"])))
        else:
            line = ("  [dim]no live session in this lane — config and git only[/]  ·  %s"
                    % ctx)
        rev = data.get("review")
        if rev:
            # fmt_ago, not fmt_age: the wait is the point of the line, and fmt_age returns
            # "" below its staleness threshold — a review staged five minutes ago would have
            # rendered with no clock at all, which reads as one staged at an unknown time.
            age = fmt_ago(rev.get("age"))
            line += "  ·  [b cyan]%s staged%s%s[/]" % (
                REVIEW,
                " '%s'" % escape(rev["name"]) if rev.get("name") else "",
                " · %s ago" % escape(age) if age else "")
        return ("[b]%s[/] [dim]%s[/]  [dim]%s[/]\n%s"
                % (escape(data["name"]), escape(data["label"]),
                   escape(data["path"]), line))

    def detail_status_markup(self, data):
        """The agent's update IN FULL — the reason this dialog is worth opening.

        The lane row shows sixty characters because it is one line in a column. Here there is
        a whole dialog, so the text is the file's, unclipped and wrapped, and it scrolls if it
        outgrows the box rather than being cut. Both clocks come with it, for the reason they
        do on the row: the text says WHAT, `(4d old)` says how old the claim is, and
        `active 2m ago` says whether the agent has done anything since.
        """
        status = data.get("status") or ""
        age = fmt_age(data.get("status_age"))
        ago = fmt_ago(data.get("last_active"))
        body = (linkify(status, self.data.get("ctx") or {}) if status
                else "[dim i]— no status —[/]")
        marks = []
        if status and age:
            marks.append("%s old" % escape(age))
        if ago:
            marks.append("active %s ago" % escape(ago))
        head = "[dim]status[/]"
        if marks:
            head += "  [dim](%s)[/]" % " · ".join(marks)
        return "%s\n[i]%s[/]" % (head, body)

    def detail_git_markup(self, data):
        """Branch, distances — and the ticket, LABELLED BY SOURCE when the two disagree.

        The row's `≠branch` marker says a disagreement exists and shows the winning id only.
        This is where the reader finds out what it disagrees WITH, so both ids appear with
        the name of the file or branch they came from: an unlabelled pair would leave the
        reader guessing which one the panel is acting on, which is the thing the marker was
        supposed to end.
        """
        g = data.get("git")
        if not g:
            return "[dim]no path on this row — nothing to read[/]"

        ids = " ".join(i for i, _u in (data.get("tickets") or []))
        ticket = ""
        if data.get("ticket_mismatch"):
            ticket = ("ticket [b cyan]%s[/] [dim]— from .claude/current-work[/]\n"
                      "[dim]branch names[/] [yellow]%s[/] "
                      "[dim]— left over from finished work; the file wins[/]\n"
                      % (escape(ids), escape(data.get("branch_ticket") or "")))
        elif ids:
            ticket = "ticket [b cyan]%s[/]\n" % escape(ids)

        def dist(c):
            return "[dim]—[/]" if c is None else "[green]↑%d[/] [yellow]↓%d[/]" % c
        dirty = ("[dim]clean[/]" if g["dirty"] == 0 else
                 "[yellow]%d dirty[/]" % g["dirty"] if g["dirty"] else "[dim]—[/]")
        return (ticket
                + "branch [b cyan]%s[/]   %s\n"
                "vs [b]%s[/]         %s\n"
                "vs [b]origin/%s[/]  %s   [dim](local ref — not fetched, may be stale)[/]"
                % (escape(g["branch"] or "(detached)"), dirty,
                   escape(g["base"]), dist(g["local"]),
                   escape(g["base"]), dist(g["origin"])))

    def close_detail(self):
        self.editing = None
        self.detail = None
        inp = self.query_one("#detail-input", Input)
        inp.remove_class("-show")
        inp.value = ""
        self.query_one("#detail").remove_class("-show")
        self.query_one("#lanes", ListView).focus()

    # ── the 4ME overlay ──────────────────────────────────────────────────────────────────
    # No worker and no `loading…` frame, unlike the lane dialog: everything here comes from
    # one already-open text file, so there is no subprocess to keep off the UI thread and
    # nothing slow enough to be worth a two-stage paint.

    def open_ask(self, item):
        """Open the overlay on a 4ME row, keyed by the row's RAW line.

        The key is the line's bytes rather than its position, because the list renumbers
        whenever anything above it is cleared — an index captured at open would quietly come
        to mean a different ask.
        """
        self.ask = {"raw": item.raw, "n": item.n}
        self.query_one("#ask-detail").add_class("-show")
        self.query_one("#ask-detail-msg", Static).update(ASK_HINT)
        self.show_ask()
        # AFTER the paint, not before: the box is scrolled relative to content it does not
        # have until show_ask has written it.
        self._scroll_top("#ask-detail-box")

    def refresh_ask(self):
        """Repaint the open 4ME overlay on the same tick the panel behind it refreshes.

        Same contract as `refresh_detail`, and it matters here for a reason of its own: the
        lead edits this file WHILE the user is reading it. A dialog frozen at the moment
        enter was pressed would go on showing an ask that has since been reworded.
        """
        if self.ask is not None:
            self.show_ask()

    def show_ask(self):
        """Paint the overlay from the FILE, not from the row that opened it.

        THE ROW IS NOT THE SOURCE. `Ask.compose` clips to sixty characters for its column,
        exactly as `status_line()` does for a lane's — so a dialog built from what the list
        displayed would reproduce the truncation it exists to undo. It re-reads the ask file
        and re-finds this line, which is the same move `status_text()` makes.

        A line that has vanished from the file keeps its last known text, marked as gone. It
        is not an error: the lead clearing an item is ordinary, and blanking the dialog under
        someone mid-read would destroy the thing they opened it to see.
        """
        if self.ask is None:
            return
        raw = self._reaim_ask(_ask_lines(self.data.get("fleet_path") or ""))
        gone = raw is None
        if raw is not None:
            self.ask["raw"] = raw          # follow the edit, so the next tick re-finds it
        else:
            raw = self.ask["raw"]
        d = ask_detail(raw)
        ctx = self.data.get("ctx") or {}
        for wid, markup in (("#ask-detail-head", self.ask_head_markup(d, gone)),
                            ("#ask-detail-text", self.ask_text_markup(d, ctx)),
                            ("#ask-detail-fields", self.ask_fields_markup(d, ctx))):
            w = self.query_one(wid, Static)
            if str(w.content) != markup:      # changed-only, like every other repaint here
                w.update(markup)

    def _reaim_ask(self, lines):
        """Find the open ask again in a file that has changed under it, or None if it is gone.

        THE LEAD REWORDS THESE LINES WHILE THEY ARE BEING READ, so the raw text cannot be the
        identity — matching on it alone would report a freshly-clarified ask as deleted, which
        is the opposite of what happened. Identity is, in order:

          1. the exact line, when it is still there — no ambiguity to resolve;
          2. the TICKET, which is what the ask is *about* and survives any rewording. Only
             when exactly one line carries it: two asks about one ticket make this a guess,
             and guessing is how a dialog ends up showing a row the user is not looking at;
          3. failing both, position — but only for a ticketless ask, and only if the line
             still at that position is of the same KIND. A `review:` where a `product:` was is
             a different item that happens to have inherited the slot.

        Anything less certain than these is reported as gone rather than resolved, for the
        reason the `o` fix exists: acting confidently on the wrong item is worse than saying
        nothing.
        """
        raw = self.ask["raw"]
        if raw in lines:
            return raw
        d = ask_detail(raw)
        tid = dict(d["trailers"]).get("ticket", "")
        if tid:
            same = [ln for ln in lines
                    if dict(ask_detail(ln)["trailers"]).get("ticket", "") == tid]
            return same[0] if len(same) == 1 else None
        i = self.ask["n"] - 1
        if 0 <= i < len(lines) and ask_detail(lines[i])["kind"] == d["kind"]:
            return lines[i]
        return None

    def ask_head_markup(self, d, gone=False):
        kind = d["kind"] or "todo"
        head = "[b]4ME[/] [dim]#%s[/]   %s [b]%s[/]" % (self.ask["n"], d["icon"], escape(kind))
        if gone:
            head += "   [yellow](cleared from the list)[/]"
        return head

    def ask_text_markup(self, d, ctx):
        """The ask IN FULL — unclipped, wrapped by the box, ids AND doc paths clickable.

        The row trades a path for a glyph because the row is a column. Here the path stays
        visible — it is what someone copies into a terminal — and is a link as well, so the
        dialog is not the one surface where you can read the location but not open it.

        AND THE CONTEXT BLOCK UNDER IT, which is why this dialog now earns its keystroke. The
        ask alone says what is being decided; the context says what the reader needs in order
        to decide it without going and asking. It is rendered UPRIGHT under the italic ask, so
        the question stays visually the question and the background stays background.
        """
        text = d["text"] or ""
        if not text:
            return "[dim i]— empty —[/]"
        out = "[i]%s[/]" % doc_text_markup(text, lambda t: linkify(t, ctx))
        if d.get("context"):
            out += "\n\n" + doc_text_markup(d["context"], lambda t: linkify(t, ctx))
        return out

    def ask_fields_markup(self, d, ctx):
        """The trailers as LABELLED fields, one per line.

        Every value wears its label for the reason the lane dialog's do: a bare date beside a
        bare agent name is two facts the reader has to guess the type of. Absent fields are
        omitted rather than shown empty — this dialog says what is known, and a column of
        `—` would make an ask with no provenance look like a broken one.
        """
        t = dict(d["trailers"])
        rows = []
        tid = t.get("ticket", "")
        if tid:
            url = ask_ticket_url(tid, ctx)
            val = "[link='%s']%s[/link]" % (url, escape(tid)) if url else escape(tid)
            goal, chain = self.data.get("goal") or "", self.data.get("goal_chain") or []
            # THE GOAL MARKER. An ask whose ticket the standing goal names is not one item
            # among many — it is gating the thing the whole fleet is pointed at, and that is
            # the single most useful fact this dialog can put in front of the lead.
            if goal_mentions(tid, goal, chain):
                val += "   [b yellow]🎯 on the goal chain[/]"
            rows.append(("ticket", val))
        if t.get("from"):
            rows.append(("raised by", esc(t["from"])))
        if t.get("added"):
            age = ask_age(t["added"])
            rows.append(("added", escape(t["added"])
                         + ("   [dim](%s ago)[/]" % escape(age) if age else "")))
        if d["deferral"]:
            rows.append(("deferred", "[yellow]%s[/]" % esc(d["deferral"])))
        if t.get("unblocks"):
            rows.append(("unblocks", linkify(t["unblocks"], ctx)))
        # THE USER'S OWN WORD ON THE ROW, written with the ✅ by `t`. Rendered exactly as
        # `unblocks` is — linkified, so a note that names a ticket or a PR is clickable from
        # here like every other id on this screen.
        if t.get("note"):
            rows.append(("note", linkify(t["note"], ctx)))
        # UNKNOWN TRAILERS RENDER AS-IS, under no label. The format will grow past this
        # reader, and an extension the dialog refused to draw would be a fact the lead wrote
        # down and never saw again.
        for key, value in d["trailers"]:
            if not key:
                rows.append(("", "[dim]%s[/]" % esc(value)))
        if not rows:
            return "[dim i]— no metadata on this ask —[/]"
        return "\n".join("[dim]%-10s[/] %s" % (label, value) for label, value in rows)

    def close_ask(self):
        self.ask = None
        self.query_one("#ask-detail").remove_class("-show")
        self.query_one("#fleet", ListView).focus()

    def edit_start(self):
        """Open the field on the highlighted knob, pre-filled with its current value."""
        item = self.query_one("#detail-cfg", ListView).highlighted_child
        if not isinstance(item, CfgRow):
            return
        e = item.entry
        self.editing = e
        inp = self.query_one("#detail-input", Input)
        inp.value = e["value"]
        allowed = VALID_EFFORT if e["kind"] == "effort" else VALID_MODEL
        inp.placeholder = "%s — %s, or empty to inherit" % (e["key"], "|".join(allowed))
        inp.add_class("-show")
        inp.focus()
        self.query_one("#detail-msg", Static).update(
            "[dim]enter saves to workflow.config.local · esc cancels · "
            "allowed: %s or empty[/]" % "|".join(allowed))

    def edit_cancel(self):
        self.editing = None
        inp = self.query_one("#detail-input", Input)
        inp.remove_class("-show")
        inp.value = ""
        self.query_one("#detail-cfg", ListView).focus()
        self.query_one("#detail-msg", Static).update("")

    def on_input_submitted(self, event):
        """Validate, then write — and say which of the two futures the save just bought.

        A REJECTED VALUE LEAVES THE FIELD OPEN. These strings are typed into a live agent's
        pane by agent-tune.sh, so anything outside the two fixed vocabularies is refused
        here rather than written and discovered later; keeping the field open with the bad
        text in it is what lets the user fix a typo instead of retyping.

        TWO FIELDS SHARE THIS HANDLER, so it dispatches on the id first. The knob editor and
        the `t` note are the same gesture on different subjects and are deliberately not the
        same code: one validates against a fixed vocabulary an agent will be told to obey, the
        other accepts any prose a human types and only checks that it can be read back.
        """
        if event.input.id == "note-input":
            self.mark_submit(event.value)
            return
        e, data = self.editing, (self.detail or {}).get("data")
        if not e or not data:
            return
        value = event.value.strip()
        if not valid_value(e["kind"], value):
            allowed = VALID_EFFORT if e["kind"] == "effort" else VALID_MODEL
            self.query_one("#detail-msg", Static).update(
                "[red]%s is not a valid %s[/] — one of %s, or empty to inherit"
                % (escape(value), e["kind"], "|".join(allowed)))
            return
        keep = self.query_one("#detail-cfg", ListView).index
        try:
            write_config_value(data["local_path"], e["key"], e["kind"], value)
        except (OSError, ValueError) as err:
            self.query_one("#detail-msg", Static).update("[red]could not save: %s[/]"
                                                         % escape(str(err)))
            return
        self.editing = None
        inp = self.query_one("#detail-input", Input)
        inp.remove_class("-show")
        inp.value = ""
        shown = value or "(inherit)"
        if e["scope"] == "live":
            # THE DISTINCTION THE USER CANNOT SEE FROM THE FILE. A lane knob describes a
            # session that is already running and re-reads nothing, so the file alone changes
            # nothing until agent-tune types it in.
            msg = ("[green]saved[/] %s=%s → workflow.config.local\n"
                   "[b yellow]the running agent has NOT changed[/] — press [b]a[/] to apply "
                   "it now with agent-tune" % (escape(e["key"]), escape(shown)))
        else:
            msg = ("[green]saved[/] %s=%s → workflow.config.local\n"
                   "[dim]read when this subagent next spawns — nothing to apply[/]"
                   % (escape(e["key"]), escape(shown)))
        # Re-read rather than patch the row in memory: the file is the truth, and a save that
        # silently failed to land must not leave the overlay claiming it did.
        self.run_worker(lambda: self._reload_detail(msg, keep), thread=True, group="detail")

    def _reload_detail(self, msg, keep):
        row = (self.detail or {}).get("row")
        if row is None:
            return
        data = detail_data(row)
        if not get_current_worker().is_cancelled:
            self.call_from_thread(self.show_detail, data, msg, keep)

    def action_apply_now(self):
        """`a` — hand the lane's configured effort/model to the running agent.

        Only inside the overlay, and only when there is a live session to type into: this is
        the one key here that reaches out and changes something outside a file.
        """
        if self.detail is None or self.editing is not None:
            return
        data = self.detail.get("data")
        if not data:
            return
        if not data.get("live"):
            self.query_one("#detail-msg", Static).update(
                "[yellow]no live session in this lane — nothing to apply to[/]")
            return
        self.query_one("#detail-msg", Static).update(
            "[dim]running agent-tune apply %s … (it serializes against other runs)[/]"
            % escape(data["name"]))
        self.run_worker(lambda: self._apply_now(data), thread=True, group="apply")

    def _apply_now(self, data):
        line = apply_now(data["tune_sh"], data["name"])
        if get_current_worker().is_cancelled:
            return
        colour = "green" if "PASS" in line else "red" if "FAIL" in line else "yellow"
        self.call_from_thread(self._apply_done,
                              "[%s]agent-tune:[/] %s" % (colour, escape(line)))

    def _apply_done(self, msg):
        if self.detail is None:
            return
        self.query_one("#detail-msg", Static).update(msg)

    def action_open_ticket(self):
        """Open the ticket of whatever the user is actually pointing at.

        IT USED TO READ `#lanes` UNCONDITIONALLY, whichever panel had focus. On a 4ME row that
        made `o` — and, through the fall-through, enter — report on a lane the user was not
        looking at: "no ticket on this lane" about someone else's row, or worse, silently
        opening an unrelated ticket. Every other key here acts on the focused panel; this one
        now does too, and an ask resolves its id from its `[TICKET]` trailer.
        """
        # While the 4ME overlay is up the focused widget is not a list at all, so the ask it
        # is showing is the subject — not whatever the cursor was left on underneath it.
        if self.ask is not None:
            item, is_ask = None, True
            tid = dict(ask_detail(self.ask["raw"])["trailers"]).get("ticket", "")
        else:
            item = self._focused_list().highlighted_child
            is_ask = isinstance(item, Ask)
            tid = dict(ask_detail(item.raw)["trailers"]).get("ticket", "") if is_ask else ""

        if is_ask:
            if not tid:
                self.notify("no ticket on this ask", severity="warning")
                return
            url = ask_ticket_url(tid, self.data.get("ctx") or {})
            links = [(tid, url)]
        else:
            links = (getattr(item, "row", {}) or {}).get("issue_links") or []
            if not links:
                self.notify("no ticket on this lane", severity="warning")
                return

        _id, url = links[0]
        if not url:
            self.notify(f"{_id} has no URL recorded", severity="warning")
            return
        subprocess.Popen(["open", url])
        self.notify(f"opened {_id}")

    def _row_trailers(self):
        """The trailers of whatever the user is pointing at — overlay first, then the row.

        Same subject-resolution as action_open_ticket, and for the same reason it was fixed
        there: while the overlay is up the focused widget is not a list, so acting on the
        cursor underneath it acts on a row the user is not looking at.
        """
        if self.ask is not None:
            return dict(ask_detail(self.ask["raw"])["trailers"])
        item = self._focused_list().highlighted_child
        return dict(ask_detail(item.raw)["trailers"]) if isinstance(item, Ask) else {}

    def open_review(self, path):
        """Focus the Monocle pane serving `path`.

        NOT itself the `@click` target — markup naming `app.open_review` reaches
        `action_open_review`, which calls this. See that method.

        THE PANE IS FOUND BY ITS TUI'S cwd, never by pane INDEX or title. Window/pane indices
        are not ordered by lane — measured, feature-1 was `main:2.1` and feature-2 `main:3.1`
        — and an agent can set its own pane title. The cwd of the monocle process inside the
        pane is the one identifier that cannot be wrong about which lane it serves.
        """
        target = self._monocle_pane(path)
        if not target:
            self.notify("no monocle pane found for %s" % os.path.basename(path or ""),
                        severity="warning")
            return
        # THE SAME `focus_pane` CTRL+CLICK USES, not a second inline switch-client/select-pane.
        # The two gestures mean one thing — "put that Monocle in front of me" — and the copy
        # this replaced had already drifted: it never zoomed, and it ignored tmux's exit code,
        # so a dead pane id reported success and moved nothing.
        if not focus_pane(target):
            self.notify("could not focus the monocle pane", severity="error")
            return
        self.notify("focused monocle · %s" % os.path.basename(path or ""))

    @staticmethod
    def _monocle_pane(path):
        """`%id` of the monocle serving `path`, or "". Pure-ish; no raises.

        `#{pane_id}` — the `%42` form — NOT `session:window.pane`. The index form renumbers
        the moment any earlier pane is killed, so a value read on one tick can name a
        different pane on the next; `%id` is unique for the pane's whole life. It is also
        what `monocle_pane()` and `focus_pane()` already speak, so the two ways into a
        Monocle now pass the same kind of thing around.
        """
        want = os.path.realpath(path or "")
        if not want:
            return ""
        try:
            out = subprocess.run(
                ["tmux", "list-panes", "-a", "-F",
                 "#{pane_id} #{pane_current_command} #{pane_current_path}"],
                capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""
        for ln in out.splitlines():
            parts = ln.split(None, 2)
            if len(parts) < 3:
                continue
            target, cmd, cwd = parts
            # ONE CONSTANT FOR BOTH FINDERS. A literal "monocle" here would keep working
            # right up until MONOCLE_CMD changed, and then only the badge would break.
            if MONOCLE_CMD not in cmd:
                continue
            # `pane_current_path` is the pane SHELL's cwd, which is the lane for a monocle
            # started in place. Compared by realpath so a symlinked lanes dir still matches.
            #
            # VERIFIED LIVE 2026-08-19, by two instruments that could have disagreed: tmux's
            # own `pane_current_path`, and `lsof -a -p <monocle child pid> -d cwd -Fn` on the
            # process resolved through `pgrep -P <pane_pid>`. All four monocle panes then
            # running agreed, and each named the lane it serves (main:2.1→feature-1,
            # 3.1→feature-2, 4.1→feature-3, 5.1→feature-4). The shell cannot drift away from
            # it while monocle runs, because the shell is blocked on that child.
            if os.path.realpath(cwd) == want:
                return target
        return ""

    def action_open_review(self, arg=None):
        """`m` on the highlighted row, and the 🔎 badge's `@click` target — ONE method.

        IT HAS TO BE ONE METHOD, and that is the whole fix here. Textual resolves
        `@click=app.open_review('…')` to `action_open_review`, NEVER to the plain
        `open_review` the markup appears to name — and `invoke()` then truncates the
        argument list to the callable's arity, so a zero-arg `action_open_review()`
        SWALLOWED the clicked row's path without raising. The badge silently acted on
        whatever row the cursor happened to be on. Measured on textual 8.2.8.

        `arg` present ⇒ a click, and it carries its own subject. `arg` absent ⇒ the
        keybinding, which asks the cursor.
        """
        path = _adec(arg) if arg is not None else self._row_trailers().get("review")
        if not path:
            self.notify("no review staged on this row", severity="warning")
            return
        self.open_review(path)

    def copy_cmd(self, cmd):
        """Put `cmd` on the system clipboard. Reached from `action_copy_cmd`, never
        directly from the badge markup — see action_open_review."""
        if not cmd:
            return
        try:
            subprocess.run(["pbcopy"], input=cmd, text=True, timeout=5, check=True)
        except (OSError, subprocess.SubprocessError) as e:
            self.notify("could not copy: %s" % e, severity="error")
            return
        self.notify("copied · %s" % clip(cmd, 48))

    def action_copy_cmd(self, arg=None):
        """`y` on the highlighted row, and the 📋 badge's `@click` target. See
        action_open_review for why the click and the key must share one entry point."""
        cmd = _adec(arg) if arg is not None else self._row_trailers().get("cmd")
        if not cmd:
            self.notify("no command on this row", severity="warning")
            return
        self.copy_cmd(cmd)

    def action_open_doc(self):
        """Open the first document this row references — its prose OR its context block.

        Both halves are searched because a long ask keeps its links in the context, which is
        exactly where the row's own doc badge now finds them too. One source, one answer.
        """
        raw = self.ask["raw"] if self.ask is not None else None
        if raw is None:
            item = self._focused_list().highlighted_child
            if not isinstance(item, Ask):
                self.notify("no document on this row", severity="warning")
                return
            raw = item.raw
        d = ask_detail(raw)
        urls = doc_refs(d["text"])[1] + doc_refs(d.get("context") or "")[1]
        if not urls:
            self.notify("no document on this row", severity="warning")
            return
        subprocess.Popen(["open", urls[0]])
        self.notify("opened %s" % os.path.basename(urls[0].split("?")[0]))

    def action_clear_ask(self):
        """Tick an item off. Lane panel clears that lane's FIRST ask; fleet panel clears the
        highlighted one. Undoable, because a mis-keyed `x` on someone else's to-do list is a
        silent loss otherwise."""
        if self._overlay_owns_keys():
            return
        w = self._focused_list()
        item = w.highlighted_child
        if isinstance(item, Ask):
            path, raw = item.path, item.raw
        elif isinstance(item, Lane):
            asks = item.row.get("raw_asks") or []
            if not asks:
                self.notify("nothing to clear on this lane", severity="warning")
                return
            path, raw = item.row["ask_path"], asks[0]
        else:
            return
        # A DERIVED ROW HAS NOTHING IN THE FILE TO DELETE. Refusing loudly beats letting
        # `_drop_line` return "" and reporting "already gone", which is a lie that would
        # look like a bug the next tick, when the row reappears.
        if dict(ask_detail(raw)["trailers"]).get("derived"):
            # NAME THE WAY OUT. "Clear it by answering it" was true and useless once the
            # engine had already been answered and the flag stayed up: the user was told what
            # not to press and left with nothing that worked. `t` is the thing that works.
            self.notify("this row tracks live state — answer it, or t to force-clear "
                        "it with a note", severity="warning")
            return
        # UNDO CARRIES WHAT THE FILE HAD, not the folded `raw` this view is holding — see
        # `_drop_line`. `raw` is still what the notification quotes: that is for a human.
        removed = _drop_line(path, raw)
        if removed:
            self.undo = (path, removed)
            self.notify(f"cleared · u to undo — {clip(raw, 40)}")
            self.load()
        else:
            self.notify("already gone", severity="warning")

    @staticmethod
    def legend_markup():
        """EVERY glyph on screen. A marker whose meaning you have to ask about is not doing
        its job, and the lane-state shapes were exactly that."""
        kinds = "\n".join("  %s  %s" % (ASK_KINDS[k], d) for k, d in (
            ("review", "a diff / PR to read and green-light"),
            ("plan", "a plan awaiting its gate"),
            ("product", "a product or scoping call"),
            ("triage", "a tracker question — is this an issue, whose, what priority"),
            ("ship", "a merge / deploy / publish gate"),
            ("fleet", "the machinery itself — hooks, scripts, skills, lane tooling"),
            ("todo", "a general action item"),
        ))
        states = "\n".join("  %s  %s" % (i, d) for i, d in (
            (f"[b yellow]{LANE_ASK}[/]", "this lane owes YOU an answer — replaces its state"),
            ("[green]●[/]", "busy — tool calls landing now"),
            ("[yellow]◔[/]", "quiet — turn open, nothing happening"),
            ("[dim]○[/]", "idle — between turns"),
            ("[red]·[/]", "down — lane exists, nothing running in it"),
        ))
        # ENTER IS DOCUMENTED HERE BECAUSE THE FOOTER CANNOT SHOW IT. The focused ListView
        # binds `enter` itself, so its own (hidden) binding is what the footer renders — the
        # app's description never appears. A key with no discoverable meaning is exactly the
        # problem this legend exists for.
        keys = "\n".join("  %-6s %s" % (k, d) for k, d in (
            ("enter", "on an agent row: its git state and config, editable"),
            ("", "on a 4ME row: the ask in full, with its ticket and provenance"),
            ("o", "open the ticket of the row you are on — lane or ask"),
            ("a", "in the detail view: apply the live knobs to the running agent"),
            ("c", "cycle the 4ME category filter — all, then each kind present. The row"),
            ("", "numbers keep their gaps, because a number is an address, not a position"),
            ("s", "cycle the 4ME order — latest, earliest, goal. Named in the panel title"),
            ("m", "focus the Monocle pane of the review on this row  (badge: %s)" % REVIEW_BADGE),
            ("d", "open the document this row references — prose or context"),
            ("y", "copy this row's command to the clipboard  (badge: %s)" % CMD_BADGE),
            ("t", "tick this row DONE without deleting it — %s in the file, plus an optional"
                  % ASK_GENERAL),
            ("", "note you type. It stays on the list, marked, until the lead sweeps it"),
            ("", "On a %s review row it force-clears the staged review instead, retiring"
                 % ASK_KINDS["review"]),
            ("", "the lane's flag file — and there the note is REQUIRED, not optional"),
            ("^f ^b", "in either text field: move a character. ^a ^e line start/end,"),
            ("", "^k kill to end, ^d delete forward, ^w ^u delete word/line back"),
        ))
        return ("[b]LANE[/]\n%s\n\n[b]ACTION ITEMS[/]\n%s\n\n[b]KEYS THE FOOTER CANNOT SHOW[/]"
                "\n%s\n\n[dim]? or esc to close[/]" % (states, kinds, keys))

    def action_cycle_category(self):
        """All → each category PRESENT in the file → All.

        Only kinds that exist are in the cycle, so the key never steps onto an empty view.
        A filter is a VIEW: nothing is written, nothing is deleted, and `x`/`u` keep acting on
        the row under the cursor exactly as before.

        The overlay swallows it for the same reason it swallows `=`/`x` — re-filtering the
        list behind a dialog moves rows the user cannot see, and the ask they are reading
        could be one of the ones that vanishes.
        """
        if self._overlay_owns_keys():
            return
        cycle = ask_kinds_present(self.data.get("fleet") or [])
        if not cycle:
            self.notify("4ME is empty — nothing to filter", severity="warning")
            return
        order = [FILTER_ALL] + cycle
        try:
            nxt = order[(order.index(self.ask_filter) + 1) % len(order)]
        except ValueError:
            # The active filter's last row was just cleared, so its kind is gone from the
            # cycle. Fall back to ALL rather than raising — the alternative is a key that
            # dies on the one press that most needs to work (an empty filtered panel).
            nxt = FILTER_ALL
        self.ask_filter = nxt
        # Force the rebuild: `structure_sig` is deliberately about the DATA, and the data did
        # not change — the view did. Clearing the signature is how the view says so without
        # teaching the signature about screen state it has no business knowing.
        self.sig = None
        self.apply(self.data)
        self.notify("4ME: %s" % (nxt or "all categories"))

    def action_legend(self):
        self.query_one("#legend").toggle_class("-show")

    # ── layout ───────────────────────────────────────────────────────────────────────────
    def _rows(self):
        """The agents on screen — lanes and their subagents, in the order they are drawn."""
        return self._display_rows()

    def _avail(self, avail=None):
        """Rows the two panels share. 0 before the first layout pass — there is no
        measurement then, and a guess would clamp the panel against a size the screen never
        had."""
        if avail is not None:
            return avail
        try:
            return self.query_one("#panels").size.height
        except Exception:
            return 0

    def _width(self):
        """Columns a panel is wide, OUTER — border, padding, scrollbar and all.

        Deliberately the outer width and not the content width. The content width shrinks by
        two the moment a scrollbar appears, and a scrollbar appears when the fit is short —
        so sizing off it would let the fit change the width the fit was computed at. The
        outer width is set by the container and is the same number whether the list overflows
        or not; text_width() takes the chrome off it with fixed reservations.

        0 before the first layout pass, which the counting reads as "no width known".
        """
        try:
            return self.query_one("#lanes").outer_size.width
        except Exception:
            return 0

    def _ceiling(self, want, avail=None):
        """The tallest the FLEET panel may be: the shared space less 4ME's floor.

        Before the first layout pass there is no measurement to clamp against, so nothing is
        clamped — the first snapshot fits again the moment there is one.
        """
        avail = self._avail(avail)
        return max(PANEL_MIN, avail - FLEET_MIN) if avail else want

    def _base_height(self, avail=None):
        """The FLEET panel's height before the user's nudge — what the two `=` states differ in.

        In `agents` mode it is the agent list's own height: the sizing the view opens with,
        and the one every other caller has always used.

        In `4ME` mode it is whatever is left once 4ME has the rows ITS list needs — but never
        MORE than the agents' own fit, so a short 4ME list cannot inflate the agent panel into
        a column of dead space. The two modes therefore COINCIDE whenever 4ME already fits,
        which is the common case; `=` says as much rather than leaving a press that changes
        nothing to look like a key that does nothing.
        """
        ctx = self.data.get("ctx") or {}
        width = self._width()
        natural = fit_height(self._rows(), width, ctx)
        if self.fit_mode != "4ME":
            return natural
        avail = self._avail(avail)
        if not avail:
            return natural
        return min(natural, avail - asks_fit_height(self._fleet(), width, ctx))

    def _fit_lanes(self, avail=None):
        """Size the FLEET panel to the agents in it, and give 4ME whatever is left.

        WHY NOT A FIXED SPLIT. Half the screen is the wrong height for every fleet except the
        one it was chosen for: two lanes left a panel of blank rows above a cramped to-do
        list, and six lanes hid the last two behind a scrollbar in a panel that had room to
        spare below it. The list is a handful of cards, so it can simply be as tall as it is.

        Called when the roster changes shape, when the terminal resizes, when the user nudges
        the boundary, when `=` switches which list is being fitted — and, on a refresh tick,
        only when the cards have come to want a different number of rows than the last fit
        gave them (_refit_if_taller), which a status growing past its column now can. A tick
        that changes no height lays nothing out, which is why a fleet that is merely working
        still does not move every five seconds.

        ONE SIZING PATH, TWO BASES. `=` does not size anything itself: it moves `fit_mode`,
        and _base_height answers differently, so a resize or a lane arriving re-derives the
        chosen fit for free instead of dropping back to the other one.

        Returns the height it set, or None when there was nothing to size — that number is
        what `=` reports on, and recomputing it afterwards would be a second answer to a
        question already settled here.
        """
        if self.full:
            return None            # a fullscreened panel owns the whole box; leave it alone
        try:
            lanes, fleet = self.query_one("#lanes"), self.query_one("#fleet")
        except Exception:
            return None            # a resize can land before compose does; on_mount fits again
        want = self._base_height(avail) + self.nudge
        height = max(PANEL_MIN, min(want, self._ceiling(want, avail)))
        # What the cards ASKED for, kept beside the height actually written: the tick
        # compares against it to decide whether anything needs laying out again, and the
        # clamped height would answer a different question — a panel already at the ceiling
        # stays there while its content keeps growing.
        self._fitted_want = want
        lanes.styles.height = height
        fleet.styles.height = "1fr"
        return height

    def _refit_if_taller(self):
        """Re-fit when the rows the cards need has changed, and only then.

        The cheap half of a refit is the arithmetic; the expensive half is writing a height
        onto a widget, which lays the panel out again. So the height is computed on every
        tick — six cards' worth of wrapping — and written only when it differs from the last
        one written. A fleet whose statuses are not changing length pays nothing visible.
        """
        want = self._base_height() + self.nudge
        if want != self._fitted_want:
            self._fit_lanes()

    def _bump(self, d):
        """Move the boundary by a row, and remember it as an OFFSET from the fit — so a lane
        that appears later still grows the panel by its own height instead of snapping back
        to the size the user picked for a smaller fleet.

        The offset is clamped to what the screen can actually honour, so a run of `+` is not
        banked: one `-` gives a row back, rather than the first dozen presses doing nothing.
        """
        if self.full:
            return                 # no boundary to move, and a nudge nobody can see is worse
        # From whichever fit is in force, not always the agents' one: in 4ME mode the nudge
        # has to be an offset from where `=` put the boundary, or the first press would jump.
        base = self._base_height()
        hi = self._ceiling(base + self.nudge + d) - base
        self.nudge = max(PANEL_MIN - base, min(hi, self.nudge + d))
        self._fit_lanes()

    def action_autofit(self):
        """`=` — grow one panel until its whole list is visible, alternating between them.

        THE CYCLE IS DERIVED FROM THE LAYOUT, not counted blindly. A press that lands while
        the boundary has been nudged goes back to the agent fit first, because "put it back
        how it opened" is what the key is for and a nudged boundary is neither of the two
        states. Only a press from an untouched agent fit hands the rows to 4ME. Blind
        alternation would spend the first press doing nothing whenever the view was already
        fitted, which is most of the time.

        IT ALWAYS SAYS WHAT IT MANAGED. When a list is taller than the terminal the panel
        stops at the other one's floor and stays scrollable — silence there is
        indistinguishable from a successful fit, which is the one way this key could mislead.
        An empty 4ME is the same case in miniature: nothing moves, and the message is the only
        thing separating that from a key that did not fire.
        """
        if self._overlay_owns_keys():
            return
        if self.full:
            self.action_fullscreen()   # a maximised panel has no boundary to size
        self.fit_mode = "agents" if (self.nudge or self.fit_mode == "4ME") else "4ME"
        self.nudge = 0
        self.notify(self._fit_note(self._fit_lanes()))

    def _fit_note(self, lanes_h):
        """How much of the fitted list actually landed on screen.

        Counted off the same row arithmetic as the fit itself rather than measured, for the
        reason the constants block gives: a widget's real height exists only after a layout
        pass, and this runs before one. The SAME arithmetic includes the wrapping — a note
        counting unwrapped rows against a wrapped fit would go back to promising rows that
        are not on screen, which is the failure this note exists to prevent.
        """
        avail = self._avail()
        if lanes_h is None or not avail:
            return "fit %s" % self.fit_mode
        ctx = self.data.get("ctx") or {}
        width = self._width()
        # CLIPPED_RESERVE, not the fit's zero: this line is answered for the case where the
        # list did NOT fit, and there the scrollbar is on screen and the cursor's gutter is
        # on one of the rows. Counting them makes the answer conservative in the one
        # direction that matters — it may say a row scrolls that in fact just fits, and will
        # never say a row is visible that is not.
        if self.fit_mode == "4ME":
            heights = [ask_rows(i, raw, width, ctx, CLIPPED_RESERVE)
                       for i, raw in enumerate(self._fleet(), 1)]
            room = avail - lanes_h - PANEL_BORDER
        else:
            heights = [lane_rows(r, width, ctx, CLIPPED_RESERVE) for r in self._rows()]
            room = lanes_h - PANEL_BORDER
        return fit_note(self.fit_mode, visible_items(heights, room), len(heights))

    def action_cycle_sort(self):
        """Step the 4ME order: latest → earliest → goal → latest.

        Announced with a toast as well as in the title, because the title is a word the eye
        has already learned to skip and the reorder itself is easy to read as a redraw.
        """
        if self._overlay_owns_keys():
            return
        self.ask_sort = ASK_SORTS[(ASK_SORTS.index(self.ask_sort) + 1) % len(ASK_SORTS)]
        # Same forced rebuild as the category cycle, and for the same reason: `structure_sig`
        # is deliberately about the DATA, and the data did not change — the view did.
        self.sig = None
        self.apply(self.data)
        self.notify("4ME order: %s first" % self.ask_sort)

    def action_grow(self):
        """Grow the FOCUSED panel — the same key does opposite things in the two panels,
        which is right: the reader is asking for more of what they are looking at."""
        if self._overlay_owns_keys():
            return
        self._bump(1 if self._focused_list().id == "lanes" else -1)

    def action_shrink(self):
        if self._overlay_owns_keys():
            return
        self._bump(-1 if self._focused_list().id == "lanes" else 1)

    def action_fullscreen(self):
        """Toggle: hide the other panel outright.

        Hiding rather than Screen.maximize() — maximize moves the widget into a different
        container, which drops focus and the cursor with it. Display-toggling leaves the
        widget exactly where it is, so `f` twice is a genuine round trip.
        """
        if self._overlay_owns_keys():
            return
        target = self._focused_list().id
        if self.full:
            for wid in ("#lanes", "#fleet"):
                self.query_one(wid).display = True
            self.full = None
            self._fit_lanes()
        else:
            other = "#fleet" if target == "lanes" else "#lanes"
            self.query_one(other).display = False
            # Explicitly, because the FLEET panel's height is a row count now: hiding its
            # neighbour would otherwise leave it fitted to its content with dead space below.
            self.query_one("#" + target).styles.height = "1fr"
            self.full = target

    def close_top_overlay(self):
        """Close the innermost open overlay; True when something closed.

        THE ORDER IS THE FACT, which is why it lives in one place: escape and enter both
        climb this ladder, and a dialog that escape closes second while enter closes it first
        is two different screens. The in-progress EDIT is deliberately not here — enter
        inside the editor submits it, so only escape may abandon it.
        """
        legend = self.query_one("#legend")
        if self.detail is not None:
            self.close_detail()
        elif self.ask is not None:
            self.close_ask()
        elif legend.has_class("-show"):
            legend.remove_class("-show")
        else:
            return False
        return True

    def action_unfullscreen(self):
        """Escape closes ONE thing, innermost first. Closing two at once would make escape
        unusable for either: an edit abandoned along with the panel it was in is a keypress
        the user cannot undo by pressing it again."""
        if self.editing is not None:
            self.edit_cancel()
        elif self.marking is not None:
            self._mark_close()
        elif not self.close_top_overlay() and self.full:
            self.action_fullscreen()

    def _mark_target(self):
        """Resolve (path, raw) for whichever row `t`/`p` would act on, or (None, None).

        SHARED BY `t` (mark_done) AND `p` (approve_review) — both start by finding the same
        row, and a second copy of this resolution is how the two would quietly diverge on
        which row "the highlighted one" means. Notifies and returns (None, None) on every
        refusal, so a caller just checks `raw is None` rather than re-deciding what to tell
        the user.

        The lane dialog swallows both keys before this is ever called: nothing under it is a
        4ME row, and its own Input owns the keyboard. A second press while the note field is
        up is a no-op, not a re-open — re-opening would silently discard a half-typed note.
        """
        if self.detail is not None or self.marking is not None:
            return None, None
        if self.ask is not None:
            path, raw = self.data.get("fleet_path") or "", self.ask["raw"]
        else:
            w = self._focused_list()
            item = w.highlighted_child
            if isinstance(item, Ask):
                path, raw = item.path, item.raw
            elif isinstance(item, Lane):
                asks = item.row.get("raw_asks") or []
                if not asks:
                    self.notify("nothing to mark on this lane", severity="warning")
                    return None, None
                path, raw = item.row["ask_path"], asks[0]
            else:
                return None, None
        if not path:
            self.notify("no file behind this row", severity="warning")
            return None, None
        return path, raw

    def action_approve_review(self):
        """`p` — one keystroke for the overwhelmingly common case: approving a staged review.

        John, 2026-08-20: typing "approve" into the note field every time was the friction —
        `t` still exists for everything else (a real note, or ticking a row that isn't a
        review). This is `t` with the note pre-decided, not a new write path: it sets
        `self.marking` exactly as `t` does and hands off to the SAME `mark_submit`, so a
        `p` press is byte-for-byte what typing "approve" and pressing enter produces —
        including the derived-row flag retirement, the trailer-safety check, and the
        `.cleared` log entry.

        SCOPED TO REVIEW ROWS ONLY. A `p` on an ordinary ask would silently invent an
        "approve" that was never asked for — this key answers one specific, recurring
        question ("is the staged diff good"), not a generic yes to whatever the row says.
        """
        path, raw = self._mark_target()
        if raw is None:
            return
        marks = dict(ask_detail(raw)["trailers"])
        if not marks.get("review"):
            self.notify("not a staged review — use t to mark this done", severity="warning")
            return
        self.marking = (path, raw, self._focused_list())
        self.mark_submit("approved")

    def action_close_merged(self):
        """`M` — one keystroke for the other recurring case: a `ship:` row's PR landed.

        Same shape as `p`/approve_review, same reason: typing "merged" every time a PR you
        already tracked on the list actually merges is friction for an answer that is always
        the same word. Goes through the identical `mark_submit` write path as `t`/`p` — this
        is that flow with the note pre-decided, not a new one.

        SCOPED TO PR-TRACKING ROWS. The ticket trailer distinguishes them already —
        `_ASK_TICKET_PR` is the same pattern `ask_ticket_url` uses to tell a PR number
        (`#186`) from a tracker id (`SRV-24`) for linking. A row with no ticket, or a
        tracker-id ticket, is not what `M` answers; `t` still handles those.
        """
        path, raw = self._mark_target()
        if raw is None:
            return
        marks = dict(ask_detail(raw)["trailers"])
        tid = marks.get("ticket", "")
        if not _ASK_TICKET_PR.match(tid):
            self.notify("not a PR row — use t to mark this done", severity="warning")
            return
        self.marking = (path, raw, self._focused_list())
        self.mark_submit("merged")

    def action_mark_done(self):
        """`t` — tick the row off WITHOUT deleting it, with an optional note for the lead.

        THE OTHER HALF OF `x` (John, 2026-08-19): "I think those reviews from ott and woo were
        approved, right? Perhaps we should have a mark completed you can check when you update
        the list. Perhaps I could leave a note when I mark completed or clear for you so I can
        have more control over the 4m list." Until now the only way to signal "I have handled
        this" was to delete the row — which is also what a mis-keyed `x` looks like, and which
        throws away the one thing the lead needed to read: that it was handled, and with what
        answer.

        IT WORKS WITH THE 4ME OVERLAY OPEN, unlike `x`, and the difference is not an
        inconsistency. `x` must be swallowed there because it DELETES the very ask the dialog
        is showing, out of a list the dialog is covering; `t` rewrites that ask in place and
        the dialog repaints to show the tick. Marking what you are reading is the case, not
        the hazard.
        """
        path, raw = self._mark_target()
        if raw is None:
            return
        # A DERIVED ROW IS NOT IN THE FILE, so `t` on one does something different: it
        # retires the FLAG the row is synthesised from, and writes the ticked row into the
        # file itself. `x` still refuses these — deleting a computed row is meaningless,
        # it is back on the next tick — but a review the engine no longer knows about had no
        # way off the panel at all, which is what John hit.
        #
        # IT MUST NAME A LANE. Every derived row today carries `[review:<lane>]`, but one
        # that did not would leave nothing to retire, and ticking it would be the same empty
        # gesture `x` is refused for.
        marks = dict(ask_detail(raw)["trailers"])
        if marks.get("derived") and not marks.get("review"):
            self.notify("this row tracks live state and names no lane to clear",
                        severity="warning")
            return
        self.marking = (path, raw, self._focused_list())
        inp = self.query_one("#note-input", Input)
        inp.value = ""
        inp.placeholder = ("why you are clearing this — REQUIRED" if marks.get("derived")
                           else "a note for the lead — optional")
        inp.add_class("-show")
        inp.focus()
        msg = self.query_one("#note-msg", Static)
        # `esc`, not rich's `escape`: this is prose the user wrote and every bracket in it is
        # a literal. See linkify for the crash that distinction prevents.
        # THE DERIVED CASE SAYS WHAT IT IS ABOUT TO DO, because it is not what the other
        # rows do: it retires a flag file in someone else's lane. A key that quietly reaches
        # outside the panel is one the user cannot audit from the panel.
        what = esc(clip(ask_short(ask_detail(raw)), 48))
        msg.update(("[dim]force-clearing [b]%s[/b] · a note is REQUIRED — it is the only "
                    "record of why · esc cancels[/]" % what) if marks.get("derived")
                   else ("[dim]marking [b]%s[/b] done · enter writes it, an empty note is "
                         "fine · esc cancels[/]" % what))
        msg.add_class("-show")

    def _mark_close(self):
        """Put the field away and give the keyboard back to the list `t` was pressed on."""
        back = self.marking[2] if self.marking else None
        self.marking = None
        inp = self.query_one("#note-input", Input)
        inp.remove_class("-show")
        inp.value = ""
        msg = self.query_one("#note-msg", Static)
        msg.update("")
        msg.remove_class("-show")
        if back is not None:
            back.focus()

    def mark_submit(self, value):
        """Write the tick — and REFUSE a note the reader could not get back out.

        THE NOTE IS A TRAILER, AND TRAILERS ARE EATEN RIGHT TO LEFT. So an unmatched bracket
        typed into this field does not merely lose the note: it stops the parse at the tail
        and takes `added`, `short`, `ticket` and `derived` down with it — the row loses its
        age, its sort slot, its badges and its short form at once, and dumps raw trailer text
        into the visible list. That is a lot of damage for one character in a free-text field.

        THE CHECK IS THE READER'S OWN, not a guess about which characters are dangerous. The
        line is built, parsed back, and required to carry exactly the trailers it had plus
        this one — so balanced brackets (`see [SRV-1]`, which `ask_trailers` handles) are
        allowed through, and only what actually breaks is refused. A rejected note keeps the
        field open with the text still in it, exactly as a rejected knob value does.
        """
        if not self.marking:
            return
        path, raw, _ = self.marking
        note = " ".join((value or "").split())
        head = raw.split("\n", 1)[0]
        marks = dict(ask_detail(head)["trailers"])
        derived = bool(marks.get("derived"))
        # A NOTE IS MANDATORY ON A DERIVED ROW and optional everywhere else, because the two
        # ticks record different things. An ordinary row keeps its own history — the question
        # is still there, ticked. A derived one is a signal the system raised and a human is
        # overruling; when the flag is gone the note is the only surviving answer to "why is
        # this not on the list any more", and an empty one makes the clear indistinguishable
        # from the staleness it is clearing.
        if derived and not note:
            self.query_one("#note-msg", Static).update(
                "[red]a note is required to force-clear a staged review[/] — it is the only "
                "record of why this was dismissed. esc cancels.")
            return
        # `derived` and `review` COME OFF the materialised line. `[derived:]` is exactly what
        # makes `x` refuse a row, so a ticked line that kept it would be one the lead could
        # never sweep — the opposite of what ticking is for — and `[review:]` drives the 🔍
        # badge onto a Monocle review this keypress has just retired.
        base = _DERIVED_TRAILERS.sub("", head).rstrip() if derived else head
        want = ask_detail(base)["trailers"] + ([("note", note)] if note else [])
        if ask_detail(ask_mark_done(base, note))["trailers"] != want:
            self.query_one("#note-msg", Static).update(
                "[red]that note breaks the row's own metadata[/] — an unmatched bracket on "
                "the tail stops every trailer being read. Try it without one.")
            return
        if derived:
            # THE FLAG FIRST. If retiring it fails the row must stay exactly as it is —
            # writing the ticked line anyway would leave the panel showing a cleared item
            # beside the live one it failed to clear.
            why = retire_staged_review(
                os.path.join(marks.get("review", ""), ".claude", REVIEW_FILE), note)
            if why:
                self.query_one("#note-msg", Static).update("[red]%s[/]" % esc(why))
                return
            written = ask_mark_done(base, note)
            if not _append_ask_line(path, written):
                written = ""
        else:
            written = _mark_line_done(path, raw, note)
        self._mark_close()
        if not written:
            self.notify("that ask is no longer in the file", severity="warning")
            self.load()
            return
        # FOLLOW THE EDIT, the way show_ask follows the lead's. `_reaim_ask` re-finds the open
        # ask by its exact line first, and that line just changed — a TICKETLESS ask would
        # otherwise fall through to the kind check, whose kind the tick has also just changed,
        # and the dialog would report the row the user is reading as gone.
        if self.ask is not None:
            self.ask["raw"] = "\n".join([written] + raw.split("\n", 1)[1:])
        self.notify("marked done · %s" % ("note: " + clip(note, 40) if note else "no note"))
        self.load()

    def action_undo(self):
        if not self.undo:
            self.notify("nothing to undo", severity="warning")
            return
        path, raw = self.undo
        _restore_line(path, raw)
        self.undo = None
        self.notify("restored")
        self.load()


if __name__ == "__main__":
    try:
        every = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
    except ValueError:
        every = 5.0
    set_pane_title()
    FleetTUI(interval=every).run()
