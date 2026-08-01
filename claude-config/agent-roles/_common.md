# Working in an agent team (every role)

This preamble is prepended to **every** role by `register-agent.sh`. It describes the machine
you are running on — tmux panes, lanes, how a spawned agent is placed — not any product. That
separation is the point: this text used to live in one project's `CLAUDE.md`, where it was 18%
of a file loaded into every session of a repo whose other engineers have no fleet at all.

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

## Saying you need the human

Nothing in the harness reports "waiting for input" — its status field only ever says `running`
or `completed`. So the signal is one you write, and the fleet console reads:

```bash
printf '%s\n' "<one line: what you need decided>" > .claude/needs-input   # asking
rm -f .claude/needs-input                                                  # answered
```

Write it the moment you stop and wait on a person, and remove it the moment you have the
answer — a stale marker is worse than none, because it trains the reader to ignore the
indicator. One line, phrased as the decision to be made ("commit on my lane, or hand you the
diff?"), never a status ("waiting"): the row already says you are waiting, and the width is
better spent on what you are waiting FOR.
