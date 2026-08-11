# Fleet operations (team lead only)

REFERENCE, read on demand — not injected. Only the lead starts, stops, places, or counts
agents, so this is the one role that needs it, and it needs it at the moment it acts rather
than at every session start.

## Layout — `/fleet-layout` → `~/.claude/scripts/fleet-layout.sh`

Sole owner of every tmux **window name** (`name-windows`, called from the SessionStart hook)
and of the agents' pane topology. It **never starts or stops an agent**.

| Mode | For |
|---|---|
| `wide` | ultra-wide monitor — 4 agents in one 2×2 window |
| `dual` | ordinary second monitor — 2 agents per window |
| `single` | laptop — one window per agent |
| `subagents` | restacks reviewer/tester panes **beneath** the pane that spawned them |
| `agent-windows` | gives every live agent the same shape: chat left, companion column right |

All are `--dry-run`-able. `subagents` exists because with `teammateMode: "tmux"` the harness
otherwise appends a spawn into the cell's 40%-wide right column and the window becomes
unreadable; the `SubagentStart` hook runs it for you.

## Up and down — `~/.claude/scripts/team-boot.sh`

`boot` · `status` · `spawn-prompt <lane>` · `down`. It enumerates the **lane directory**
rather than a manifest, so there is nothing to keep in sync.

- `boot` **resumes the lead** (`claude --continue` whenever lane 0 has a transcript), so a
  shutdown/boot cycle is not amnesia; `--fresh` opts out. It asks `fleet-layout lead-window`
  to build the lead's window *before* the launch keystrokes, because the lead's window is not
  a cell and nothing else ever built it.
- **Teammates have no `--continue` equivalent** — the lead creates them through the Agent
  tool, so their continuity is on disk (lane branch + `.claude/current-work`), and
  `spawn-prompt` tells them to resume from it.

Agents come **up** through `/staff` and go **down** through `/shutdown`, both of which take
targets, so one agent can be cycled without restarting the fleet.

**`/staff` exists because only the lead can create teammates** — one launched any other way
runs fine and is permanently unaddressable — and because nothing previously verified the
result: a teammate that skipped `EnterWorktree` sat in lane 0 with every write bounced by
`lane-guard` and nobody watching. It claims success only when `status` shows the pid in the
lane, then places agents with `fleet-layout reapply`, which repairs the two things staffing
breaks: a teammate arrives as a lone full-width pane, and the lead's own chat is left
squeezed (tmux keeps the survivors' geometry when spawned panes are broken out).

**`/shutdown`, not `down` alone.** The graceful path is the native **`shutdown_request`
protocol** — a `SendMessage` tool call, so it cannot live in a shell script — which lets each
agent decide from inside its own turn whether stopping is safe. That is about accuracy, not
manners: `down` gates on the busy marker fail-closed, and stale markers made it skip an
entire idle fleet on 2026-07-30, so **the agent's own reply is the only accurate liveness
signal**. `down --force` is the fallback for non-responders.

Order: **teammates first, lead last** — a lead that dies first orphans everyone.

## tmux hazards

- **Never `tmux kill-server`.** Other windows hold unrelated sessions.
- **Never spawn a second tmux server**, and **never type into a freshly-opened terminal** —
  the zshrc auto-attaches it to the fleet session.
- Teammates spawn as split panes and are broken out into their own windows afterwards. **Pane
  ids survive `break-pane`**, so routing follows the pane id, not the window.

## Seeing what the team is doing

The agent panel under your prompt **cannot** show teammate context, and no setting fixes it:
`subagentStatusLine` decorates only rows whose type is `local_agent`, and a lead's panel is
teammates plus `main` — zero eligible rows, so the script never runs.
`~/.claude/scripts/fleet-status.sh` is the lead's view instead: state · context% · uptime ·
issue · open PRs · the lead-written status line and its asks · and how long ago that agent
last wrote its transcript (`active 2m ago`). All read off disk. The last one is the only
per-lane fact nobody maintains, which is exactly why it is there: the status text says what
a lane is doing, the mtime says whether that is still true.
Leave it running in a window (watch is its default).
