---
name: fleet-layout
description: Rearrange the fleet's tmux panes for the monitors you have, relabel windows from their resident agents, and restack a lead's subagent panes. Modes: wide, dual, single, plus subagents. Restructures only — never starts or stops an agent. Use for "relayout the fleet", "I'm on one monitor now", "fix the tab names", "my subagent panes are unreadable".
---

# fleet-layout — retopologize the fleet for the monitors you have

```bash
~/.claude/scripts/fleet-layout.sh <single|dual|wide|attach|balance|name-windows|subagents|lead-window|agent-windows> [--dry-run]
```

An agent's identity is its **tmux pane id**, and `join-pane` / `move-window` *move* panes rather
than recreating them. So panes can be rearranged freely — across windows and even across
sessions — around **live** agents: no restarts and no re-registration.
That is the whole reason this is safe.

## The three modes

| Mode | Shape | Lives in |
|---|---|---|
| `wide` | all feature agents, ONE window, 2×2 of cells | external session, ultra-wide monitor |
| `dual` | 2 agents per window × 2 windows (`features-1`, `features-2`), stacked | external session, ordinary 2nd monitor |
| `single` | one window per agent | the home session, laptop |

Each feature agent occupies a **cell**: its claude pane on the left, its companions stacked to the
right, split 60/40. The top-right companion runs `WORKFLOW_CELL_COMMAND` when the project sets one
(**empty by default** — then it is simply a shell). The team lead, the review/test window,
and any unrelated window are never touched.

**Canonical window order, in every mode:** the team lead first, then the feature agents in
agent-number order (`feature-1` … `feature-4`, or the merged `features` / `features-1` / `features-2`),
then `review-test`, then any unrelated window, keeping its relative position. Applied by
`name_windows`, so every path gets it; idempotent, so it emits nothing when already in order.

`wide` and `dual` **open the second-monitor window themselves** — they create a dedicated tmux
session, attach an iTerm window to it on the widest non-main screen, and move the feature windows
across. `single` brings them home and closes that window. You do not need `attach`.

## Supporting verbs

| Verb | What it does |
|---|---|
| `name-windows` | Label every window from **all** of its resident live agents, then put the windows in canonical order. No pane moves. Called automatically by the SessionStart hook. |
| `attach` | Re-open the external-monitor window for an already-built `wide`/`dual` layout. |
| `balance` | Re-split each cell 60/40. Run after the terminal changes size. |
| `subagents` | Restack a lead's subagent panes below the lead's own pane. See below. |
| `agent-windows` | Give EVERY live agent the same window shape — chat left, companion column right. **Every layout verb ends with this**, so staffing an agent can no longer leave the lead's chat squeezed or a teammate alone at full width. Idempotent. |
| `lead-window` | Build the lead's OWN window: a companion column beside its chat, sized 60/40 and seeded with `WORKFLOW_CELL_COMMAND`. `--pane=%N` names the lead's pane (default `$TMUX_PANE`). Called by `team-boot.sh boot`; idempotent by pane count, so re-running is free. |

## `subagents` — put a lead's helpers where they can be read

With `teammateMode: "tmux"`, an `Agent`-tool spawn becomes a **real tmux pane**, and the
harness puts it wherever the current layout puts a new pane — in practice appended into the
cell's **right column, under the monocle companion**. Five reviewers and testers land on a
40%-wide column and the window becomes unreadable.

```bash
~/.claude/scripts/fleet-layout.sh subagents [--dry-run]
```

Run it **in the lead's own pane** — that pane is the stacking target, so it is known exactly
rather than inferred, and a subagent can never end up as its own target. Each subagent pane is
`join-pane -v`'d beneath it, in the left column, then the window is evened vertically. They are
work the lead is waiting on, so reading them top-to-bottom beside the lead's transcript matches
how they are used.

Which panes move comes from the **team config** (`~/.claude/teams/*/config.json`), which records
each member's `tmuxPaneId` and `agentType` — not from pane titles (an agent can set its own) and
not from `ps` (a pane's claude is a grandchild of the pane's pid). Every config is scanned and
self-located: one is ours if a non-lead member sits on a pane that currently exists. So no
session id is needed, and a crashed lead's stale config contributes nothing because its recorded
panes are gone.

## Starting and stopping agents is NOT here

`boot` and `down` used to be verbs of this script. They enumerated the fleet from a
machine-local **worktrees manifest** that the lanes migration stopped maintaining, so both had
been exiting 1 with `manifest missing or unreadable` on every invocation — including `down`, the
verb you would reach for in a hurry.

They now live in **`~/.claude/scripts/team-boot.sh`** (`boot` · `status` · `spawn-prompt` ·
`down [--force] [--dry-run]`), which enumerates the **lane directory** instead. A lane is on
disk by definition, so there is no manifest to go stale.

`down`'s guards travelled with it, and it gained two it was missing: it never targets itself
(the lead occupies lane 0, so an unguarded sweep killed the process running the sweep), and its
"stopped" claim is earned by observing the process exit rather than by `kill`'s exit status.

This script now **never starts or stops an agent** — it only moves and labels panes, which is
why every verb here is safe to re-run.

## How to run it

1. **`--dry-run` first** for `single`/`dual`/`wide`. It prints the exact tmux commands and
   mutates nothing. Read them, then re-run without the flag.
2. `name-windows` and `balance` are cosmetic and idempotent — just run them.
3. Report what changed. Re-running any mode is a no-op.

## Why a dedicated session, not a grouped one

A **grouped** session (`tmux new-session -t main -s wide`) shares the window list by
construction, so the feature windows would still be tabs in the laptop's window. The layouts use
a **dedicated** session (`wide`) and `move-window` the feature windows into it, unlinking them
from `main`. Pane ids survive the move, so delivery, liveness, and the registry are unaffected.

## Rules

- **Never spawn a second tmux server.** Attach more clients instead. A second server restarts
  pane ids at `%0`, so ids collide, `list-panes -a` goes blind across servers, the fleet tooling
  prunes live agents from the registry, and `send-keys` types into an unrelated pane.
  `FLEET_TMUX_SOCKET` exists solely for `fleet-layout.test.sh`.
- **Never `write text` / `send-keys` into a new terminal window.** `~/.zshrc` ends with
  `exec tmux -2 new-session -A -s main`, so a fresh interactive shell is *already* a tmux client
  of the home session — typed text lands in whatever pane that session has active, which can be
  an agent's Claude prompt. `attach` instead spots the new client by its `tty` and uses
  `tmux switch-client`.
- **A pane you parked in a worktree yourself** gets conscripted into that agent's cell.
  Exempt it: `tmux set-option -p -t %N @fleet-layout-skip 1`.
- **A companion that `cd`s out of the worktree** stops being attributed and is left where it is
  (subdirectories still match). It is never destroyed.
- Missing agents degrade — `wide` with three feature agents renders a three-cell grid.
- **Nothing here kills a pane** except the `attach` placeholder window and, in `single`, the
  agent-free external session — and that refuses while any agent pane is still in it. The test
  suite pins this structurally, with comment-stripped counts asserting there is no
  `kill-server`, exactly one `kill-window` (the placeholder drop), one `kill-session`
  (`_teardown_ext`, via `_rw`), and no pid signal other than a `kill -0` liveness probe.
  Stopping an agent is `team-boot.sh down`, in another file, on purpose.

## Config

| Variable | Default | Meaning |
|---|---|---|
| `WORKFLOW_CELL_COMMAND` | *(empty)* | command the cell's top-right companion pane runs. Empty ⇒ nothing is keyed and it stays a shell. Set it per project (e.g. `monocle`) |
| `WORKFLOW_FLEET_HOME_SESSION` | `main` if such a session exists, else the invoking client's session | the session the agents' windows live in. **Persist it in `.claude/workflow.config.local`** (seeded into each lane by `lanes.sh provision`) — it is machine-local, never committed |
| `WORKFLOW_FLEET_EXT_SESSION` | `wide` | the external-monitor session |

Tests: `bash ~/.claude/scripts/fleet-layout.test.sh` (hermetic `$HOME` + scratch tmux socket).
