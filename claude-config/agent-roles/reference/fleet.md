# Working in an agent team (every role)

REFERENCE, read on demand — this file is NOT injected. The injected preamble
(`../_common.md`) carries only the handful of facts you could get wrong without knowing to
look; everything else lives here, because injected role context is truncated to ~2 KB and
anything past that arrives as a stub rather than as text.

It describes the machine you are running on — tmux panes, lanes, how a spawned agent is
placed — not any product.

## The team

The fleet is a **team**: lane 0 is the lead (`team-lead`), lanes 1..N are `feature-N`
teammates, each a real session in its own tmux pane with its own hooks. Messaging is native
**`SendMessage`**, addressed by team name; there is no mailbox and no `tmux send-keys`
nudging.

Two rules that bite:

- **A teammate cannot be launched into a directory.** There is no cwd parameter — it boots in
  the *lead's* worktree and must call `EnterWorktree` into its lane as its first act.
  `~/.claude/hooks/lane-guard.sh` blocks writes until it does, so the window between boot and
  `EnterWorktree` is a failed tool call rather than silent corruption of lane 0.
- **`SendMessage` success means the inbox accepted the write, not that anyone read it.** If
  receipt matters, wait for the reply.

The **busy marker** (`~/.claude/agent-busy/`, written by the `mark-busy` hook) is not
messaging — it is what every destructive fleet verb gates on: `team-boot.sh down` and
`agent-fanout restart`/`compact` refuse to act on an agent that is mid-turn.

**A lead crash leaves teammates running but permanently unaddressable.** Recovery is
**respawn into the same lanes**, never re-adopt: `--continue` forks a new session id (a new,
empty team) and `--resume` reuses the id but still cannot reach them. No work is lost — the
lane branch and `.claude/current-work` hold it.

## WHERE A SPAWNED AGENT GOES — the canonical rule

Three kinds, three placements, and the kind is decided by **how long it lives**:

| Kind | Spawn as | Lands | Why |
|---|---|---|---|
| **Lane agent** (`feature-N`) — long-lived | background teammate, then `EnterWorktree` into its lane | **its own tmux window** (`fleet-layout single`/`dual`/`wide`) | it outlives any one task; it needs a full window you can sit in |
| **Reviewer / tester** — task-scoped | background (`run_in_background` default) | **the current window**, stacked under the pane that spawned it | you watch and steer it mid-run; `fleet-layout subagents` places it, and the `SubagentStart` hook runs that automatically |
| **Any agent's own subagent** | background | **the current window**, selectable in the agent list below the prompt | same reason — it belongs to whoever spawned it and should be readable next to them |

**`run_in_background: false` is the escape hatch, not the default.** It runs the subagent
*in-process*: no pane, no team membership, no agent-list row — it blocks the turn and returns
its result directly. Use it when only the result matters (a sweep, a probe, a lookup) and
nobody needs to watch. Verified: a foreground spawn reports the parent's own `TMUX_PANE` and
carries no `--agent-id`.

**A background agent does NOT die when its work is done** — in either mode. It reports, goes
idle, and stays addressable until stopped (`TaskStop`, or the lead asking it to shut down).
That is why five accumulated in one window before this rule existed.

## Subagents are panes here, and that is a setting

`teammateMode` (`~/.claude/settings.json`, or `--teammate-mode`) defaults to `"in-process"`;
`team-boot.sh` launches the lead with `tmux`, so every `Agent` spawn becomes a real
pane-dwelling team member instead. Two consequences before you change it:

- A teammate's final text is **not** returned as a tool result — it must `SendMessage`. A
  spawn that simply finishes leaves its report only in its transcript
  (`~/.claude/projects/<munged-cwd>/*.jsonl`).
- Per the Claude Code docs, in-process teammates are **not restored by `/resume`** and
  **cannot spawn background subagents** at all.

## The scratchpad is SHARED between siblings — name your files after yourself

A session's scratchpad directory is per-session, but **subagents you spawn write into the same
one**, so two siblings running concurrently share a namespace. Measured 2026-08-06: two
migration agents each wrote a `verify.py`, and one overwrote the other mid-run. Nothing was
lost only because the loser happened to re-run under a different name — luck, not design.

**Prefix every scratch filename with your own agent name**: `feature-3-verify.py`, not
`verify.py`. The collision is silent in the worst way — the second writer succeeds, and the
first agent then executes a file that is no longer the one it wrote.

## Saying you need the human

Nothing in the harness reports "waiting for input" — its status field only ever says `running`
or `completed`. So the signal is one somebody writes and the fleet console reads. **As of
2026-08-04 that somebody is the LEAD, not you.**

**Send the lead one message naming the decision, the moment you stop and wait.** Do not write
`.claude/needs-input`; the lead owns every one of those files and keeps the panel current.

**The reason is that you cannot clear a flag you raise.** The standing order on a timed-out
human gate is to go quiet, so the lane never learns its answer landed and the marker outlives
the question. A stale marker is worse than none: it trains the reader to ignore the one
indicator there is, including the time it is real.

Phrase it as the decision to be made ("commit on my lane, or hand you the diff?"), never as a
status ("waiting") — the row already says you are waiting, and the width is better spent on
what you are waiting FOR.
