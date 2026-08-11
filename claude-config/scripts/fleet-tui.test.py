# /// script
# requires-python = ">=3.11"
# dependencies = ["textual>=8,<9"]
# ///
"""Headless tests for fleet_tui.py.  Run: uv run ~/.claude/scripts/fleet-tui.test.py

Hermetic: the fleet snapshot is stubbed and the ask files live in a temp dir, so nothing here
reads or writes the live fleet.

What it locks in — each is a way this view could lie or lose work:
  - a lane renders its status and its asks, and the asks are TYPED by their kind token
  - a status the lead stopped maintaining wears its age instead of passing for the present,
    and the age is re-read from the FILE on every tick rather than fixed at startup
  - …and the row carries the OTHER clock beside it — when the agent itself was last active,
    from a transcript mtime nobody has to maintain — resolved the same way agent-fanout.sh
    resolves it, so the two surfaces cannot name different sessions for the same agent
  - `x` removes the ask from the FILE, not merely from the screen
  - `u` puts it back — an accidental keypress on the user's to-do list must be recoverable
  - an unchanged snapshot does not rebuild the lists, so the cursor survives a refresh
  - the FLEET panel is as tall as the agents in it — at startup, and again whenever one
    arrives or leaves — without ever pushing the 4ME panel off the screen
  - `=` cycles which of the two lists is shown WHOLE, and says what it actually managed to
    fit — the user refers to 4ME rows by number, so those rows are numbered too
  - enter on an agent row opens the detail overlay, and enter's OLD job still has a key
  - the overlay's git numbers are the right way round, and say "no ref" rather than 0/0
  - a config value shows which FILE it came from, and an edit lands only in the local one,
    preserving every unrelated line — including the comment that explained the value
  - a value outside the allowed vocabulary is refused before it is written, because these
    strings are later typed into a live agent's pane
  - the overlay tells the user whether an edit reached the running agent or waits for a spawn
  - …and it shows the agent's update IN FULL — the row's 60-char clip is the column's
    constraint, and the dialog goes back to the file rather than trying to widen bytes that
    no longer exist
  - the overlay RE-READS ITSELF on the same tick the panel does, so `r` and a resize reflow it
    instead of leaving a snapshot of the moment enter was pressed
  - nothing unlabelled sits where a number is expected: a tmux pane id (`%182`) beside
    `effort=xhigh` was read as a percentage, so every pane id wears its label and the one real
    percentage on that line is the LIST view's gauge, labelled `context`
"""

import asyncio
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_tui  # noqa: E402
# The threshold by NAME, not a literal: a test that hard-codes 7200 goes on passing after
# someone retunes the constant, while asserting about a boundary that no longer exists.
from _agent_facts import STATUS_STALE_AFTER  # noqa: E402
from textual.widgets import ListView, Static  # noqa: E402

PASS = FAIL = 0


def ok(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        print("  PASS: %s" % name)
        PASS += 1
    else:
        print("  FAIL: %s%s" % (name, ("\n        " + str(detail)) if detail else ""))
        FAIL += 1


def screen_text(app):
    """Every Static's content, as the markup that was handed to it.

    Textual 8 exposes `.content` as the source markup, not the rendered cells — so these
    assertions read what the app MEANT to draw. That is the right level for content: a test
    that greps rendered cells breaks on a theme change. The one thing it cannot see is a
    markup bug, which is why the fixtures deliberately include a status containing brackets.
    """
    return "\n".join(str(w.content) for w in app.screen.query(Static))


async def main():
    tmp = tempfile.mkdtemp()
    lane = os.path.join(tmp, "lanes", "feature-1")
    os.makedirs(os.path.join(lane, ".claude"))
    ask_path = os.path.join(lane, ".claude", "needs-input")
    fleet_path = os.path.join(tmp, "needs-input-fleet")
    with open(ask_path, "w") as f:
        f.write("review: the DX-6 diff\nsomething untyped\n")
    with open(fleet_path, "w") as f:
        f.write("ship: merge #124\n")

    # The ids that must become links live in ORDINARY TEXT — a status and an ask — not in the
    # ticket column. That is where most of them are, and where the table renderer never linked.

    # The fields the tests mutate between refreshes, to drive the rebuild-or-not decision.
    volatile = {
        "uptime": "3h",
        "pct": 60,
        # A TAG-SHAPED bracket, not just any bracket. `[2 GREEN]` reads as a hazard and is
        # not one — rich only treats `[` as markup when a tag name follows, so escape()
        # leaves it alone and so does the parser. `[b]` is the real case: unescaped it turns
        # the rest of the status bold and vanishes itself.
        "status": "SRV-11 done [b]2 GREEN[/b], uncommitted",
        # How old that status is, in seconds. Volatile in the truest sense — it grows on
        # every tick whether or not anyone rewrites the line, which is the whole point: a
        # status nobody maintains has to become visibly older, not silently stay "now".
        "status_age": 60,
        # Seconds since the AGENT last wrote its transcript — the fact nobody maintains, and
        # the one the status line structurally cannot supply. Volatile for the same reason
        # status_age is: it grows every tick until the agent does something.
        "last_active": 120,
        # A PR list is volatile too: it disappears the moment the PR merges. It rides the
        # head line rather than a shape change, so it has to survive the no-rebuild path.
        "prs": [(133, "https://gh/x/pull/133", False)],
    }

    # The roster the SIZING tests drive: how many agents beyond the fixture lane, and whether
    # that lane is there at all — a fleet can be empty, and the panel still has to be a panel.
    roster = {"extra": 0, "base": True}

    def fake_snapshot():
        base = {
            "name": "feature-1", "path": lane, "state": "idle",
            "uptime": volatile["uptime"],
            "kind": "lane", "label": "vii", "context_pct": volatile["pct"],
            "issue": "DX-6",
            "issue_links": [("DX-6", "https://example.invalid/DX-6")],
            "status": volatile["status"],
            "status_age": volatile["status_age"],
            "last_active": volatile["last_active"],
            "open_prs": volatile["prs"],
            "ask_path": ask_path, "raw_asks": fleet_tui._ask_lines(ask_path),
        }
        extra = [dict(base, name="extra-%d" % i, label="e%d" % i, issue_links=[],
                      status="", raw_asks=[], open_prs=[])
                 for i in range(roster["extra"])]
        return {
            "lanes": ([base] if roster["base"] else []) + extra,
            "subs": [],
            "fleet": fleet_tui._ask_lines(fleet_path),
            "fleet_path": fleet_path,
            "ctx": {"linear_base": "https://linear.app/acme",
                    "repo": "https://github.com/acme/goals"},
            "error": "",
        }

    fleet_tui.snapshot = fake_snapshot

    app = fleet_tui.FleetTUI(interval=3600)     # no timer refresh; the tests drive it
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.pause()
        text = screen_text(app)

        ok("the lane's status is rendered", "uncommitted" in text, text)
        ok("…with tag-shaped brackets escaped, so markup cannot eat them",
           r"\[b]2 GREEN\[/b]" in text, text)
        # The id inside it is a link by now, so match around it rather than through it.
        ok("a review: ask carries the review glyph", "🔍 the [link=" in text, text)
        ok("…and the words after the linked id survive", "[/link] diff" in text, text)
        ok("an untyped ask is a general action item", "✅ something untyped" in text, text)
        ok("the kind token is consumed, not printed", "review:" not in text, text)
        ok("the header counts every ask", "3 needs you" in text, text)

        # ── the panel the user calls "4me", and the numbers they call its rows by ─────────
        # "4me 1" is only unambiguous if the row wears the 1. The panel's own title carries
        # the count, so the label and the numbering are one contract, tested together.
        ok("the fleet-level panel is titled 4ME, with its count",
           app.query_one("#fleet").border_title == "4ME  (1)",
           app.query_one("#fleet").border_title)
        ok("…and its rows are numbered, so \"4me 1\" resolves to a row",
           "[dim] 1[/]" in text, text)

        # ── linking, everywhere an id appears ────────────────────────────────────────────
        ok("the ticket column links to the URL the tracker gave",
           "[link='https://example.invalid/DX-6']DX-6[/link]" in text, text)
        ok("a ticket id inside an ASK is linked too",
           "[link='linear://acme/issue/DX-6']DX-6[/link]" in text, text)
        ok("a ticket id inside a STATUS is linked too",
           text.count("[link='linear://acme/issue/SRV-11']SRV-11[/link]") == 1, text)
        ok("a ticket link uses the linear:// app scheme, never https",
           "https://linear.app" not in text, text)
        ok("…but a PR link stays https, since GitHub registers no scheme",
           "[link='https://github.com/acme/goals/pull/124']#124[/link]" in text, text)
        ok("a non-Linear URL is returned untouched rather than coerced",
           fleet_tui.linear_uri("https://example.invalid/DX-6")
           == "https://example.invalid/DX-6")
        ok("a PR number in a fleet ask is linked",
           "[link='https://github.com/acme/goals/pull/124']#124[/link]" in text, text)

        # No base learned ⇒ NOTHING is linked. A hyperlink assembled from a guessed workspace
        # looks authoritative and 404s, which is worse than the plain id it replaced.
        ok("with no learned base, an id stays plain text",
           fleet_tui.linkify("SRV-11 and #124", {}) == "SRV-11 and #124")

        # ── an unchanged snapshot must not rebuild the lists ──────────────────────────────
        lanes = app.query_one("#lanes", ListView)
        before = lanes.children[0]
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("an unchanged refresh does not rebuild (the cursor survives)",
           lanes.children[0] is before)

        # THE BLINK. uptime and ctx% move on every single tick; folding them into the redraw
        # signature rebuilt both lists every five seconds. The row must still update.
        volatile["uptime"] = "9h99m"
        volatile["pct"] = 71
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a changed uptime does NOT rebuild the list", lanes.children[0] is before)
        ok("…but the row shows the new value", "9h99m" in screen_text(app))
        ok("…and the new context%", "71%" in screen_text(app))

        # A changed STATUS is also line-confined, so it must not rebuild either — the lead
        # rewrites these constantly, and every rewrite used to repaint the whole panel.
        volatile["status"] = "now something else entirely"
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a changed status does NOT rebuild either", lanes.children[0] is before)
        ok("…but the new status is shown", "now something else entirely" in screen_text(app))
        ok("…and the lane's open PR is on the row while it is open",
           "#133" in screen_text(app), screen_text(app))
        ok("a status written a minute ago wears no age",
           "old)" not in screen_text(app), screen_text(app))

        # THE FROZEN-STATUS REGRESSION, and it is the same bug as the stale PR above wearing a
        # different costume. Nothing refreshes the status file, so a lane the lead stopped
        # updating advertised a four-day-old line as the live state of the fleet — and because
        # linkify makes every `#N` in it clickable, "PR #130 open; awaiting your merge" looked
        # exactly like PR data fetched a second ago, beside a correct uptime and context%.
        # Age is line-confined like uptime, so it must land WITHOUT a rebuild.
        volatile["status"] = "FEAT-6 PR #130 open; awaiting your merge"
        volatile["status_age"] = 4 * 86400
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a four-day-old status is marked as old", "(4d old)" in screen_text(app),
           screen_text(app))
        ok("…and says so without a rebuild", lanes.children[0] is before)
        ok("…while the line itself is kept, not blanked",
           "awaiting your merge" in screen_text(app), screen_text(app))
        # Blanking is what the PR cache does past PR_STALE_AFTER; it refreshes itself, so
        # silence there means broken. Here silence is normal, and blanking would delete the
        # only description of the lane the panel has.
        ok("the age is a fact ABOUT the line, dim and outside the lead's italic",
           "[/] [dim](4d old)[/]" in screen_text(app), screen_text(app))

        # Crossing the threshold is the only thing that decorates. Just under it, nothing.
        volatile["status_age"] = STATUS_STALE_AFTER - 1
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a status just under the threshold is undecorated",
           "old)" not in screen_text(app), screen_text(app))
        ok("…and an absent age is not an old one either",
           fleet_tui.fmt_age(None) == "")
        volatile["status_age"] = 60

        # THE OTHER CLOCK. The status text is only ever as current as the lead's memory —
        # that is what let every lane's line freeze for four days. The transcript mtime needs
        # nobody, so the row carries both: what the lane is doing, and when it last did
        # anything. They must be separable on screen, and the activity one must survive the
        # no-rebuild path exactly like uptime does.
        ok("the row says when the agent was last active",
           "active 2m ago" in screen_text(app), screen_text(app))
        ok("…as a fact about the row, dim and outside the lead's italic",
           "[dim]· active 2m ago[/]" in screen_text(app), screen_text(app))
        volatile["last_active"] = 3 * 3600
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a lane gone quiet for hours says so, without a rebuild",
           "active 3h ago" in screen_text(app) and lanes.children[0] is before,
           screen_text(app))
        # The two clocks are INDEPENDENT: a fresh status on a silent agent and a stale status
        # on a busy one are different problems, so neither field may imply the other.
        ok("a fresh status and a silent agent are shown as the different facts they are",
           "old)" not in screen_text(app) and "active 3h ago" in screen_text(app),
           screen_text(app))
        volatile["last_active"] = 120

        # THE STALE-PR REGRESSION. The PR merges, so the snapshot stops carrying it. Nothing
        # about the row's SHAPE changed, so this goes down the no-rebuild path — which is
        # exactly where a merged PR could linger on screen indefinitely.
        volatile["prs"] = []
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a merged PR leaves the row on the next refresh, without a rebuild",
           lanes.children[0] is before and "#133" not in screen_text(app), screen_text(app))

        # Only a change of SHAPE rebuilds. An ask appearing adds a line to the item, so it must.
        with open(ask_path, "a") as f:
            f.write("plan: a brand new ask\n")
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a NEW ASK does rebuild — it changes the item's shape",
           lanes.children[0] is not before)
        ok("…and the new ask is shown, typed", "📋 a brand new ask" in screen_text(app))

        # ── the FLEET panel is sized to the agent list, not to a fixed split ──────────────
        # Half the screen was the wrong height for every fleet but the one it was picked for:
        # two lanes left a panel of blank rows above a cramped to-do list, six hid the last
        # two behind a scrollbar with room going spare below them.
        panels = app.query_one("#panels")

        def panel_rows():
            return app.query_one("#lanes").outer_size.height

        def content_rows():
            """Measured off the laid-out items — an expectation INDEPENDENT of the arithmetic
            under test, so a wrong ITEM_ROWS cannot quietly agree with itself."""
            return sum(c.outer_size.height for c in lanes.children)

        lanes.focus()
        await pilot.pause()
        ok("the panel is exactly as tall as the agents in it, plus its border",
           panel_rows() == content_rows() + fleet_tui.PANEL_BORDER,
           "panel %d, content %d" % (panel_rows(), content_rows()))
        ok("…and 4ME takes every row it does not need",
           app.query_one("#fleet").outer_size.height == panels.size.height - panel_rows())

        fitted = panel_rows()
        roster["extra"] = 1
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a second agent grows the panel by exactly one agent's rows",
           panel_rows() == fitted + fleet_tui.ITEM_ROWS, panel_rows())
        ok("…and it still fits its content exactly",
           panel_rows() == content_rows() + fleet_tui.PANEL_BORDER,
           "panel %d, content %d" % (panel_rows(), content_rows()))
        roster["extra"] = 0
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("…and shrinks back when that agent goes away", panel_rows() == fitted)

        # A fleet with nothing in it. The panel must stay a titled box: a zero-height FLEET
        # header reads as a broken view, not as an empty one.
        roster["base"] = False
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("with no agents at all the panel is still a titled box",
           panel_rows() == fleet_tui.PANEL_MIN, panel_rows())
        roster["base"] = True

        # More agents than the terminal has rows: the panel stops at 4ME's floor
        # instead of pushing it off the bottom of the screen.
        roster["extra"] = 20
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a fleet taller than the terminal stops at the 4ME floor",
           panel_rows() == panels.size.height - fleet_tui.FLEET_MIN, panel_rows())
        ok("…so 4ME is still on screen rather than pushed off it",
           app.query_one("#fleet").outer_size.height == fleet_tui.FLEET_MIN)
        tall = panel_rows()
        await pilot.resize_terminal(80, 60)
        await pilot.pause()
        await pilot.pause()
        ok("…and a taller terminal hands the new rows to the agents, with no keypress",
           panel_rows() > tall
           and panel_rows() == panels.size.height - fleet_tui.FLEET_MIN, panel_rows())
        await pilot.resize_terminal(80, 24)
        roster["extra"] = 0
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("…and it comes back to the fit when the fleet does", panel_rows() == fitted)

        # ── + / - nudge the fit; they do not replace it ───────────────────────────────────
        await pilot.press("plus")
        await pilot.pause()
        ok("+ gives the focused panel one more row",
           panel_rows() == fitted + 1 and app.nudge == 1, panel_rows())
        await pilot.press("minus")
        await pilot.press("minus")
        await pilot.pause()
        ok("- takes one off", panel_rows() == fitted - 1 and app.nudge == -1, panel_rows())
        roster["extra"] = 1
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a nudge survives a roster change, as an OFFSET from the new fit — the panel does "
           "not snap back to the size picked for a smaller fleet",
           panel_rows() == fitted - 1 + fleet_tui.ITEM_ROWS, panel_rows())
        roster["extra"] = 0
        app.load()
        await pilot.pause()
        await pilot.pause()

        for _ in range(20):
            await pilot.press("plus")
        await pilot.pause()
        ok("a run of + cannot push 4ME off the bottom",
           app.query_one("#fleet").outer_size.height == fleet_tui.FLEET_MIN)
        await pilot.press("minus")
        await pilot.pause()
        ok("…and one - hands a row straight back — the extra presses are not banked",
           app.query_one("#fleet").outer_size.height == fleet_tui.FLEET_MIN + 1)
        for _ in range(30):
            await pilot.press("minus")
        await pilot.pause()
        ok("a run of - cannot shrink the panel past its own border",
           panel_rows() == fleet_tui.PANEL_MIN, panel_rows())
        app.nudge = 0                       # back to the plain fit for what follows
        app._fit_lanes()
        await pilot.pause()

        # ── = cycles which list is shown WHOLE ───────────────────────────────────────────
        # The fixture here is deliberately over-full — seven agents and eight items in a
        # 24-row terminal — because in a fleet where BOTH lists already fit the two states are
        # legitimately identical, so a test on that fixture would pass no matter what `=` did.
        #
        # notify is captured rather than displayed: the message is the only thing that
        # distinguishes "your whole list is on screen" from "this is as far as it goes", and a
        # real toast is a widget that later content assertions would then have to step around.
        notes = []
        real_notify, app.notify = app.notify, lambda msg, **kw: notes.append(str(msg))

        def said():
            """The last thing `=` reported — never an IndexError, because a key that
            failed to fire at all is a result this suite has to be able to PRINT."""
            return notes[-1] if notes else "(nothing was reported)"

        with open(fleet_path, "w") as f:
            f.write("".join("todo: fleet item %d\n" % i for i in range(1, 9)))
        roster["extra"] = 6
        app.load()
        await pilot.pause()
        await pilot.pause()

        def fleet_rows():
            return app.query_one("#fleet").outer_size.height

        ok("the view opens fitted to the agents", app.fit_mode == "agents", app.fit_mode)
        ok("…so with both lists over-full, 4ME is down to its floor",
           fleet_rows() == fleet_tui.FLEET_MIN, fleet_rows())

        await pilot.press("equals_sign")
        await pilot.pause()
        ok("= hands the rows over and 4ME shows its whole list",
           app.fit_mode == "4ME" and fleet_rows() == fleet_tui.asks_fit_height(8),
           "%s / fleet %d" % (app.fit_mode, fleet_rows()))
        ok("…and says so", said() == "fit 4ME · all 8 visible", said())
        ok("…without collapsing the agent panel to nothing",
           panel_rows() >= fleet_tui.PANEL_MIN, panel_rows())

        await pilot.press("equals_sign")
        await pilot.pause()
        ok("= again gives them back to the agents, at the size the view opens with",
           app.fit_mode == "agents"
           and panel_rows() == panels.size.height - fleet_tui.FLEET_MIN, panel_rows())
        await pilot.press("equals_sign")
        await pilot.pause()
        ok("…and a third press is on 4ME again — the cycle does not settle",
           app.fit_mode == "4ME" and fleet_rows() == fleet_tui.asks_fit_height(8))

        # A nudged boundary is NOT one of the two states, so the next `=` returns to the fit
        # rather than advancing — "put it back how it opened" is what the key is for.
        await pilot.press("plus")
        await pilot.press("equals_sign")
        await pilot.pause()
        ok("= after a +/- nudge returns to the agent fit rather than advancing the cycle",
           app.fit_mode == "agents" and app.nudge == 0, "%s %d" % (app.fit_mode, app.nudge))

        # ── a list taller than the terminal cannot be fitted, and must not pretend ────────
        with open(fleet_path, "w") as f:
            f.write("".join("todo: fleet item %d\n" % i for i in range(1, 21)))
        app.load()
        await pilot.pause()
        await pilot.pause()
        await pilot.press("equals_sign")
        await pilot.pause()
        ok("twenty 4ME items in a 24-row terminal are reported as PARTLY shown, not as fitted",
           "of 20 visible, the rest scroll" in said(), said())
        ok("…while the agent panel keeps its own floor rather than vanishing",
           panel_rows() == fleet_tui.PANEL_MIN, panel_rows())
        await pilot.press("equals_sign")
        await pilot.pause()
        ok("…and so are seven agents", "of 7 visible, the rest scroll" in said(),
           said())

        # ── an empty 4ME is the common case ──────────────────────────────────────────────
        with open(fleet_path, "w") as f:
            f.write("")
        app.load()
        await pilot.pause()
        await pilot.pause()
        empty_fleet, empty_lanes = fleet_rows(), panel_rows()
        await pilot.press("equals_sign")
        await pilot.pause()
        ok("an empty 4ME says it is empty instead of claiming a fit",
           said() == "4ME is empty — the agents keep the rows", said())
        ok("…and the layout does not collapse: 4ME keeps its floor, the agents keep the rest",
           fleet_rows() == fleet_tui.FLEET_MIN
           and (fleet_rows(), panel_rows()) == (empty_fleet, empty_lanes),
           "%d / %d" % (panel_rows(), fleet_rows()))

        # `=` is a sizing request, and a maximised panel has no boundary to size.
        await pilot.press("f")
        await pilot.pause()
        ok("f still maximises", app.query_one("#fleet").display is False)
        await pilot.press("equals_sign")
        await pilot.pause()
        ok("= leaves fullscreen rather than doing nothing there",
           app.full is None and app.query_one("#fleet").display is True)

        with open(fleet_path, "w") as f:
            f.write("ship: merge #124\n")
        roster["extra"] = 0
        app.fit_mode, app.nudge = "agents", 0
        app.load()
        await pilot.pause()
        await pilot.pause()
        app.notify = real_notify
        ok("the fit is back where the rest of the tests expect it", panel_rows() == fitted,
           panel_rows())

        # ── fullscreen ───────────────────────────────────────────────────────────────────
        await pilot.press("f")
        await pilot.pause()
        ok("f hides the other panel", app.query_one("#fleet").display is False)
        ok("…and keeps the focused one", app.query_one("#lanes").display is True)
        ok("…which fills the box rather than staying fitted to its agents",
           panel_rows() == panels.size.height, panel_rows())
        await pilot.press("plus")
        await pilot.press("plus")
        await pilot.pause()
        await pilot.press("f")
        await pilot.pause()
        ok("f again restores both", app.query_one("#fleet").display is True)
        ok("…and the FLEET panel is back to fitting its agents", panel_rows() == fitted)
        ok("…with no nudge banked from the presses made while it was fullscreen — there was "
           "no boundary to move", app.nudge == 0, app.nudge)

        # ── the legend TOGGLES; as a toast each press stacked another copy ────────────────
        legend = app.query_one("#legend")
        ok("the legend starts hidden", not legend.has_class("-show"))
        await pilot.press("question_mark")
        await pilot.pause()
        ok("? opens it", legend.has_class("-show"))
        ok("…and it names every glyph on screen",
           all(g in str(legend.content) for g in
               ("🔍", "📋", "💬", "🏷️", "🚀", "✅", "●", "◔", "○")), str(legend.content))
        # The footer structurally CANNOT advertise enter — the focused ListView's own hidden
        # binding is what it renders — so the legend is the only place that key exists.
        ok("…and the keys the footer cannot show",
           "enter" in str(legend.content) and "editable" in str(legend.content),
           str(legend.content))
        await pilot.press("question_mark")
        await pilot.pause()
        ok("? again closes it — pressing twice does not leave two",
           not legend.has_class("-show"))
        await pilot.press("question_mark")
        await pilot.press("escape")
        await pilot.pause()
        ok("escape closes it too", not legend.has_class("-show"))
        ok("…without also leaving fullscreen", app.query_one("#fleet").display is True)

        # ── x clears from the FILE, u puts it back ────────────────────────────────────────
        lanes.focus()
        lanes.index = 0
        await pilot.pause()
        await pilot.press("x")
        await pilot.pause()
        await pilot.pause()
        on_disk = open(ask_path).read()
        ok("x removes the ask from the file", "review: the DX-6 diff" not in on_disk, on_disk)
        ok("…and leaves the lane's other ask alone", "something untyped" in on_disk, on_disk)
        ok("…and the screen follows", "🔍 the DX-6 diff" not in screen_text(app))

        await pilot.press("u")
        await pilot.pause()
        await pilot.pause()
        ok("u restores it", "review: the DX-6 diff" in open(ask_path).read())

        # ── the fleet panel clears its own highlighted item ───────────────────────────────
        fleet = app.query_one("#fleet", ListView)
        fleet.focus()
        fleet.index = 0
        await pilot.pause()
        await pilot.press("x")
        await pilot.pause()
        await pilot.pause()
        ok("x on the fleet panel clears that item",
           "merge #124" not in open(fleet_path).read())

        # ── enter opens the agent detail overlay ─────────────────────────────────────────
        # The lane's two config files, layered the way _config.sh layers them. The fixtures
        # are chosen so every failure mode is distinguishable: a value set in BOTH files (the
        # local one must win and say so), one set only in the committed file, one that exists
        # there ONLY AS A COMMENT (which is not a value), and one nobody has ever set.
        cfg_dir = os.path.join(lane, ".claude")
        committed_cfg = os.path.join(cfg_dir, "workflow.config")
        local_cfg = os.path.join(cfg_dir, "workflow.config.local")
        with open(committed_cfg, "w") as f:
            f.write("# project defaults\n"
                    'WORKFLOW_LANE_EFFORT="high"\n'
                    'WORKFLOW_REVIEW_MODEL_B="sonnet"   # pinned for model diversity\n'
                    '#   WORKFLOW_TEST_MODEL=""\n'
                    'WORKFLOW_PR_TARGET_BRANCH="master"\n')
        with open(local_cfg, "w") as f:
            f.write("# per-machine\n"
                    'WORKFLOW_TODO_NS="jn"        # unrelated, must survive every edit\n'
                    'WORKFLOW_LANE_EFFORT="medium"\n')

        # The lane's REAL status file. The row above is fed a pre-clipped copy through the
        # snapshot, exactly as fleet-status.sh delivers it; the overlay must go back to the
        # file instead, so the fixture is deliberately longer than the 60-char column cap and
        # its distinguishing words live PAST the cap.
        status_file = os.path.join(cfg_dir, "status")
        long_status = ("SRV-11 rebased onto master and the migration re-run; still waiting on "
                       "the operator CLI decision before the final commit lands")
        with open(status_file, "w") as f:
            f.write("# a comment, which is not the status\n" + long_status + "\n")

        # The live session is STUBBED. Reading it for real means capturing a tmux pane, which
        # on this machine would reach into the actual running fleet — a test that touches the
        # thing it is meant to be independent of. The parse it would have fed is covered
        # below, against fixture bytes.
        #
        # THE PANE ID IS `%182` ON PURPOSE — the exact value that was reported as "182%". A
        # tmux pane id is a `%` followed by digits, so printed bare after `effort=medium` it
        # reads as a percentage of something, next to a field whose values are words.
        live = {"on": True}
        fleet_tui.live_tuning = lambda name: (
            {"pane": "%182", "model": "Opus", "effort": "xhigh"} if live["on"] else None)
        applied = []
        fleet_tui.apply_now = lambda sh, name: (
            applied.append((sh, name)) or "  %-12s PASS     effort=xhigh✓" % name)

        async def open_overlay():
            lanes.focus()
            lanes.index = 0
            await pilot.pause()
            await pilot.press("enter")
            for _ in range(6):
                await pilot.pause()

        def detail_text():
            return "\n".join(str(w.content)
                             for w in app.query_one("#detail").query(Static))

        def cfg_items():
            return [c.entry for c in app.query_one("#detail-cfg", ListView).children]

        await open_overlay()
        ok("enter on an agent row opens the detail overlay",
           app.detail is not None and app.query_one("#detail").has_class("-show"))
        text = detail_text()
        ok("…which names the agent and its lane path", "feature-1" in text and lane in text)
        ok("…and shows what the session is running right now",
           "model=[b]Opus[/]" in text and "effort=[b]xhigh[/]" in text, text)

        # ── git state ────────────────────────────────────────────────────────────────────
        ok("…the branch line is there", "branch " in text, text)
        ok("…with a comparison against the local base", "vs [b]master[/]" in text, text)
        ok("…and against origin, LABELLED as unfetched rather than silently stale",
           "vs [b]origin/master[/]" in text and "not fetched" in text, text)

        # ── config, with the file each value came from ────────────────────────────────────
        keys = [e["key"] for e in cfg_items()]
        ok("the per-lane override is listed first, above the fleet-wide fallback it beats",
           keys[:2] == ["WORKFLOW_LANE_EFFORT_1", "WORKFLOW_LANE_MODEL_1"], keys[:2])
        by_key = {e["key"]: e for e in cfg_items()}
        ok("a value set in the LOCAL file wins, and says it came from there",
           (by_key["WORKFLOW_LANE_EFFORT"]["value"],
            by_key["WORKFLOW_LANE_EFFORT"]["origin"]) == ("medium", "local"),
           by_key["WORKFLOW_LANE_EFFORT"])
        ok("…a value only in the committed file is shown as committed",
           (by_key["WORKFLOW_REVIEW_MODEL_B"]["value"],
            by_key["WORKFLOW_REVIEW_MODEL_B"]["origin"]) == ("sonnet", "committed"),
           by_key["WORKFLOW_REVIEW_MODEL_B"])
        ok("…a COMMENTED-OUT assignment is not a value — the shell never sets it",
           by_key["WORKFLOW_TEST_MODEL"]["origin"] == "unset",
           by_key["WORKFLOW_TEST_MODEL"])
        ok("a lane knob is marked as reaching the LIVE agent…",
           by_key["WORKFLOW_LANE_EFFORT"]["scope"] == "live")
        ok("…and a subagent knob as taking effect at the NEXT SPAWN",
           by_key["WORKFLOW_TEST_MODEL"]["scope"] == "spawn")
        ok("the two scopes are visible on the rows themselves, not only in the data",
           "live agent" in text and "next spawn" in text, text)

        # ── the status, IN FULL ──────────────────────────────────────────────────────────
        # The row's copy arrives from the snapshot already cut to 60 characters, so nothing
        # downstream could ever widen it — the words were gone before the TUI saw them. The
        # overlay has a whole dialog, so it reads the file.
        # Matched from AFTER the ticket id: linkify has turned that id into a hyperlink by
        # now, exactly as it does on the row, so the assertion reads around it rather than
        # through it — the same convention the ask tests above use.
        ok("the overlay shows the agent's update IN FULL, not the row's 60-char clip",
           long_status.split(" ", 1)[1] in text, text)
        ok("…including the words past the cap, with no ellipsis where the column cut it",
           "operator CLI decision" in text
           and fleet_tui.clip(long_status) not in text, text)
        ok("…without the status file's comment lines", "not the status" not in text, text)
        ok("…labelled, and wearing the two clocks the row carries",
           "[dim]status[/]" in text and "active 2m ago" in text, text)

        # ── the effort line is never a percentage ────────────────────────────────────────
        # `%182` beside `effort=xhigh` was read as "182%" — a percentage on a line whose only
        # values are words, which sends the reader hunting a context bug that is not there.
        # Asserted STRUCTURALLY, not as the string "182%" — which never appears literally,
        # so a test looking for it could not fail for the defect it is named after. The
        # defect is an UNLABELLED `%182` sitting where a number is expected; so the rule is
        # that every pane id on this line wears its label.
        head_markup = app.detail_head_markup((app.detail or {}).get("data") or {})
        bare = [m.group(0) for m in fleet_tui.re.finditer(r"%\d+", head_markup)
                if not head_markup[:m.start()].endswith("pane ")]
        ok("the pane id is never printed bare beside effort, where it reads as a percent",
           not bare, (bare, head_markup))
        ok("…it is labelled as a pane", "pane %182" in text, text)
        ok("…and the only percentage on that line is labelled context",
           "[dim]context[/]" in text and "71%" in text, text)
        # The gauge itself is the LIST view's fixed one, not a second implementation: the
        # 216% bug lived in the denominator, and a surface that re-derives its own percentage
        # re-earns that bug the day someone tunes it.
        broken = dict((app.detail or {}).get("data") or {}, context_pct=216)
        ok("…and an out-of-range value is an admission here too, not a confident number",
           "216%" not in app.detail_head_markup(broken)
           and ">100%" in app.detail_head_markup(broken),
           app.detail_head_markup(broken))
        unknown = dict(broken, context_pct=None)
        ok("…while an unknown context is a dash rather than a guess",
           "context[/] [dim]—[/]" in app.detail_head_markup(unknown),
           app.detail_head_markup(unknown))

        # ── the sections are separated, like everything else in this view ────────────────
        # Head, status, git and config are four different subjects. Run together they read as
        # one paragraph and the reader has to parse sentences to find the seams; the rest of
        # the view already spends a row per item for exactly this reason.
        gaps = {w.id: w.styles.margin.bottom
                for w in app.query_one("#detail").children if w.id}
        ok("every section of the overlay is followed by a blank line",
           all(gaps.get(i) == 1 for i in
               ("detail-head", "detail-status-box", "detail-git", "detail-cfg")), gaps)

        # ── the overlay is a LIVE view, not a snapshot of the moment enter was pressed ────
        # It used to be filled once and never re-read, so `r` reloaded the fleet underneath a
        # dialog that went on showing what was true when it opened — which is why widening
        # the terminal and reloading never expanded anything.
        with open(status_file, "w") as f:
            f.write("rewritten while the overlay is open\n")
        volatile["pct"] = 88
        await pilot.press("r")
        for _ in range(6):
            await pilot.pause()
        ok("r re-reads the open overlay rather than only the panel behind it",
           "rewritten while the overlay is open" in detail_text(), detail_text())
        ok("…the stale text is gone, not merely appended to",
           long_status.split(" ", 1)[1] not in detail_text(), detail_text())
        ok("…and the numbers on the row it came from move with it",
           "88%" in detail_text(), detail_text())
        ok("…without closing the overlay or losing the config list",
           app.detail is not None and len(cfg_items()) > 0)
        with open(status_file, "w") as f:
            f.write(long_status + "\n")

        # ── the overlay swallows the keys that act on what it is covering ─────────────────
        # `x` deletes from the lead's to-do file, and `=`/`+` resize panels the overlay hides.
        # Acting at a distance on something the reader cannot see is the worst case here.
        before_asks = open(ask_path).read()
        before_h = panel_rows()
        await pilot.press("x")
        await pilot.press("equals_sign")
        await pilot.press("plus")
        await pilot.pause()
        ok("x while the overlay is open does not delete an ask behind it",
           open(ask_path).read() == before_asks)
        ok("…and = / + do not resize the panels it is covering",
           panel_rows() == before_h and app.nudge == 0, panel_rows())

        # ── editing: rejected before it is ever written ───────────────────────────────────
        cfg_list = app.query_one("#detail-cfg", ListView)
        cfg_list.index = keys.index("WORKFLOW_LANE_EFFORT")
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        inp = app.query_one("#detail-input", fleet_tui.Input)
        ok("enter on a knob opens the editor, pre-filled with its current value",
           inp.has_class("-show") and inp.value == "medium", inp.value)
        inp.value = "rm -rf /"
        await pilot.press("enter")
        await pilot.pause()
        ok("a value outside the allowed vocabulary is REFUSED — these strings get typed into "
           "a live agent's pane", "is not a valid effort" in detail_text(), detail_text())
        ok("…and nothing was written", "rm -rf" not in open(local_cfg).read())
        ok("…while the field stays open so the typo can be fixed", inp.has_class("-show"))

        inp.value = "xhigh"
        await pilot.press("enter")
        for _ in range(6):
            await pilot.pause()
        on_disk = open(local_cfg).read()
        ok("a valid value is written to the LOCAL config",
           'WORKFLOW_LANE_EFFORT="xhigh"' in on_disk, on_disk)
        ok("…never to the committed one",
           'WORKFLOW_LANE_EFFORT="high"' in open(committed_cfg).read())
        ok("…and the unrelated lines and comments survive",
           'WORKFLOW_TODO_NS="jn"' in on_disk and "# per-machine" in on_disk
           and "must survive every edit" in on_disk, on_disk)
        ok("…the overlay re-reads the file rather than trusting the write",
           {e["key"]: e for e in cfg_items()}["WORKFLOW_LANE_EFFORT"]["value"] == "xhigh")
        ok("a LIVE knob says the running agent has not changed yet",
           "has NOT changed" in detail_text() and "press [b]a[/]" in detail_text(),
           detail_text())

        # ── the other half of the split: a subagent knob needs no apply ───────────────────
        cfg_list.index = keys.index("WORKFLOW_TEST_MODEL")
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        inp.value = "haiku"
        await pilot.press("enter")
        for _ in range(6):
            await pilot.pause()
        ok("a knob absent from the local file is APPENDED, not silently dropped",
           'WORKFLOW_TEST_MODEL="haiku"' in open(local_cfg).read(), open(local_cfg).read())
        ok("…and a SPAWN knob says so instead of offering an apply",
           "next spawns" in detail_text() or "next spawn" in detail_text(), detail_text())
        ok("…without claiming the running agent is stale", "press [b]a[/]" not in detail_text())

        # ── empty means inherit, and must be enterable ────────────────────────────────────
        await pilot.press("enter")
        await pilot.pause()
        inp.value = ""
        await pilot.press("enter")
        for _ in range(6):
            await pilot.pause()
        ok("an EMPTY value is accepted and clears the override",
           'WORKFLOW_TEST_MODEL=""' in open(local_cfg).read(), open(local_cfg).read())

        # ── apply-now, for the live knobs only ───────────────────────────────────────────
        await pilot.press("a")
        for _ in range(6):
            await pilot.pause()
        ok("a runs agent-tune apply for THIS agent", applied == [
            (os.path.join(lane, ".claude", "scripts", "agent-tune.sh"), "feature-1")], applied)
        ok("…and surfaces its own PASS/FAIL line rather than a verdict of our own",
           "agent-tune:" in detail_text() and "PASS" in detail_text(), detail_text())

        # ── esc closes; enter elsewhere still means what it meant ─────────────────────────
        await pilot.press("escape")
        await pilot.pause()
        ok("esc closes the overlay", app.detail is None
           and not app.query_one("#detail").has_class("-show"))
        ok("…and hands focus back to the fleet list", lanes.has_focus)

        # A lane with no live agent still has git and config — the overlay must work from the
        # roster row alone, and simply omit the line it cannot honestly fill.
        live["on"] = False
        await open_overlay()
        ok("a lane with no live session still opens", app.detail is not None)
        ok("…showing config and git, with no invented model/effort line",
           "no live session" in detail_text() and "vs [b]master[/]" in detail_text(),
           detail_text())
        await pilot.press("a")
        await pilot.pause()
        ok("…and apply-now refuses rather than tuning nothing",
           "nothing to apply to" in detail_text(), detail_text())
        await pilot.press("escape")
        await pilot.pause()

        # The key enter USED to be. It still opens the ticket from the 4ME panel, and `o`
        # opens it from a lane row — the meaning moved, it was not deleted.
        opened = []
        real_popen, fleet_tui.subprocess.Popen = fleet_tui.subprocess.Popen, \
            lambda argv, *a, **k: opened.append(argv)
        try:
            lanes.focus()
            lanes.index = 0
            await pilot.pause()
            await pilot.press("o")
            await pilot.pause()
            ok("o opens the lane's ticket — enter's old job, not lost",
               opened == [["open", "https://example.invalid/DX-6"]], opened)
            ok("…and pressing it did NOT open the overlay", app.detail is None)
            opened.clear()
            with open(fleet_path, "w") as f:
                f.write("ship: merge #124\n")
            app.load()
            await pilot.pause()
            await pilot.pause()
            fleet.focus()
            fleet.index = 0
            await pilot.pause()
            await pilot.press("enter")
            await pilot.pause()
            ok("enter on a 4ME row still opens the ticket rather than a detail overlay",
               opened and app.detail is None, opened)
        finally:
            fleet_tui.subprocess.Popen = real_popen

    # ── a lane's open PR, beside its ticket ──────────────────────────────────────────────
    # Driven against Lane.pr_markup directly rather than restarting the app three times. The
    # two cases that could LIE are the ones worth locking: a PR shown for a lane that has
    # none, and a draft presented as if it were ready to merge.
    lane_row = {"name": "feature-1", "label": "vii", "state": "idle", "kind": "lane"}
    mk = fleet_tui.Lane.pr_markup

    class _R:
        """A Lane stand-in: these markup builders read only `row` and `ctx`, so driving them
        directly beats restarting the app once per case."""

        pr_markup = fleet_tui.Lane.pr_markup

        def __init__(self, row):
            self.row = row
            self.ctx = {}

    ready = mk(_R(dict(lane_row, open_prs=[(999, "https://gh/x/pull/999", False)])))
    draft = mk(_R(dict(lane_row, open_prs=[(1000, "https://gh/x/pull/1000", True)])))
    none_ = mk(_R(dict(lane_row)))

    ok("an open PR renders its number", "#999" in ready, ready)
    ok("…as a clickable https link — GitHub registers no custom scheme",
       "[link='https://gh/x/pull/999']" in ready, ready)
    ok("a draft PR is marked", "#1000…" in draft, draft)
    ok("…and is dim rather than green, so it cannot read as ready to merge",
       "dim" in draft and "b green" not in draft, draft)
    ok("a lane with no PR renders nothing at all", none_ == "", repr(none_))

    # MULTIPLE PRs, like the tickets beside them. Showing only the first is a lie that looks
    # like a fact — the reader cannot tell one-PR from first-of-two.
    two = mk(_R(dict(lane_row, open_prs=[(1, "https://gh/x/pull/1", False),
                                         (2, "https://gh/x/pull/2", True)])))
    ok("a lane with two PRs renders both", "#1" in two and "#2…" in two, two)
    ok("…and only the draft is dimmed", two.index("b green") < two.index("dim"), two)

    # branch_for is the half that fails silently: a worktree's `.git` is a FILE, so the
    # obvious <cwd>/.git/HEAD read finds nothing in exactly the layout this fleet runs in.
    import _agent_facts
    with tempfile.TemporaryDirectory() as td:
        real = os.path.join(td, "realgit")
        os.makedirs(real)
        with open(os.path.join(real, "HEAD"), "w") as fh:
            fh.write("ref: refs/heads/some/branch\n")
        wt = os.path.join(td, "wt")
        os.makedirs(wt)
        with open(os.path.join(wt, ".git"), "w") as fh:
            fh.write("gitdir: %s\n" % real)
        ok("branch_for follows a worktree's .git FILE",
           _agent_facts.branch_for(wt) == "some/branch", _agent_facts.branch_for(wt))
        with open(os.path.join(real, "HEAD"), "w") as fh:
            fh.write("9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c\n")
        ok("…and returns empty on a detached HEAD rather than a fake branch name",
           _agent_facts.branch_for(wt) == "", _agent_facts.branch_for(wt))

    # ── the status, at both of its two lengths ───────────────────────────────────────────
    # ONE FILE, TWO READERS, and the difference is the CALLER's layout rather than the data's:
    # a column gets sixty characters, a dialog gets the file. They must still agree about what
    # counts as a status line, which is why they share the filtering.
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, ".claude"))
        sf = os.path.join(td, ".claude", "status")
        first = ("SRV-11 rebased and the migration re-run, still waiting on the operator CLI "
                 "decision")
        with open(sf, "w") as fh:
            fh.write("# not a status\n\n" + first + "\nand a second line\n")
        ok("the column reader clips to the cap and marks the cut",
           _agent_facts.status_line(td) == _agent_facts.clip(first)
           and _agent_facts.status_line(td).endswith("…"),
           _agent_facts.status_line(td))
        ok("the dialog reader returns the file's own bytes, uncut",
           _agent_facts.status_text(td) == first + "\nand a second line",
           _agent_facts.status_text(td))
        ok("…dropping comments and blanks, exactly as the column reader does",
           "not a status" not in _agent_facts.status_text(td),
           _agent_facts.status_text(td))
        with open(sf, "w") as fh:
            fh.write("# only comments here\n")
        ok("a status file with nothing in it yields empty on BOTH readers — never a comment",
           (_agent_facts.status_line(td), _agent_facts.status_text(td)) == ("", ""),
           (_agent_facts.status_line(td), _agent_facts.status_text(td)))

    # ── the context gauge: the DENOMINATOR is the model's, and it is never guessed ────────
    # A lead running a 1M-context model against a hardcoded 200k denominator read 216%, which
    # is the visible half of the bug. The invisible half is that the SAME wrong denominator
    # reads a plausible 80% at 128k used — so the fix is both a correct per-model window and
    # a renderer that refuses to print a percentage it cannot stand behind.
    ok("a 1M model resolves a 1M window even though its name carries no [1m] marker",
       _agent_facts.window_for("claude-fable-5") == 1_000_000,
       _agent_facts.window_for("claude-fable-5"))
    ok("…and so does the current Opus", _agent_facts.window_for("claude-opus-5") == 1_000_000,
       _agent_facts.window_for("claude-opus-5"))
    ok("a 200k model is not promoted to 1M by its major version",
       _agent_facts.window_for("claude-haiku-4-5") == 200_000,
       _agent_facts.window_for("claude-haiku-4-5"))
    ok("an explicit [1m] marker still wins",
       _agent_facts.window_for("claude-haiku-4-5[1m]") == 1_000_000)
    # THE ROOT CAUSE, GENERALISED. Guessing 200k for a name we do not recognise is what
    # produced 216%; an unknown model must yield no window, so the gauge renders "—".
    ok("an unrecognised model yields NO window rather than a 200k guess",
       _agent_facts.window_for("claude-something-new-9") is None,
       _agent_facts.window_for("claude-something-new-9"))
    ok("…and so does an absent model", _agent_facts.window_for(None) is None)

    with tempfile.TemporaryDirectory() as td:
        tr = os.path.join(td, "t.jsonl")
        with open(tr, "w") as fh:
            fh.write(json.dumps({
                "type": "assistant",
                "message": {"model": "claude-fable-5",
                            "usage": {"input_tokens": 2, "cache_read_input_tokens": 356750,
                                      "cache_creation_input_tokens": 434,
                                      "output_tokens": 568}},
            }) + "\n")
        used, win = _agent_facts.context_for(td, tr)
        ok("a real 1M-model transcript reports a 1M window", win == 1_000_000, win)
        ok("…so 357k used is a third of the window, not double it",
           round(100 * used / (win * 0.8)) == 45, (used, win))

    # The clamp. Even with the denominator fixed, a gauge that CAN print 216% will one day
    # print 80% wrong. Over 100% is rendered as an admission, not as a number.
    over = fleet_tui.Lane.head_markup(_R(dict(lane_row, context_pct=216, issue_links=[])))
    ok("a percentage over 100 is not printed as a confident number", "216%" not in over, over)
    ok("…it says >100% instead", ">100%" in over, over)
    ok("…louder than a merely-full lane, since it means the gauge is broken",
       "[b red]" in over, over)
    fine = fleet_tui.Lane.head_markup(_R(dict(lane_row, context_pct=45, issue_links=[])))
    ok("a percentage in range is still printed plainly", " 45%" in fine, fine)

    # ── the PR list is never stickier than the cache it came from ────────────────────────
    # The cache has a max age on the WRITE path only; nothing bounded the READ. A `gh` that
    # stops working (expired auth, offline) leaves the last good file in place forever, and
    # the panel goes on advertising PRs that closed days ago with nothing looking broken.
    with tempfile.TemporaryDirectory() as td:
        cache = os.path.join(td, "fleet-prs.json")
        real_cache, _agent_facts.PR_CACHE = _agent_facts.PR_CACHE, cache
        wt = os.path.join(td, "lane")
        os.makedirs(os.path.join(wt, ".claude"))
        with open(os.path.join(wt, ".claude", "current-work"), "w") as fh:
            fh.write("DX-16\thttps://linear.app/acme/issue/DX-16\n")

        def write_cache(prs, age=0):
            with open(cache, "w") as fh:
                json.dump(prs, fh)
            if age:
                t = time.time() - age
                os.utime(cache, (t, t))

        pr = {"number": 133, "url": "https://gh/x/pull/133", "isDraft": False,
              "title": "plans become Linear documents (Fixes DX-16)",
              "headRefName": "pr/dx-16-plans"}
        write_cache([pr])
        ok("a fresh cache surfaces the lane's open PR",
           _agent_facts.open_prs_for(wt) == [(133, "https://gh/x/pull/133", False)],
           _agent_facts.open_prs_for(wt))
        # THE REGRESSION: the PR closes, so it leaves the cache. The next read must drop it.
        write_cache([])
        ok("a PR that left the cache leaves the row on the very next read",
           _agent_facts.open_prs_for(wt) == [], _agent_facts.open_prs_for(wt))
        # And the unbounded-staleness case the write-side max age cannot cover.
        write_cache([pr], age=_agent_facts.PR_STALE_AFTER + 60)
        ok("a cache too old to trust reports nothing rather than yesterday's PRs",
           _agent_facts.open_prs_for(wt) == [], _agent_facts.open_prs_for(wt))
        _agent_facts.PR_CACHE = real_cache

    # ── the ticket column survives a lane agent's sloppy bookkeeping ─────────────────────
    # The column reads line 1 of .claude/current-work, a file the lane agents maintain by
    # hand. Two live lanes had it wrong at once: one opened with a shutdown checkpoint, the
    # other still named the ticket before last. Neither is fixable by asking agents harder.
    with tempfile.TemporaryDirectory() as td:
        def lane_at(body, branch=None):
            d = os.path.join(td, "l%d" % lane_at.n)
            lane_at.n += 1
            os.makedirs(os.path.join(d, ".claude"))
            with open(os.path.join(d, ".claude", "current-work"), "w") as fh:
                fh.write(body)
            if branch:
                g = os.path.join(d, "gitdir")
                os.makedirs(g)
                with open(os.path.join(g, "HEAD"), "w") as fh:
                    fh.write("ref: refs/heads/%s\n" % branch)
                with open(os.path.join(d, ".git"), "w") as fh:
                    fh.write("gitdir: %s\n" % g)
            return d
        lane_at.n = 0

        buried = lane_at("# CHECKPOINT 2026-08-01 — feature-3, 2nd revision.\n"
                         "Resume by re-reading the plan document, then the diff.\n"
                         "SRV-22\thttps://linear.app/acme/issue/SRV-22\n")
        ok("a ticket buried under a checkpoint header is still found",
           _agent_facts.todo_for(buried) == "SRV-22", _agent_facts.todo_for(buried))
        ok("…with its URL, so the column stays clickable",
           _agent_facts.todo_pairs_for(buried)
           == [("SRV-22", "https://linear.app/acme/issue/SRV-22")],
           _agent_facts.todo_pairs_for(buried))

        commented = lane_at("# ACTIVE: DX-6 (then DX-5). Plan approved 2026-08-04.\n")
        ok("a file that is only comments yields no ticket at all",
           _agent_facts.todo_for(commented) == "", _agent_facts.todo_for(commented))
        ok("…and never renders the comment line as if it were one",
           "#" not in _agent_facts.todo_for(commented))

        # The pointer block is contiguous, which is what BOUNDS the forgiving scan. One live
        # file carries 370 commented checkpoint lines and then repeats its pointer; treating
        # comments as invisible everywhere read the same ticket twice.
        repeated = lane_at("DX-5\thttps://linear.app/acme/issue/DX-5\n"
                           + "# checkpoint\n" * 40
                           + "DX-5\thttps://linear.app/acme/issue/DX-5\n")
        ok("a commented checkpoint ends the pointer block rather than being skipped over",
           _agent_facts.todo_for(repeated) == "DX-5", _agent_facts.todo_for(repeated))

        prose = lane_at("DX-5\thttps://linear.app/acme/issue/DX-5\n"
                        "Now write the warmup navigation into authSetup.\n"
                        "SRV-99\thttps://linear.app/acme/issue/SRV-99\n")
        ok("resume prose still ends the ticket list — a later id is not a second ticket",
           _agent_facts.todo_for(prose) == "DX-5", _agent_facts.todo_for(prose))

        # The branch is machine truth; the file is agent diligence. When they disagree, the
        # column follows the branch and SAYS SO, rather than silently picking a side.
        ok("a ticket id is read out of the branch name",
           _agent_facts.branch_ticket_for(
               lane_at("", branch="john/dx-16-move-plans-to-documents")) == "DX-16")
        ok("…and a branch that names no ticket yields none",
           _agent_facts.branch_ticket_for(lane_at("", branch="feature-2")) == "")

        agreed = lane_at("SRV-22\thttps://linear.app/acme/issue/SRV-22\n",
                         branch="john/srv-22-unnameable-nft-identity")
        ok("agreement between branch and file is not flagged",
           _agent_facts.tickets_for(agreed) == ([("SRV-22",
                                                  "https://linear.app/acme/issue/SRV-22")],
                                                False),
           _agent_facts.tickets_for(agreed))

        stale = lane_at("DX-6\thttps://linear.app/acme/issue/DX-6\n",
                        branch="john/dx-16-move-plans-to-documents")
        pairs, mismatch = _agent_facts.tickets_for(stale)
        ok("a stale current-work loses to the branch", pairs == [("DX-16", "")], pairs)
        ok("…and the disagreement is reported, not swallowed", mismatch is True)
        ok("…so the row shows the branch's ticket with a ≠ marker",
           "≠" in fleet_tui.Lane.head_markup(
               _R(dict(lane_row, issue_links=pairs, ticket_mismatch=True))))
        ok("…and an agreeing row wears no marker",
           "≠" not in fleet_tui.Lane.head_markup(
               _R(dict(lane_row, issue_links=[("SRV-22", "")]))))

    # ── the detail overlay's own data, against real files and a real repo ────────────────
    # The UI tests above drive the overlay; these drive the functions under it, where the
    # numbers are actually computed and where a wrong one would be invisible on screen.

    # A status line as the TUI actually pads it: U+00A0, not spaces. Every shell-native
    # attempt at this returns empty, which a caller renders as a confident "?" — a read that
    # never verifies anything. Locked here so a "simplification" cannot quietly reintroduce it.
    nbsp = "Model: Opus 5  Thinking: xhigh"
    ok("the status line parses through NBSP padding",
       fleet_tui.parse_status_text(nbsp) == ("Opus", "xhigh"),
       fleet_tui.parse_status_text(nbsp))
    ok("…and a pane with no status line yields ? rather than a guess",
       fleet_tui.parse_status_text("just some scrollback") == ("?", "?"))

    # ── "last active", and where the transcript it measures comes from ──────────────────
    # The resolution has to agree with agent-fanout.sh's, because both claim to name THE
    # transcript of a given agent; if they disagree, one of them is describing a different
    # session and nothing on screen says which.
    with tempfile.TemporaryDirectory() as td:
        home = os.path.join(td, "home")
        agents = os.path.join(home, ".claude", "agents")
        projects = os.path.join(home, ".claude", "projects")
        os.makedirs(agents)
        cwd = os.path.join(td, "lanes", "feature-9")
        pdir = os.path.join(projects, _agent_facts.re.sub(r"[^A-Za-z0-9]", "-", cwd))
        os.makedirs(pdir)
        exact = os.path.join(pdir, "exact.jsonl")
        newest = os.path.join(pdir, "newest.jsonl")
        for p in (exact, newest):
            open(p, "w").close()
        os.utime(exact, (1, 1))          # older, so "newest file" would NOT pick it

        real_expand = os.path.expanduser
        _agent_facts.os.path.expanduser = lambda p: p.replace("~", home, 1)
        try:
            with open(os.path.join(agents, "feature-9.transcript"), "w") as fh:
                fh.write(exact + "\n")
            ok("the recorded transcript sidecar wins — a cwd can host several sessions",
               _agent_facts.agent_transcript("feature-9", cwd) == exact,
               _agent_facts.agent_transcript("feature-9", cwd))

            # A sidecar naming a file that is gone is not an answer; the cwd still is.
            with open(os.path.join(agents, "feature-9.transcript"), "w") as fh:
                fh.write(os.path.join(pdir, "vanished.jsonl") + "\n")
            ok("…a sidecar pointing at a missing file falls through to the cwd",
               _agent_facts.agent_transcript("feature-9", cwd) == newest,
               _agent_facts.agent_transcript("feature-9", cwd))

            # The recorded cwd is the second key, and it must beat the caller's — that is the
            # case where the caller has no cwd at all.
            os.remove(os.path.join(agents, "feature-9.transcript"))
            with open(os.path.join(agents, "feature-9.cwd"), "w") as fh:
                fh.write(cwd + "\n")
            ok("…then the recorded cwd, so an agent with no path passed still resolves",
               _agent_facts.agent_transcript("feature-9", "") == newest,
               _agent_facts.agent_transcript("feature-9", ""))

            ok("an agent with no sidecars and no cwd resolves to nothing, not a guess",
               _agent_facts.agent_transcript("never-booted", "") == "")
        finally:
            _agent_facts.os.path.expanduser = real_expand

        now = time.time()
        os.utime(newest, (now - 300, now - 300))
        secs = _agent_facts.last_active(newest)
        ok("last_active measures the transcript's mtime, in seconds",
           secs is not None and 295 <= secs <= 305, secs)
        ok("…and an unresolvable transcript yields None rather than 0 — 'unknown' is not 'now'",
           _agent_facts.last_active("") is None
           and _agent_facts.last_active(os.path.join(td, "nope.jsonl")) is None)

    # fmt_ago is NEVER empty for a known value, unlike fmt_age: the field's whole purpose is
    # that it is always there, so silence must mean "no transcript" and nothing else.
    ok("recent activity is coarse but never silent",
       (fleet_tui.fmt_ago(0), fleet_tui.fmt_ago(59), fleet_tui.fmt_ago(420),
        fleet_tui.fmt_ago(3 * 3600), fleet_tui.fmt_ago(4 * 86400))
       == ("<1m", "<1m", "7m", "3h", "4d"))
    ok("…and only an unknown value is silent", fleet_tui.fmt_ago(None) == "")

    ok("lane numbers match agent-tune's mapping, so the override shown is the one it reads",
       (fleet_tui.lane_num_of("team-lead"), fleet_tui.lane_num_of("feature-3"),
        fleet_tui.lane_num_of("rev-a")) == (0, 3, None))

    # Validation: the whole safety claim of the editor. Empty must be ENTERABLE — it is how
    # an override is cleared — while anything outside the vocabulary must be refused.
    ok("empty is a valid value for both kinds — it means inherit",
       fleet_tui.valid_value("effort", "") and fleet_tui.valid_value("model", ""))
    ok("every allowed effort and model is accepted",
       all(fleet_tui.valid_value("effort", v) for v in fleet_tui.VALID_EFFORT)
       and all(fleet_tui.valid_value("model", v) for v in fleet_tui.VALID_MODEL))
    ok("…and nothing else is",
       not any(fleet_tui.valid_value("effort", v)
               for v in ("sonnet", "LOW", "medium ", "high; rm -rf /", "$(id)"))
       and not any(fleet_tui.valid_value("model", v) for v in ("xhigh", "opus[1m]", "gpt")))
    try:
        fleet_tui.write_config_value("/tmp/never-written", "WORKFLOW_LANE_MODEL",
                                     "model", "; rm -rf /")
        ok("a rejected value cannot be written even by calling the writer directly", False)
    except ValueError:
        ok("a rejected value cannot be written even by calling the writer directly",
           not os.path.exists("/tmp/never-written"))

    with tempfile.TemporaryDirectory() as td:
        # ── the config layer ─────────────────────────────────────────────────────────────
        cfg = os.path.join(td, "workflow.config.local")
        with open(cfg, "w") as fh:
            fh.write("# a header comment\n"
                     "\n"
                     'WORKFLOW_TODO_NS="jn"\n'
                     'WORKFLOW_LANE_EFFORT="high"   # why it is high\n'
                     "WORKFLOW_LANE_MODEL=sonnet\n"
                     'export WORKFLOW_TEST_EFFORT="low"\n'
                     '#   WORKFLOW_PLAN_MODEL="opus"\n')
        got = fleet_tui.read_shell_config(cfg)
        ok("quoted, bare and exported assignments all read the same",
           (got["WORKFLOW_TODO_NS"], got["WORKFLOW_LANE_MODEL"], got["WORKFLOW_TEST_EFFORT"])
           == ("jn", "sonnet", "low"), got)
        ok("…an inline comment is not part of the value",
           got["WORKFLOW_LANE_EFFORT"] == "high", repr(got.get("WORKFLOW_LANE_EFFORT")))
        ok("…and a commented-out assignment is not a value at all",
           "WORKFLOW_PLAN_MODEL" not in got, got)

        fleet_tui.write_config_value(cfg, "WORKFLOW_LANE_EFFORT", "effort", "xhigh")
        fleet_tui.write_config_value(cfg, "WORKFLOW_REVIEW_MODEL_A", "model", "fable")
        body = open(cfg).read()
        ok("a rewrite replaces the value in place", 'WORKFLOW_LANE_EFFORT="xhigh"' in body,
           body)
        ok("…keeping the comment that explained it — an edit must not eat the reason",
           "# why it is high" in body, body)
        ok("…and every unrelated line, comment and blank",
           "# a header comment" in body and 'WORKFLOW_TODO_NS="jn"' in body
           and '#   WORKFLOW_PLAN_MODEL="opus"' in body, body)
        ok("a key that was not there is appended rather than lost",
           'WORKFLOW_REVIEW_MODEL_A="fable"' in body, body)
        ok("…exactly once", body.count("WORKFLOW_LANE_EFFORT=") == 1, body)

        # A local file that does not exist yet is CREATED — a fresh clone has none, and an
        # edit that silently no-ops there would look identical to one that worked.
        fresh = os.path.join(td, "made", "workflow.config.local")
        os.makedirs(os.path.dirname(fresh))
        fleet_tui.write_config_value(fresh, "WORKFLOW_LANE_MODEL", "model", "opus")
        ok("a missing local config is created rather than the edit being dropped",
           fleet_tui.read_shell_config(fresh)["WORKFLOW_LANE_MODEL"] == "opus")

        # ── git numbers, from a real scratch repo ─────────────────────────────────────────
        # GIT_DIR is UNSET for every command here: this suite may run inside a hook or a
        # worktree that exports it, and a scratch repo that silently operated on the caller's
        # real repository is the one failure mode a git test must not have.
        import subprocess as sp
        env = {k: v for k, v in os.environ.items()
               if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
        repo = os.path.join(td, "repo")
        os.makedirs(repo)

        def git(*args):
            return sp.run(["git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t",
                           "-c", "commit.gpgsign=false"] + list(args),
                          capture_output=True, text=True, env=env)

        def commit(msg):
            with open(os.path.join(repo, msg), "w") as fh:
                fh.write(msg)
            git("add", "-A")
            git("commit", "-m", msg)

        git("init", "-b", "master")
        commit("a")
        git("checkout", "-b", "work")
        commit("b")
        commit("c")
        git("checkout", "master")
        commit("d")
        git("checkout", "work")
        state = fleet_tui.git_state(repo, "master")
        ok("the branch is read from git's own files", state["branch"] == "work", state)
        ok("ahead/behind is (ahead, behind) against the local base — never the two swapped",
           state["local"] == (2, 1), state["local"])
        ok("a clean tree reports zero dirty files, not None", state["dirty"] == 0, state)
        ok("with no origin/master fetched, the origin row is EMPTY rather than a fake 0/0 — "
           "'no ref' and 'level with it' are different facts",
           state["origin"] is None, state["origin"])

        with open(os.path.join(repo, "scratch"), "w") as fh:
            fh.write("uncommitted")
        ok("an untracked file counts as dirt",
           fleet_tui.git_state(repo, "master")["dirty"] == 1)

        # A real origin, so the second row is exercised on a ref that exists.
        origin = os.path.join(td, "origin.git")
        sp.run(["git", "clone", "--bare", repo, origin], capture_output=True, env=env)
        git("remote", "add", "origin", origin)
        git("fetch", "-q", "origin")
        state = fleet_tui.git_state(repo, "master")
        ok("with the ref present, the origin row carries real numbers",
           state["origin"] == (2, 1), state["origin"])

        # A path that is not a repo at all — a lane can be a bare directory, and the overlay
        # still has to open on it rather than throwing.
        plain = os.path.join(td, "notarepo")
        os.makedirs(plain)
        ok("a non-repo path yields empties instead of an exception",
           fleet_tui.git_state(plain) == {"base": "master", "branch": "", "dirty": None,
                                          "local": None, "origin": None},
           fleet_tui.git_state(plain))

    print("\n  %d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    print("fleet_tui.py")
    sys.exit(asyncio.run(main()))
