---
name: agent-fanout
description: Inspect and manage the agent fleet's live processes — show fleet status (incl. per-agent context usage), force-restart idle agents (kill the pane's claude, relaunch with `claude --continue`), and inject `/compact` into agents that are filling up. Backed by `~/.claude/scripts/agent-fanout.sh` (one allow-listed command per action). Messaging is NOT here — a lead addresses a teammate with native `SendMessage`. High blast-radius; every restart and compact is confirmed first. Use for "show me the fleet", "restart feature-2", "compact the full agents".
---

# agent-fanout — fleet process management

Knows the fleet's **registry** (who is live, on what branch, how full) and its **panes**, so you
can look before acting and then act on a targeted set. It derives **roles** from agent names the
same way `register-agent.sh` does, so targeting can never disagree with how an agent was booted.

**This is not a messaging tool.** There used to be `send` / `merge-down` verbs wrapping a durable
mailbox transport; the transport is gone. To reach a teammate, use native **`SendMessage`**,
addressed by team name. What is left here is process and pane mechanics — the things
`SendMessage` cannot do because they are about the OS, not the conversation.

**Blast radius: restarts and compactions ALWAYS ask first** — never kill, relaunch, or inject
into an agent without an explicit confirmation in this turn, even when relaying a lead's
instruction.

## Backing script

The mechanics live in **`~/.claude/scripts/agent-fanout.sh`** — one allow-listed command per
action, so you don't re-prompt on ad-hoc bash. Subcommands:

```
~/.claude/scripts/agent-fanout.sh status
~/.claude/scripts/agent-fanout.sh restart --yes [--clean] [--role R] [--only a,b] [--exclude a,b] [--dry-run]
~/.claude/scripts/agent-fanout.sh compact --yes [--threshold N] [--role R] [--only a,b] [--exclude a,b] [--dry-run]
```

The script always excludes self, idle-gates `restart`/`compact` (skips BUSY / copy-mode panes),
and `restart` relaunches with `claude --continue --name "<name>"` (no session-id needed — it
resumes the pane's latest conversation, name set at launch). **`restart` and `compact` refuse to
run without `--yes`** — the human gate below decides when to pass it; the allow-list removes the
bash prompt, NOT the confirmation.

Targeting flags: `--role feature|review|test|team-lead|all` · `--only name1,name2` explicit
list · `--exclude a,b` · `--dry-run`. `compact` adds `--threshold N` (default 80).

Roles are derived from the agent name via **dash-delimited segment matching** — the canonical
patterns live in `fleet_resolve_role()` (`_fleet.sh`), which `role_of()` here and
`resolve_role()` in `register-agent.sh` both delegate to. A `test` segment → test, a
`pr`/`review` segment → review, a `cc`/`coordinator`/`team-lead` segment → team-lead, else
feature (`x-print` is NOT review). **You are never a target of your own fan-out** (self is
excluded by identity token).

## Mode: `status` (read-only — start here)

```bash
~/.claude/scripts/agent-fanout.sh status
```

No authorization needed; do this before any action so you (and the user) see who's live, busy
(the busy window and role classification are the script's — do not re-derive them inline), and
on what branch. Report live agents grouped by role and flag STALE entries. This is the "look
before you leap" step for the other modes.

> `agent-fanout.sh status` also prints a **`CTX` column** — each agent's main-loop context usage
> as `NN%` of its model's context window (`⚠`≥80%, `🔴`≥90%, `—` if unknown). It finds each
> agent's transcript **without requiring tmux**: it reads the
> `~/.claude/agents/<name>.transcript` / `<name>.cwd` sidecars that `register-agent.sh` records
> on every SessionStart, derives the project dir from the cwd, and takes the newest `*.jsonl`;
> tmux `pane_current_path` is only an **optional fallback** for agents that haven't re-registered
> since the sidecars were introduced. The window comes from `$WORKFLOW_CTX_WINDOW` (a global
> override) or, failing that, from the model id: an explicit window marker (`[1m]`) wins, else
> opus/sonnet at major version **≥ 4** → 1M, else 200k. (Deliberately not version-pinned — the
> earlier `"opus-4" in m` test sent every newer model to the 200k default and reported nonsense,
> e.g. a 1M-window session at 714k tokens shown as **357%**.) Use this to spot who is filling up
> and decide a `compact`.

## Mode: `restart` — force-restart agents (idle-gated, always confirmed)

Kill an agent's `claude` in its pane and relaunch it with **`claude --continue --name "<name>"`**,
which resumes the pane's most recent conversation (no session-id lookup needed) — so context is
preserved, and the session name is set at launch (not by a post-launch `/rename` keystroke that a
high-context startup modal could swallow — DX-jn-8-024).
Useful when an agent is wedged, on a stale version of the skills/hooks, or needs a clean reload
without losing history.

> ### ⚠ WRONG FOR A TEAM MEMBER
> `claude --continue` **forks a new session id**. A teammate relaunched this way comes back in a
> new, empty team — its lead can no longer address it with `SendMessage`, permanently. The agent
> is alive and drivable in its own pane, but it has left the team.
>
> This verb is correct for a **standalone lane agent**. To recover a teammate, have the lead
> **respawn** it into the same lane; because a lane is a fixed path and branch, no work is lost.

> **Never restart without an explicit confirmation in this turn.** Restart kills the live process.
> Always show the plan and ask first.

How to run it: confirm with the user (show the candidate list — `agent-fanout.sh restart
--dry-run [targeting]` prints it), then:

```bash
~/.claude/scripts/agent-fanout.sh restart --yes [--role R] [--only a,b] [--exclude a,b]
```

What the script does per target (sequential, fail-contained):

1. **Idle-gate** — skips any agent with a fresh `~/.claude/agent-busy/<name>` marker or a pane in
   copy-mode (killing mid-turn loses in-flight work). To wait for a busy agent instead of skipping,
   poll with the **Monitor** tool until idle, then re-run.

   > **Recovery escape.** "Fresh" means newer than `WORKFLOW_BUSY_STALE_MIN` (default **30 min**),
   > and `restart`/`compact` have **no `--force`** — so an agent that CRASHED mid-turn without
   > clearing its marker is un-restartable for that whole window, which is a real cost for the
   > verb whose purpose is recovery. When you have confirmed the agent is genuinely dead (no
   > live pid in `~/.claude/running-agents/<name>.*`, pane idle), clear the marker by hand and
   > re-run: `rm ~/.claude/agent-busy/<name>`. Do **not** do this to skip the gate on an agent
   > that is merely slow — a long tool call is exactly what the window was widened to cover.
2. **Kill** — `tmux send-keys C-c` twice, then waits for the pid to exit. In current Claude Code the
   double-`C-c` often does NOT exit, so the script falls back to `kill <pid>` once the grace window
   passes. (SessionEnd fires either way → unregisters.)
3. **Relaunch** — `tmux send-keys 'claude --continue --name "<name>"' Enter` in the same pane.
   `--name` sets the session name at launch, which settles it before the hook's settle-recheck
   runs, so the fallback `/rename` keystroke is never reached.
   > There used to be a `WORKFLOW_AGENT_SKIP_RENAME=1` prefix here. It was redundant — `--name`
   > already makes the fallback unreachable — and harmful: it rides in the pane's shell
   > environment, so it outlived the startup it was scoped to and suppressed the fallback on
   > every later `/clear` in that pane. Removed (it needed a special case in `register-agent.sh`
   > just to undo itself). To fix a cleared agent's name, run `fleet-clear.sh` in its pane. The hook re-registers the agent (new
   pid) and re-injects its role context; `--continue` resumes the prior conversation. No session-id
   lookup needed.

   **`--clean` drops `--continue`** so the agent returns with a **fresh conversation**. Reach for it
   when shedding stale in-context state is the *point* of the restart — after a workflow or role
   change, resuming would carry the old assumptions forward and defeat the exercise. It **discards
   that agent's history**, so confirm it explicitly and separately from an ordinary restart; the
   role context is re-injected either way, and committed work is unaffected (it's in git).
4. **Verify** — polls for a NEW `<name>.<newpid>` registry entry on that pane; prints OK or a WARN
   (with the pane) if it didn't come back.

**Never restarts the caller** (self is always excluded).

## Mode: `compact` — partial-fanout compaction (idle-gated, always confirmed)

Inject `/compact` into the panes of agents whose context usage is **at/above a threshold** — the
"who's full → compact exactly those" action, paired with the `CTX%` column. `/compact` is a pane
action, so it's delivered via `tmux send-keys`, like `restart`.

```bash
~/.claude/scripts/agent-fanout.sh compact --dry-run [--threshold N]      # list who WOULD be compacted (+ their %)
~/.claude/scripts/agent-fanout.sh compact --yes [--threshold N] [targeting]
```

- **Audience** = live, non-self agents with `CTX% ≥ N` (default `N=80`). Below-threshold and
  context-unknown agents are listed as skipped, not compacted.
- **Idle-gated** — skips any BUSY / copy-mode pane (compacting mid-turn would interrupt in-flight
  work). To compact a busy agent, wait (Monitor until idle) and re-run.
- **Always confirmed** — like `restart`, it refuses without `--yes`. Show the user the `--dry-run`
  list (each target + its %), get explicit go, then pass `--yes`.
- Composes with the targeting flags. **Never compacts the caller** (self excluded).

> **Why this matters:** an agent near its window auto-compacts on its own schedule (losing your
> control over *when*); a deliberate `compact` at a quiet moment (e.g. before handing out new
> work) keeps the summary boundary where you want it.

## Other useful behaviors (built in / suggested)

Built in (in `agent-fanout.sh`): read-only `status` (no auth), role/`--only`/`--exclude` targeting,
`--dry-run` everywhere, self-exclusion, idle-gating (skip BUSY/copy-mode), sequential restart via
`claude --continue` with re-registration verification, and the `--yes` tripwire on `restart`.

Worth considering (ask the user before adding — out of scope unless requested):

- **Auto-prune stale entries** during `status` (currently it only *reports* them).
- **A background crash-watcher** that notices a `claude` pid vanished without `SessionEnd` and offers
  to relaunch — deliberately NOT built (a daemon doesn't belong in a hook, and it would still need
  the never-without-asking gate).

## What this skill will NOT do

- Restart or compact anything without explicit user authorization in the current turn (the script's `restart`/`compact` refuse without `--yes`, which you pass only after confirming).
- Kill, restart, or compact a BUSY agent (idle-gated — skipped).
- Restart or compact the caller (self is always excluded).
- Send a message. That is native `SendMessage`, addressed by team name.
- Touch `origin` (it only manages local panes). Publishing is `/open-pr`, and it is user-gated.

## Companion skills

- **`fleet-layout`** — owns the pane/window topology and every tmux window name; `boot` and `down`.
- **`fleet-clear`** — restore an agent's own session name after a `/clear` (self-targeting).
