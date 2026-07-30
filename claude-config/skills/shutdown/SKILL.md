---
name: shutdown
description: Shut agents down cleanly and in order — ask each teammate to stop itself via the native shutdown_request protocol (so IT decides when its work is safe), verify each one actually died, then, only when shutting down everything, the lead closes its own companion panes and exits last, leaving its tmux window alive at a shell. Takes targets, so one agent can be stopped without touching the fleet. Use for "shut down the fleet", "stop feature-2", "close all the agents", "kill the fleet".
---

# shutdown — stop the fleet in order, without orphans

**Request, verify, then the lead exits last.** Every step below exists because the obvious
shortcut (`tmux kill-server`, or SIGTERM to everything) either kills processes the fleet
doesn't own or leaves agents running that nothing can ever address again.

## Why this is a skill and not a script

`team-boot.sh down` can only send a **signal**. The graceful path is a **`SendMessage` tool
call** — `{"type": "shutdown_request"}` — which only an agent can make. So the orchestration
has to live in an agent's turn, with the script doing the shell-side halves (`status`,
`down --force`). Don't try to move this into `team-boot.sh`; it can't get there.

## Targets

`/shutdown` with no argument means **everything, lead included**. `/shutdown feature-2` (or
`/shutdown feature-1 feature-3`) means exactly those, and **the lead is never implied** — step
4 is skipped entirely, so the fleet keeps running minus those agents. That is the form to use
for cycling one agent; [`/staff`](../staff/SKILL.md) brings it back.

Naming the lead explicitly (`/shutdown team-lead`) still stops teammates first — the ordering
invariant below is not something a target list can opt out of.

## The two invariants

1. **Teammates first, lead last.** A lead that exits first doesn't take its teammates with
   it — they keep running, and **no relaunched lead can ever re-adopt them** (membership is
   rebuilt in-process at startup). Killing the lead first converts a fleet into orphans.
2. **A send is not a shutdown.** `SendMessage` returning `success: true` means the inbox
   accepted the write. Liveness is proven by `team-boot.sh status`, never by the send.

## Step 1 — Pre-flight: what would be lost, and what must not be touched

```bash
for d in ~/git/goals-onchain-worktrees/*/; do
  n="$(basename "$d")"; [ "$n" = team-lead ] && continue
  printf '=== %s ===\n' "$n"
  /usr/bin/git -C "$d" status --short
done
tmux list-panes -s -t main -F '#{window_index}:#{window_name} #{pane_id} #{pane_current_command} #{pane_current_path}'
```

- **Report uncommitted work per lane before sending anything.** Nothing is *lost* to a
  shutdown — the working tree stays on disk — but work that dies uncommitted comes back as
  an unlabelled diff nobody remembers, so it's worth one round trip.
- **Fix the blast radius here.** In scope: panes whose cwd is a lane, plus the lead's own
  window. **Everything else is the user's** — other windows routinely hold unrelated Claude
  sessions and shells. A `tmux kill-server` takes all of them; it is never the right verb.

## Step 2 — Send the request to every teammate

One `SendMessage` per teammate, **all in one message** so they wrap up concurrently:

```json
{"to": "feature-N", "message": {"type": "shutdown_request", "reason": "<why, plus: commit anything you want to keep on your OWN lane branch — do not push, do not open a PR, do not merge>"}}
```

The teammate replies `shutdown_response`; **approving terminates its own process.** That is
the whole point — the agent answers "is it safe to stop me?" for itself, from inside its own
turn, instead of the lead guessing from outside.

> **This is strictly better than SIGTERM, and not for politeness.** `team-boot.sh down` gates
> on the busy marker, fail-closed, and markers go stale: on the 2026-07-30 run all four
> teammates carried markers ~4 hours old yet were idle and answered immediately. `down` would
> have skipped every one of them. **The only accurate liveness signal is the agent's own
> reply.**

## Step 3 — Verify, and clean up the stragglers

```bash
~/.claude/scripts/team-boot.sh status     # every teammate's AGENT column must read "-"
tmux list-windows -t main
```

- **A teammate's window does NOT close by itself — its companion outlives it.** `remain-on-exit`
  is `off`, so the agent's own pane dies with its process; but every agent window now carries a
  **companion column** (built by `fleet-layout agent-windows`) running `WORKFLOW_CELL_COMMAND`,
  and that pane survives and holds the window open. **A lingering window is therefore NOT
  evidence the agent is alive.** Trust `status`, which resolves by process cwd, then close the
  orphaned companions by **pane id**. This bullet used to say the opposite, and would now
  produce a confident, false "the fleet is not down".
- **No reply within ~60s** ⇒ that agent is genuinely mid-turn or wedged. Escalate only that
  one: `~/.claude/scripts/team-boot.sh down --force`, which SIGTERMs and then **verifies death
  by observation** rather than trusting `kill`'s exit status. Report anything it can't prove
  dead.
- **A rejected request (`approve: false`) is an answer, not an obstacle.** Relay the reason
  and stop — the user decides whether to force it.

## Step 4 — The lead exits last

**Skip this entire step when the run was scoped to named targets** — a partial shutdown leaves
the lead running by definition. Report the remaining fleet and stop.

Otherwise, only once every teammate reads `-`:

1. **Save your own work first.** Commit to the lane branch — never push, never PR; shipping
   is user-gated and you are about to stop existing. If there is nothing to commit, say so.
2. **Close your companion panes**, addressing them by **pane id** (`%N`) — indices renumber
   as panes die, ids don't. Companions are the MCP daemons and idle shells the lead started
   (e.g. `monocle`, `zsh`). **A pane running something unrecognized is left alone and
   reported** — it is more likely the user's than yours.
3. **Give up the `team-lead` name, then respawn your own pane.** Both, in this order — the
   respawn never returns, so a rename after it never runs:
   ```bash
   tmux rename-window -t '%<lead-pane-id>' zsh
   tmux respawn-pane  -k -t '%<lead-pane-id>'
   ```
   `kill-pane` on the last pane destroys the window; `respawn-pane -k` kills the process and
   starts a fresh shell in place, so **the window survives at a command line**.

   The rename matters because the window outlives you. A shell still called `team-lead` is a
   lie about what is running there, and it used to be an active hazard: `team-boot.sh` looked
   its new pane up by window *name*, tmux answered with the lowest-index match — this stale
   window — and the next lead booted into it, in the wrong cwd. Boot resolves pane ids
   directly now, so this is no longer load-bearing, but leaving the name behind is what makes
   the window honest, and it keeps any future name lookup unambiguous.

## What this skill will NOT do

- Run `tmux kill-server`, or kill any pane outside a lane or the lead's own window.
- Kill the lead before the teammates, or claim the fleet is down on a `success: true` send.
- Push, open a PR, or merge anything while "saving work".
- Force-kill an agent that answered `approve: false`, or one it never heard from, without
  saying so first.

## Companions

- **[`/staff`](../staff/SKILL.md)** — the other direction: spawns agents into lanes, verifies
  each entered its own worktree, and places them in their own windows.
- **`/fleet-layout`** (user-level skill, `~/.claude/skills/fleet-layout/`) — owns window/pane
  topology while the fleet is *up*. This skill is its counterpart on the way down; neither
  starts or stops an agent except through the paths above.
- **`~/.claude/scripts/team-boot.sh`** — `boot` · `status` · `spawn-prompt` · `down`. This
  skill drives `status` and, only as a fallback, `down --force`.

---

**Skill Version**: 1.1.0
**Category**: Fleet / Lifecycle

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
