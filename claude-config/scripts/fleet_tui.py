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

THE TWO WRITES IT PERFORMS are deletions from the lead's own ask files, because ticking an
item off is the one interaction this view genuinely wants. Both are undoable in-session, and
neither ever creates a file.
"""

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# One definition of the 60-char cap and of the ask vocabulary, shared with the table renderer
# so the two views cannot type the same item differently.
from _agent_facts import ASK, ASK_KINDS, ask_kind, clip, refresh_open_prs  # noqa: E402

from rich.markup import escape  # noqa: E402
from textual.app import App, ComposeResult  # noqa: E402
from textual.binding import Binding  # noqa: E402
from textual.containers import Vertical  # noqa: E402
from textual.widgets import Footer, ListItem, ListView, Static  # noqa: E402
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


class Lane(ListItem):
    """One lane: the identity row, its status, then its asks. Selectable as a unit."""

    def __init__(self, row, ctx=None):
        super().__init__()
        self.row = row
        self.ctx = ctx or {}

    def pr_markup(self):
        """This lane's open PR, beside its ticket.

        They belong together because they answer one question jointly: what is this lane on,
        and has the work left the lane yet. A lane with an open PR is waiting on review rather
        than working, and nothing about the ticket alone says so.

        A draft is DIM, never green — the colour is the whole signal at a glance, and a draft
        rendered like a ready PR is the one way this field could mislead.

        The URL stays https: GitHub registers no custom scheme, unlike Linear's `linear://`.
        """
        pr = self.row.get("open_pr")
        if not pr:
            return ""
        num, url, draft = pr
        label = "PR#%s%s" % (num, " draft" if draft else "")
        body = "[link='%s']%s[/link]" % (url, label) if url else label
        return "  [%s]%s[/]" % ("dim" if draft else "b green", body)

    def head_markup(self):
        r = self.row
        state = r.get("state", "?")
        icon = LANE_ASK if r.get("raw_asks") else STATE_ICON.get(state, "?")
        icolor = "b yellow" if r.get("raw_asks") else STATE_STYLE.get(state, "white")
        pct = r.get("context_pct")
        pcs = "—" if pct is None or state == "down" else "%d%%" % pct
        pcolor = "red" if (pct or 0) >= 90 else "yellow" if (pct or 0) >= 80 else "dim"
        up = "—" if state == "down" else (r.get("uptime") or "—")
        # The recorded URL wins over the learned base — it is what the tracker actually
        # returned, slug and all. linkify() is the fallback for ids that have none.
        links = r.get("issue_links") or []
        ids = " ".join("[link='%s']%s[/link]" % (linear_uri(u), i) if u
                       else linkify(i, self.ctx)
                       for i, u in links) or linkify(escape(r.get("issue") or "—"), self.ctx)
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
        status = self.row.get("status") or ""
        return (f"[i]{linkify(escape(status), self.ctx)}[/]" if status
                else "[dim i]— no status —[/]")

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
    #lanes { height: 1fr; }
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
        Binding("enter", "open_ticket", "open ticket"),
        Binding("x", "clear_ask", "clear ask"),
        Binding("u", "undo", "undo"),
        Binding("f", "fullscreen", "fullscreen"),
        Binding("question_mark", "legend", "legend"),
        Binding("plus", "grow", "grow panel"),
        Binding("equals_sign", "grow", "", show=False),
        Binding("minus", "shrink", "shrink panel"),
        Binding("underscore", "shrink", "", show=False),
        Binding("escape", "unfullscreen", "", show=False),
        Binding("tab", "focus_next", "switch panel", show=False),
        Binding("j", "cursor_down", "", show=False),
        Binding("k", "cursor_up", "", show=False),
    ]

    # 1..9 — how many parts of the split the LANES panel takes; the fleet panel takes the
    # rest. Starts even, which is what the user asked for.
    SPLIT_MIN, SPLIT_MAX, SPLIT_TOTAL = 1, 9, 10

    def __init__(self, interval=5.0):
        super().__init__()
        self.interval = interval
        self.data = {"lanes": [], "subs": [], "fleet": [], "error": ""}
        self.sig = None            # last STRUCTURAL snapshot, to skip no-op rebuilds
        self.undo = None           # (path, raw) of the last cleared ask
        self.split = 5             # even
        self.full = None           # id of the panel currently fullscreened, or None

    def compose(self) -> ComposeResult:
        yield Static("", id="head")
        with Vertical():
            yield ListView(id="lanes")
            yield ListView(id="fleet")
        yield Static(self.legend_markup(), id="legend")
        yield Footer()

    def on_mount(self):
        self.query_one("#lanes").border_title = "FLEET"
        self.query_one("#fleet").border_title = "NEEDS YOU"
        self._apply_split()
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
        title = f"NEEDS YOU  ({len(d['fleet'])})"
        fleet = self.query_one("#fleet")
        if fleet.border_title != title:
            fleet.border_title = title

    # ── actions ──────────────────────────────────────────────────────────────────────────
    def _focused_list(self):
        for wid in ("#lanes", "#fleet"):
            w = self.query_one(wid, ListView)
            if w.has_focus:
                return w
        return self.query_one("#lanes", ListView)

    def action_cursor_down(self):
        self._focused_list().action_cursor_down()

    def action_cursor_up(self):
        self._focused_list().action_cursor_up()

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
        return ("[b]LANE[/]\n%s\n\n[b]ACTION ITEMS[/]\n%s\n\n[dim]? or esc to close[/]"
                % (states, kinds))

    def action_legend(self):
        self.query_one("#legend").toggle_class("-show")

    # ── layout ───────────────────────────────────────────────────────────────────────────
    def _apply_split(self):
        self.query_one("#lanes").styles.height = "%dfr" % self.split
        self.query_one("#fleet").styles.height = "%dfr" % (self.SPLIT_TOTAL - self.split)

    def action_grow(self):
        """Grow the FOCUSED panel — the same key does opposite things in the two panels,
        which is right: the reader is asking for more of what they are looking at."""
        d = 1 if self._focused_list().id == "lanes" else -1
        self.split = max(self.SPLIT_MIN, min(self.SPLIT_MAX, self.split + d))
        self._apply_split()

    def action_shrink(self):
        d = -1 if self._focused_list().id == "lanes" else 1
        self.split = max(self.SPLIT_MIN, min(self.SPLIT_MAX, self.split + d))
        self._apply_split()

    def action_fullscreen(self):
        """Toggle: hide the other panel outright.

        Hiding rather than Screen.maximize() — maximize moves the widget into a different
        container, which drops focus and the cursor with it. Display-toggling leaves the
        widget exactly where it is, so `f` twice is a genuine round trip.
        """
        target = self._focused_list().id
        if self.full:
            for wid in ("#lanes", "#fleet"):
                self.query_one(wid).display = True
            self.full = None
            self._apply_split()
        else:
            other = "#fleet" if target == "lanes" else "#lanes"
            self.query_one(other).display = False
            self.full = target

    def action_unfullscreen(self):
        """Escape closes ONE thing, and the legend is the innermost. Closing both at once
        would make escape unusable for either."""
        legend = self.query_one("#legend")
        if legend.has_class("-show"):
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
