# /// script
# requires-python = ">=3.11"
# dependencies = ["textual>=8,<9"]
# ///
"""Headless tests for fleet_tui.py.  Run: uv run ~/.claude/scripts/fleet-tui.test.py

Hermetic: the fleet snapshot is stubbed and the ask files live in a temp dir, so nothing here
reads or writes the live fleet.

What it locks in — each is a way this view could lie or lose work:
  - a lane renders its status and its asks, and the asks are TYPED by their kind token
  - `x` removes the ask from the FILE, not merely from the screen
  - `u` puts it back — an accidental keypress on the user's to-do list must be recoverable
  - an unchanged snapshot does not rebuild the lists, so the cursor survives a refresh
  - the FLEET panel is as tall as the agents in it — at startup, and again whenever one
    arrives or leaves — without ever pushing the NEEDS YOU panel off the screen
"""

import asyncio
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_tui  # noqa: E402
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
            "ask_path": ask_path, "raw_asks": fleet_tui._ask_lines(ask_path),
        }
        extra = [dict(base, name="extra-%d" % i, label="e%d" % i, issue_links=[],
                      status="", raw_asks=[]) for i in range(roster["extra"])]
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
        ok("…and NEEDS YOU takes every row it does not need",
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

        # More agents than the terminal has rows: the panel stops at NEEDS YOU's floor
        # instead of pushing it off the bottom of the screen.
        roster["extra"] = 20
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a fleet taller than the terminal stops at the NEEDS YOU floor",
           panel_rows() == panels.size.height - fleet_tui.FLEET_MIN, panel_rows())
        ok("…so NEEDS YOU is still on screen rather than pushed off it",
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
        ok("a run of + cannot push NEEDS YOU off the bottom",
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

    # ── a lane's open PR, beside its ticket ──────────────────────────────────────────────
    # Driven against Lane.pr_markup directly rather than restarting the app three times. The
    # two cases that could LIE are the ones worth locking: a PR shown for a lane that has
    # none, and a draft presented as if it were ready to merge.
    lane_row = {"name": "feature-1", "label": "vii", "state": "idle", "kind": "lane"}
    mk = fleet_tui.Lane.pr_markup

    class _R:
        def __init__(self, row):
            self.row = row

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

    print("\n  %d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    print("fleet_tui.py")
    sys.exit(asyncio.run(main()))
