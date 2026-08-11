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

EVERY ROW CARRIES ONE FACT NOBODY MAINTAINS. The status line is written by the lead, so it is
only ever as current as the lead's memory — every lane's froze for four days once, beside
numbers that kept moving. So the row also shows when that agent last wrote its transcript
(`active 2m ago`), which needs nobody: the text says WHAT the lane is doing and the mtime
says WHETHER THAT IS STILL CURRENT.

WHAT IT WRITES, and nothing else. Deletions from the lead's own ask files (ticking an item
off, undoable in-session), and the per-lane tuning knobs in a lane's GITIGNORED
`.claude/workflow.config.local` — never the committed `workflow.config`, which belongs to the
project rather than to this machine. Every value it can write comes from a fixed vocabulary,
because agent-tune.sh later types those strings into a live agent's pane.

ENTER ON AN AGENT ROW opens the detail overlay: that lane's branch and its distance from the
base (local and origin, unfetched), what its session is running right now, and the config
knobs, editable in place. The overlay is the only part of this view that shells out, and it
does so on a worker thread — the five-second tick must never grow a subprocess.
"""

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# One definition of the 60-char cap and of the ask vocabulary, shared with the table renderer
# so the two views cannot type the same item differently.
from _agent_facts import (ASK, ASK_KINDS, ask_kind, branch_for, clip,  # noqa: E402
                          fmt_age, fmt_ago, refresh_open_prs)

from rich.markup import escape  # noqa: E402
from textual.app import App, ComposeResult  # noqa: E402
from textual.binding import Binding  # noqa: E402
from textual.containers import Vertical  # noqa: E402
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
    return [ln.rstrip() for ln in body.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]


def _drop_line(path, raw):
    """Remove the first exact occurrence of `raw`. Returns True when the file changed.

    Rewrites rather than truncates: another line may have been added since the snapshot, and
    a to-do list that loses an entry nobody ticked off is worse than one that fails to tick.
    """
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        return False
    for i, ln in enumerate(lines):
        if ln.rstrip() == raw:
            del lines[i]
            with open(path, "w") as f:
                f.write("\n".join(lines) + ("\n" if lines else ""))
            return True
    return False


_TICKET = re.compile(r"\b([A-Z]{2,5}-\d+)\b")
_PR = re.compile(r"#(\d+)\b")


def linkify(text, ctx):
    """Make every ticket id and PR number in a string clickable, wherever it appears.

    The table renderer only ever linked the ▸ column, so an id mentioned in a status or an ask
    was dead text — and those are where most of them are. Textual emits OSC-8 for `[link=…]`,
    so this is the same mechanism the table used, applied to the whole line.

    Call this AFTER escape(): escaping turns `[` into `\\[`, and the markup inserted here has
    to survive that. Neither an id nor a `#123` contains a bracket, so the order is safe.

    A base URL is only ever LEARNED, never assembled from a guess about the workspace — a
    hyperlink that 404s is worse than plain text, because it looks authoritative.
    """
    base, repo = ctx.get("linear_base"), ctx.get("repo")
    if base:
        text = _TICKET.sub(
            lambda m: "[link='%s']%s[/link]" % (
                linear_uri("%s/issue/%s" % (base, m.group(1))), m.group(1)), text)
    if repo:
        text = _PR.sub(
            lambda m: "[link='%s/pull/%s']#%s[/link]" % (repo, m.group(1), m.group(1)), text)
    return text


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
    return {
        "name": name,
        "label": row.get("label") or "",
        "kind": row.get("kind") or "lane",
        "path": path,
        "state": row.get("state") or "?",
        "git": git_state(path, base) if path else None,
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
    try:
        with open(path) as f:
            body = f.read()
    except OSError:
        body = ""
    if body and not body.endswith("\n"):
        body += "\n"
    with open(path, "w") as f:
        f.write(body + raw + "\n")


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

    for r in lanes:
        r["ask_path"] = os.path.join(r["path"], ".claude", "needs-input")
        r["raw_asks"] = _ask_lines(r["ask_path"])

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
        "fleet": _ask_lines(fleet_path) if fleet_path else [],
        "fleet_path": fleet_path,
        "ctx": {"linear_base": linear_base,
                "repo": _repo_url(lanes[0]["path"]) if lanes else ""},
        "error": "",
    }


# ── how much room the agent list needs, in rows ──────────────────────────────────────────
# Lane.compose draws two lines — the head and the status — plus one per ask, and the ListItem
# rule leaves a blank row under each item.
#
# COUNTED, NOT MEASURED. A widget's real height only exists after a layout pass, so sizing
# from the measurement means drawing the panel at the wrong height once per change to learn
# the right one — and, once the panel is clamped, a scrollbar narrowing the content can change
# the measurement that set the width, which is a loop. The price of counting is a terminal
# narrow enough to wrap a status: that row is not counted, and the panel scrolls, exactly as it
# did at every size before.
ITEM_ROWS = 3
ASK_ROWS = 2          # a 4ME row is one line, plus the blank the same ListItem rule leaves
PANEL_BORDER = 2      # the round border takes a row off the top and one off the bottom
PANEL_MIN = 3         # border + a row: a fleet with nothing in it still shows a titled box
FLEET_MIN = 4         # rows 4ME keeps however many lanes there are — its border + one ask


def fit_height(rows):
    """Rows the FLEET panel needs to show every agent in `rows` without scrolling."""
    return PANEL_BORDER + sum(ITEM_ROWS + len(r.get("raw_asks") or []) for r in rows)


def asks_fit_height(n):
    """Rows the 4ME panel needs to show `n` items without scrolling.

    Never below FLEET_MIN, which is the same floor every other path respects: an empty list
    is still a titled box, and a panel that vanished would read as a broken view rather than
    an empty one.
    """
    return max(FLEET_MIN, PANEL_BORDER + n * ASK_ROWS)


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


class Lane(ListItem):
    """One lane: the identity row, its status, then its asks. Selectable as a unit."""

    def __init__(self, row, ctx=None):
        super().__init__()
        self.row = row
        self.ctx = ctx or {}

    def pr_markup(self):
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
        prs = self.row.get("open_prs") or []
        if not prs:
            return ""
        out = []
        for num, url, draft in prs:
            label = "#%s%s" % (num, "…" if draft else "")
            body = "[link='%s']%s[/link]" % (url, label) if url else label
            out.append("[%s]%s[/]" % ("dim" if draft else "b green", body))
        return "  " + " ".join(out)

    def head_markup(self):
        r = self.row
        state = r.get("state", "?")
        icon = LANE_ASK if r.get("raw_asks") else STATE_ICON.get(state, "?")
        icolor = "b yellow" if r.get("raw_asks") else STATE_STYLE.get(state, "white")
        pct = r.get("context_pct")
        # OVER 100% IS AN ADMISSION, NOT A NUMBER. A gauge read 216% for a lane on a 1M-token
        # model because the denominator defaulted to 200k. That denominator is fixed, but the
        # visible absurdity was luck: the same class of error reads a believable 80% at half
        # the occupancy. Anything out of range is rendered as out of range, so the next wrong
        # denominator is caught by the panel rather than by a reader who happened to look.
        if pct is None or state == "down":
            pcs, pcolor = "—", "dim"
        elif pct > 100:
            pcs, pcolor = ">100%", "b red"
        else:
            pcs = "%d%%" % pct
            pcolor = "red" if pct >= 90 else "yellow" if pct >= 80 else "dim"
        up = "—" if state == "down" else (r.get("uptime") or "—")
        # The recorded URL wins over the learned base — it is what the tracker actually
        # returned, slug and all. linkify() is the fallback for ids that have none.
        links = r.get("issue_links") or []
        ids = " ".join("[link='%s']%s[/link]" % (linear_uri(u), i) if u
                       else linkify(i, self.ctx)
                       for i, u in links) or linkify(escape(r.get("issue") or "—"), self.ctx)
        # ≠ MEANS "THE BRANCH AND THE FILE DISAGREE, AND THIS IS THE BRANCH'S ANSWER". The id
        # shown is machine truth either way; the marker is there because the other source has
        # gone stale and someone should fix it — silently preferring the branch would hide the
        # one fact the reader can act on.
        if r.get("ticket_mismatch"):
            ids = "[b yellow]≠[/]" + ids
        return (
            f"[{icolor}]{icon}[/] "
            f"[b]{escape(r.get('label') or ''):<4}[/]"
            f"[dim]{escape(r['name']):<11}[/]"
            f"[{STATE_STYLE.get(state, 'white')}]{state:<7}[/]"
            f"[{pcolor}]{pcs:>5}[/]  "
            f"[dim]{up:>6}[/]   "
            f"[cyan]{ids}[/]"
            f"{self.pr_markup()}"
        )

    def compose(self):
        yield Static(self.head_markup(), classes="lane-head")
        yield Static(self.status_markup(), classes="lane-status")
        for raw in self.row.get("raw_asks") or []:
            icon, text = ask_kind(raw)
            yield Static(f"{icon} {linkify(escape(clip(text)), self.ctx)}",
                         classes="lane-ask")

    def status_markup(self):
        """The lane's status, WEARING ITS AGE once the line is too old to mean "now", and the
        agent's own last sign of life beside it.

        This is the one line on the row that nothing refreshes — a human writes it — so it is
        the one line that can freeze while every number beside it keeps moving. That is what
        made it dangerous rather than merely stale: linkify turns any `#N` in it into a live
        hyperlink, so a four-day-old "PR #130 open; awaiting your merge" rendered exactly like
        PR data fetched a second ago, beside a correct uptime and a correct context%.

        TWO CLOCKS, BECAUSE THEY ANSWER DIFFERENT QUESTIONS. `(4d old)` is when the LEAD last
        wrote this claim; `active 2m ago` is when the AGENT last did anything, taken from the
        mtime of the transcript it stamps by working — nobody maintains it, which is exactly
        why it is trustworthy in a way the status text is not. So the text says WHAT the lane
        is doing and the mtime says WHETHER THAT IS STILL CURRENT, and neither substitutes for
        the other: a busy lane can wear a status from Friday, and a status written this minute
        can describe a lane that died an hour ago.

        Both suffixes are dim and sit OUTSIDE the italic: they are facts about the line, not
        part of the claim, and must not read as something the lead wrote. The activity suffix
        shows even with no status at all — that is the row where it is the ONLY thing known.
        """
        status = self.row.get("status") or ""
        age = fmt_age(self.row.get("status_age"))
        ago = fmt_ago(self.row.get("last_active"))
        head = (f"[i]{linkify(escape(status), self.ctx)}[/]" if status
                else "[dim i]— no status —[/]")
        if status and age:
            head += f" [dim]({escape(age)} old)[/]"
        if ago:
            head += f" [dim]· active {escape(ago)} ago[/]"
        return head

    def refresh_volatile(self, row):
        """Update everything that is CONFINED TO A LINE, in place — never a rebuild.

        Uptime, context%, the state word and its icon all live on the head line; the status
        lives on its own line. None of them changes the shape of this item, so none of them
        needs the list torn down. Folding them into the redraw signature is what produced the
        periodic full repaint: uptime moves every tick and `state` flips whenever any lane
        starts or finishes a turn, so on a working fleet the signature was rarely stable for
        two consecutive refreshes.

        **Each Static is written only when its markup actually differs.** `Static.update()`
        repaints unconditionally, so calling it every five seconds with an identical string is
        itself a visible flicker — the cheap equality check is the difference between a quiet
        panel and one that twitches.
        """
        self.row = row
        for sel, markup in ((".lane-head", self.head_markup()),
                            (".lane-status", self.status_markup())):
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
        icon, text = ask_kind(self.raw)
        yield Static("[dim]%2d[/]  %s %s" % (self.n, icon,
                                             linkify(escape(clip(text)), self.ctx)))


DETAIL_HINT = ("[dim]j/k move · enter edits the highlighted knob · a applies the live knobs "
               "to the running agent · o opens the ticket · esc closes[/]")


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


class Detail(Vertical):
    """The overlay Enter opens on an agent row: its git state, its live session, its config.

    A PANEL, LIKE THE LEGEND — not a screen. The fleet panel behind it stays live and keeps
    ticking, which is the point: the numbers you are about to act on and the fleet you are
    acting on are visible at once.
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
    Screen { background: $surface; layers: base overlay; }
    #head { padding: 0 1; height: 1; color: $text-muted; }

    /* A PANEL, NOT A TOAST. As a notification each `?` stacked another copy — press it three
       times, get three legends — because notifications queue by design and only expire on a
       timer. A legend is reference material you hold open while you read the screen behind
       it, so it toggles. */
    #legend {
        layer: overlay;
        display: none;
        margin: 2 6;
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
        margin: 1 3;
        padding: 1 2;
        height: auto;
        max-height: 100%;
        border: heavy $accent;
        background: $panel;
    }
    #detail.-show { display: block; }
    #detail-cfg { height: auto; max-height: 14; background: transparent; }
    #detail-cfg > ListItem { padding: 0; }
    #detail-input { display: none; margin: 0; }
    #detail-input.-show { display: block; }
    #detail-msg { height: auto; color: $text-muted; }

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
    .lane-status { padding-left: 4; color: $text; }
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
        Binding("u", "undo", "undo"),
        Binding("f", "fullscreen", "fullscreen"),
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
        Binding("j", "cursor_down", "", show=False),
        Binding("k", "cursor_up", "", show=False),
    ]

    def __init__(self, interval=5.0):
        super().__init__()
        self.interval = interval
        self.data = {"lanes": [], "subs": [], "fleet": [], "error": ""}
        self.sig = None            # last STRUCTURAL snapshot, to skip no-op rebuilds
        self.undo = None           # (path, raw) of the last cleared ask
        self.nudge = 0             # rows the user has added to the fit with + / -
        self.full = None           # id of the panel currently fullscreened, or None
        self.fit_mode = "agents"   # which list `=` is currently fitting: "agents" or "4ME"
        self.detail = None         # the open overlay's assembled data, or None
        self.editing = None        # the cfg entry currently being edited, or None

    def compose(self) -> ComposeResult:
        yield Static("", id="head")
        with Panels(id="panels"):
            yield ListView(id="lanes")
            yield ListView(id="fleet")
        yield Static(self.legend_markup(), id="legend")
        with Detail(id="detail"):
            yield Static("", id="detail-head")
            yield Static("", id="detail-git")
            yield ListView(id="detail-cfg")
            yield Input(id="detail-input")
            yield Static("", id="detail-msg")
        yield Footer()

    def on_mount(self):
        self.query_one("#lanes").border_title = "FLEET"
        self.query_one("#fleet").border_title = "4ME"
        self._fit_lanes()
        self.reload()
        self.set_interval(self.interval, self.reload)

    # ── data ─────────────────────────────────────────────────────────────────────────────
    def action_reload(self):
        self.reload()

    def reload(self):
        self.load()

    def load(self):
        self.run_worker(self._load, thread=True, exclusive=True, group="load")

    def _load(self):
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
        if path:
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

    def apply(self, data):
        """Rebuild only on a STRUCTURAL change; otherwise update the moving numbers in place.

        A ListView rebuilt on a timer throws away the cursor and repaints the screen, which
        makes the view unusable exactly while you are reading it.
        """
        sig = self.structure_sig(data)
        self.data = data
        self.update_head()

        rows = data["lanes"] + data["subs"]
        lanes = self.query_one("#lanes", ListView)
        if sig == self.sig:
            for item, r in zip(lanes.children, rows):
                if isinstance(item, Lane):
                    item.refresh_volatile(r)
            return
        self.sig = sig

        ctx = data.get("ctx") or {}
        keep = lanes.index
        lanes.clear()
        for r in rows:
            lanes.append(Lane(r, ctx))
        if keep is not None and 0 <= keep < len(rows):
            lanes.index = keep

        fleet = self.query_one("#fleet", ListView)
        keepf = fleet.index
        fleet.clear()
        for i, raw in enumerate(data["fleet"], 1):
            fleet.append(Ask(i, raw, data.get("fleet_path", ""), ctx))
        if keepf is not None and 0 <= keepf < len(data["fleet"]):
            fleet.index = keepf

        # The roster just changed shape — an agent came or went, or one grew an ask — which is
        # the only thing the panel's height depends on. Nothing here runs on the tick that
        # merely moves uptime, so the fit costs nothing on a steady fleet.
        self._fit_lanes()

    def update_head(self):
        d = self.data
        if d.get("error"):
            self.query_one("#head", Static).update(f"[red]{escape(d['error'])}[/]")
            return
        lanes = d["lanes"]
        live = sum(1 for r in lanes if r.get("state") != "down")
        busy = sum(1 for r in lanes + d["subs"] if r.get("state") == "busy")
        n_ask = sum(len(r.get("raw_asks") or []) for r in lanes) + len(d["fleet"])
        bits = [f"[b]{live}/{len(lanes)}[/] up", f"{busy} busy"]
        if d["subs"]:
            bits.append(f"{len(d['subs'])} sub")
        if n_ask:
            bits.append(f"[b yellow]{ASK} {n_ask} needs you[/]")
        # Written only when changed, for the same reason the lane lines are: an unconditional
        # update() on a timer repaints, and a repaint of the header is as visible as any other.
        head, markup = self.query_one("#head", Static), "  " + "  ·  ".join(bits)
        if str(head.content) != markup:
            head.update(markup)
        # 4ME, and the count is part of the label: the user refers to these rows by number
        # ("4me 1"), so the panel says how many numbers there are.
        title = f"4ME  ({len(d['fleet'])})"
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
        """
        return self.detail is not None

    def _focused_list(self):
        for wid in ("#lanes", "#fleet"):
            w = self.query_one(wid, ListView)
            if w.has_focus:
                return w
        return self.query_one("#lanes", ListView)

    def action_cursor_down(self):
        self._cursor_list().action_cursor_down()

    def action_cursor_up(self):
        self._cursor_list().action_cursor_up()

    def _cursor_list(self):
        """j/k move the list the reader is actually looking at — the overlay's, when it is up.
        Moving the hidden lane cursor instead would silently re-aim `x` and `enter`."""
        return (self.query_one("#detail-cfg", ListView) if self._overlay_owns_keys()
                else self._focused_list())

    # ── the agent detail overlay ─────────────────────────────────────────────────────────
    def action_enter(self):
        """One key, dispatched by what is on screen — never two meanings at once.

        Inside the overlay it edits the highlighted knob. On an agent row it opens the
        overlay. Anywhere else — the 4ME panel, chiefly — it keeps doing what it always did.
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

    def _enter(self, list_id, item):
        if list_id == "detail-cfg":
            self.edit_start()
            return
        if self.detail is not None:
            return                 # the overlay is up; the lists behind it are not the target
        if list_id == "lanes" and isinstance(item, Lane):
            self.open_detail(item.row)
            return
        self.action_open_ticket()

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
        self.query_one("#detail-git", Static).update("")
        self.query_one("#detail-msg", Static).update(DETAIL_HINT)
        self.query_one("#detail-cfg", ListView).clear()
        self.run_worker(lambda: self._load_detail(row), thread=True, group="detail")

    def _load_detail(self, row):
        data = detail_data(row)
        if not get_current_worker().is_cancelled:
            self.call_from_thread(self.show_detail, data)

    def show_detail(self, data, msg=None, keep=None):
        """Paint the overlay. `keep` restores the cursor across the reload a save triggers."""
        if self.detail is None:
            return                 # closed while the worker was still reading
        self.detail["data"] = data
        self.query_one("#detail-head", Static).update(self.detail_head_markup(data))
        self.query_one("#detail-git", Static).update(self.detail_git_markup(data))
        cfg = self.query_one("#detail-cfg", ListView)
        cfg.clear()
        for e in data["cfg"]:
            cfg.append(CfgRow(e))
        if keep is not None and 0 <= keep < len(data["cfg"]):
            cfg.index = keep
        if msg is not None:
            self.query_one("#detail-msg", Static).update(msg)
        cfg.focus()

    def detail_head_markup(self, data):
        live = data.get("live")
        # The live line is OMITTED, not filled with a guess, when the pane cannot be read —
        # a lane with no agent in it still has git state and config worth looking at.
        if live:
            line = ("  [dim]running[/] model=[b]%s[/] effort=[b]%s[/] [dim]%s[/]"
                    % (escape(live["model"]), escape(live["effort"]), live["pane"]))
        else:
            line = "  [dim]no live session in this lane — config and git only[/]"
        return ("[b]%s[/] [dim]%s[/]  [dim]%s[/]\n%s"
                % (escape(data["name"]), escape(data["label"]),
                   escape(data["path"]), line))

    def detail_git_markup(self, data):
        g = data.get("git")
        if not g:
            return "[dim]no path on this row — nothing to read[/]"

        def dist(c):
            return "[dim]—[/]" if c is None else "[green]↑%d[/] [yellow]↓%d[/]" % c
        dirty = ("[dim]clean[/]" if g["dirty"] == 0 else
                 "[yellow]%d dirty[/]" % g["dirty"] if g["dirty"] else "[dim]—[/]")
        return ("branch [b cyan]%s[/]   %s\n"
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
        """
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
        item = self.query_one("#lanes", ListView).highlighted_child
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
        if _drop_line(path, raw):
            self.undo = (path, raw)
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
            ("o", "open this lane's ticket"),
            ("a", "in the detail view: apply the live knobs to the running agent"),
        ))
        return ("[b]LANE[/]\n%s\n\n[b]ACTION ITEMS[/]\n%s\n\n[b]KEYS THE FOOTER CANNOT SHOW[/]"
                "\n%s\n\n[dim]? or esc to close[/]" % (states, kinds, keys))

    def action_legend(self):
        self.query_one("#legend").toggle_class("-show")

    # ── layout ───────────────────────────────────────────────────────────────────────────
    def _rows(self):
        """The agents on screen — lanes and their subagents, in the order they are drawn."""
        return self.data["lanes"] + self.data["subs"]

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
        natural = fit_height(self._rows())
        if self.fit_mode != "4ME":
            return natural
        avail = self._avail(avail)
        if not avail:
            return natural
        return min(natural, avail - asks_fit_height(len(self.data["fleet"])))

    def _fit_lanes(self, avail=None):
        """Size the FLEET panel to the agents in it, and give 4ME whatever is left.

        WHY NOT A FIXED SPLIT. Half the screen is the wrong height for every fleet except the
        one it was chosen for: two lanes left a panel of blank rows above a cramped to-do
        list, and six lanes hid the last two behind a scrollbar in a panel that had room to
        spare below it. The list is a handful of cards, so it can simply be as tall as it is.

        Called when the roster changes shape, when the terminal resizes, when the user nudges
        the boundary and when `=` switches which list is being fitted — never on the refresh
        tick, which is why a fleet that is merely working does not relayout every five seconds.

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
        lanes.styles.height = height
        fleet.styles.height = "1fr"
        return height

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
        pass, and this runs before one.
        """
        avail = self._avail()
        if lanes_h is None or not avail:
            return "fit %s" % self.fit_mode
        if self.fit_mode == "4ME":
            heights = [ASK_ROWS] * len(self.data["fleet"])
            room = avail - lanes_h - PANEL_BORDER
        else:
            heights = [ITEM_ROWS + len(r.get("raw_asks") or []) for r in self._rows()]
            room = lanes_h - PANEL_BORDER
        return fit_note(self.fit_mode, visible_items(heights, room), len(heights))

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

    def action_unfullscreen(self):
        """Escape closes ONE thing, innermost first. Closing two at once would make escape
        unusable for either: an edit abandoned along with the panel it was in is a keypress
        the user cannot undo by pressing it again."""
        legend = self.query_one("#legend")
        if self.editing is not None:
            self.edit_cancel()
        elif self.detail is not None:
            self.close_detail()
        elif legend.has_class("-show"):
            legend.remove_class("-show")
        elif self.full:
            self.action_fullscreen()

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
    FleetTUI(interval=every).run()
