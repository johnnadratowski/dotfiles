---
name: fleet-clear
description: Clear THIS agent's context and restore its session name, or just restore the name after a manual /clear. Run it in the agent's own pane — a bare /clear silently drops the name and the SessionStart auto-rename structurally cannot restore it. Self-targeting only; nothing ever types into a pane you are using.
---

# fleet-clear — clear without losing your name

`/clear` drops the agent's session name and nothing puts it back. Run this **in the agent's
own pane** to do the clear and the rename together, or to fix the name after clearing by
hand.

```bash
~/.claude/scripts/fleet-clear.sh              # /clear + /rename <name>, one step
~/.claude/scripts/fleet-clear.sh --name-only  # just the rename, after you cleared yourself
~/.claude/scripts/fleet-clear.sh --dry-run    # print what it would send, touch nothing
```

## Why `/clear` loses the name

`register-agent.sh`'s settle re-check reads the session name from
`~/.claude/sessions/<pid>.json` — **keyed by PID**. `/clear` starts a new session inside the
**same process**, so that file still holds the *old* name. The settle compares it to
`boot_name`, sees a match, and correctly concludes there is nothing to do — while Claude
Code's actual new session is unnamed.

**The check is blind to the exact case it exists for, so waiting longer never helps.**
Observed on `feature-2`: cleared at `12:44:19`, settle at `12:44:24` logged
`settled name matches boot name 'feature-2' — no-op`, name gone.

The name itself is read from the **fleet registry**, which `register-agent.sh` rewrites on
every SessionStart — including the one `/clear` fires. So the registry is correct even
though the session file is stale. That staleness is the bug; the registry is the truth.

## Self-targeting, deliberately

The obvious design — have the lead drive `/clear` + `/rename` into the agent's pane —
reintroduces the problem it is meant to solve. Right after clearing an agent you are
normally typing to it, and an external `tmux send-keys` interleaves with your keystrokes.
That fragility is why the delayed auto-rename keystroke was unreliable even in the cases
where it did fire.

So this sends **only to its own pane**, **only when you invoke it**, and **only while you
are waiting for it**. No timer, no daemon, no cross-agent path. If you want to clear a
different agent, run it in that agent's pane.

## What it does

1. Resolve this agent's name from `~/.claude/running-agents/` via the pane token.
   **Fails loudly if it cannot** — a guessed name would be typed into a live pane, and
   renaming an agent to something the fleet does not expect breaks message delivery to it.
2. Queue `/clear` (unless `--name-only`), then `/rename <name>`, into this pane.
3. They run in order as ordinary input once the turn ends: the clear wipes the
   conversation, the rename names the session the clear created.

## What this skill will NOT do

- Type into any pane but its own.
- Clear or rename another agent.
- Restart anything — the process is untouched, only the conversation is cleared. Use
  `agent-fanout.sh restart` to reload machinery from disk.
- Touch git or origin.

## Companion skills

- **`agent-fanout`** — `restart` (kill + `claude --continue`, preserves history), `compact`,
  `status`.
- **`agent-rename`** — rename an agent for real (branch, registry, tmux, session) rather
  than restoring the name it already has.
