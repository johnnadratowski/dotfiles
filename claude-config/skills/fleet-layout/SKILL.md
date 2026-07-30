---
name: fleet-layout
description: Rearrange the agent fleet's tmux panes for the monitors you have, (re)label every tmux window from its resident agents, boot the fleet from cold, and bring it down cleanly. Three layout modes — `wide` (ultra-wide: all 4 feature agents in one 2x2 window), `dual` (ordinary 2nd monitor: 2 agents per window, two windows), `single` (laptop: one window per agent) — plus `boot` (crash recovery: create windows for dead manifest agents and launch claude, dry-runnable) and `down` (stop every fleet agent and remove its panes — path-keyed, idle-gated, fail-closed guards, dry-runnable). Use when the user says "switch to my double-wide", "I'm on one monitor now", "put the agents on the second screen", "fix the tab names", "relayout the fleet", "boot the fleet", "bring the fleet back up", "bring the fleet down", "stop all agents". The LAYOUT verbs restructure only — they never kill a pane, never restart an agent, never drop a message; `down` is the single deliberate, guarded exception.
---

# fleet-layout — retopologize the fleet for the monitors you have

```bash
~/.claude/scripts/fleet-layout.sh <single|dual|wide|attach|balance|name-windows|boot|down> [--dry-run] [--force]
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
| `name-windows` | Label every window from **all** of its resident live agents, then put the windows in canonical order. No pane moves. Called automatically by the SessionStart hook and `/agent-rename`. |
| `attach` | Re-open the external-monitor window for an already-built `wide`/`dual` layout. |
| `balance` | Re-split each cell 60/40. Run after the terminal changes size. |
| `boot` | Bring the fleet up from cold (crash recovery). See below. |
| `down` | Stop every fleet agent and remove its panes. The inverse of `boot`; the only verb that kills. See below. |

## `boot` — one command brings the fleet up from cold

Enumerates the fleet from the **machine-local worktrees manifest** — its path comes from
`fleet_manifest_path` (`_fleet.sh`): `WORKFLOW_WORKTREES_MANIFEST` when set, else
`~/.config/<main-clone-basename>-worktrees.json` (derived from the git common dir, so every
worktree of a clone resolves to the same file). Entries carrying an `agent` field; schema
documented in [`list-worktrees`](../list-worktrees/SKILL.md). Then per agent, in canonical
(agent-number) order:

- **`active: false`** → reported `held` (parked lane), skipped.
- **Self** (the invoking agent) → `skipped (self)` — boot never touches its own window.
- **Dead same-name registry entries** are swept (pid-only check — a live-pid/dead-pane
  entry is deliberately left for the registration-time prune; sweeping a live pid is the
  riskier error).
- **Live registration** (pid + pane) → reported `live`, untouched.
- **Manifest path missing on disk** → warned, others still boot.
- **A window already named for the agent** → `window-exists`, left untouched — boot
  NEVER types into a pane it did not just create (its state is unknown; it could be
  showing a resume prompt or a running claude).
- Otherwise: create the window at the worktree (`new-window -n <agent> -c <path>`) and
  type the launch into the pane id captured from that very call — `claude --continue`
  when `~/.claude/projects/` has prior sessions for the worktree, plain `claude` when
  not. The new window is then built into the full **cell** (DX-jn-cc-012): claude
  full-height on the left (~60%), a right column stacked with the **configured companion
  command running top-right** (`WORKFLOW_CELL_COMMAND` — **empty by default**, in which case
  nothing is keyed and both right panes sit at a shell prompt) and a **shell at the prompt
  bottom-right** — sized at creation time
  (`split-window -l 40%`, then an even v-split; attribution-driven `balance` can't run
  yet because the booting claude hasn't registered), all panes created and keyed by
  this same run. A failed split or keystroke **degrades, loudly**: the claude launch
  survives (it already happened and matters more than its companions), the degradation
  is reported (`cell DEGRADED …`), the remaining agents still boot, and the run exits
  non-zero. A failed v-split leaves the single right pane at the prompt with no companion
  — a bare shell is the safe degraded state.

**The window session resolves, and is never assumed.** Boot creates its windows in
`WORKFLOW_FLEET_HOME_SESSION` when a session by that name exists; otherwise it falls back to
the invoking client's current session, says so, and **rebinds** the home session for the whole
run — so the duplicate-launch guard, the window creation, and the canonical ordering all follow
one identity. Boot never creates a session, and refuses (exit 2) if the resolved session is the
external-monitor session. The **persisted** identity is the primary mechanism:
`WORKFLOW_FLEET_HOME_SESSION` lives in the gitignored `.claude/workflow.config.local`, and
`lanes.sh provision` seeds that file into every lane — because each agent's SessionStart runs
`name-windows` in **its own worktree**, and a lane with no `.local` would silently fall back to
the default and never order its windows.

Window names and canonical order **converge on their own**: each booting agent's
SessionStart registration fires `name-windows` (register-agent.sh), so boot doesn't
poll or wait. When it finishes, boot **hands the selection back to the invoking
window** (the operator who typed it gets their own window back) — cosmetic, degrades
silently when headless or the pane is unresolvable.

**Resume prompts stay human.** Booted claudes may show "Resume from summary" pickers;
boot reminds you and answers nothing — never blind-key Enter into a pane.

**Failure model is loud:** a corrupt/missing/unreadable manifest (or python3
unavailable) fails the run non-zero — it never degrades to "0 agents, exit 0", which a
crash-recovering operator would misread as "fleet already up". **Outside tmux, boot refuses
(exit 2)** rather than reporting "nothing to do, exit 0" — a spin-up verb an init flow depends
on must not report success while launching zero agents (the cosmetic layout verbs keep exit 0). Agent names are validated
(`A-Za-z0-9_-` only) and paths must be absolute before anything touches the filesystem.

Re-running boot is idempotent: live agents report `live`, already-created windows report
`window-exists`, nothing is double-launched and no cell is re-split. `--dry-run` prints
the exact `new-window` + `split-window` + `send-keys` commands and mutates nothing (not
even the dead-entry sweep).

## `down` — stop the fleet cleanly (DX-jn-cc-010)

```bash
fleet-layout.sh down [--dry-run] [--force] [agent...]
```

The inverse of `boot`, and the script's ONLY killing verb. With **no agent names** it downs the
whole fleet; with names it downs **only those agents** — `remove-worktree` uses that to stop one
agent before removing its worktree. A requested name that is **not in the manifest** is a loud
refusal (`rc≠0`, nothing killed for it): a filtered-to-empty set must never read as "that agent
is down" while it still runs. A requested name that resolves to **self** is likewise refused —
a run cannot kill its own pane, and a silent skip would tell the caller the agent is down.
(The unrequested whole-fleet sweep still skips self quietly, which is what "stop all the
others" means.)

Enumerates the same manifest (every `agent`-bearing entry — `active: false` does NOT exempt an
entry: "stop all agents" means all; the flag gates boot only), excludes self, and per entry:

- **Targeting is keyed on the WORKTREE PATH, never the name**: a live registration
  matches when its `~/.claude/agents/<name>.cwd` sidecar resolves to the entry path,
  whatever the name — live agents can carry transient auto-names (observed 2026-07-10),
  and a name-keyed down would miss all of them.
- **Kills panes, never pids** (a registry pid can be recycled): the claude pane (the
  registry token, corroborated to actually sit at the worktree before the kill) plus its
  attributed companions (the `attribute_panes` cell model, exemptions intact —
  `@fleet-layout-skip` panes and ambiguity-exempt shared-cwd panes survive; co-tenant
  panes at other cwds are never touched). Companions die first, the claude pane last
  (its death is the SessionEnd trigger). Emptied windows die on their own; windows with
  survivors persist.
- **Idle-gated**: a fresh busy marker skips the agent (`rc=1`); `--force` overrides the
  BUSY gate — and ONLY the BUSY gate. A `@fleet-layout-skip` marker on the claude pane
  is the user's explicit hands-off: the agent is skipped BEFORE any kill, `--force`
  never bulldozes it (removing the marker is the override).
- **`downed` is earned by observation**, never by `kill-pane`'s exit status (the verb's
  founding incident was a sandbox masking kill failures): after a settle window
  (`FLEET_DOWN_SETTLE`, default 5s) each targeted pane is re-checked; a survivor is
  `FAILED` + `rc=1`. Registry entries at targeted paths are swept **pid-only** (a live
  pid is never swept), and each downed worktree is re-probed — an unregistered surviving
  pane is `UNACCOUNTED` + `rc=1`, never killed.
- **Every guard input fails CLOSED into a loud non-zero refusal** — corrupt/empty
  manifest enumeration, unreadable registry entries, an unresolvable sidecar on a live
  registration, a blind or silent tmux, an unreadable skip marker or busy dir, an
  unresolvable self. The failure direction is the inverse of the layout verbs': for a
  destroy verb the danger is the operator reading "fleet is down, exit 0" while agents
  still run, so nothing ever degrades to "nothing matched, proceed".
- **Exit 0 means exactly**: every non-self entry is downed-and-verified or
  probe-confirmed not running. Anything skipped, refused, failed, or unaccounted is
  non-zero.
- `--dry-run` prints the exact kills + sweep and mutates nothing (verification is
  neutralized — nothing died, so it would flag every target).

Booted claudes recover with `claude --continue`, so `down` + `boot` is the sanctioned
full-fleet restart path (resume prompts stay human-answered).

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
- **The layout verbs never kill** anything except the `attach` placeholder window and, in
  `single`, the agent-free external session — and that refuses while any agent pane is
  still in it. **`down` is the single sanctioned kill path**: one helper
  (`_down_kill_pane`, with a terminal never-kill-own-pane backstop), structurally pinned
  by the test suite's comment-stripped kill-verb counts and caller allowlist.

## Config

| Variable | Default | Meaning |
|---|---|---|
| `WORKFLOW_WORKTREES_MANIFEST` | `~/.config/<main-clone-basename>-worktrees.json` | the fleet manifest `boot`/`down` enumerate (resolved by `fleet_manifest_path`) |
| `WORKFLOW_CELL_COMMAND` | *(empty)* | command the cell's top-right companion pane runs. Empty ⇒ nothing is keyed and it stays a shell. Set it per project (e.g. `monocle`) |
| `WORKFLOW_FLEET_HOME_SESSION` | `main` if such a session exists, else the invoking client's session | the session the agents' windows live in. **Persist it in `.claude/workflow.config.local`** (seeded into each lane by `lanes.sh provision`) — it is machine-local, never committed |
| `WORKFLOW_FLEET_EXT_SESSION` | `wide` | the external-monitor session |

Tests: `bash ~/.claude/scripts/fleet-layout.test.sh` (hermetic `$HOME` + scratch tmux socket).
Background: [`.claude/docs/inter-agent-comms.md`](../../docs/inter-agent-comms.md#window-names--layouts).
