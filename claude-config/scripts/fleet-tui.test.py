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
  - …and it shows the agent's update IN FULL — the snapshot's 60-char clip is the column's
    constraint, and the dialog goes back to the file rather than trying to widen bytes that
    no longer exist
  - the overlay RE-READS ITSELF on the same tick the panel does, so `r` and a resize reflow it
    instead of leaving a snapshot of the moment enter was pressed
  - nothing unlabelled sits where a number is expected: a tmux pane id (`%182`) beside
    `effort=xhigh` was read as a percentage, so every pane id wears its label and the one real
    percentage on that line is the LIST view's gauge, labelled `context`
  - `r` REACHES THE DATA SOURCE — asserted on the key, not on the method under it, because a
    key that does nothing is exactly what a user cannot distinguish from a quiet fleet
  - …and forces the one fact behind a cache (the PR list), which the timer still serves cached
  - …and the header carries a `refreshed HH:MM:SS` that moves when data LANDS, goes loud when
    three ticks bring nothing, and has its own clock so that state can draw itself at all
  - the fleet's STANDING GOAL is on the header while one is set, re-read on the same tick as
    everything else, and occupies no row at all when no goal file exists
  - enter on a 4ME row opens THAT ASK, not whatever lane the other panel was left on — and
    shows it in full, since the snapshot carries it clipped at sixty characters
  - …with its bracket trailers as labelled fields, hidden from the row, unknown keys kept,
    and a marker when the standing goal names the same ticket
  - …and prose containing a bracketed id renders instead of taking the whole app down
"""

import asyncio
import json
import os
import re
import sys
import tempfile
import time
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_tui  # noqa: E402
import _agent_facts  # noqa: E402
# The threshold by NAME, not a literal: a test that hard-codes 7200 goes on passing after
# someone retunes the constant, while asserting about a boundary that no longer exists.
from _agent_facts import ASK_KINDS, STATUS_STALE_AFTER, ask_deferral  # noqa: E402
from rich.cells import cell_len  # noqa: E402
from textual.events import Key  # noqa: E402
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
    # The standing goal sits beside the fleet ask list, and starts ABSENT: no goal is the
    # ordinary state of a fleet, and the view has to render it as nothing at all.
    goal_path = os.path.join(tmp, "fleet-goal")
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
        # Whether this lane has a review staged for the user — the fact ctrl+click acts on.
        # snapshot() reads it from the lane's flag file; the fixture sets it directly, since
        # what is under test here is what the ROW does with it.
        "review": None,
        # Whether this lane's monocle predates the binary on disk. Volatile because it flips
        # the moment someone rebuilds monocle, with nothing about the lane itself changing.
        "monocle_stale": None,
    }

    # The roster the SIZING tests drive: how many agents beyond the fixture lane, and whether
    # that lane is there at all — a fleet can be empty, and the panel still has to be a panel.
    roster = {"extra": 0, "base": True, "subs": []}

    # Every call to the data source, counted. `r` had never been tested as a KEY — only
    # app.load() was, which cannot fail the way the user suspected it was failing.
    calls = {"snapshot": 0, "prs": []}

    # LANES WITH A REVIEW STAGED. Their 4ME rows are SYNTHESISED on every call, exactly as
    # snapshot() synthesises them, rather than written into the ask file — because that is
    # the whole nature of a derived row and a fixture that faked one as a file line would be
    # testing a row that cannot exist. It also means retiring a flag makes the row disappear
    # here for the same reason it does in the fleet: nothing re-reads it into being.
    staged_lanes = []

    def _derived_rows():
        rows = []
        for lp in staged_lanes:
            rv = fleet_tui.staged_review(
                os.path.join(lp, ".claude", fleet_tui.REVIEW_FILE))
            if rv:
                rows.append({"name": os.path.basename(lp), "label": "jaa",
                             "path": lp, "review": rv})
        return fleet_tui._review_asks(rows)

    def fake_snapshot():
        calls["snapshot"] += 1
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
            "review": volatile["review"],
            "monocle_stale": volatile["monocle_stale"],
        }
        extra = [dict(base, name="extra-%d" % i, label="e%d" % i, issue_links=[],
                      status="", raw_asks=[], open_prs=[])
                 for i in range(roster["extra"])]
        return {
            "lanes": ([base] if roster["base"] else []) + extra,
            "subs": list(roster["subs"]),
            # SORTED, exactly as the real snapshot() sorts — oldest `[added:]` first. A
            # fixture that skipped the sort would let the panel's ordering go untested while
            # every row-level assertion still passed.
            "fleet": sorted(fleet_tui._ask_lines(fleet_path) + _derived_rows(),
                            key=fleet_tui.ask_sort_key),
            "fleet_path": fleet_path,
            # Read through the REAL reader on every call, exactly as snapshot() does, so the
            # "a goal edited mid-session lands on the next tick" assertion is testing the
            # re-read rather than a value the fixture happened to hold.
            "goal": fleet_tui.fleet_goal(goal_path)[0],
            "goal_chain": fleet_tui.fleet_goal(goal_path)[1],
            # The goal rides in `ctx` TOO, because `ctx` is what reaches the row renderers
            # and the 🎯 marker is drawn on the row, not only in the dialog.
            "ctx": {"linear_base": "https://linear.app/acme",
                    "goal": fleet_tui.fleet_goal(goal_path)[0],
                    "goal_chain": fleet_tui.fleet_goal(goal_path)[1],
                    "repo": "https://github.com/acme/goals"},
            "error": "",
        }

    fleet_tui.snapshot = fake_snapshot
    # The PR fetch is a `gh` subprocess. Recorded rather than run — and the max_age it is
    # called WITH is the fact under test, since that argument is the whole difference between
    # an explicit refresh and a tick.
    fleet_tui.refresh_open_prs = lambda path, max_age=None: calls["prs"].append(max_age)

    # The clock, held still. Every assertion about a refresh indicator is an assertion about a
    # clock; reading the real one could only check that SOMETHING was printed.
    clock = {"t": 1_700_000_000.0}
    fleet_tui._now = lambda: clock["t"]

    app = fleet_tui.FleetTUI(interval=3600)     # no timer refresh; the tests drive it
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.pause()
        text = screen_text(app)

        # THE STATUS LINE IS GONE (John 2026-08-14). The row is one line — head only — and the
        # agent-written prose lives in the detail dialog, which is the only place it is shown.
        ok("the lane row does NOT carry the status prose",
           "uncommitted" not in text, text)
        ok("…nor the agent's last-active clock, which travelled with it",
           "active " not in text, text)
        # The id inside it is a link by now, so match around it rather than through it.
        ok("a review: ask carries the review glyph", "🔍 the [link=" in text, text)
        ok("…and the words after the linked id survive", "[/link] diff" in text, text)
        ok("an untyped ask is a general action item", "✅ something untyped" in text, text)
        ok("the kind token is consumed, not printed", "review:" not in text, text)
        ok("the header counts every ask", "3 needs you" in text, text)
        # A GAP THE GLYPH CANNOT SWALLOW. The umbrella is the VS16 emoji form, which the
        # terminal draws double-width in one cell, so the single space that used to follow it
        # rendered as none and the count read as part of the glyph.
        ok("…with a gap after the umbrella, which is drawn double-width",
           "%s  3 needs you" % fleet_tui.ASK
           in str(app.query_one("#head", Static).content),
           str(app.query_one("#head", Static).content))

        # ── the panel the user calls "4me", and the numbers they call its rows by ─────────
        # "4me 1" is only unambiguous if the row wears the 1. The panel's own title carries
        # the count, so the label and the numbering are one contract, tested together.
        ok("the fleet-level panel is titled 4ME, with its count",
           app.query_one("#fleet").border_title == "4ME  (1)  ↓latest",
           app.query_one("#fleet").border_title)
        ok("…and its rows are numbered, so \"4me 1\" resolves to a row",
           "[dim] 1[/]" in text, text)

        # ── linking, everywhere an id appears ────────────────────────────────────────────
        ok("the ticket column links to the URL the tracker gave",
           "[link='https://example.invalid/DX-6']DX-6[/link]" in text, text)
        ok("a ticket id inside an ASK is linked too",
           "[link='linear://acme/issue/DX-6']DX-6[/link]" in text, text)
        ok("a ticket id that appears ONLY in a status reaches no row — the line is gone",
           text.count("[link='linear://acme/issue/SRV-11']SRV-11[/link]") == 0, text)
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
        ok("…and does not reach the row at all", 
           "now something else entirely" not in screen_text(app), screen_text(app))
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
        # THE FIX FOR IT IS NOW REMOVAL, not decoration: a four-day-old claim cannot mislead
        # from a row that never shows it. The age marker still exists for the detail dialog.
        ok("a stale status reaches neither the row nor its age marker",
           "(4d old)" not in screen_text(app)
           and "awaiting your merge" not in screen_text(app), screen_text(app))
        ok("…and the snapshot change still lands without a rebuild",
           lanes.children[0] is before)

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

        # ── the refresh indicator, and whether `r` refreshes at all ──────────────────────
        # THE KEY ITSELF WAS NEVER TESTED. Every refresh assertion above calls app.load()
        # directly, which cannot fail the way a user suspects a key is failing — and with
        # nothing on screen moving when a fleet is quiet, a working `r` and a dead one look
        # identical. So: the key reaches the data source, and the screen says it did.
        n0, t0 = calls["snapshot"], clock["t"]
        head_before = str(app.query_one("#head", Static).content)
        clock["t"] += 5
        app.query_one("#lanes", ListView).focus()
        await pilot.press("r")
        for _ in range(4):
            await pilot.pause()
        ok("r actually re-reads the data source — the KEY, not just the method under it",
           calls["snapshot"] == n0 + 1, (n0, calls["snapshot"]))
        head_after = str(app.query_one("#head", Static).content)
        ok("…and the panel says so with a timestamp that MOVED",
           "refreshed " in head_after and head_after != head_before,
           (head_before, head_after))
        ok("…which is the time the data landed, not the time the key was pressed",
           time.strftime("%H:%M:%S", time.localtime(t0 + 5)) in head_after, head_after)

        # THE ONE FACT `r` COULD NOT REFRESH. The PR list comes from a `gh` call behind a
        # three-minute cache, so an explicit refresh used to return the cached answer — which
        # is exactly the field a user pressing `r` is most often asking about.
        ok("an explicit r forces the PR fetch past its cache age",
           calls["prs"][-1:] == [0], calls["prs"])
        calls["prs"].clear()
        app.load()
        for _ in range(4):
            await pilot.pause()
        ok("…while the timer keeps the cache, so the tick never waits on the network",
           0 not in calls["prs"], calls["prs"])

        # The three states, at the level they are decided. A view that has stopped refreshing
        # is NOT staleness — it is a broken view, and it is the whole reason the indicator is
        # on screen, so it must not whisper in the same dim grey as a healthy stamp.
        landed = fleet_tui.refresh_markup(t0, False, 5, now=t0 + 1)
        ok("a fresh landing is a quiet timestamp", landed.startswith("[dim]refreshed "), landed)
        inflight = fleet_tui.refresh_markup(t0, True, 5, now=t0 + 1)
        ok("…a request in flight says so, while still naming the last one it landed",
           "refreshing…" in inflight and "last " in inflight, inflight)
        dead = fleet_tui.refresh_markup(t0, False, 20, now=t0 + 3 * 20 + 1)
        ok("…and three ticks with nothing arriving is a LOUD failure, not a dim one",
           "NOT REFRESHING" in dead and "[b yellow]" in dead, dead)
        ok("…but a single slow tick is not accused of anything",
           fleet_tui.refresh_markup(t0, False, 20, now=t0 + 21).startswith("[dim]"),
           fleet_tui.refresh_markup(t0, False, 20, now=t0 + 21))
        # The floor, which is what actually decides at the default five-second interval:
        # three ticks there is fifteen seconds, and accusing the view of being dead every
        # time `gh` takes a moment would train the reader to ignore the one loud thing here.
        ok("…and a fast interval does not cry wolf on ordinary jitter",
           fleet_tui.refresh_markup(t0, False, 5, now=t0 + 29).startswith("[dim]"),
           fleet_tui.refresh_markup(t0, False, 5, now=t0 + 29))
        ok("…though it still gives up eventually",
           "NOT REFRESHING" in fleet_tui.refresh_markup(t0, False, 5, now=t0 + 31),
           fleet_tui.refresh_markup(t0, False, 5, now=t0 + 31))
        ok("before anything has landed the panel admits it, rather than showing a fake time",
           fleet_tui.refresh_markup(None, False, 5, now=t0) == "[dim]no data yet[/]")

        # …AND IT NEEDS ITS OWN TIMER TO SAY SO. The header is otherwise repainted only when
        # data arrives, so without a clock of its own the one state this indicator exists to
        # report — nothing is arriving — is the one state it could never draw. Asserted on the
        # registered timer rather than by sleeping, which would make the suite slow and flaky.
        ticks = {(getattr(t, "_callback", None), getattr(t, "_interval", None))
                 for t in getattr(app, "_timers", ())}
        ok("the indicator has a clock of its own, independent of the data tick",
           (app.update_head, 1.0) in ticks and (app.reload, app.interval) in ticks, ticks)

        # The indicator has to REPAINT ITSELF, not wait for data — the state it exists to
        # report is precisely the state in which no data is coming.
        # The app under test runs a 3600s interval so no timer fires mid-test; the threshold
        # is three of those, so the interval is what has to move for this to be reachable.
        app.interval, n_before = 20, calls["snapshot"]
        clock["t"] += 3600
        app.update_head()
        ok("the stale marker appears without any snapshot arriving to draw it",
           "NOT REFRESHING" in str(app.query_one("#head", Static).content)
           and calls["snapshot"] == n_before,
           (str(app.query_one("#head", Static).content), n_before, calls["snapshot"]))
        app.interval = 3600
        app.load()
        for _ in range(4):
            await pilot.pause()
        ok("…and clears the moment one does",
           "NOT REFRESHING" not in str(app.query_one("#head", Static).content))

        # ── the standing goal ────────────────────────────────────────────────────────────
        # The one line that says what everything else on the screen is FOR. Three properties,
        # and the absent case is the one worth guarding: a fleet with no goal is ordinary, so
        # a permanent row saying "no goal" would spend screen to say nothing — and, worse,
        # would make the presence of a goal indistinguishable at a glance from its absence.
        goal_w = app.query_one("#goal", Static)
        ok("with no goal file there is no goal line at all",
           str(goal_w.content) == "" and not goal_w.has_class("-show"),
           (str(goal_w.content), goal_w.classes))

        with open(goal_path, "w") as f:
            f.write("ship DX-6 end to end\n# a comment\ndepends: SRV-11 merged\n")
        app.load()
        for _ in range(4):
            await pilot.pause()
        # The id inside it is a link by now — the goal names tickets like every other line on
        # this screen does, so it is linkified too. Match around the link, not through it.
        ok("a goal file puts the objective on the header",
           "ship [link='linear://acme/issue/DX-6']DX-6[/link] end to end"
           in str(goal_w.content), str(goal_w.content))
        ok("…in the goal line specifically, which is now shown",
           goal_w.has_class("-show") and "GOAL" in str(goal_w.content),
           (str(goal_w.content), goal_w.classes))
        ok("…and only the one-liner — the chain below it is not header material",
           "SRV-11 merged" not in str(goal_w.content), str(goal_w.content))

        # RE-READ ON THE TICK, not at startup. A goal the lead rewrites mid-session must not
        # need a restart to stop pointing the fleet at the old objective.
        with open(goal_path, "w") as f:
            f.write("cut the release\n")
        app.load()
        for _ in range(4):
            await pilot.pause()
        ok("a rewritten goal lands on the next refresh",
           "cut the release" in str(goal_w.content)
           and "ship DX-6" not in str(goal_w.content), str(goal_w.content))

        os.remove(goal_path)
        app.load()
        for _ in range(4):
            await pilot.pause()
        ok("…and clearing the goal takes the line away again",
           str(goal_w.content) == "" and not goal_w.has_class("-show"),
           (str(goal_w.content), goal_w.classes))

        # The reader itself, at the level the file format is decided: line 1 is the objective,
        # everything under it is the chain, and comments and blanks are annotation.
        with open(goal_path, "w") as f:
            f.write("\n# heading\nland the migration\n\nneeds: SRV-11\nthen: SRV-12\n")
        ok("the goal file is (objective, chain) with comments and blanks skipped",
           fleet_tui.fleet_goal(goal_path)
           == ("land the migration", ["needs: SRV-11", "then: SRV-12"]),
           fleet_tui.fleet_goal(goal_path))
        ok("a missing goal file is empty, not an exception",
           fleet_tui.fleet_goal(os.path.join(tmp, "nope")) == ("", []))
        # The goal belongs to the FLEET, so it sits beside the fleet ask list rather than in a
        # lane — the same placement rule, resolved by the same kind of walk.
        ok("the goal file sits beside needs-input-fleet",
           fleet_tui.fleet_goal_path(os.path.join(tmp, "lanes")) == goal_path,
           fleet_tui.fleet_goal_path(os.path.join(tmp, "lanes")))
        ok("…and no lanes dir names no goal file, rather than one in the cwd",
           fleet_tui.fleet_goal_path("") == "")
        os.remove(goal_path)

        # THE OTHER CLOCK travelled with the status line and left the row with it: the row's
        # own uptime and state say whether a lane is alive, and the detail dialog keeps
        # `active Xm ago` for the reader who opens it. The FIELD must still be collected —
        # deleting the render must not quietly kill the data the dialog reads.
        ok("no last-active clock on the row",
           "active 2m ago" not in screen_text(app), screen_text(app))
        volatile["last_active"] = 3 * 3600
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("…and a lane gone quiet for hours still does not say so on the row",
           "active 3h ago" not in screen_text(app) and lanes.children[0] is before,
           screen_text(app))
        ok("…while the value itself is still carried in the snapshot for the dialog",
           fleet_tui.fmt_ago(3 * 3600) == "3h", fleet_tui.fmt_ago(3 * 3600))
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

        # ── THE WRAP REGRESSION: a counted row is not a drawn row ────────────────────────
        # `=` broke without a single test reddening, because every fixture here was WIDER
        # than its content. Live, the fleet runs in a 72-column tmux pane, and a lane row can
        # still outrun it — the head line carries a ticket column and every open PR. A lane
        # that then draws two rows where the arithmetic counts one leaves the panel short and
        # `=` saying "all 5 visible" over a list that scrolled.
        #
        # So the assertion is COUNTED-VS-MEASURED at a width narrow enough to wrap. It is
        # not a restatement of the arithmetic: content_rows() is what Textual laid out, and
        # nothing under test contributes to it.
        # THE WRAPPING LINE IS NOW THE HEAD, since the status line was removed — and the PR
        # list is the part of it that grows, which is also the part that is line-confined and
        # so must move the panel WITHOUT a rebuild.
        short_prs = volatile["prs"]
        volatile["prs"] = [(130 + i, "https://gh/x/pull/%d" % (130 + i), False)
                           for i in range(6)]
        # TALL ENOUGH THAT THE FIT IS THE FIT. A 24-row terminal leaves the panel clamped at
        # 4ME's floor, and a clamped panel cannot show a growth — the assertion below would
        # pass on a panel that never moved.
        await pilot.resize_terminal(66, 32)
        app.load()
        await pilot.pause()
        await pilot.pause()
        narrow_w = app._width()
        counted = fleet_tui.fit_height(app._rows(), narrow_w, app.data.get("ctx"))
        ok("in a pane too narrow for the head line, the fit counts the WRAPPED rows",
           counted == content_rows() + fleet_tui.PANEL_BORDER,
           "counted %d, drawn %d (+border), width %d"
           % (counted, content_rows(), narrow_w))
        ok("…and that is strictly more than the unwrapped count — the fixture really wraps",
           counted > fleet_tui.PANEL_BORDER
           + sum(fleet_tui.ITEM_ROWS + len(r.get("raw_asks") or [])
                 for r in app._rows()),
           counted)
        ok("…and the panel drawn is that wrapped fit, clamped only by 4ME's floor",
           panel_rows() == min(counted, panels.size.height - fleet_tui.FLEET_MIN),
           "panel %d, counted %d, avail %d"
           % (panel_rows(), counted, panels.size.height))

        # THE HEAD LINE IS PART OF THE HEIGHT, and its PR list is not part of the rebuild
        # signature — PRs move on ticks nobody wants a rebuild for. So a head that grows past
        # its column has to move the panel down the NO-REBUILD path, or the panel keeps a
        # height that was right for the shorter line.
        before_item = lanes.children[0]
        grew_from = panel_rows()
        volatile["prs"] = [(130 + i, "https://gh/x/pull/%d" % (130 + i), False)
                           for i in range(26)]
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("a head that grows past its column grows the panel, without a rebuild",
           panel_rows() > grew_from and lanes.children[0] is before_item,
           "panel %d, was %d" % (panel_rows(), grew_from))
        ok("…and the grown panel still matches what was drawn",
           panel_rows() == content_rows() + fleet_tui.PANEL_BORDER,
           "panel %d, content %d" % (panel_rows(), content_rows()))

        # The width the counting uses is the panel's OUTER width, which a scrollbar cannot
        # move. Sizing off the content width would let a short fit summon a scrollbar, the
        # scrollbar narrow the text, the narrower text want more rows — a loop that settles
        # at a different height depending on which frame you look at.
        ok("the fit's width is the outer one, so a scrollbar cannot feed back into it",
           narrow_w == app.query_one("#lanes").outer_size.width
           and fleet_tui.text_width(narrow_w)
           == narrow_w - fleet_tui.PANEL_BORDER - fleet_tui.PANEL_PAD,
           narrow_w)
        ok("…and a CLIPPED list is counted two columns narrower still, per panel chrome",
           fleet_tui.text_width(narrow_w, fleet_tui.CLIPPED_RESERVE)
           == fleet_tui.text_width(narrow_w) - fleet_tui.SCROLLBAR
           - fleet_tui.CURSOR_GUTTER,
           fleet_tui.text_width(narrow_w, fleet_tui.CLIPPED_RESERVE))

        # A wrapped list that does NOT fit must be reported as partly shown. This is the
        # half the user actually saw: `=` claiming a fit over a list it had just clipped.
        #
        # THE ROSTER IS OVERSIZED ON PURPOSE. At 5 extras the list overflowed by a single row,
        # so the row asserted a real property from a fixture that only just satisfied it —
        # one card growing a line (fixed-width columns did exactly that) flipped it to a
        # legitimate fit and reddened a row about clipping. 14 cards in a panel that can hold
        # at most 26 content rows overflows by a margin no layout tweak closes.
        roster["extra"] = 13
        app.load()
        await pilot.pause()
        await pilot.pause()
        note = app._fit_note(app._fit_lanes())
        ok("= does not claim a fit for wrapped rows it had to clip",
           "the rest scroll" in note
           and fleet_tui.visible_items(
               [fleet_tui.lane_rows(r, narrow_w, app.data.get("ctx"),
                                    fleet_tui.CLIPPED_RESERVE)
                for r in app._rows()],
               panel_rows() - fleet_tui.PANEL_BORDER) < len(app._rows()),
           note)
        volatile["prs"] = short_prs
        roster["extra"] = 0
        await pilot.resize_terminal(80, 24)
        app.load()
        await pilot.pause()
        await pilot.pause()
        ok("…and a pane wide enough for every line is back to the unwrapped fit",
           panel_rows() == fitted, "%d vs %d" % (panel_rows(), fitted))

        # The row arithmetic on its own, away from any terminal: one line per line, until a
        # line is too long for its column.
        # The head is kept short here: a unit test of the arithmetic wants ONE variable in
        # the card, and that variable is the ask.
        wide_row = {"name": "n", "label": "l", "state": "idle", "raw_asks": []}
        ok("with no width known, a card counts its lines unwrapped",
           fleet_tui.lane_rows(wide_row) == fleet_tui.ITEM_ROWS,
           fleet_tui.lane_rows(wide_row))
        # An unbreakable 200-character token has no word boundary to wrap at, so the row count
        # it costs is stateable without borrowing the wrapper under test: the ask is clipped
        # to LINE_MAX at render, the glyph keeps the first row to itself because a word longer
        # than the column cannot start on it, and the rest is plain division.
        col = fleet_tui.text_width(60) - fleet_tui.LANE_INDENT
        clipped = len(fleet_tui.clip("x" * 200))
        ok("…and an ask too long for the column costs the card the rows it overflows by",
           fleet_tui.lane_rows(dict(wide_row, raw_asks=["x" * 200]), 60)
           == fleet_tui.ITEM_ROWS + 1 + -(-clipped // col),
           (fleet_tui.lane_rows(dict(wide_row, raw_asks=["x" * 200]), 60), col, clipped))
        ok("a 4ME item wraps by the same rule, and an int still counts the old way",
           fleet_tui.asks_fit_height(2) == fleet_tui.PANEL_BORDER + 2 * fleet_tui.ASK_ROWS
           and fleet_tui.asks_fit_height(["todo: " + "y" * 200], 40)
           > fleet_tui.asks_fit_height(["todo: y"], 40),
           (fleet_tui.asks_fit_height(["todo: " + "y" * 200], 40),
            fleet_tui.asks_fit_height(["todo: y"], 40)))

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
        roster["extra"] = 40
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
               (*ASK_KINDS.values(), "●", "◔", "○")), str(legend.content))
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

        # ── t marks a row DONE without deleting it, and can carry a note ──────────────────
        # THE FAILURE THIS CLOSES IS A LIE OF OMISSION. `x` was the only thing the user could
        # do to a row they had already dealt with, so on the lead's next sync a handled ask
        # and an ask nobody had opened were the same thing — an absence — and so was a
        # mis-keyed `x`. `t` writes a POSITIVE mark the lead reads, and the answer with it.
        # The file is restored at the end of the block: later tests own this fixture too.
        fleet_before_mark = open(fleet_path).read()
        # A REAL LANE WITH A REAL FLAG, because `t` on a derived row reaches OUT of the ask
        # file and retires that file — the one action on this panel with an effect outside
        # it, so it is driven end-to-end rather than asserted on intent.
        staged_lane = os.path.join(tmp, "lanes", "feature-9")
        os.makedirs(os.path.join(staged_lane, ".claude"), exist_ok=True)
        staged_flag = os.path.join(staged_lane, ".claude", fleet_tui.REVIEW_FILE)
        with open(staged_flag, "w") as f:
            f.write("UI-4 closing goals\nbase_ref: 3737e63c — THE MERGE BASE, deliberately\n")
        staged_lanes.append(staged_lane)     # synthesised from here on, never a file line
        with open(fleet_path, "w") as f:
            f.write("product: MON-16 — High or Urgent? [MON-16] [added:2026-08-19]\n"
                    "  Urgent was argued from overlapping ticks.\n"
                    "review: woo staged one [derived:staged-review] [added:2026-08-19]\n"
                    "todo: bump the date? [added:2026-08-19]\n"
                    "fleet: push the commits? [added:2026-08-19]\n")
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()

        def ask_row(needle):
            """The panel index of the row carrying `needle` — never a hard-coded number.

            The list is SORTED on its way to the screen, so an index literal would silently
            come to mean a different ask the moment the order or the fixture changed."""
            for i, it in enumerate(fleet.children):
                if isinstance(it, fleet_tui.Ask) and needle in it.raw:
                    return i
            return -1

        note_inp = app.query_one("#note-input", fleet_tui.Input)
        fleet.focus()
        fleet.index = ask_row("MON-16")
        await pilot.pause()
        await pilot.press("t")
        await pilot.pause()
        ok("t opens the note field on the highlighted 4ME row",
           note_inp.has_class("-show") and app.marking is not None)

        # ── EMACS MOTIONS IN THE NOTE FIELD ──────────────────────────────────────────────
        # Only ctrl+f / ctrl+b are ours: textual 8.2.8 already binds ctrl+a home, ctrl+e end,
        # ctrl+d delete-right, ctrl+w delete-word-left, ctrl+u delete-all-left and ctrl+k
        # kill-to-end. The home/end pair is asserted anyway — not to test textual, but because
        # this field is where a user will reach for them, and an upgrade that dropped them
        # would be silent otherwise.
        note_inp.value = "hello world"
        note_inp.cursor_position = 11
        await pilot.pause()
        await pilot.press("ctrl+b")
        await pilot.pause()
        ok("ctrl+b steps the cursor back a character", note_inp.cursor_position == 10,
           note_inp.cursor_position)
        await pilot.press("ctrl+f")
        await pilot.pause()
        ok("…and ctrl+f steps it forward again", note_inp.cursor_position == 11,
           note_inp.cursor_position)
        await pilot.press("ctrl+a")
        await pilot.pause()
        ok("…ctrl+a goes to the start of the line", note_inp.cursor_position == 0,
           note_inp.cursor_position)
        await pilot.press("ctrl+e")
        await pilot.pause()
        ok("…and ctrl+e to the end", note_inp.cursor_position == 11,
           note_inp.cursor_position)

        # THE ONE THAT LOOKS LIKE A COLLISION AND IS NOT. `ctrl+k` is bound at APP level to
        # the tmux pane move; a focused Input consumes it first, so inside this field it
        # kills to end of line and the pane never moves. That ordering is textual's, not
        # ours — which is exactly why it is pinned here: if it ever changes, or if someone
        # rebinds ctrl+k more aggressively, a user loses their half-typed note to a pane jump.
        note_inp.cursor_position = 5
        await pilot.pause()
        await pilot.press("ctrl+k")
        await pilot.pause()
        ok("ctrl+k kills to end of line in the field, and does NOT move the tmux pane",
           note_inp.value == "hello", note_inp.value)
        note_inp.value = ""
        await pilot.pause()
        ok("…and names the row it is about, so the field is never ambiguous",
           "MON-16" in screen_text(app))
        note_inp.value = "approved, ott's version"
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        marked_line = open(fleet_path).read().splitlines()[0]
        ok("enter marks the row done in the FILE — tick first, note on the tail",
           marked_line == "✅ product: MON-16 — High or Urgent? [MON-16] [added:2026-08-19] "
                          "[note:approved, ott's version]", marked_line)
        # THE ROW STAYS. This is the whole difference from `x`, and the reason the count is
        # asserted and not just the text: a mark that also removed the row would pass a
        # "starts with ✅" check on a file it had emptied.
        ok("…and the ask is STILL ON THE LIST — marking is not deleting",
           len(fleet_tui._ask_lines(fleet_path)) == 4,
           fleet_tui._ask_lines(fleet_path))
        ok("…with its context block untouched, since that is what made it answerable",
           "\n  Urgent was argued from overlapping ticks.\n" in open(fleet_path).read())
        ok("…and the field closes and hands the keyboard back to the list",
           not note_inp.has_class("-show") and app.marking is None and fleet.has_focus)

        fleet.index = ask_row("bump the date")
        await pilot.pause()
        await pilot.press("t")
        await pilot.pause()
        await pilot.press("enter")          # submitted EMPTY — a note is optional
        await pilot.pause()
        await pilot.pause()
        plain = [ln for ln in open(fleet_path).read().splitlines() if "bump the date" in ln][0]
        ok("an empty note marks the row done and writes no note trailer at all",
           plain == "✅ todo: bump the date? [added:2026-08-19]", plain)

        # ── a DERIVED row: `t` force-clears it, `x` still will not ───────────────────────
        # A derived row is synthesised from a lane's flag file every tick, so there is no line
        # to delete and `x` is refused. That left NO way off the panel for a review the engine
        # had already resolved — John hit exactly this. `t` clears it by retiring the flag the
        # row is computed from, and demands a note, because when the flag is gone that note is
        # the only surviving answer to "why is this not on the list any more".

        # A derived row that names NO lane is still refused: nothing to retire, so ticking it
        # would be the same empty gesture `x` is refused for. This is the row the old refusal
        # assertion was actually exercising once `t` learned the derived path — kept, and now
        # saying which branch it tests.
        before_derived = open(fleet_path).read()
        fleet.index = ask_row("woo staged one")
        await pilot.pause()
        await pilot.press("t")
        await pilot.pause()
        ok("a derived row naming no lane is refused — there is nothing to retire",
           app.marking is None and not note_inp.has_class("-show")
           and open(fleet_path).read() == before_derived)

        fleet.index = ask_row("jaa has a review staged")
        await pilot.pause()
        await pilot.press("t")
        await pilot.pause()
        ok("t on a derived row that names a lane opens the note field instead of refusing",
           app.marking is not None and note_inp.has_class("-show"))
        ok("…and says the note is REQUIRED, since this one reaches outside the panel",
           "REQUIRED" in screen_text(app), screen_text(app))
        await pilot.press("enter")          # empty — mandatory here, unlike an ordinary row
        await pilot.pause()
        await pilot.pause()
        ok("an EMPTY note is refused on a derived row, and the flag is left staged",
           (app.marking is not None, os.path.exists(staged_flag),
            open(fleet_path).read() == before_derived) == (True, True, True))
        note_inp.value = "approved in monocle round 4; engine lost the stage"
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        ok("…while a note RETIRES the flag, so the row stops being synthesised at source",
           not os.path.exists(staged_flag) and fleet_tui.staged_review(staged_flag) is None)
        cleared_log = open(staged_flag + ".cleared").read()
        ok("…keeping the flag's hand-written content and the note in a log beside it",
           ("base_ref: 3737e63c — THE MERGE BASE, deliberately" in cleared_log
            and "approved in monocle round 4" in cleared_log), cleared_log)
        materialised = [ln for ln in open(fleet_path).read().splitlines()
                        if "jaa" in ln and ln.startswith("✅")][0]
        # THE TICKED ROW IS WRITTEN INTO THE FILE, because a row that merely vanished would
        # be a delete — and the lead would never learn it had been force-cleared, or why.
        ok("…and the row is MATERIALISED into the ask file, ticked, carrying the note",
           dict(fleet_tui.ask_detail(materialised)["trailers"]).get("note")
           == "approved in monocle round 4; engine lost the stage", materialised)
        # THE TRAP THIS AVOIDS: `[derived:]` is exactly what makes `x` refuse a row. A
        # materialised line that kept it would be one the lead could never sweep — a row
        # welded to the panel for good, which is a worse version of the bug being fixed.
        mt = dict(fleet_tui.ask_detail(materialised)["trailers"])
        ok("…with `derived` and `review` STRIPPED, so the lead can sweep it like any other",
           (mt.get("derived"), mt.get("review")) == (None, None), mt)
        fleet.index = ask_row("jaa")
        await pilot.pause()
        await pilot.press("x")
        await pilot.pause()
        await pilot.pause()
        ok("…proved by sweeping it with x, which a derived row refuses",
           "jaa" not in open(fleet_path).read(), open(fleet_path).read())
        # AND IT DOES NOT COME BACK. The row was synthesised from the flag on every tick, so
        # the only proof the clear actually took is that a fresh snapshot no longer produces
        # it — the exact failure John reported was a row that returned every scan.
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()
        ok("…and it is not re-synthesised on the next scan, which is what `x` could never do",
           ask_row("jaa has a review staged") == -1 and "jaa" not in screen_text(app))

        fleet.index = ask_row("MON-16")
        await pilot.pause()
        await pilot.press("t")
        await pilot.pause()
        note_inp.value = "changed my mind"
        await pilot.press("escape")
        await pilot.pause()
        ok("escape abandons the note and writes nothing",
           app.marking is None and not note_inp.has_class("-show")
           and "changed my mind" not in open(fleet_path).read())

        await pilot.press("enter")          # the 4ME overlay, on the row just marked
        await pilot.pause()
        ok("the note is a LABELLED FIELD in the ask dialog, rendered like unblocks",
           "[dim]note      [/] approved, ott's version" in screen_text(app),
           screen_text(app))
        await pilot.press("escape")
        await pilot.pause()

        # `t` WORKS WITH THE 4ME OVERLAY OPEN, UNLIKE `x`, and the row here is TICKETLESS on
        # purpose: `_reaim_ask` falls back to position-and-kind for those, and the mark
        # changes the kind — so without the dialog being told what was written it would
        # report the very ask the user is reading as gone.
        fleet.index = ask_row("push the commits")
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("t")
        await pilot.pause()
        ok("t acts on the ask the 4ME overlay is showing — a mark rewrites it, never removes "
           "it, so there is nothing to hide from the reader",
           app.marking is not None and app.ask is not None)
        note_inp.value = "pushed"
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        pushed = [ln for ln in open(fleet_path).read().splitlines()
                  if "push the commits" in ln][0]
        ok("…and the dialog follows the edit instead of reporting the row gone",
           (pushed, app.ask is not None,
            "(cleared from the list)" in screen_text(app))
           == ("✅ fleet: push the commits? [added:2026-08-19] [note:pushed]", True, False),
           (pushed, app.ask))
        await pilot.press("escape")
        await pilot.pause()

        # THE GUARD ON THE NOTE IS THE READER, NOT A CHARACTER BLACKLIST. A note is a
        # trailer and trailers are eaten RIGHT TO LEFT, so an unmatched bracket does not
        # merely lose the note — it stops the parse at the tail and takes the row's `added`,
        # `short`, ticket and `derived` down with it: the row loses its age, its sort slot and
        # its badges at once. Both halves are asserted, because a guard that refused
        # everything with a bracket in it would pass the refusal test alone.
        guard_before = open(fleet_path).read()
        fleet.index = ask_row("bump the date")
        await pilot.pause()
        await pilot.press("t")
        await pilot.pause()
        note_inp.value = "oops ]"
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        ok("a note the reader could not get back out is REFUSED, nothing written, field open",
           app.marking is not None and note_inp.has_class("-show")
           and open(fleet_path).read() == guard_before, open(fleet_path).read())
        note_inp.value = "see [SRV-9]"
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        balanced = [ln for ln in open(fleet_path).read().splitlines()
                    if "bump the date" in ln][0]
        ok("…while a BALANCED bracket goes through, since ask_trailers reads one level of it",
           dict(fleet_tui.ask_detail(balanced)["trailers"]).get("note") == "see [SRV-9]",
           balanced)

        # THE LANE PANEL MARKS THAT LANE'S FIRST ASK, the same row `x` clears there — the item
        # under the cursor is a lane, not an ask, and both keys have to resolve it the same
        # way or the two halves of the gesture would act on different things.
        lane_before = open(ask_path).read()
        lanes.focus()
        lanes.index = 0
        await pilot.pause()
        await pilot.press("t")
        await pilot.pause()
        note_inp.value = "handed the answer over"
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        ok("t on a lane row marks that lane's first ask, note and all",
           open(ask_path).read().splitlines()[0]
           == "✅ %s [note:handed the answer over]" % lane_before.splitlines()[0],
           open(ask_path).read())
        with open(ask_path, "w") as f:
            f.write(lane_before)
        fleet.focus()
        await pilot.pause()

        with open(fleet_path, "w") as f:
            f.write(fleet_before_mark)
        await pilot.press("r")
        await pilot.pause()
        await pilot.pause()

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
        ok("the overlay shows the agent's update IN FULL, not the snapshot's 60-char clip",
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
            # THE BUG THIS REPLACES, and why the old test could not see it. Enter on a 4ME row
            # fell through to action_open_ticket, which read the LANES list no matter which
            # panel had focus — so it acted on the highlighted lane while the user was looking
            # at a fleet ask, opening DX-6 or warning "no ticket on this lane" about a row that
            # was not on screen. The assertion here was `opened and app.detail is None`, which
            # passed on exactly that behaviour: it never named the ticket, so the wrong one
            # satisfied it. Every assertion below names what opened.
            with open(fleet_path, "w") as f:
                f.write("ship: merge the release PR [PR#124] [from:feature-2]\n")
            app.load()
            await pilot.pause()
            await pilot.pause()
            fleet.focus()
            fleet.index = 0
            await pilot.pause()
            await pilot.press("enter")
            await pilot.pause()
            ok("enter on a 4ME row opens the ask overlay rather than acting on a lane",
               app.ask is not None and app.detail is None and opened == [],
               (app.ask, app.detail, opened))
            await pilot.press("o")
            await pilot.pause()
            ok("…and o there opens the ASK's own ticket, not the highlighted lane's",
               opened == [["open", "https://github.com/acme/goals/pull/124"]], opened)
            await pilot.press("escape")
            await pilot.pause()
            ok("…and escape closes it", app.ask is None)
        finally:
            fleet_tui.subprocess.Popen = real_popen

        # ── the 4ME detail overlay ───────────────────────────────────────────────────────
        # The list beside the lanes had the same defect the lane rows had: it is a column, so
        # it clips at sixty characters, and the clipped half was simply unreachable. This is
        # the surface with room for it — plus the facts the lead knows about an ask and had
        # nowhere to write: which ticket, who raised it, when, what it is holding up.
        def ask_text():
            return "\n".join(str(w.content)
                             for w in app.query_one("#ask-detail").query(Static))

        # A REAL over-length ask, so the clip is exercised rather than assumed. The prose runs
        # well past sixty characters and the trailers sit behind a deferral stamp, which is
        # the order the live file is written in.
        LONG = ("MON-10 Phase 4 rescope — likely moot: ticket sequencing already gates "
                "Phase 4 behind SRV-21; Phases 1-3 are unblocked")
        with open(fleet_path, "w") as f:
            f.write("product: %s (deferred 2026-08-11 — until SRV-11+SRV-21 merge) "
                    "[MON-10] [from:feature-3] [added:2026-08-10] "
                    "[unblocks:MON-10 phase 4 after SRV-21] [odd:keep me]\n" % LONG)
        with open(goal_path, "w") as f:
            f.write("finish the MON-10 chain\n1. SRV-11\n2. SRV-21\n3. MON-10\n")
        app.load()
        for _ in range(4):
            await pilot.pause()

        # THE LIST STILL CLIPS — that is the column's job and the reason the dialog exists.
        # Asserting it here keeps the two halves of the contract in one place: what the row
        # drops is exactly what the overlay has to go back to the file for.
        row_text = str(app.query_one("#fleet", ListView).children[0].query_one(Static).content)
        ok("the 4ME row still clips its ask to the column",
           "…" in row_text, row_text)
        ok("…and hides the trailers, which are provenance rather than the question",
           "from:feature-3" not in row_text and "added:" not in row_text
           and "[MON-10]" not in row_text, row_text)
        # THE AGE AND THE GOAL MARKER RIDE ON THE ROW (2026-08-19). Both were reachable only
        # by opening the ask, which is backwards: they are what decides WHICH ask to open.
        # The age is asserted as a real value, not merely present — an age that rendered ""
        # would leave the row looking correct while saying nothing.
        ok("…but the AGE rides on the row, after the clip, where it costs the question nothing",
           re.search(r"\d+[smhdw](\[/\])?\s*$", row_text.rstrip()), row_text)
        ok("…and an ask whose ticket the standing goal names is marked on the ROW",
           "🎯" in row_text, row_text)

        fleet.focus()
        fleet.index = 0
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()

        # THE WHOLE ASK, and specifically the half the row threw away. Matching on the TAIL is
        # what makes this test able to fail: asserting the opening words would pass against the
        # clipped value too, which is the bug it is guarding.
        ok("the overlay shows the ask in full, including what the row clipped",
           "Phases 1-3 are unblocked" in ask_text(), ask_text())
        ok("…and does not clip it itself", "…" not in ask_text(), ask_text())
        # The trailers are METADATA, so they become fields — they must not be left sitting in
        # the prose they were lifted out of.
        ok("…with the trailers lifted out of the text rather than printed in it",
           "[from:feature-3]" not in ask_text() and "[MON-10]" not in ask_text(), ask_text())

        ok("the kind tag is a labelled field", "product" in ask_text(), ask_text())
        ok("the ticket is a field, linked to the tracker",
           "linear://acme/issue/MON-10" in ask_text(), ask_text())
        ok("who raised it is a field", "raised by" in ask_text()
           and "feature-3" in ask_text(), ask_text())
        ok("…and when, with an age beside the date rather than instead of it",
           "added" in ask_text() and "2026-08-10" in ask_text()
           and "ago)" in ask_text(), ask_text())
        ok("the deferral stamp is its own field, not left buried in the prose",
           "deferred" in ask_text() and "until SRV-11+SRV-21 merge" in ask_text()
           and "(deferred" not in str(
               app.query_one("#ask-detail-text", Static).content), ask_text())
        # The ids inside a trailer are linkified like every other id on this screen, so match
        # AROUND the link rather than through it — `after SRV-21` is `after [link=…]SRV-21…`.
        ok("what it unblocks is a field",
           "unblocks" in ask_text() and "phase 4 after" in ask_text()
           and "]SRV-21[/link]" in ask_text(), ask_text())
        # THE GOAL MARKER. MON-10 is named in the goal chain, so this ask is not one item
        # among many — it is gating the objective the whole fleet is pointed at.
        ok("an ask whose ticket the standing goal names is marked as chain-gating",
           "on the goal chain" in ask_text(), ask_text())
        # AN UNKNOWN TRAILER IS KEPT. The lead writes this file by hand and the format will
        # grow; a key this reader has never heard of must survive to the screen rather than
        # being dropped silently or blowing the dialog up.
        ok("an unknown trailer renders as-is instead of erroring or vanishing",
           "odd:keep me" in ask_text(), ask_text())

        # RE-READ ON THE TICK, from the FILE. The lead edits this list while the user is
        # reading it, and an overlay that kept the row it was opened with would show an ask
        # that has since been reworded — the same defect the lane dialog already fixed.
        with open(fleet_path, "w") as f:
            f.write("product: %s (deferred 2026-08-11 — until SRV-11+SRV-21 merge) "
                    "[MON-10] [from:feature-3] [added:2026-08-10] "
                    "[unblocks:MON-10 phase 4 after SRV-21] [odd:keep me]\n"
                    % (LONG + " AND NEWLY REWORDED"))
        app.load()
        for _ in range(4):
            await pilot.pause()
        ok("an ask reworded under the open overlay lands on the next tick",
           "AND NEWLY REWORDED" in ask_text(), ask_text())

        # ── A DIALOG OPENS AT THE TOP, whatever the last reader left it at ──────────────
        # One widget serves every subject, and `-show` only stops it being DISPLAYED — it is
        # never remounted, so its scroll offset is the previous ask's. Read a long one to the
        # bottom, open a short one, and it renders past its own first line.
        with open(fleet_path, "w") as f:
            f.write("product: a question with a lot behind it [MON-10] [added:2026-08-10]\n"
                    + "".join("  context line %02d, long enough to need scrolling\n" % i
                              for i in range(40)))
        app.load()
        for _ in range(4):
            await pilot.pause()
        box = app.query_one("#ask-detail-box", fleet_tui.VerticalScroll)
        for _ in range(6):
            await pilot.press("j")          # j SCROLLS this overlay; it holds no list
        await pilot.pause()
        scrolled = box.scroll_offset.y
        ok("j scrolls the open 4ME overlay away from the top", scrolled > 0, scrolled)

        # THE TICK MUST NOT TOUCH IT. This box is repainted every few seconds while it is
        # being read, so a reset living in the refresh would drag the reader back to the top
        # mid-sentence — a worse bug than the one being fixed, and the reason the reset is on
        # the OPEN path alone. Asserted directly, because the two paths share the repaint.
        app.load()
        for _ in range(4):
            await pilot.pause()
        ok("…and a refresh under the reader does NOT yank them back to the top",
           box.scroll_offset.y == scrolled, (scrolled, box.scroll_offset.y))

        await pilot.press("escape")
        await pilot.pause()
        await pilot.press("enter")          # reopen, on the same long ask
        await pilot.pause()
        ok("…but reopening a dialog starts it at the top, not where the last one was left",
           box.scroll_offset.y == 0, box.scroll_offset.y)

        await pilot.press("escape")
        await pilot.pause()
        ok("escape closes the 4ME overlay", app.ask is None)

        # An ask with NO metadata at all is the ordinary case — most lines in this file are
        # one sentence. It must read as a plain ask, not as a broken one.
        with open(fleet_path, "w") as f:
            f.write("something untyped and bare\n")
        app.load()
        for _ in range(4):
            await pilot.pause()
        fleet.focus()
        fleet.index = 0
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        ok("an ask with no trailers opens, and says so rather than showing empty fields",
           app.ask is not None and "no metadata" in ask_text()
           and "something untyped and bare" in ask_text(), ask_text())
        await pilot.press("escape")
        await pilot.pause()
        os.remove(goal_path)

        # ── A SNAPSHOT APPLIED WHILE THE PANELS ARE NOT IN THE TREE ──────────────────────
        # Appending a row to a detached ListView raises MountError and kills the app. Seen in
        # the wild during SHUTDOWN — the `c` filter key landing as the app tore down, which
        # becomes a full rebuild — and reachable at startup too, since `load()` hands its
        # result back from a worker thread.
        _requeued = []
        _real_q, _real_after = app.query_one, app.call_after_refresh

        class _NotAttached:
            is_attached = False
            # THE PROPERTY THE FIRST FIX GUARDED ON, kept here because it is the whole trap:
            # Textual's own Widget.mount tests `is_attached`, so a guard written on
            # `is_mounted` passes at exactly the moment the mount is about to raise.
            is_mounted = True

        app.query_one = lambda *a, **k: _NotAttached()
        app.call_after_refresh = lambda *a, **k: _requeued.append(a)
        _before = app.data
        try:
            app.apply(fake_snapshot())
        finally:
            app.query_one, app.call_after_refresh = _real_q, _real_after
        ok("a snapshot arriving before the panels are attached is re-queued, not mounted",
           _requeued and _requeued[0][0] == app.apply, _requeued)
        ok("…and nothing of it is applied early, so the retry draws the whole first frame",
           app.data is _before)

        # ── EVERY DIALOG IS CENTRED ON THE SCREEN ────────────────────────────────────────
        # They were pinned to the top-left corner: each is `height: auto` with a fixed
        # `margin`, and a margin is an offset from the corner, not a position. Asserted in
        # BOTH axes against the screen's own size, because the horizontal half was the one
        # that looked deliberate — a full-width dialog is centred by accident, and stops
        # being so the moment it is given a width.
        def centred(sel):
            r, scr = app.query_one(sel).region, app.screen.size
            # max(0, …) because a dialog TALLER than the screen is centred at the top edge,
            # not at a negative offset — that is the small-terminal case, and it must read as
            # centred rather than as a failure.
            return (abs(r.x - max(0, (scr.width - r.width) // 2)) <= 1
                    and abs(r.y - max(0, (scr.height - r.height) // 2)) <= 1)

        fleet.focus()
        fleet.index = 0
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        ok("the 4ME dialog is centred on screen, both axes", centred("#ask-detail"),
           (app.query_one("#ask-detail").region, app.screen.size))

        # ── ENTER TOGGLES: the key that opened a dialog closes it ────────────────────────
        # It used to open only, so the reflex of pressing it again did nothing at all and
        # `esc` — a different key, on the other side of the keyboard — was the only way out.
        await pilot.press("enter")
        await pilot.pause()
        ok("enter closes the 4ME dialog it opened", app.ask is None)
        ok("…and does not open something else on the way out", app.detail is None)

        await pilot.press("question_mark")
        await pilot.pause()
        ok("the legend is centred too", centred("#legend"),
           (app.query_one("#legend").region, app.screen.size))
        await pilot.press("enter")
        await pilot.pause()
        # ENTER USED TO REACH THE LIST BEHIND THE LEGEND, opening the lane dialog under a
        # panel covering it — the second assertion is that failure, not a restatement.
        ok("enter closes the legend", not app.query_one("#legend").has_class("-show"))
        ok("…rather than acting on the list it is covering", app.detail is None)

        lanes.focus()
        lanes.index = 0
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        ok("the lane dialog is centred as well", app.detail is not None
           and centred("#detail"), (app.query_one("#detail").region, app.screen.size))
        # THE ONE EXCEPTION, and it is checked before the toggle: inside the lane dialog the
        # cursor sits on a knob and enter EDITS it, which is that dialog's whole purpose.
        await pilot.press("escape")
        await pilot.pause()

        # ── ENTER ON THE AGGREGATE OPENS THE SUBAGENTS (item 8) ─────────────────────────
        # Driven through the LIST, not through toggle_subs(): what is under test is that the
        # collapsed row is reachable, that enter reaches it rather than the detail dialog,
        # and that the rebuild the toggle forces actually lands in the panel.
        roster["subs"] = [
            {"name": "reviewer-a", "kind": "subagent", "state": "idle", "context_pct": 41},
            {"name": "reviewer-b", "kind": "subagent", "state": "busy", "context_pct": 78},
        ]
        app.load()
        for _ in range(3):
            await pilot.pause()

        def lane_names():
            return [w.row.get("name") for w in app.query_one("#lanes", ListView).children]

        ok("the collapsed fleet ends in one aggregate row, not two subagent rows",
           lane_names()[-1] == fleet_tui.SUBAGG_NAME
           and "reviewer-a" not in lane_names(), lane_names())
        ok("…and the panel says how many it stands for and how hot the hottest is",
           "2 running" in screen_text(app) and "max ctx 78%" in screen_text(app),
           screen_text(app))
        lanes.focus()
        lanes.index = len(lane_names()) - 1
        await pilot.pause()
        await pilot.press("enter")
        for _ in range(3):
            await pilot.pause()
        ok("enter on the aggregate row expands it", "reviewer-a" in lane_names(),
           lane_names())
        # ENTER IS NOT "OPEN THE DIALOG" HERE. The aggregate has no path, no branch and no
        # config, so a detail dialog on it would be a panel of blanks.
        ok("…rather than opening a detail dialog on a row that is not an agent",
           app.detail is None, app.detail)
        await pilot.press("enter")
        for _ in range(3):
            await pilot.pause()
        ok("…and enter again collapses it, the same way it closes every other overlay",
           "reviewer-a" not in lane_names(), lane_names())
        roster["subs"] = []
        app.load()
        for _ in range(3):
            await pilot.pause()

        # ── CTRL+CLICK ON A ROW WITH A REVIEW STAGED → that lane's Monocle ───────────────
        # Both halves are stubbed at the seam: what is under test is that the gesture is
        # received with its modifier and dispatched to the right lane, not that tmux works.
        jumps = {"looked": [], "focused": []}
        real_pane, real_focus = fleet_tui.monocle_pane, fleet_tui.focus_pane
        fleet_tui.monocle_pane = lambda n: (jumps["looked"].append(n) or "%42")
        fleet_tui.focus_pane = lambda p: (jumps["focused"].append(p) or True)
        try:
            volatile["review"] = {"name": "SRV-28 diff", "age": 60}
            app.load()
            for _ in range(3):
                await pilot.pause()
            row = app.query_one("#lanes", ListView).children[0]
            await pilot.click(row, control=True)
            await app.workers.wait_for_complete()
            await pilot.pause()
            ok("ctrl+click on a staged row asks for THAT lane's monocle pane",
               jumps["looked"] == ["feature-1"], jumps)
            ok("…and focuses the pane tmux named, rather than a guess",
               jumps["focused"] == ["%42"], jumps)
            # THE SAME GESTURE ARRIVES TWICE — a modified click still selects the row under
            # it. Leaving the lane dialog open behind a window the user has just been sent
            # away from is what this drops.
            ok("…and the click's own selection does not also open the lane dialog",
               app.detail is None, app.detail)

            # A PLAIN click must be untouched by that suppression, or the guard has traded
            # one broken gesture for another.
            await pilot.click(row)
            await pilot.pause()
            ok("an UNmodified click still opens the lane dialog",
               app.detail is not None)
            await pilot.press("escape")
            await pilot.pause()

            # A ROW WITH NOTHING STAGED SAYS SO. A silent no-op here is indistinguishable
            # from a click the terminal swallowed, which is the failure mode this feature is
            # most likely to hit.
            jumps["looked"].clear()
            volatile["review"] = None
            app.load()
            for _ in range(3):
                await pilot.pause()
            await pilot.click(app.query_one("#lanes", ListView).children[0], control=True)
            await app.workers.wait_for_complete()
            await pilot.pause()
            ok("ctrl+click on a lane with no review staged jumps nowhere",
               jumps["looked"] == [], jumps)
            ok("…and says so rather than doing nothing",
               any("no review staged" in str(n.message) for n in app._notifications),
               [str(n.message) for n in app._notifications])
        finally:
            fleet_tui.monocle_pane, fleet_tui.focus_pane = real_pane, real_focus
            volatile["review"] = None
            app.load()
            for _ in range(3):
                await pilot.pause()

        # ── DRIFT IS VISIBLE WITHOUT ASKING ANYONE ──────────────────────────────────────
        # The header, not a row: fixing it is a fleet-wide restart, and the marker is absent
        # on every day but the one after a rebuild.
        volatile["monocle_stale"] = True
        app.load()
        for _ in range(3):
            await pilot.pause()
        ok("a lane whose monocle predates the binary is counted in the header",
           "1 old monocle" in screen_text(app), screen_text(app).split("\n")[0])
        # THE NEGATIVE, which is what keeps the marker worth reading: on an ordinary day it
        # must be absent entirely, not shown as a zero.
        volatile["monocle_stale"] = False
        app.load()
        for _ in range(3):
            await pilot.pause()
        ok("…and a lane on the current build puts nothing in the header at all",
           "monocle" not in screen_text(app).split("\n")[0],
           screen_text(app).split("\n")[0])
        # UNKNOWN IS NOT STALE EITHER. A lane with no monocle to compare must not be counted.
        volatile["monocle_stale"] = None
        app.load()
        for _ in range(3):
            await pilot.pause()
        ok("…nor does a lane whose monocle could not be resolved",
           "monocle" not in screen_text(app).split("\n")[0],
           screen_text(app).split("\n")[0])

        # ── CTRL+HJKL: MOVE INSIDE THE TUI, THEN HAND OFF TO TMUX AT THE EDGE ───────────
        # BOTH BRANCHES OF EVERY DIRECTION are asserted, because each alone passes against a
        # different broken implementation: internal-only never leaves the pane, hand-off-only
        # never moves between the panels, and either one looks correct from the other's tests.
        #
        # `select_pane` is stubbed at the seam. What is under test is that the TUI decides to
        # hand off and in which direction — that tmux moves a pane is tmux's business, and it
        # was verified against a real nested client separately.
        moves = []
        real_select = fleet_tui.select_pane
        fleet_tui.select_pane = lambda d: (moves.append(d) or True)
        try:
            lanes.focus()
            await pilot.pause()

            def focused():
                return next((w.id for w in (app.query_one("#lanes", ListView),
                                            app.query_one("#fleet", ListView))
                             if w.has_focus), None)

            await pilot.press("ctrl+j")
            await pilot.pause()
            ok("ctrl+j from the FLEET panel moves down into 4ME",
               focused() == "fleet", focused())
            ok("…and does NOT leave the pane, because there was somewhere to go",
               moves == [], moves)
            await pilot.press("ctrl+k")
            await pilot.pause()
            ok("ctrl+k moves back up into FLEET", focused() == "lanes", focused())
            ok("…still without leaving the pane", moves == [], moves)

            # THE EDGES. Focus must NOT move, and the movement must go to tmux instead.
            await pilot.press("ctrl+k")
            await pilot.pause()
            ok("ctrl+k at the top edge hands the movement to tmux", moves == ["U"], moves)
            ok("…and leaves focus where it was", focused() == "lanes", focused())
            moves.clear()
            app.query_one("#fleet", ListView).focus()
            await pilot.pause()
            await pilot.press("ctrl+j")
            await pilot.pause()
            ok("ctrl+j at the bottom edge hands the movement to tmux", moves == ["D"], moves)
            ok("…and leaves focus where it was", focused() == "fleet", focused())

            # LEFT AND RIGHT ALWAYS HAND OFF — the panels are stacked, not columned, so there
            # is no such thing as an internal horizontal move to try first.
            moves.clear()
            await pilot.press("ctrl+l")
            await pilot.pause()
            ok("ctrl+l always hands off, there being no panel to its right",
               moves == ["R"], moves)

            # CTRL+H ARRIVES AS `backspace`, NOT AS A KEY OF ITS OWN. Posted as the real
            # event — key name plus the 0x08 character tmux forwards — because a pilot press
            # of "ctrl+h" would synthesise an event the terminal never produces, and the
            # whole difficulty of this direction is that the byte is shared with Backspace.
            moves.clear()
            app.post_message(Key("backspace", "\x08"))
            await pilot.pause()
            await pilot.pause()
            ok("ctrl+h hands off to the left, recognised by its byte", moves == ["L"], moves)
            # THE NEGATIVE THAT MAKES THAT SAFE. A real Backspace is 0x7F and must not
            # navigate — binding the key NAME rather than the byte would move the pane every
            # time the user hit backspace.
            moves.clear()
            app.post_message(Key("backspace", "\x7f"))
            await pilot.pause()
            await pilot.pause()
            ok("…and a real Backspace, which shares that key name, does not",
               moves == [], moves)

            # NEVER SWALLOWED. Every state that cannot move internally still hands off; a key
            # that does nothing at all is indistinguishable from the terminal eating it.
            moves.clear()
            lanes.focus()
            await pilot.pause()
            await pilot.press("enter")           # the lane dialog: one region, not two
            for _ in range(3):
                await pilot.pause()
            await pilot.press("ctrl+j")
            await pilot.pause()
            ok("with a dialog open the movement goes to tmux rather than nowhere",
               moves == ["D"], moves)
            await pilot.press("escape")
            await pilot.pause()

            moves.clear()
            app.editing = {"key": "x"}           # as if a knob edit were open
            await pilot.press("ctrl+j")
            await pilot.pause()
            ok("…and so does one arriving mid-edit", moves == ["D"], moves)
            app.editing = None

            moves.clear()
            lanes.focus()
            await pilot.pause()
            await pilot.press("f")               # fullscreen: the other panel is gone
            await pilot.pause()
            await pilot.press("ctrl+j")
            await pilot.pause()
            ok("…and so does one with the neighbouring panel hidden", moves == ["D"], moves)
            await pilot.press("f")
            await pilot.pause()
        finally:
            fleet_tui.select_pane = real_select

        # ── the trailer format itself ────────────────────────────────────────────────────
        # Driven against the readers directly: this is where the FILE FORMAT is decided, and
        # the lead writes that file by hand, so the edges are what matter.
        ok("trailers come off the tail and keep their writing order",
           fleet_tui.ask_trailers("do the thing [SRV-24] [from:vii] [added:2026-08-10]")
           == ("do the thing",
               [("ticket", "SRV-24"), ("from", "vii"), ("added", "2026-08-10")]),
           fleet_tui.ask_trailers("do the thing [SRV-24] [from:vii] [added:2026-08-10]"))
        # BRACKETS IN PROSE ARE PROSE. Only the tail is metadata — a line-wide scan would eat
        # the "[sic]" out of a quoted sentence and silently change what the lead wrote.
        ok("a bracket inside the sentence is left alone",
           fleet_tui.ask_trailers("their reply said [sic] and then stopped [SRV-9]")
           == ("their reply said [sic] and then stopped", [("ticket", "SRV-9")]),
           fleet_tui.ask_trailers("their reply said [sic] and then stopped [SRV-9]"))
        ok("an ask with no trailers is returned untouched",
           fleet_tui.ask_trailers("just a question") == ("just a question", []))
        ok("an unknown key is KEPT, under an empty label rather than dropped",
           fleet_tui.ask_trailers("x [owner:jaa]") == ("x", [("", "owner:jaa")]),
           fleet_tui.ask_trailers("x [owner:jaa]"))
        ok("a bare non-ticket bracket is kept too, rather than mistaken for a ticket",
           fleet_tui.ask_trailers("x [whatever]") == ("x", [("", "whatever")]),
           fleet_tui.ask_trailers("x [whatever]"))
        ok("a PR trailer is a ticket",
           fleet_tui.ask_trailers("x [PR#147]") == ("x", [("ticket", "PR#147")]))

        ok("the deferral stamp lifts off the tail of the prose",
           ask_deferral("rescope it (deferred 2026-08-11 — until SRV-21)")
           == ("rescope it", "deferred 2026-08-11 — until SRV-21"),
           ask_deferral("rescope it (deferred 2026-08-11 — until SRV-21)"))
        ok("…and an ordinary parenthetical is not mistaken for one",
           ask_deferral("rescope it (per the sequencing ruling)")
           == ("rescope it (per the sequencing ruling)", ""),
           ask_deferral("rescope it (per the sequencing ruling)"))

        # THE WHOLE LINE, in the order it is written: kind, prose, stamp, trailers. The stamp
        # sits INSIDE the trailers' reach, so getting the peel order wrong strands one in the
        # other — which is the one way this parser can quietly lose a field.
        d = fleet_tui.ask_detail(
            "product: rescope (deferred 2026-08-11 — until SRV-21) [MON-10] [from:woo]")
        ok("ask_detail peels kind, prose, stamp and trailers in the written order",
           d == {"kind": "product", "icon": "💬", "text": "rescope", "context": "",
                 "deferral": "deferred 2026-08-11 — until SRV-21",
                 "trailers": [("ticket", "MON-10"), ("from", "woo")]}, d)
        ok("an untyped ask still parses, as the general kind",
           fleet_tui.ask_detail("bare [SRV-1]")["kind"] == "",
           fleet_tui.ask_detail("bare [SRV-1]"))

        # ── the CONTEXT BLOCK, the SHORT form, and the ORDERING ──────────────────────────
        # All three landed together (2026-08-19) for one reason: the user could not act on
        # the list. Each is asserted against the failure it was added for, not its mechanism.
        d = fleet_tui.ask_detail("product: fold it in? [SRV-1]\nbecause vii is idle\nand it is cheap")
        ok("context is every line after the first, and the first line still parses normally",
           (d["text"], d["context"], dict(d["trailers"])["ticket"])
           == ("fold it in?", "because vii is idle\nand it is cheap", "SRV-1"), d)
        ok("…so a bracket in the CONTEXT can never be mistaken for a trailer",
           fleet_tui.ask_detail("a?\ncontext [not:a-trailer]")["trailers"] == [],
           fleet_tui.ask_detail("a?\ncontext [not:a-trailer]"))
        ok("an ask with no context reports an empty one, never None",
           fleet_tui.ask_detail("a?")["context"] == "")

        # FOLDING AND DELETING ARE ONE CONTRACT and are asserted together: the reader turns a
        # block into one item, and `x` must remove the same block. A delete that matched the
        # head and left the indented lines behind would silently re-parent a paragraph onto
        # an unrelated ask — corruption that looks like a working list.
        ok("indented lines fold into the ask above them, so the list still counts ITEMS",
           fleet_tui.fold_ask_context(
               ["product: a?", "  ctx one", "\tctx two", "ship: b?", "  ctx b"])
           == ["product: a?\nctx one\nctx two", "ship: b?\nctx b"],
           fleet_tui.fold_ask_context(
               ["product: a?", "  ctx one", "\tctx two", "ship: b?", "  ctx b"]))
        # ITS BYTES ARE KEPT, indent and all, rather than tidied. `x` deletes by matching the
        # head line against the file, so a head this reader had silently stripped would no
        # longer match the line it came from — a delete that fails quietly is worse than an
        # ugly row. Being its own ITEM is the fact under test; its spelling is incidental.
        ok("…and a stray leading indent is its own ask, never a continuation of nothing",
           len(fleet_tui.fold_ask_context(["  orphan", "product: a?"])) == 2,
           fleet_tui.fold_ask_context(["  orphan", "product: a?"]))

        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tf:
            tf.write("product: a?\n  ctx one\n  ctx two\nship: b?\n  ctx b\n")
            block_path = tf.name
        folded = fleet_tui._ask_lines(block_path)
        dropped = fleet_tui._drop_line(block_path, folded[0])
        with open(block_path) as f:
            left = f.read()
        os.unlink(block_path)
        ok("deleting an ask takes its whole context block with it, and nothing else",
           dropped and left == "ship: b?\n  ctx b\n", (dropped, left))
        # WHAT IT RETURNS IS WHAT UNDO WRITES BACK, so the indent has to survive the trip.
        # `_drop_line` used to answer a bare True and `u` restored the FOLDED string, whose
        # continuation lines `fold_ask_context` had already stripped — see the round-trip
        # assertion below for the corruption that caused.
        ok("…and it hands back the bytes it removed, indentation intact",
           dropped == "product: a?\n  ctx one\n  ctx two", dropped)

        # THE ROUND TRIP IS THE CONTRACT, asserted on the ITEM COUNT and not only on the
        # bytes: the failure this locks in was silent and structural. `x` then `u` on an ask
        # with context wrote its context back flush left, and the next read parsed those
        # lines as top-level asks — a 2-ask file became 5, the panel's count was wrong, and
        # `x` on one of the strays deleted a sentence of someone's prose. Counting items is
        # what a reader of the file would notice; comparing bytes is what pins the cause.
        original = ("fleet: push the commits? [added:2026-08-19]\n"
                    "  Six commits on master, unpushed.\n"
                    "  Nothing depends on it.\n"
                    "product: bump the date? [added:2026-08-19]\n"
                    "  Today it does not.\n")
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tf:
            tf.write(original)
            trip_path = tf.name
        before = fleet_tui._ask_lines(trip_path)
        # Against a file that EXISTS, so the empty answer means "no such head" and not
        # "could not open it" — the two share a return value and only one is under test.
        ok("a head that matches nothing returns falsy, and leaves the file alone",
           fleet_tui._drop_line(trip_path, "product: never written?") == ""
           and open(trip_path).read() == original)
        cut = fleet_tui._drop_line(trip_path, before[0])
        fleet_tui._restore_line(trip_path, cut)
        after = fleet_tui._ask_lines(trip_path)
        with open(trip_path) as f:
            round_tripped = f.read()
        os.unlink(trip_path)
        ok("clearing an ask with context and undoing it leaves the SAME NUMBER of asks",
           len(after) == len(before) == 2, (len(before), len(after), round_tripped))
        ok("…and the same asks, context still attached to the item it belongs to",
           sorted(after) == sorted(before), (sorted(before), sorted(after)))
        # Byte-level, because "same asks" would also pass if the indent were re-tidied to a
        # different width — which would be this view silently rewriting a human's file.
        ok("…and the file's own indentation, not a normalised guess",
           "\n  Six commits on master, unpushed.\n  Nothing depends on it." in round_tripped,
           round_tripped)

        # A PARAGRAPH BREAK IS INSIDE THE ASK; THE BLANK BETWEEN ASKS IS NOT. `_ask_lines`
        # drops blanks before folding, so a context block written with a paragraph break
        # reads as ONE item — but the delete scan stopped at the first blank, took only the
        # half above it, and left the rest as an indented orphan the next read counted as its
        # own ask. Both directions are asserted, because the fix could over-correct just as
        # easily: eating the separator blank would silently reformat the user's file every
        # time an item above it was cleared.
        def _cut(body, idx=0):
            """(asks before, bytes removed, file left, asks after an undo) for one fixture."""
            with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tf:
                tf.write(body)
                q = tf.name
            was = fleet_tui._ask_lines(q)
            gone = fleet_tui._drop_line(q, was[idx])
            with open(q) as f:
                rest = f.read()
            fleet_tui._restore_line(q, gone)
            back = fleet_tui._ask_lines(q)
            os.unlink(q)
            return was, gone, rest, back

        inner = "fleet: push? [a]\n  ctx one\n\n  ctx two\nproduct: bump? [b]\n  its ctx\n"
        was, gone, rest, back = _cut(inner)
        ok("a blank line INSIDE a context block does not end the delete",
           rest == "product: bump? [b]\n  its ctx\n", rest)
        ok("…so no half-block is left behind to read as an ask of its own",
           len(was) == len(back) == 2 and sorted(was) == sorted(back), (was, back))
        # The blank is part of the bytes, so undo replays the paragraph break too. Asserted
        # on `gone` rather than the round-tripped file because THIS is what the undo stack
        # holds — a truncated value here is the corruption, wherever it is later written.
        ok("…and the blank line itself survives in the removed bytes",
           gone == "fleet: push? [a]\n  ctx one\n\n  ctx two", gone)

        between = "fleet: push? [a]\n  ctx one\n\nproduct: bump? [b]\n  its ctx\n"
        _, gone2, rest2, _ = _cut(between)
        ok("a blank line BETWEEN two asks is left alone, not swallowed by the delete",
           rest2 == "\nproduct: bump? [b]\n  its ctx\n", rest2)
        ok("…and is not carried off in the removed bytes either",
           gone2 == "fleet: push? [a]\n  ctx one", gone2)

        # Trailing blanks at EOF are the same question with nothing after them to prove the
        # block ended — the scan must still hand them back rather than absorb them.
        eof = "product: bump? [b]\n  its ctx\nfleet: push? [a]\n  ctx\n\n\n"
        _, _, rest3, _ = _cut(eof, idx=1)
        ok("blank lines at end of file are not absorbed into the last ask",
           rest3 == "product: bump? [b]\n  its ctx\n\n\n", rest3)

        # ── MARKING AN ASK DONE, the other half of `x` ───────────────────────────────────
        # A ROW THAT IS HANDLED MUST BE DISTINGUISHABLE FROM ONE NOBODY OPENED, and until `t`
        # the only way to say "I dealt with this" was to delete it — indistinguishable from a
        # mis-keyed `x`, and it threw away the answer along with the question.
        # Asserted through ask_detail rather than on the string, because what matters is that
        # the READERS still see the same ask: a marker that cost the row its kind, its prose
        # or its trailers would be a new format, not a mark.
        marked = fleet_tui.ask_mark_done(
            "product: fold it in? [SRV-1] [added:2026-08-19]", "approved, ott's version")
        ok("marking writes the tick, keeps the kind token, the prose and every trailer, and "
           "adds the note",
           (marked.startswith("✅"),
            fleet_tui.ask_detail(marked)["text"],
            fleet_tui.ask_detail(marked)["trailers"])
           == (True, "product: fold it in?",
               [("ticket", "SRV-1"), ("added", "2026-08-19"),
                ("note", "approved, ott's version")]), marked)
        ok("…and with no note there is no note trailer at all, just the tick",
           fleet_tui.ask_detail(fleet_tui.ask_mark_done("product: fold it in? [SRV-1]"))
           ["trailers"] == [("ticket", "SRV-1")],
           fleet_tui.ask_mark_done("product: fold it in? [SRV-1]"))
        # ONE TICK, NOT TWO. `ask_kind` already de-duplicates a leading ✅ when it READS one,
        # for the same reason: a doubled glyph reads as a second marker with a meaning to
        # work out, and there is none. Marking a row twice is an ordinary thing to do.
        ok("…and marking an already-marked ask keeps exactly one tick",
           fleet_tui.ask_mark_done(fleet_tui.ask_mark_done("todo: a thing")) == "✅ todo: a thing",
           fleet_tui.ask_mark_done(fleet_tui.ask_mark_done("todo: a thing")))
        # A NOTE IS METADATA ABOUT THE ROW, NEVER A SECOND ROW. It lands on the TAIL, so a
        # newline in it would make everything after the break a context line of its own — and
        # the reader would then attach that context to this ask as if someone had written it.
        ok("…and a note carrying a newline is collapsed, never split into a context line",
           fleet_tui.ask_detail(fleet_tui.ask_mark_done("todo: a thing", "one\ntwo"))
           ["context"] == "",
           fleet_tui.ask_mark_done("todo: a thing", "one\ntwo"))

        # THE FILE WRITER TOUCHES THE HEAD LINE AND NOTHING ELSE. The context under an ask is
        # the reasoning that made it answerable and is still worth reading once it is
        # answered, so a marker that consumed or re-indented it would be destroying the half
        # of the item the block change existed to add.
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tf:
            tf.write("product: a? [SRV-2]\n  ctx one\n  ctx two\nship: b?\n")
            mark_path = tf.name
        wrote = fleet_tui._mark_line_done(mark_path, fleet_tui._ask_lines(mark_path)[0], "yes")
        with open(mark_path) as f:
            marked_file = f.read()
        ok("marking rewrites the head line IN PLACE and leaves the block and its neighbours "
           "untouched",
           marked_file == "✅ product: a? [SRV-2] [note:yes]\n  ctx one\n  ctx two\nship: b?\n",
           marked_file)
        ok("…and it is still ONE item, with its context still attached",
           fleet_tui._ask_lines(mark_path)
           == ["✅ product: a? [SRV-2] [note:yes]\nctx one\nctx two", "ship: b?"],
           fleet_tui._ask_lines(mark_path))
        ok("…and it hands back the line it wrote", wrote == "✅ product: a? [SRV-2] [note:yes]",
           wrote)
        # Against a file that EXISTS, so the empty answer means "no such head" rather than
        # "could not open it" — the two share a return value and only one is under test.
        ok("a head that matches nothing writes nothing and answers falsy",
           fleet_tui._mark_line_done(mark_path, "product: never written?") == ""
           and open(mark_path).read() == marked_file)
        os.unlink(mark_path)

        ok("a `[short:]` trailer is what the one-line views show, not the prose",
           fleet_tui.ask_short(fleet_tui.ask_detail(
               "product: a very long question indeed [short:the gist]")) == "the gist")
        ok("…and with no short form the prose is used, exactly as before",
           fleet_tui.ask_short(fleet_tui.ask_detail("product: the gist")) == "the gist")

        # OLDEST FIRST, undated after dated, deferred last of all. Asserted as a whole
        # ordering rather than pairwise: the bug this replaces was a list that was *usually*
        # chronological, so a check that only compared two adjacent dated rows would have
        # passed on the broken version too.
        rows = ["new [added:2026-08-19]", "undated", "old [added:2026-01-01]",
                "put off (deferred 2026-08-01) [added:2020-01-01]"]
        def _sorted(mode, goal="", chain=()):
            return sorted(rows, key=lambda ln: fleet_tui.ask_sort_key(ln, mode, goal, chain))

        ok("`earliest` sorts oldest first, undated after dated, deferred last of all",
           _sorted("earliest")
           == ["old [added:2026-01-01]", "new [added:2026-08-19]", "undated",
               "put off (deferred 2026-08-01) [added:2020-01-01]"], _sorted("earliest"))
        # UNDATED STAYS LAST IN BOTH DIRECTIONS, which is the whole reason `latest` is not
        # `earliest` reversed: a plain reverse would float the rows we know least about to
        # the top, and would carry the deferred rows up with them.
        ok("`latest` sorts newest first — and is NOT `earliest` reversed",
           _sorted("latest")
           == ["new [added:2026-08-19]", "old [added:2026-01-01]", "undated",
               "put off (deferred 2026-08-01) [added:2020-01-01]"], _sorted("latest"))
        ok("…and an unknown mode falls back to `latest` rather than raising",
           _sorted("nonsense") == _sorted("latest"))
        goal_rows = ["off [added:2026-08-19]", "on [SRV-9] [added:2026-01-01]"]
        ok("`goal` floats chain-gating asks above everything else, whatever their date",
           sorted(goal_rows,
                  key=lambda ln: fleet_tui.ask_sort_key(ln, "goal", "g", ["1. SRV-9"]))
           == ["on [SRV-9] [added:2026-01-01]", "off [added:2026-08-19]"])

        # THE CRASH THIS REPLACED took the whole app down from inside a click handler, so the
        # positive control matters more than the negative one: a parser that returned "" for
        # everything would satisfy "does not raise" and tell us nothing.
        # ── STAGED REVIEWS BECOME 4ME ROWS ──────────────────────────────────────────────
        # Derived from the flag file every tick, so they appear and vanish on their own. The
        # assertions are about what makes them USABLE: the review kind (so the category
        # filter finds them), a path to act on, and the derived mark that stops `x` lying.
        rows = fleet_tui._review_asks([
            {"name": "feature-3", "label": "woo", "path": "/lanes/feature-3",
             "review": {"name": "UI-4", "age": 0}},
            {"name": "feature-1", "label": "vii", "path": "/lanes/feature-1",
             "review": None},
            {"name": "feature-2", "label": "ott", "path": "", "review": {"name": "x", "age": 0}},
        ])
        ok("one 4ME row per STAGED review, and none for a lane without one",
           len(rows) == 1, rows)
        rd = fleet_tui.ask_detail(rows[0])
        rt = dict(rd["trailers"])
        ok("…typed `review`, so it carries the magnifying glass and the filter finds it",
           (rd["kind"], rd["icon"]) == ("review", ASK_KINDS["review"]), rd)
        ok("…carrying the lane path to act on, and the derived mark",
           (rt.get("review"), rt.get("derived")) == ("/lanes/feature-3", "staged-review"), rt)
        ok("…and it names the agent, not the lane, since that is how the user refers to them",
           "woo" in fleet_tui.ask_short(rd), fleet_tui.ask_short(rd))
        # THE AGE IS THE FLAG FILE'S, NOT TODAY'S. A review staged three days ago must read
        # and sort as three days old — that age is the entire reason it is urgent — so a
        # synthesizer that stamped `today` would make every stale review look fresh.
        old = fleet_tui._review_asks([{"name": "l", "label": "l", "path": "/p",
                                       "review": {"name": "", "age": 3 * 86400}}])
        ok("…stamped with the FLAG FILE'S age, never today",
           fleet_tui.ask_age(dict(fleet_tui.ask_detail(old[0])["trailers"])["added"]) == "3d",
           fleet_tui.ask_detail(old[0])["trailers"])

        # ── A BRACKET IN A TRAILER VALUE NO LONGER EATS THE WHOLE LINE ──────────────────
        # Trailers are bitten off RIGHT TO LEFT, so a `[` in the LAST one used to stop the
        # loop and leave every trailer to its LEFT unparsed as well. The collateral is what
        # makes this worth a test: the ask silently lost its `added` stamp — so no age and
        # the wrong sort slot — its `short` form and its `ticket`, and dumped the raw
        # trailer text into the row. `jq '.a[0]'` is an ordinary command.
        for cmd in ("jq '.a[0]'", "git log --format='%h [%s]'"):
            bt = dict(fleet_tui.ask_trailers(
                "todo: run it [SRV-9] [added:2026-08-19] [short:run] [cmd:%s]" % cmd)[1])
            ok("a `[` inside [cmd:%s] costs neither its own value…" % cmd[:12],
               bt.get("cmd") == cmd, bt)
            ok("…nor the trailers written to its LEFT, which is the damage that hid it",
               (bt.get("added"), bt.get("short"), bt.get("ticket"))
               == ("2026-08-19", "run", "SRV-9"), bt)
        # THE WIDENING MUST NOT SWALLOW PROSE. A bracketed aside in the ask's own text is
        # not a trailer, and a pattern loose enough to fix the above could easily take it.
        pt, ptr = fleet_tui.ask_trailers("todo: see [fig 2] and decide [added:2026-08-19]")
        ok("…while a bracketed aside in the PROSE is still prose, not a trailer",
           (pt, dict(ptr)) == ("todo: see [fig 2] and decide", {"added": "2026-08-19"}),
           (pt, ptr))

        # ── THE ACTION BADGES: 🔎 focus-monocle and 📋 copy-command ─────────────────────
        # These shipped UNTESTED and, measured against textual 8.2.8, all three of their
        # moving parts were wrong. Each block below states the defect it pins.

        # (1) THE ARGUMENT IS PERCENT-ENCODED, and the round trip must be exact for the
        # characters a shell command actually contains. The escape this replaced emitted
        # `\'` for a quote, which textual's markup grammar has no rule for at all.
        HOSTILE = ["/lanes/feature-1", "git commit -m 'wip'", 'jq ".a"', "a\\b",
                   "pnpm test --grep 'a[b]c' | head -5", "goals—onchain", ""]
        ok("every action argument survives the encode/decode round trip byte for byte",
           [fleet_tui._adec(fleet_tui._aesc(v)) for v in HOSTILE] == HOSTILE,
           [(v, fleet_tui._aesc(v)) for v in HOSTILE])
        ok("…and the encoding emits nothing the markup grammar can mistake for syntax",
           not (set("".join(fleet_tui._aesc(v) for v in HOSTILE)) & set("'\"[]\\")),
           [fleet_tui._aesc(v) for v in HOSTILE])

        # (2) THE ROW STILL PARSES. This is the assertion with teeth: `Static` parses markup
        # during compose, so a row carrying a quoted command used to raise MarkupError from
        # inside the mount and take the app down — the crash class the `linkify` docstring
        # records. Parsed with the SAME function `Static` uses, not a regex that approximates
        # it, and the positive control is the second case: it is the one that used to raise.
        from textual.content import Content
        for label, cmd in (("a plain command", "pnpm test"),
                           ("a command containing quotes AND brackets",
                            "git log --format='%h [%s]' | head")):
            raw = "todo: run it [added:2026-08-19] [cmd:%s]" % cmd
            markup = fleet_tui.ask_row_markup(3, raw, {})
            try:
                Content.from_markup(markup)
                parsed, err = True, ""
            except Exception as e:
                parsed, err = False, "%s: %s" % (type(e).__name__, e)
            ok("a 4ME row carrying %s renders as valid markup" % label, parsed, err)
            ok("…and the badge that makes it clickable is actually on the row",
               fleet_tui.CMD_BADGE in markup, markup)

        # (3) THE CLICK'S OWN SUBJECT REACHES THE HANDLER. Textual resolves
        # `@click=app.copy_cmd(…)` to `action_copy_cmd`, never to the plain `copy_cmd` the
        # markup names, and `invoke()` silently truncates the arguments to the callable's
        # arity — so the zero-arg handler this replaced accepted the click and then acted on
        # whatever row the CURSOR was on. The test drives the real dispatcher for that
        # reason: calling the method directly would prove nothing about the resolution.
        CMD = "git commit -m 'it works'"
        raw = "todo: ship it [added:2026-08-19] [cmd:%s] [review:/lanes/feature-9]" % CMD
        markup = fleet_tui.ask_row_markup(4, raw, {})
        copied, reviewed = [], []
        real_copy, real_open = fleet_tui.FleetTUI.copy_cmd, fleet_tui.FleetTUI.open_review
        fleet_tui.FleetTUI.copy_cmd = lambda self, c: copied.append(c)
        fleet_tui.FleetTUI.open_review = lambda self, p: reviewed.append(p)
        try:
            # Driven through textual's OWN dispatcher, exactly as a click on the badge
            # would be — the resolution is the thing under test.
            for act in ("copy_cmd", "open_review"):
                ok("the %s badge's action is present in the row's markup" % act,
                   "app.%s(" % act in markup, markup)
            await app.run_action("app.copy_cmd('%s')" % fleet_tui._aesc(CMD))
            await app.run_action("app.open_review('%s')" % fleet_tui._aesc("/lanes/feature-9"))
            await pilot.pause()
            ok("clicking 📋 copies THAT row's command, quotes intact — not the cursor row's",
               copied == [CMD], copied)
            ok("clicking 🔎 opens THAT row's review path — not the cursor row's",
               reviewed == ["/lanes/feature-9"], reviewed)
            # THE KEYBINDING MUST STILL WORK. One entry point now serves both, so a fix that
            # made the click work by breaking `y`/`m` would otherwise pass everything above.
            copied.clear()
            await app.run_action("copy_cmd")
            await pilot.pause()
            ok("…while `y` with no argument still asks the cursor, rather than raising",
               copied == [] or isinstance(copied[0], str), copied)
        finally:
            fleet_tui.FleetTUI.copy_cmd = real_copy
            fleet_tui.FleetTUI.open_review = real_open

        # (4) THE MONOCLE PANE IS FOUND BY cwd AND RETURNED AS A STABLE `%id`. tmux is stubbed
        # at the subprocess seam — what is under test is the parse and the match, not tmux.
        # The fixture mirrors a REAL `list-panes -a` reading taken 2026-08-19, including the
        # decoy: an agent pane whose cwd is a monocle CHECKOUT but which is not running it.
        PANES = ("%158 monocle /Users/john/lanes/feature-1\n"
                 "%160 monocle /Users/john/lanes/feature-2\n"
                 "%16 2.1.228 /Users/john/git/monocle\n"
                 "%220 zsh /Users/john/lanes/feature-1\n")
        real_run = fleet_tui.subprocess.run
        asked = []
        fleet_tui.subprocess.run = lambda *a, **k: (
            asked.append(a[0]) or type("R", (), {"stdout": PANES, "returncode": 0})())
        try:
            mp = fleet_tui.FleetTUI._monocle_pane
            ok("the monocle serving a lane is found by cwd, as a stable %id",
               mp("/Users/john/lanes/feature-2") == "%160", mp("/Users/john/lanes/feature-2"))
            ok("…and a shell sitting in the same lane is NOT mistaken for it",
               mp("/Users/john/lanes/feature-1") == "%158", mp("/Users/john/lanes/feature-1"))
            ok("…a pane merely CHECKED OUT in a monocle repo is not a monocle pane",
               mp("/Users/john/git/monocle") == "", mp("/Users/john/git/monocle"))
            ok("…and a lane with no monocle says so instead of guessing a neighbour",
               [mp("/Users/john/lanes/feature-7"), mp("")] == ["", ""],
               [mp("/Users/john/lanes/feature-7"), mp("")])
            # IT MUST ASK TMUX FOR `#{pane_id}`, and that is asserted against the REQUEST,
            # not the reply: a stub answers in whatever shape the fixture is written in, so
            # a test that only reads the return value goes on passing after the format
            # string is changed back to the `session:window.pane` index form — which
            # renumbers whenever an earlier pane is killed, silently retargeting the badge.
            ok("…and it asks tmux for the STABLE pane id, not the renumbering index form",
               any("#{pane_id}" in " ".join(a) for a in asked)
               and not any("#{pane_index}" in " ".join(a) for a in asked), asked)
        finally:
            fleet_tui.subprocess.run = real_run

        # A DOC LINK IN THE CONTEXT STILL EARNS THE ROW'S BADGE. Moving detail into a context
        # block moved the links with it, and the row silently lost the one glyph on it that
        # is clicked rather than read.
        ctx_doc = {"linear_base": "", "repo": ""}
        with_ctx = fleet_tui.ask_row_markup(
            1, "todo: read this [added:2026-08-19]\nfile:///tmp/findings.md", ctx_doc)
        ok("a document referenced only in the CONTEXT still badges the row",
           "file:///tmp/findings.md" in with_ctx, with_ctx)
        ok("…and the context prose itself never reaches the row",
           "findings.md" not in with_ctx.split("[link=")[0], with_ctx)

        ok("a real date yields a real age", fleet_tui.ask_age("2026-01-01") != "")
        ok("…and a malformed stamp yields no age rather than raising",
           [fleet_tui.ask_age(s) for s in ("", "nope", "2026-13-01", "26-1-1")]
           == ["", "", "", ""],
           [fleet_tui.ask_age(s) for s in ("", "nope", "2026-13-01", "26-1-1")])

        CTX = {"linear_base": "https://linear.app/acme",
               "repo": "https://github.com/acme/goals"}
        ok("a ticket trailer resolves to the tracker's own deep link",
           fleet_tui.ask_ticket_url("SRV-24", CTX) == "linear://acme/issue/SRV-24")
        ok("a PR trailer resolves against the repo",
           fleet_tui.ask_ticket_url("PR#147", CTX)
           == "https://github.com/acme/goals/pull/147")
        # NEVER A GUESSED BASE. A link that 404s is worse than plain text, because it looks
        # authoritative — the same rule linkify already holds itself to.
        ok("…and with no base learned there is no URL, rather than an invented one",
           fleet_tui.ask_ticket_url("SRV-24", {}) == "")

        CHAIN = ["1. SRV-11", "2. SRV-21", "3. MON-10"]
        ok("a ticket named in the goal chain is on the chain",
           fleet_tui.goal_mentions("MON-10", "finish the chain", CHAIN))
        ok("…and one named in the objective line itself is too",
           fleet_tui.goal_mentions("DX-6", "ship DX-6 end to end", []))
        ok("a ticket the goal does not name is not",
           not fleet_tui.goal_mentions("SRV-99", "finish the chain", CHAIN))
        # WHOLE IDS ONLY. `SRV-1` is a different ticket from `SRV-11`, and usually a different
        # lane — a substring match here would put the goal marker on the wrong ask.
        ok("…and a prefix of a chain id does not count as a mention",
           not fleet_tui.goal_mentions("SRV-1", "finish the chain", CHAIN))
        ok("no ticket at all is never on the chain",
           not fleet_tui.goal_mentions("", "finish the chain", CHAIN))

        # ── a bracket in the prose must not take the TUI down ────────────────────────────
        # FOUND BY MUTATION-TESTING THIS FEATURE, and pre-existing: `linkify` was called as
        # `linkify(escape(text))` on the reasoning that ids contain no brackets. True, and
        # beside the point — the hazard is the text AROUND the id. `rich.markup.escape` only
        # escapes a `[` that already looks like a tag, so `[PR#124]` (capital P) survived
        # unescaped, linkify inserted a link INSIDE it, and the renderer saw `[PR…]` as an
        # opening tag with a stray `[/link]` after it: MarkupError, whole app down. One fleet
        # ask or lane status mentioning a bracketed PR was enough.
        #
        # Asserted through the REAL renderer, not by eyeballing the string: the bug was that
        # markup which looks plausible does not parse, so only parsing it proves anything.
        from textual.markup import to_content

        def renders(s):
            try:
                to_content(s)
                return True
            except Exception:
                return False

        CRASHERS = ["merge the release PR [PR#124] now",
                    "see [SRV-24] and [PR#9] before deciding",
                    "a [bracket] with no id at all",
                    "trailing bracket [",
                    "[link] is a word here"]
        ok("prose containing a bracketed id still renders",
           all(renders(fleet_tui.linkify(c, CTX)) for c in CRASHERS),
           [c for c in CRASHERS if not renders(fleet_tui.linkify(c, CTX))])
        # …and the link is still MADE — an escape that worked by disabling linkification
        # would pass the test above while silently costing every id on the screen its link.
        ok("…and the id inside the brackets is still linked",
           "]#124[/link]" in fleet_tui.linkify("merge the release PR [PR#124] now", CTX),
           fleet_tui.linkify("merge the release PR [PR#124] now", CTX))
        ok("…with the literal bracket kept, escaped rather than eaten",
           "\\[PR" in fleet_tui.linkify("merge the release PR [PR#124] now", CTX),
           fleet_tui.linkify("merge the release PR [PR#124] now", CTX))

        ok("an added-date becomes an age the reader does not have to compute",
           fleet_tui.ask_age(
               time.strftime("%Y-%m-%d", time.localtime(time.time() - 3 * 86400))) == "3d",
           fleet_tui.ask_age(
               time.strftime("%Y-%m-%d", time.localtime(time.time() - 3 * 86400))))
        ok("…and a stamp that is not a date yields nothing rather than a guess",
           fleet_tui.ask_age("last tuesday") == "" and fleet_tui.ask_age("") == "")

        # ── the 4ME category filter (`c`) ────────────────────────────────────────────────
        # The property that matters is not "the right rows are shown" — it is that a row's
        # NUMBER does not move when they are. A human reading a filtered panel says "4me 3"
        # and the lead reads line 3 of the file; renumbering would make those two different
        # asks, silently, depending on a filter the lead cannot see.
        with open(fleet_path, "w") as f:
            f.write("product: a scoping call\n"
                    "fleet: the machinery\n"
                    "ship: merge #124\n"
                    "fleet: more machinery\n"
                    "✅ RESOLVED — done last week\n")
        app.load()
        await pilot.pause()
        await pilot.pause()

        def fleet_title():
            return str(app.query_one("#fleet").border_title)

        def fleet_numbers():
            return [w.n for w in app.query_one("#fleet").children
                    if isinstance(w, fleet_tui.Ask)]

        ok("unfiltered, every row is there and the title is a bare count",
           fleet_numbers() == [1, 2, 3, 4, 5] and fleet_title() == "4ME  (5)  ↓latest",
           "%s / %s" % (fleet_numbers(), fleet_title()))

        await pilot.press("c")
        await pilot.pause()
        ok("c filters to the first kind PRESENT, in the kinds' declared order",
           app.ask_filter == "product" and fleet_numbers() == [1], app.ask_filter)
        ok("…and the title says which, with its icon and shown/total",
           fleet_title() == "4ME  (1/5)  ↓latest [💬 product]", fleet_title())

        await pilot.press("c")
        await pilot.pause()
        ok("the next press moves to the next kind present, skipping the absent ones",
           app.ask_filter == "ship" and fleet_numbers() == [3], app.ask_filter)

        await pilot.press("c")
        await pilot.pause()
        ok("THE NUMBERS KEEP THEIR GAPS — a number is an address, not a position",
           app.ask_filter == "fleet" and fleet_numbers() == [2, 4],
           "%s %s" % (app.ask_filter, fleet_numbers()))

        await pilot.press("c")
        await pilot.pause()
        ok("an untyped / resolved row is reachable under `todo`, not stranded",
           app.ask_filter == "todo" and fleet_numbers() == [5],
           "%s %s" % (app.ask_filter, fleet_numbers()))

        await pilot.press("c")
        await pilot.pause()
        ok("the cycle returns to ALL rather than settling on a subset",
           app.ask_filter == "" and fleet_numbers() == [1, 2, 3, 4, 5]
           and fleet_title() == "4ME  (5)  ↓latest", "%s / %s" % (app.ask_filter, fleet_title()))

        # A FILTER IS A VIEW. `x` deletes by exact line match, so it must delete the row the
        # cursor is ON — not the row that would sit at that position unfiltered.
        await pilot.press("c")
        await pilot.press("c")
        await pilot.press("c")           # → fleet: rows 2 and 4
        await pilot.pause()
        app.query_one("#fleet").focus()
        app.query_one("#fleet").index = 0
        await pilot.pause()
        await pilot.press("x")
        await pilot.pause()
        body = open(fleet_path).read()
        ok("x under a filter clears the row the cursor is on, not the one at that position",
           "fleet: the machinery\n" not in body and "product: a scoping call" in body, body)
        await pilot.press("u")
        await pilot.pause()
        ok("…and undo puts it back",
           "fleet: the machinery\n" in open(fleet_path).read(), open(fleet_path).read())

        # A resolved line renders ONE tick. It is written with a ✅ and carries no kind, so
        # both the written glyph and the general icon used to land on the same row.
        ok("a resolved row is not double-ticked",
           fleet_tui.ask_row_markup(1, "✅ RESOLVED — done") .count("✅") == 1,
           fleet_tui.ask_row_markup(1, "✅ RESOLVED — done"))
        ok("a fleet: ask wears the machinery glyph",
           "🔧" in fleet_tui.ask_row_markup(1, "fleet: the machinery"),
           fleet_tui.ask_row_markup(1, "fleet: the machinery"))
        # The lead writes this file by hand: an unknown kind must render, never crash.
        # An unrecognised kind is NOT dropped and NOT a crash: it renders under the neutral
        # glyph with its token intact (so the reader can see the lead typed something this
        # build does not know), and it is reachable — as a general item, which is what an
        # unclassifiable ask is. The alternative, a row that exists in the file and appears
        # under no filter at all, is the one outcome a filter must never produce.
        UNK = ["wobble: who knows"]
        ok("an unknown kind renders neutrally, keeping its token",
           fleet_tui.ask_row_markup(1, UNK[0]).count("✅") == 1
           and "wobble:" in fleet_tui.ask_row_markup(1, UNK[0]),
           fleet_tui.ask_row_markup(1, UNK[0]))
        ok("…and is reachable rather than stranded outside every filter",
           fleet_tui.ask_kinds_present(UNK) == ["todo"]
           and fleet_tui.filter_asks(UNK, "todo") == [(1, UNK[0])],
           "%s %s" % (fleet_tui.ask_kinds_present(UNK), fleet_tui.filter_asks(UNK, "todo")))

        app.ask_filter = ""
        app.sig = None
        app.load()
        await pilot.pause()
        await pilot.pause()

    # ── a lane's open PR, beside its ticket ──────────────────────────────────────────────
    # Driven against pr_markup directly rather than restarting the app three times. The
    # two cases that could LIE are the ones worth locking: a PR shown for a lane that has
    # none, and a draft presented as if it were ready to merge.
    #
    # A row dict is the whole fixture: these builders are free functions over (row, ctx),
    # which they have to be — the fit calls them to measure a card's wrapped height before
    # any widget exists — so the Lane stand-in this block used to need is gone.
    lane_row = {"name": "feature-1", "label": "vii", "state": "idle", "kind": "lane"}
    mk = fleet_tui.pr_markup

    ready = mk(dict(lane_row, open_prs=[(999, "https://gh/x/pull/999", False)]))
    draft = mk(dict(lane_row, open_prs=[(1000, "https://gh/x/pull/1000", True)]))
    none_ = mk(dict(lane_row))

    ok("an open PR renders its number", "#999" in ready, ready)
    ok("…as a clickable https link — GitHub registers no custom scheme",
       "[link='https://gh/x/pull/999']" in ready, ready)
    ok("a draft PR is marked", "#1000…" in draft, draft)
    ok("…and is dim rather than green, so it cannot read as ready to merge",
       "dim" in draft and "b green" not in draft, draft)
    ok("a lane with no PR renders nothing at all", none_ == "", repr(none_))

    # MULTIPLE PRs, like the tickets beside them. Showing only the first is a lie that looks
    # like a fact — the reader cannot tell one-PR from first-of-two.
    two = mk(dict(lane_row, open_prs=[(1, "https://gh/x/pull/1", False),
                                      (2, "https://gh/x/pull/2", True)]))
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
    over = fleet_tui.head_markup(dict(lane_row, context_pct=216, issue_links=[]))
    ok("a percentage over 100 is not printed as a confident number", "216%" not in over, over)
    ok("…it says >100% instead", ">100%" in over, over)
    ok("…louder than a merely-full lane, since it means the gauge is broken",
       "[b red]" in over, over)
    fine = fleet_tui.head_markup(dict(lane_row, context_pct=45, issue_links=[]))
    ok("a percentage in range is still printed plainly", " 45%" in fine, fine)

    # ── THE HEAD LINE IS A TABLE, so every column starts at the same offset on every row ──
    # Until fixed widths landed, only the MINIMUM of each column was pinned (`:<11` pads a
    # short name and lets a long one push everything right), so `manual-test-audit` shifted
    # state, context and uptime six columns right ON ITS ROW ONLY and the panel read as
    # columns that resize as agents come and go.
    def plain(markup):
        return fleet_tui.Text.from_markup(markup).plain

    long_name = dict(lane_row, name="manual-test-audit", issue_links=[("SRV-24", "")])
    short_name = dict(lane_row, name="a", issue_links=[("SRV-24", "")])
    ok("a name past its budget is cut in the MIDDLE, keeping both ends",
       fleet_tui.fit_name("manual-test-audit") == "manua..audit",
       fleet_tui.fit_name("manual-test-audit"))
    ok("…and a name that fits is untouched, not padded into a cut",
       fleet_tui.fit_name("g-feature-1") == "g-feature-1",
       fleet_tui.fit_name("g-feature-1"))
    # The cut must be a middle cut rather than a tail cut, because fleet names share their
    # prefixes: two lanes cut at the tail read as the same agent.
    ok("…so two names sharing a long prefix stay distinguishable",
       fleet_tui.fit_name("machinery-findings-a")
       != fleet_tui.fit_name("machinery-findings-b"),
       (fleet_tui.fit_name("machinery-findings-a"),
        fleet_tui.fit_name("machinery-findings-b")))
    ok("no rendered name can be wider than its column",
       all(len(fleet_tui.fit_name(n)) <= fleet_tui.NAME_W
           for n in ("manual-test-audit", "g-feature-1", "a", "x" * 80, "")),
       [fleet_tui.fit_name(n) for n in ("manual-test-audit", "x" * 80)])

    # THE ASSERTION THAT CATCHES A WIDENING COLUMN: the same field starts at the same index
    # whatever is in the row before it. Measured on the PLAIN text, which is what the reader
    # sees — the markup's length is link tags nobody renders.
    ok("the state column starts at one offset whatever the name's length",
       plain(fleet_tui.head_markup(long_name)).index("idle")
       == plain(fleet_tui.head_markup(short_name)).index("idle"),
       (plain(fleet_tui.head_markup(long_name)),
        plain(fleet_tui.head_markup(short_name))))
    ok("…and so does the ticket column",
       plain(fleet_tui.head_markup(long_name)).index("SRV-24")
       == plain(fleet_tui.head_markup(short_name)).index("SRV-24"),
       (plain(fleet_tui.head_markup(long_name)),
        plain(fleet_tui.head_markup(short_name))))
    ok("…and a full-width name still has a space before the next column",
       " idle" in plain(fleet_tui.head_markup(long_name)),
       plain(fleet_tui.head_markup(long_name)))

    # The ticket column is the LAST fixed one, so the PR list is what a widening ticket cell
    # would push around. Whole ids are dropped rather than cut in half — half an id is a
    # different id that still looks like one — and the count of the dropped ones is shown.
    one_id = dict(lane_row, issue_links=[("SRV-24", "")],
                  open_prs=[("88", "https://gh/x/pull/88", False)])
    many_ids = dict(one_id, issue_links=[("SRV-24", ""), ("MON-10", ""), ("FEAT-9", ""),
                                         ("DX-16", ""), ("SRV-118", "")])
    ok("the PR column starts at one offset however many tickets the lane carries",
       plain(fleet_tui.head_markup(one_id)).index("#88")
       == plain(fleet_tui.head_markup(many_ids)).index("#88"),
       (plain(fleet_tui.head_markup(one_id)), plain(fleet_tui.head_markup(many_ids))))
    # The count is derived from what actually rendered rather than written as a literal, so
    # the row states the invariant (every dropped id is counted) instead of restating the
    # column width — which is a number that moves when the pane does.
    _shown = plain(fleet_tui.head_markup(many_ids))
    _dropped = sum(1 for i, _ in many_ids["issue_links"] if i not in _shown)
    ok("…and the ids that did not fit are COUNTED, not silently dropped",
       _dropped and "+%d" % _dropped in _shown, (_dropped, _shown))
    ok("…while no id is cut into a different, valid-looking id",
       "SRV-1" not in plain(fleet_tui.head_markup(many_ids)).replace("SRV-118", ""),
       plain(fleet_tui.head_markup(many_ids)))
    ok("a single over-long id is clipped rather than replaced by a bare count",
       fleet_tui.fit_ids([("VERYLONGPROJECT-1234567890123456789012345", "x")])[0]
       .endswith("…"),
       fleet_tui.fit_ids([("VERYLONGPROJECT-1234567890123456789012345", "x")]))
    # ── 🔍 A REVIEW STAGED FOR THE HUMAN ────────────────────────────────────────────────
    # A lane waiting on a person renders `idle`, which is also what a lane with nothing to do
    # renders — opposite facts about whose turn it is, drawn identically. The marker is read
    # from a flag file the lane writes, never by probing an engine that answers "nothing
    # pending" whether or not it is even up.
    with tempfile.TemporaryDirectory() as td:
        flag = os.path.join(td, fleet_tui.REVIEW_FILE)
        ok("no flag file means nothing is staged, rather than an unknown",
           fleet_tui.staged_review(flag) is None)
        with open(flag, "w") as fh:
            fh.write("SRV-28 diff\n")
        got = fleet_tui.staged_review(flag)
        ok("a flag file names the review and how long it has waited",
           got and got["name"] == "SRV-28 diff" and got["age"] < 5, got)
        # The age rides on the FILE's mtime, so it cannot go stale the way a stamp written
        # into the body does — and a lane that rewrites the file re-dates it by writing.
        # Dated against fleet_tui's OWN clock seam, which earlier rows in this suite hold
        # still — time.time() here would measure the distance to a frozen now.
        old = fleet_tui._now() - 3600
        os.utime(flag, (old, old))
        ok("…and the age is the file's own mtime, not a line inside it",
           3500 < fleet_tui.staged_review(flag)["age"] < 3700,
           fleet_tui.staged_review(flag))
        # An empty file is the shape a lane writes when it has no name handy. It must not
        # read as "waiting on nobody" — the fact the user acts on is that a review exists.
        with open(flag, "w") as fh:
            fh.write("")
        ok("an EMPTY flag file still means staged", fleet_tui.staged_review(flag) is not None,
           fleet_tui.staged_review(flag))

        # ── RETIRING A FLAG, which is the only way to clear a derived row ────────────────
        # THE FILE'S EXISTENCE IS THE SIGNAL, so the file is what has to go. A record kept
        # BESIDE it — dismissed ids, a stored mtime, a hash — would have to be invalidated by
        # whatever stages the next review, and nothing documents who that is: `grep -rnF
        # monocle-staged` over the repo finds only the constant that READS it. A suppression
        # record that guessed wrong would hide a real review, which is worse than the stale
        # row it cleared. Removing the file assumes nothing about the writer.
        with open(flag, "w") as fh:
            fh.write("SRV-28 diff\nbase_ref: abc123 — the merge base, deliberately\n")
        why = fleet_tui.retire_staged_review(flag, "approved in monocle, engine lost it")
        ok("retiring a flag clears the signal and reports no error",
           (why, os.path.exists(flag)) == ("", False), (why, os.path.exists(flag)))
        cleared = open(flag + ".cleared").read()
        # THE HAND-AUTHORED CONTENT SURVIVES. These files carry review provenance a person
        # wrote — base_ref reasoning, diff stats, which rounds were audited — and a clear
        # that discarded it would destroy the only record of what was being cleared.
        ok("…keeping what the flag said, and the note, in a log beside it",
           ("base_ref: abc123 — the merge base, deliberately" in cleared
            and "approved in monocle, engine lost it" in cleared), cleared)
        ok("…and the row stops being synthesised, because nothing is staged any more",
           fleet_tui.staged_review(flag) is None)
        # A SECOND CLEAR APPENDS. Clobbering would mean the newest clear silently erased the
        # record of the previous one — the log exists precisely because these decisions are
        # the only surviving answer to "why is this not on the list".
        with open(flag, "w") as fh:
            fh.write("SRV-31 diff\n")
        fleet_tui.retire_staged_review(flag, "second one")
        twice = open(flag + ".cleared").read()
        ok("…and a later clear APPENDS to that log rather than clobbering it",
           ("SRV-28 diff" in twice and "SRV-31 diff" in twice
            and twice.count("=== cleared ") == 2), twice)
        ok("a lane with no flag at all is refused, not silently reported as cleared",
           fleet_tui.retire_staged_review(flag, "n") != "")

    # IT FAILS TOWARD THE ROW STAYING UP. If the log cannot be written the flag must be left
    # exactly where it is: clearing a signal we just failed to record reproduces the silence
    # the feature exists to fix. Forced by making the log path a DIRECTORY, so the append
    # raises for a reason nothing else in the test has to simulate.
    with tempfile.TemporaryDirectory() as td:
        blocked = os.path.join(td, fleet_tui.REVIEW_FILE)
        with open(blocked, "w") as fh:
            fh.write("SRV-40 diff\n")
        os.makedirs(blocked + ".cleared")
        why = fleet_tui.retire_staged_review(blocked, "a note")
        ok("a clear that cannot be recorded leaves the flag UP and says so",
           why != "" and os.path.exists(blocked), (why, os.path.exists(blocked)))

    staged = dict(lane_row, issue_links=[("SRV-24", "")], review={"name": "d", "age": 60})
    unstaged = dict(lane_row, issue_links=[("SRV-24", "")])
    ok("a staged lane wears the magnifier on its row",
       fleet_tui.REVIEW in plain(fleet_tui.head_markup(staged)),
       plain(fleet_tui.head_markup(staged)))
    ok("…and an unstaged one does not",
       fleet_tui.REVIEW not in plain(fleet_tui.head_markup(unstaged)),
       plain(fleet_tui.head_markup(unstaged)))
    # THE POINT OF A FIXED SLOT: measured in DISPLAY CELLS, because the glyph is
    # emoji-presentation and occupies two of them while len() calls it one. Padding it by
    # character count would shift every column right of it on staged rows only.
    ok("…and the columns after it do not move when it appears",
       cell_len(plain(fleet_tui.head_markup(staged)).split("SRV-24")[0])
       == cell_len(plain(fleet_tui.head_markup(unstaged)).split("SRV-24")[0]),
       (plain(fleet_tui.head_markup(staged)), plain(fleet_tui.head_markup(unstaged))))

    # The row affords one glyph; the dialog is where the name and the wait go.
    class _StubApp:
        data = {"ctx": {}}

    detail = {"name": "feature-2", "label": "ott", "path": "/lanes/feature-2",
              "state": "idle", "context_pct": 40, "live": None,
              "review": {"name": "SRV-28 diff", "age": 900}}
    head = fleet_tui.FleetTUI.detail_head_markup(_StubApp(), detail)
    ok("the dialog names the staged review and how long it has been waiting",
       "SRV-28 diff" in head and "15m" in head, head)
    ok("…and says nothing at all when none is staged",
       fleet_tui.REVIEW not in fleet_tui.FleetTUI.detail_head_markup(
           _StubApp(), dict(detail, review=None)),
       fleet_tui.FleetTUI.detail_head_markup(_StubApp(), dict(detail, review=None)))

    # ── EVERY KIND ICON IS A GLYPH THE TERMINAL CAN ACTUALLY DRAW ───────────────────────
    # `triage` was U+1F3F7 + U+FE0F and drew a GREY BOX on the machine this list is written
    # for: U+1F3F7 has Emoji_Presentation=No, so it needs the variation selector to be emoji
    # at all — and a codepoint that rare is the one an emoji font is missing. The same rarity
    # made it MEASURE wrong (rich reports two cells; the terminal drew one box), which is why
    # the prose after it started a column early in every row and in the dialog head.
    #
    # THE INVARIANT IS STRUCTURAL, not a cell count: cell_len already believed the broken
    # glyph was two wide, so a width assertion alone passes on the defect. One codepoint,
    # already Wide, no variation selector — that is what would have caught it.
    for _kind, _icon in ASK_KINDS.items():
        ok("the %s icon is one already-emoji codepoint, needing no VS16" % _kind,
           len(_icon) == 1 and unicodedata.east_asian_width(_icon) == "W",
           (_icon, [hex(ord(c)) for c in _icon]))
    _prefix = {k: plain(fleet_tui.ask_row_markup(1, "%s: PROSE" % k, {})).split("PROSE")[0]
               for k in ASK_KINDS}
    ok("…so every 4ME row starts its prose at the same display column",
       len({cell_len(v) for v in _prefix.values()}) == 1, _prefix)

    class _AskApp:
        ask = {"n": 1}
        data = {"ctx": {}}

    _head = {k: plain(fleet_tui.FleetTUI.ask_head_markup(
        _AskApp(), fleet_tui.ask_detail("%s: x" % k))) for k in ASK_KINDS}
    ok("…and the dialog head puts every kind's label at the same column, which is the "
       "misalignment beside `triage`",
       len({cell_len(v.split(k)[0]) for k, v in _head.items()}) == 1, _head)

    # ── A DOC REFERENCE IN A 4ME ROW BECOMES ONE CLICKABLE PAGE GLYPH ────────────────────
    # The live ask this was built for, verbatim in shape: the path is longer than the column
    # and the prose runs past sixty characters BEFORE reaching it, so an in-place glyph alone
    # would have vanished in exactly the case that motivated the feature.
    DOCPATH = ("/Users/john/git/goals-onchain/.claude/worktrees/team-lead/.claude/plans/"
               "findings-consolidated-2026-08-17.md")
    FINDINGS = ("triage: CONSOLIDATED FINDINGS — 12 items merged, needs your triage — "
                "file://%s — pick the P0s" % DOCPATH)
    _row = fleet_tui.ask_row_markup(3, FINDINGS, {})
    ok("a doc reference in a 4ME row is a link to the file, not a path in the prose",
       "[link='file://%s']%s[/link]" % (DOCPATH, fleet_tui.DOC) in _row, _row)
    ok("…and the path itself is off the row, which is the width it was eating",
       ".claude/plans" not in plain(_row), plain(_row))
    ok("…and the glyph is the LAST thing on the row (John 2026-08-18)",
       plain(_row).rstrip().endswith(fleet_tui.DOC), plain(_row))
    # THE BADGE IS PAID FOR OUT OF THE PROSE. Appended to a row already filling its column it
    # wraps the list item onto a second line — a whole row of the panel spent on one glyph,
    # which is what the live 4ME list did before the budget settled.
    # Measured against the column's OWN ceiling — a row of unbroken text, which clips to the
    # full budget — rather than against another ask, whose width is one character short for
    # the incidental reason that clip trims the space it cut at.
    _widest = fleet_tui.ask_row_markup(3, "triage: " + "x" * 200, {})
    ok("…without spending more than the column's budget, which would wrap the row",
       cell_len(plain(_row)) <= cell_len(plain(_widest)),
       (cell_len(plain(_row)), cell_len(plain(_widest))))
    _short = fleet_tui.ask_row_markup(4, "plan: read /tmp/a.md before the gate", {})
    ok("a bare absolute .md path is a doc reference too",
       "[link='file:///tmp/a.md']%s[/link]" % fleet_tui.DOC in _short, _short)
    # THE SHORT ASK IS WHERE THE POSITION IS DECIDABLE. On the long one the clip puts the
    # glyph at the end whatever the rule is, so only a row whose path would have FIT can tell
    # end-of-line from in-place — and this one used to render `read 📄 before the gate`.
    ok("…and it rides the end of the line even when it would have fitted in the sentence",
       plain(_short).rstrip().endswith("before the gate " + fleet_tui.DOC), plain(_short))
    # ASSERTED ON THE SHORT ASK, where the path would otherwise have FIT. On the long one the
    # clip removes it either way, so the same words there prove nothing about this change.
    ok("…and the path is replaced rather than shown beside the glyph",
       "/tmp/a.md" not in plain(_short), plain(_short))
    # THE GAP THE PATH LEFT IS CLOSED. Dropping the mark alone left `read  before the gate` —
    # a double space where a word had been, which reads as a typo rather than as a link.
    ok("…and the prose closes over the gap the path left",
       "read before the gate" in plain(_short), plain(_short))
    # THE ORDER IS THE POINT: the mark is substituted before the clip and linked after it, so
    # a path containing an id cannot have a ticket link inserted INSIDE the href.
    ok("a path containing a ticket id is not linkified inside its own href",
       "[link='file:///tmp/SRV-24.md']" in fleet_tui.ask_row_markup(
           5, "plan: /tmp/SRV-24.md", {"linear_base": "https://linear.app/acme"}),
       fleet_tui.ask_row_markup(5, "plan: /tmp/SRV-24.md",
                                {"linear_base": "https://linear.app/acme"}))
    ok("prose carrying no doc reference passes through untouched",
       fleet_tui.doc_markup("plain [b]text[/]", []) == "plain [b]text[/]")
    # THE DIALOG KEEPS THE PATH. The row trades it for a glyph because the row is a column;
    # the surface with room is where the location itself has to stay readable and copyable.
    _dlg = fleet_tui.FleetTUI.ask_text_markup(_AskApp(), fleet_tui.ask_detail(FINDINGS), {})
    ok("the 4ME dialog still shows the path in full", DOCPATH in _dlg, _dlg)
    # …AND OPENS IT (John 2026-08-18). Readable but not clickable made the dialog the one
    # surface where you could see where the document lived and not go there.
    ok("…and the path in the dialog is itself the link",
       "[link='file://%s']file://%s[/link]" % (DOCPATH, DOCPATH) in _dlg, _dlg)
    # THE SAME ORDERING GUARANTEE AS THE ROW, on the surface that renders the path rather
    # than a glyph: the id inside the path must not become a ticket link inside the href.
    _dlg_id = fleet_tui.FleetTUI.ask_text_markup(
        _AskApp(), fleet_tui.ask_detail("plan: /tmp/SRV-24.md"),
        {"linear_base": "https://linear.app/acme"})
    ok("…and a ticket id inside that path is not linkified inside its own href",
       "[link='file:///tmp/SRV-24.md']/tmp/SRV-24.md[/link]" in _dlg_id, _dlg_id)

    # ── MONOCLE BUILD DRIFT ─────────────────────────────────────────────────────────────
    # THE FAILURE THIS ENCODES. Four lanes were each running a different stale monocle, one
    # of them a fortnight old, and no surface reported a version — so a shipped feature read
    # as broken and a correct change was rolled back. Driven against fabricated `tmux` and
    # `ps` output, which is the only way to get a STALE lane on demand: the real fleet is
    # current, so a test that only looked at it would assert nothing.
    _PANES = ("monocle\t100\t/lanes/feature-1\n"
              "monocle\t200\t/lanes/feature-2\n"
              "zsh\t300\t/lanes/feature-3\n"                # a shell, not a monocle
              "2.1.233\t400\t/lanes/feature-4\n")           # an agent, not a monocle
    _PS = ("11 100    05:00 monocle\n"                        # 5 minutes old
           "22 200 14-02:00:00 /Users/john/bin/monocle\n"     # a fortnight old, by full path
           "33 300    05:00 zsh\n"
           # A MONOCLE THAT IS NOT THE PANE'S FOREGROUND PROCESS — suspended with ctrl+z, or
           # backgrounded. `pane_current_command` says `zsh`, so this lane HAS no running
           # monocle to be stale, and counting it would mark a lane for a restart of
           # something nobody is looking at.
           "55 300    05:00 monocle\n"
           "44 999    05:00 monocle\n")                       # a monocle in no listed pane
    _NOW = 1_700_000_000.0
    _found = _agent_facts.parse_monocle_procs(_PANES, _PS)
    ok("a monocle pane is joined to its process through the pane's own pid",
       _found == {"/lanes/feature-1": (11, 300),
                  "/lanes/feature-2": (22, 14 * 86400 + 7200)}, _found)
    # THE PANE IS THE FILTER, not the process list: a monocle running outside any listed
    # pane belongs to no lane, and a shell in a lane is not a monocle.
    ok("…and a pane running something else contributes nothing, even with a monocle "
       "still alive underneath it",
       "/lanes/feature-3" not in _found and "/lanes/feature-4" not in _found, _found)

    # THE COMPARISON IS TIMES, NOT VERSIONS. A process that started before the binary was
    # last written cannot be running it — which needs no version string, and is the one fact
    # about a running TUI that is knowable from outside.
    _bin_written = _NOW - 3600          # rebuilt an hour ago
    _drift = _agent_facts.monocle_drift(_PANES, _PS, _bin_written, _NOW)
    ok("a monocle started after the binary was written is NOT stale",
       _drift["/lanes/feature-1"]["stale"] is False, _drift["/lanes/feature-1"])
    ok("…and one that predates it is",
       _drift["/lanes/feature-2"]["stale"] is True, _drift["/lanes/feature-2"])
    # THE NEGATIVE THAT KEEPS THE MARKER HONEST. Every lane on the current build must come
    # back clean, or the marker is noise on every ordinary day and stops being read.
    _all_fresh = _agent_facts.monocle_drift(_PANES, _PS, _NOW - 14 * 86400 - 99999,
                                                      _NOW)
    ok("with the binary older than everything, no lane is marked",
       [v["stale"] for v in _all_fresh.values()] == [False, False], _all_fresh)
    # UNKNOWN IS NOT CURRENT. With no binary to compare against, `stale` is None — a reader
    # who cannot tell must not be shown the same answer as one who checked and found it fine.
    _no_bin = _agent_facts.monocle_drift(_PANES, _PS, 0, _NOW)
    ok("…and with no binary to compare against the answer is unknown, not 'current'",
       all(v["stale"] is None for v in _no_bin.values()), _no_bin)

    ok("an elapsed time is read the same way the console's uptime column reads it",
       (_agent_facts.etime_secs("05:00"),
        _agent_facts.etime_secs("2:03:04"),
        _agent_facts.etime_secs("14-02:00:00"),
        _agent_facts.etime_secs("")) == (300, 7384, 14 * 86400 + 7200, None))

    # ── THE NAME TMUX MATCHES THIS PANE BY ──────────────────────────────────────────────
    # The tmux condition keys off this string, so a change here silently stops the forwarding
    # rule from ever firing — the feature would simply never be reached, with nothing on
    # screen to say why. Pinned so that edit cannot be made accidentally on one side only.
    class _Sink:
        def __init__(self, tty=True):
            self.wrote, self._tty = "", tty

        def isatty(self):
            return self._tty

        def write(self, s):
            self.wrote += s

        def flush(self):
            pass

    _real_env = fleet_tui.os.environ
    try:
        fleet_tui.os.environ = {"TMUX": "/tmp/tmux-501/default,1,0"}
        _sink = _Sink()
        ok("the pane is named with the OSC sequence tmux reads a title from",
           fleet_tui.set_pane_title(stream=_sink) is True
           and _sink.wrote == "\033]2;fleet-tui\007", repr(_sink.wrote))
        # NOT A PIPE. `--json`-style callers and the test harness redirect stdout; an escape
        # written there is corruption of someone's data, not a title.
        _pipe = _Sink(tty=False)
        ok("…and nothing is written when stdout is not a terminal",
           fleet_tui.set_pane_title(stream=_pipe) is False and _pipe.wrote == "",
           repr(_pipe.wrote))
        fleet_tui.os.environ = {}
        _out = _Sink()
        ok("…nor outside tmux, where the title would name nothing",
           fleet_tui.set_pane_title(stream=_out) is False and _out.wrote == "",
           repr(_out.wrote))
    finally:
        fleet_tui.os.environ = _real_env

    # ── THE TMUX HALF OF THE HAND-OFF ───────────────────────────────────────────────────
    # Driven against the argv, not against tmux: a wrong flag would move the user in the
    # wrong direction, which is the one failure here that looks like the feature working.
    _calls = []

    class _Ran:
        returncode = 0

    _real_run, fleet_tui.subprocess.run = fleet_tui.subprocess.run, \
        lambda argv, **kw: (_calls.append(argv), _Ran)[1]
    _real_env = fleet_tui.os.environ
    try:
        fleet_tui.os.environ = {"TMUX": "/tmp/tmux-501/default,1,0", "TMUX_PANE": "%42"}
        ok("each direction becomes tmux's own flag for it, on OUR pane",
           all(fleet_tui.select_pane(d) for d in ("L", "D", "U", "R"))
           and _calls == [["tmux", "select-pane", f, "-t", "%42"]
                          for f in ("-L", "-D", "-U", "-R")], _calls)
        # A DIRECTION THAT IS NOT ONE cannot become a bare `select-pane`, which would move
        # the user somewhere they did not ask to go.
        _calls.clear()
        ok("…and an unknown direction issues no command at all",
           fleet_tui.select_pane("X") is False and _calls == [], _calls)
        # OUTSIDE TMUX THERE IS NOTHING TO HAND OFF TO. Both halves are required: TMUX_PANE
        # survives in the environment of a process that has left tmux behind.
        for _env, _why in (({}, "no tmux at all"),
                           ({"TMUX_PANE": "%42"}, "a stale pane id with no live tmux"),
                           ({"TMUX": "x"}, "tmux with no pane of our own")):
            fleet_tui.os.environ = _env
            _calls.clear()
            ok("no hand-off with %s" % _why,
               fleet_tui.select_pane("L") is False and _calls == [], _calls)
    finally:
        fleet_tui.subprocess.run, fleet_tui.os.environ = _real_run, _real_env

    # ── THE ORDER OF THE AGENT LIST IS FIXED, NOT DISCOVERED (item 7) ────────────────────
    # Driven with the input DELIBERATELY SHUFFLED into the order fleet-status actually
    # produces — alphabetical — because a test fed an already-correct list cannot fail for
    # the defect: it would pass against a sort function that does nothing at all.
    def _agent(name, kind="lane"):
        return {"name": name, "kind": kind}

    _mixed = [_agent(n) for n in ("feature-2", "manual-testing-audit", "feature-10",
                                  "tester", "merge-fst", "feature-1", "team-lead")]
    ok("the lead leads, then the numbered lanes, then the tester, then everything else",
       [r["name"] for r in fleet_tui.order_agents(_mixed)]
       == ["team-lead", "feature-1", "feature-2", "feature-10", "tester",
           "manual-testing-audit", "merge-fst"],
       [r["name"] for r in fleet_tui.order_agents(_mixed)])
    # NUMERICALLY, which alphabetical order gets wrong at exactly ten lanes — the point at
    # which a name sort puts feature-10 between feature-1 and feature-2 and nobody notices
    # because a fleet that size is rare.
    ok("…and lane 10 sorts after lane 2, not between 1 and 2",
       [r["name"] for r in fleet_tui.order_agents(
           [_agent("feature-10"), _agent("feature-2")])] == ["feature-2", "feature-10"])
    # A LANE NAMED `feature-1-old` IS NOT LANE 1. The rank is matched on the whole name, so a
    # retired lane cannot displace the live one it was named after.
    ok("…and a name that merely starts like a lane is not ranked as one",
       fleet_tui.agent_rank(_agent("feature-1-old"))[0] == fleet_tui.RANK_LANE,
       fleet_tui.agent_rank(_agent("feature-1-old")))
    # THE KIND DECIDES BEFORE THE NAME. A subagent may be named exactly like a lane (the
    # standing tester runs as one), and ranking it by name would file it among the lanes.
    ok("a subagent ranks below every lane whatever it is called",
       fleet_tui.agent_rank(_agent("team-lead", "subagent"))[0] == fleet_tui.RANK_SUB,
       fleet_tui.agent_rank(_agent("team-lead", "subagent")))

    # ── THE SUBAGENTS COLLAPSE TO ONE ROW (item 8) ───────────────────────────────────────
    _subs = [{"name": "reviewer-a", "kind": "subagent", "state": "idle", "context_pct": 41},
             {"name": "reviewer-b", "kind": "subagent", "state": "busy", "context_pct": 78},
             {"name": "planner-c", "kind": "subagent", "state": "down", "context_pct": 12}]
    _agg = fleet_tui.subagg_row(_subs)
    _aggplain = plain(fleet_tui.subagg_markup(_agg))
    ok("the aggregate row counts the LIVE subagents, not every registration",
       "2 running" in _aggplain, _aggplain)
    ok("…and reports the highest context, which is the runaway it exists to catch",
       "max ctx 78%" in _aggplain, _aggplain)
    ok("…and says the dead one is dead rather than only omitting it from the count",
       "1 down" in _aggplain, _aggplain)
    # ABSENT, NOT ZERO. A subagent whose transcript cannot be attributed reports no context
    # at all, and "max ctx 0%" would be a measurement where there is none.
    ok("…and with nothing measurable it omits the context clause rather than printing 0%",
       "max ctx" not in plain(fleet_tui.subagg_markup(fleet_tui.subagg_row(
           [{"name": "x", "kind": "subagent", "state": "idle", "context_pct": None}]))),
       plain(fleet_tui.subagg_markup(fleet_tui.subagg_row(
           [{"name": "x", "kind": "subagent", "state": "idle", "context_pct": None}]))))
    # THE COLLAPSE MUST NOT BE THE REASON YOU MISSED SOMETHING. Everything that made an
    # individual row shout is counted here, or hiding the rows would hide the exceptions.
    _loud = fleet_tui.subagg_row([
        {"name": "a", "kind": "subagent", "state": "idle", "needs_input": "which one?"},
        {"name": "b", "kind": "subagent", "state": "idle", "review": 1_700_000_000.0}])
    ok("an ask owed to the user bubbles up to the collapsed row",
       fleet_tui.LANE_ASK in plain(fleet_tui.subagg_markup(_loud)),
       plain(fleet_tui.subagg_markup(_loud)))
    ok("…and so does a staged review",
       fleet_tui.REVIEW in plain(fleet_tui.subagg_markup(_loud)),
       plain(fleet_tui.subagg_markup(_loud)))
    ok("the caret says which way the row will go",
       plain(fleet_tui.subagg_markup(fleet_tui.subagg_row(_subs, True))).startswith(
           fleet_tui.SUBAGG_NAME) and fleet_tui.CARET_OPEN
       in plain(fleet_tui.subagg_markup(fleet_tui.subagg_row(_subs, True))),
       plain(fleet_tui.subagg_markup(fleet_tui.subagg_row(_subs, True))))
    # THE CARETS ARE HELD TO THE SAME GLYPH RULE AS THE KIND ICONS — one codepoint and no
    # U+FE0F — which is what stopped `triage:` from rendering as a grey box.
    for _c in (fleet_tui.CARET_SHUT, fleet_tui.CARET_OPEN):
        ok("caret %r is one codepoint carrying no variation selector" % _c,
           len(_c) == 1 and "\ufe0f" not in _c, repr(_c))
    # ONE LIST, ONE ORDER. `apply` rebuilds from display_rows and `_rows` measures from it,
    # so a disagreement between them would zip the in-place refresh against the wrong rows.
    _rows_shut = fleet_tui.display_rows([_agent("feature-1"), _agent("team-lead")], _subs)
    ok("collapsed, the subagents are one row below the lanes",
       [r["name"] for r in _rows_shut] == ["team-lead", "feature-1", "subagents"],
       [r["name"] for r in _rows_shut])
    _rows_open = fleet_tui.display_rows([_agent("feature-1"), _agent("team-lead")],
                                        _subs, True)
    ok("…and expanded it is followed by them, in their own fixed order",
       [r["name"] for r in _rows_open]
       == ["team-lead", "feature-1", "subagents", "planner-c", "reviewer-a", "reviewer-b"],
       [r["name"] for r in _rows_open])
    # NO SUBAGENTS, NO ROW. An aggregate standing for nothing is a line of panel spent to
    # say "0 running", on the fleet that needs its rows most.
    ok("a fleet with no subagents grows no aggregate row",
       [r["name"] for r in fleet_tui.display_rows([_agent("team-lead")], [])]
       == ["team-lead"])
    # THE ROW RENDERS THROUGH THE SAME head_markup EVERY AGENT ROW DOES, which is what lets
    # it live in the list as an ordinary item — measured, refreshed and drawn like the rest.
    ok("the aggregate row renders through head_markup, not a second renderer",
       plain(fleet_tui.head_markup(_agg)) == _aggplain, plain(fleet_tui.head_markup(_agg)))

    # ── FROM THE 🔍 TO THE REVIEW: resolving the lane's monocle pane ─────────────────────
    # Driven against tmux's OUTPUT rather than tmux: what is under test is that the window is
    # derived from the agent's own pane (a window is NAMED for a nickname the harness renames)
    # and that an unresolvable jump is reported instead of landing somewhere plausible.
    class _Run:
        def __init__(self, out="", rc=0):
            self.stdout, self.returncode = out, rc

    def _tmux_stub(panes_out, win="@3"):
        def run(argv, **kw):
            _tmux.append(argv)
            if argv[1] == "display-message" and argv[-1] == "#{window_id}":
                return _Run(win)
            if argv[1] == "display-message":
                return _Run(_zoomed["flag"])
            if argv[1] == "list-panes":
                return _Run(panes_out)
            return _Run()
        return run

    _tmux, _zoomed = [], {"flag": "0"}
    _real_run, _real_panes = fleet_tui.subprocess.run, fleet_tui._team_panes
    fleet_tui._team_panes = lambda: {"feature-1": "%279"}
    try:
        fleet_tui.subprocess.run = _tmux_stub("%279 node\n%158 monocle\n%173 zsh")
        ok("the monocle pane is found in the window holding the agent's own pane",
           fleet_tui.monocle_pane("feature-1") == "%158", _tmux)
        ok("…and the window is asked for BY PANE ID, never by the nickname it is named for",
           ["tmux", "display-message", "-p", "-t", "%279", "#{window_id}"] in _tmux, _tmux)
        fleet_tui.subprocess.run = _tmux_stub("%279 node\n%173 zsh")
        ok("a window with no monocle running resolves to nothing, not to another pane",
           fleet_tui.monocle_pane("feature-1") == "")
        fleet_tui._team_panes = lambda: {}
        ok("…and so does an agent the team config does not place in a pane",
           fleet_tui.monocle_pane("feature-1") == "")

        # `resize-pane -Z` TOGGLES. Run unconditionally it would un-zoom the very pane it was
        # asked to enlarge, on every second press — so the flag is read after the selection.
        _tmux.clear()
        _zoomed["flag"] = "0"
        fleet_tui.subprocess.run = _tmux_stub("")
        ok("focusing a pane selects its window, then the pane, then zooms",
           fleet_tui.focus_pane("%158") is True
           and [a[1:3] for a in _tmux if a[1] != "display-message"]
           == [["select-window", "-t"], ["select-pane", "-t"], ["resize-pane", "-Z"]], _tmux)
        _tmux.clear()
        _zoomed["flag"] = "1"
        fleet_tui.focus_pane("%158")
        ok("…and does NOT re-zoom an already-zoomed window, which would un-zoom it",
           not any(a[1] == "resize-pane" for a in _tmux), _tmux)
    finally:
        fleet_tui.subprocess.run, fleet_tui._team_panes = _real_run, _real_panes

    ok("…and a row with no PRs is NOT padded, which would cost it a wrapped line",
       not plain(fleet_tui.head_markup(
           dict(lane_row, issue_links=[("SRV-24", "")]))).endswith(" "),
       repr(plain(fleet_tui.head_markup(dict(lane_row, issue_links=[("SRV-24", "")])))))

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

        # The two sources, and which one the column follows. `current-work` is what the agent
        # is DOING; the branch is machine state that outlives the work on it. The branch used
        # to win here, and the live failure that ended that was a lane still on
        # `john/dx-16-…` from finished work while actively on SRV-24: the panel confidently
        # showed DX-16. The disagreement is still SAID, so nothing is silently picked.
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

        # THE LIVE FAILURE, in its real shapes: the lane finished DX-16, left the branch
        # behind, and is on SRV-24 with the file to prove it. The panel showed DX-16 and the
        # user asked why SRV-24 was missing.
        moved_on = lane_at("SRV-24\thttps://linear.app/acme/issue/SRV-24\n",
                           branch="john/dx-16-move-implementation-plans-to-documents")
        pairs, mismatch = _agent_facts.tickets_for(moved_on)
        ok("the work the file names beats a branch left over from finished work",
           pairs == [("SRV-24", "https://linear.app/acme/issue/SRV-24")], pairs)
        ok("…and the URL survives the resolution, so the column stays clickable",
           pairs[0][1] == "https://linear.app/acme/issue/SRV-24", pairs)
        ok("…and the disagreement is reported, not swallowed", mismatch is True)
        ok("…so the row shows the WORK's ticket, marked ≠branch",
           "SRV-24" in fleet_tui.head_markup(
               dict(lane_row, issue_links=pairs, ticket_mismatch=True))
           and "≠branch" in fleet_tui.head_markup(
               dict(lane_row, issue_links=pairs, ticket_mismatch=True)),
           fleet_tui.head_markup(dict(lane_row, issue_links=pairs, ticket_mismatch=True)))
        ok("…and the branch's stale id is NOT in the column",
           "DX-16" not in fleet_tui.head_markup(
               dict(lane_row, issue_links=pairs, ticket_mismatch=True)))
        ok("…and an agreeing row wears no marker",
           "≠" not in fleet_tui.head_markup(
               dict(lane_row, issue_links=[("SRV-22", "")])))

        # The fallback: a lane whose file names nothing still gets the branch's id — one
        # source, so nothing to disagree with and nothing to mark.
        empty_file = lane_at("# nothing but a checkpoint here\n",
                             branch="john/dx-16-move-plans-to-documents")
        ok("a file naming no ticket falls back to the branch's id",
           _agent_facts.tickets_for(empty_file) == ([("DX-16", "")], False),
           _agent_facts.tickets_for(empty_file))
        ok("…and a lane with neither reports nothing rather than a guess",
           _agent_facts.tickets_for(lane_at("", branch="feature-2")) == ([], False))

        # PR matching resolves the ticket the same way — one answer per row. The branch's own
        # leftover id is deliberately not matched on: those PRs belong to finished work.
        ok("PR matching follows the same resolution as the column",
           _agent_facts.todo_for(moved_on) == "SRV-24", _agent_facts.todo_for(moved_on))

        # THE DETAIL DIALOG IS WHERE THE LOSER GOES. The row says a disagreement exists; the
        # dialog says what with, and both ids wear the name of where they came from.
        detail = fleet_tui.detail_data({"name": "feature-1", "path": moved_on})
        ok("the overlay's data carries both sides of the resolution",
           detail["tickets"] == pairs and detail["ticket_mismatch"] is True
           and detail["branch_ticket"] == "DX-16",
           (detail["tickets"], detail["ticket_mismatch"], detail["branch_ticket"]))
        git_markup = fleet_tui.FleetTUI.detail_git_markup(
            None, dict(detail, git={"branch": "john/dx-16-move-implementation-plans-"
                                              "to-documents",
                                    "dirty": 0, "base": "master",
                                    "local": (1, 0), "origin": (1, 0)}))
        ok("…and shows BOTH ids, each labelled with its source",
           "SRV-24" in git_markup and "DX-16" in git_markup
           and "current-work" in git_markup and "branch names" in git_markup, git_markup)

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

            # THE EXACT HALF, ALONE. A SUBAGENT shares its spawner's cwd, so steps 2 and 3
            # above would hand it the LEAD's transcript and report the lead's context on a
            # reviewer's row — which is why the subagent rows carried no context at all
            # until this split let them ask for step 1 without the fallbacks.
            with open(os.path.join(agents, "feature-9.transcript"), "w") as fh:
                fh.write(exact + "\n")
            ok("the exact resolver returns the per-agent sidecar",
               _agent_facts.agent_transcript_exact("feature-9") == exact,
               _agent_facts.agent_transcript_exact("feature-9"))
            # THE WHOLE POINT OF THE SPLIT, and the one assertion that separates it from
            # agent_transcript: with the sidecar gone, the cwd fallback must NOT fire.
            os.remove(os.path.join(agents, "feature-9.transcript"))
            ok("…and refuses to fall back to the newest file in the cwd, which is a guess",
               _agent_facts.agent_transcript_exact("feature-9") == "",
               (_agent_facts.agent_transcript_exact("feature-9"),
                _agent_facts.agent_transcript("feature-9", cwd)))
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
