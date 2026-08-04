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
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# One definition of the 60-char cap and of the ask vocabulary, shared with the table renderer
# so the two views cannot type the same item differently.
from _agent_facts import ASK, ASK_KINDS, ask_kind, clip  # noqa: E402

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
    return {
        "lanes": lanes,
        "subs": subs,
        "fleet": _ask_lines(fleet_path) if fleet_path else [],
        "fleet_path": fleet_path,
        "error": "",
    }


class Lane(ListItem):
    """One lane: the identity row, its status, then its asks. Selectable as a unit."""

    def __init__(self, row):
        super().__init__()
        self.row = row

    def head_markup(self):
        r = self.row
        state = r.get("state", "?")
        icon = LANE_ASK if r.get("raw_asks") else STATE_ICON.get(state, "?")
        icolor = "b yellow" if r.get("raw_asks") else STATE_STYLE.get(state, "white")
        pct = r.get("context_pct")
        pcs = "—" if pct is None or state == "down" else "%d%%" % pct
        pcolor = "red" if (pct or 0) >= 90 else "yellow" if (pct or 0) >= 80 else "dim"
        up = "—" if state == "down" else (r.get("uptime") or "—")
        ids = " ".join(i for i, _ in (r.get("issue_links") or [])) or (r.get("issue") or "—")
        return (
            f"[{icolor}]{icon}[/] "
            f"[b]{escape(r.get('label') or ''):<4}[/]"
            f"[dim]{escape(r['name']):<11}[/]"
            f"[{STATE_STYLE.get(state, 'white')}]{state:<7}[/]"
            f"[{pcolor}]{pcs:>5}[/]  "
            f"[dim]{up:>6}[/]   "
            f"[cyan]{escape(ids)}[/]"
        )

    def compose(self):
        yield Static(self.head_markup(), classes="lane-head")
        status = self.row.get("status") or ""
        yield Static(f"[i]{escape(status)}[/]" if status else "[dim i]— no status —[/]",
                     classes="lane-status")
        for raw in self.row.get("raw_asks") or []:
            icon, text = ask_kind(raw)
            yield Static(f"{icon} {escape(clip(text))}", classes="lane-ask")

    def refresh_volatile(self, row):
        """Update ONLY the fields that change every tick, in place.

        Uptime and context% move on every refresh, so folding them into the redraw signature
        made the signature differ every five seconds — which rebuilt both lists, every time,
        and is exactly the periodic blink the user saw. They live on the head line alone, so
        updating that one Static costs nothing and disturbs nothing.
        """
        self.row = row
        try:
            self.query_one(".lane-head", Static).update(self.head_markup())
        except Exception:
            pass


class Ask(ListItem):
    """One fleet-level to-do. Belongs to no lane, so it lives in its own panel."""

    def __init__(self, n, raw, path):
        super().__init__()
        self.n = n
        self.raw = raw
        self.path = path

    def compose(self):
        icon, text = ask_kind(self.raw)
        yield Static(f"[dim]{self.n:>2}[/]  {icon} {escape(clip(text))}")


class FleetTUI(App):
    CSS = """
    Screen { background: $surface; }
    #head { padding: 0 1; height: 1; color: $text-muted; }

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

    @staticmethod
    def structure_sig(data):
        """What a rebuild is actually FOR — everything except the per-tick counters.

        Deliberately excludes `uptime` and `context_pct`. They change on every single refresh,
        so including them made the signature differ every time and rebuilt both lists every
        five seconds: the periodic blink, and a cursor that could not be kept anywhere.
        """
        rows = [[r.get("name"), r.get("kind"), r.get("label"), r.get("state"),
                 r.get("status"), r.get("raw_asks"), r.get("issue_links")]
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

        keep = lanes.index
        lanes.clear()
        for r in rows:
            lanes.append(Lane(r))
        if keep is not None and 0 <= keep < len(rows):
            lanes.index = keep

        fleet = self.query_one("#fleet", ListView)
        keepf = fleet.index
        fleet.clear()
        for i, raw in enumerate(data["fleet"], 1):
            fleet.append(Ask(i, raw, data.get("fleet_path", "")))
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
        self.query_one("#head", Static).update("  " + "  ·  ".join(bits))
        self.query_one("#fleet").border_title = f"NEEDS YOU  ({len(d['fleet'])})"

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

    def action_legend(self):
        """EVERY glyph on screen, on demand. A marker whose meaning you have to ask about is
        not doing its job, and the lane-state shapes were exactly that."""
        kinds = "\n".join("  %s  %s" % (ASK_KINDS[k], d) for k, d in (
            ("review", "a diff / PR to read and green-light"),
            ("plan", "a plan awaiting its gate"),
            ("product", "a product or scoping call"),
            ("triage", "a tracker question — is this an issue, whose, what priority"),
            ("ship", "a merge / deploy / publish gate"),
            ("todo", "a general action item"),
        ))
        states = "\n".join("  %s  %s" % (i, d) for i, d in (
            (LANE_ASK, "this lane owes YOU an answer (replaces its state icon)"),
            ("●", "busy — tool calls landing now"),
            ("◔", "quiet — turn open, nothing happening"),
            ("○", "idle — between turns"),
            ("·", "down — lane exists, nothing running in it"),
        ))
        self.notify("LANE\n%s\n\nACTION ITEMS\n%s" % (states, kinds),
                    title="legend", timeout=20)

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
        if self.full:
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
