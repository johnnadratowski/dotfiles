---
name: staff
description: Spin up agents into lanes — spawn a teammate per lane, VERIFY each one actually entered its own worktree (not the lead's), and place them in their own tmux windows via the remembered layout. Handles one lane or the whole fleet, and refuses to double-staff an occupied lane. Use for "spin up an agent", "start feature-2", "staff the fleet", "add two more agents", "bring the team up".
---

# staff — put agents in lanes, and prove they landed

The counterpart to [`/shutdown`](../shutdown/SKILL.md). Bringing agents **up** has one failure
mode worth a whole procedure: a teammate boots in the *lead's* worktree and has to move itself.
Nothing today checks that it did.

## Why this is a skill, and why it is not `boot`

`~/.claude/scripts/team-boot.sh boot` starts **the lead**, in shell, and needs no agent. That
part stays a script — wrapping it would add a lookup layer and no capability.

The half that has no home is this one: **only the lead can create teammates.** A teammate
launched any other way runs fine and is permanently unaddressable, which is the exact failure
`team-boot.sh` exists to avoid. So spawning is necessarily an agent's tool call, and the
verification after it is the part that has never existed —`boot --with-team` types a request
into the lead's pane and then nothing confirms the outcome.

## Step 1 — Resolve targets, and refuse the two bad ones

```bash
~/.claude/scripts/team-boot.sh status
```

`/staff` (no args) means every unoccupied lane. `/staff feature-2` or `/staff 2` means that
one. `/staff 3` when three lanes are free means the first three by lane number.

- **An occupied lane is skipped, never re-staffed.** The `AGENT` column is resolved from
  process cwd, so a name there means a real process is standing in that directory. Spawning a
  second agent into it gives two sessions editing one worktree.
- **A missing lane is reported, not created.** `lanes.sh create` makes a git worktree, a
  branch, a port block and a Caddy import — durable, user-visible changes that should not
  happen as a side effect of "add an agent". Say which lane is missing and offer the command.

## Step 2 — Spawn, one teammate per lane

Get each prompt verbatim and spawn them **all in one message** so they boot concurrently:

```bash
~/.claude/scripts/team-boot.sh spawn-prompt <lane>
```

Agent tool, **background** (the default), `name` = the lane name exactly. The name is
load-bearing twice over: `SendMessage` addresses it, and the `SessionStart` hook picks the
role doc from it.

> **The prompt's first instruction must stay first.** It is `EnterWorktree` with the absolute
> lane path, because a teammate cannot be launched into a directory — there is no cwd
> parameter, so every teammate boots in *your* worktree on *your* branch. Do not summarize,
> reorder, or "improve" the prompt. Until that call lands, `lane-guard` refuses the teammate's
> every write, which is a blocked tool call rather than silent corruption of lane 0.

> ### The lane path is what keeps this promptless. Do not "tidy" it.
>
> `EnterWorktree` is each teammate's first action, and **no permission rule pre-approves it** —
> an `EnterWorktree` rule and "don't ask again" both fail; only `bypassPermissions` skips the
> prompt, and teammates inherit the lead's **current** mode at spawn time rather than its launch
> flags. A stalled teammate is also invisible: the prompt sits in its own pane, `status` cannot
> see it, and step 3 cannot tell it from a slow boot.
>
> **The carve-out we rely on is the MAIN CLONE's own `.claude/worktrees/`**, and that is
> where lanes now live (moved 2026-08-03 from a sibling `<clone>-worktrees/` directory). It is
> *a* carve-out demonstrated by the test below — not proven to be the only one; do not reason
> from "the sole exception".
> Teammates entering there are not prompted in any mode. Verified end to end: four teammates
> spawned from a lead in **`auto`**, all four confirmed by process cwd inside ~10s, zero prompts.
>
> An earlier note here recorded the carve-out as tested-and-rejected. That test entered
> `<lane>/.claude/worktrees/<name>` — a **lane's** `.claude/`, not the main clone's — and the
> rejection was real for that path only. The main-clone form was the untested variant, and it
> works.
>
> **So: no bypass step, and nothing to ask the user for.** Two rules survive from when there was:
>
> - **Never keystroke into a teammate's pane**, and never answer a teammate's prompt for it —
>   auto mode's classifier blocks exactly that, reading it as Claude altering its own oversight.
>   A stalled teammate gets surfaced, not driven.
> - **If a teammate ever does stall on `EnterWorktree`, the lane path is wrong** — check it
>   against `WORKFLOW_LANES_DIR` (`~/.claude/fleet.env`) before reaching for bypass. Bypass
>   would paper over a misconfigured fleet, and the whole fleet inherits it.

## Step 3 — Verify each one actually landed (the reason this exists)

A spawn returning is not an agent in its lane. Poll until each target lane shows a pid:

```bash
for i in $(seq 1 20); do ~/.claude/scripts/team-boot.sh status; sleep 3; done   # stop when all report
```

- **`status` reads process cwd**, so a name in the `AGENT` column is positive proof that the
  teammate is standing in its own worktree. Nothing weaker counts — not the spawn result, not
  the teammate saying it entered, not the team config on disk.
- **Still empty after ~60s** ⇒ that teammate is alive but standing in the lead's tree. Say so
  by name. The fix is a `SendMessage` telling it to call `EnterWorktree` with the absolute
  path and report the verbatim error if it fails — never "just work here".
- **Report a partial result honestly.** Three of four landing is a three-agent fleet, not a
  four-agent one with a caveat.

## Step 4 — Place them in their own windows

Teammates spawn as **split panes in the lead's window**; they are lane agents, so they belong
in windows of their own.

```bash
~/.claude/scripts/fleet-layout.sh reapply
```

`reapply` restores the last mode you chose (`~/.claude/fleet-layout-mode`) rather than
imposing one, which is what stops each new agent from silently degrading the arrangement.
It also ends in `agent-windows`, which is what repairs the two things staffing breaks: a
teammate arrives as a lone full-width pane with no companion column, and the lead's own chat
is left squeezed — tmux keeps the surviving panes' geometry when the spawned panes are broken
out, which once cut the lead to 62 columns of 208.
Pass an explicit `single` / `dual` / `wide` only if the user names one. Pane ids survive
`break-pane`, so routing follows the pane id, not the window.

## Step 5 — Report

One line per lane: name, branch, pid, and where it is now. Then the fleet total. If anything
was skipped or missing, that goes in the same report, not a footnote.

## What this skill will NOT do

- Create or remove a lane, install dependencies, or touch a branch.
- Spawn a second agent into an occupied lane, or launch a teammate any way other than as the
  lead's own spawn.
- Claim an agent is staffed on anything less than `status` showing its pid in its lane.
- Rearrange windows into a mode the user did not ask for.

## Companions

- **[`/shutdown`](../shutdown/SKILL.md)** — the other direction, and it takes targets too, so
  a single agent can be cycled without touching the rest of the fleet.
- **[`/fleet-layout`](../fleet-layout/SKILL.md)** — owns arrangement; `reapply` is its verb.
- **`~/.claude/scripts/team-boot.sh`** — `boot` (the lead) · `status` · `spawn-prompt` · `down`.

---

**Skill Version**: 1.0.0
**Category**: Fleet / Lifecycle

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
