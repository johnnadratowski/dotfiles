---
name: staff
description: Spin up agents into lanes — spawn a teammate per lane plus the standing tester, and VERIFY each one actually entered its own worktree (not the lead's). Handles one lane or the whole fleet, and refuses to double-staff an occupied lane. Use for "spin up an agent", "start feature-2", "staff the fleet", "add two more agents", "bring the team up".
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

## Step 0 — CHECK YOUR OWN cwd FIRST. A wandering lead blocks every teammate.

```bash
pwd    # must be the lead's own lane
```

**A teammate boots in the LEAD's process cwd**, and `EnterWorktree`'s carve-out resolves
against *the repo it is standing in*. So if the lead has `cd`'d into another repo — trivially
easy while editing dotfiles, config, or a sibling project — every teammate boots there, the
lane path is not a worktree of that repo, and **all four are refused**. Not prompted: refused.

Measured, 2026-08-03: a full staff-and-verify cycle burned because the lead's shell had drifted
to `~/git/dotfiles`. Four teammates came up, each correctly diagnosed it, each wrote a blocker
to `.claude/needs-input`, and all four had to be stopped and respawned. The signal was
indistinguishable from a slow boot for three minutes — step 3 polls for a pid, and a refused
teammate never gets one.

`cd` back to the lane before spawning. If you cannot, say so and stop; do not spawn and hope.
The failure is loud in the teammate's pane and silent everywhere the lead can see.

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

## Step 1.5 — Engines up BEFORE agents, or every bind is refused

A teammate calls `set_repo` as its **second act**, and the fleet launches with
`MONOCLE_REQUIRE_SET_REPO=1`. **`set_repo` does not autospawn an engine** — measured twice,
against a reading of `EnsureServe` that said it did. So a lane with no `monocle serve`
running gets a hard refusal at bind time. Step 4 is too late: it builds the companion pane
that would have started the engine, long after the agent already tried to bind.

```bash
LANES="$(bash -c '. ~/.claude/scripts/_fleet.sh; fleet_lanes_dir')"
for n in <targets>; do
  pgrep -f "monocle serve -C $LANES/$n" >/dev/null 2>&1 ||
    (nohup monocle serve -C "$LANES/$n" >/dev/null 2>&1 &)
done
sleep 2; pgrep -laf 'monocle serve -C'   # one line per target lane
```

- **A live `monocle` TUI is not proof of a live engine.** The TUI spawns the engine as a
  child and holds it; kill the engine and the TUI survives engine-less — and no reseed
  replaces it, because the pane is still there. `pgrep` for `monocle serve`, and kill a
  stale TUI by **pane id** so step 4 rebuilds it.
- **Verify by process, never by the absence of an error.** A dead engine behind a correct
  binding answers `review_status` with "No feedback pending." That is a wrong answer, not a
  failure, and it is the worst thing this fleet has produced.

## Step 2 — Spawn, one teammate per lane

Get each prompt verbatim and spawn them **all in one message** so they boot concurrently:

```bash
~/.claude/scripts/team-boot.sh spawn-prompt <lane>
```

Agent tool, **background** (the default), `name` = **the AGENT name: the project's
`WORKFLOW_AGENT_NAME_PREFIX` + the lane name** (goals: `g-feature-1`, not `feature-1`; with
no prefix configured they coincide). The spawn prompt's own first line names the agent — use
exactly that. The name is load-bearing twice over: `SendMessage` addresses it (an unprefixed
spawn would register prefixed via the hook while the lead addresses the bare name it thinks
it spawned — reports into the void), and the `SessionStart` hook picks the role doc from it.

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

## Step 2b — Spawn the STANDING TESTER. A fleet without it cannot test at all.

```bash
~/.claude/scripts/team-boot.sh spawn-prompt --tester
```

Same Agent-tool spawn as a lane teammate, `name` = the prefix + `tester` (goals: `g-tester`).
Include it in the **same message** as the lane spawns.

- **It gets no lane and must not enter one.** Its prompt's first instruction is the opposite
  of a lane agent's: *do NOT call `EnterWorktree`*. It parks in the main clone and `cd`s into
  whichever worktree asks — because tests run **in place** against a lane's tree, and a tester
  with a worktree of its own could only test it by checking someone else's branch out, which
  is the one thing the tester contract forbids.
- **Therefore step 3's proof does not apply to it.** No lane will ever show its pid. Confirm
  it instead by its own report (parked in the main clone, queue empty) and by
  `ls ~/.claude/running-agents/ | grep tester`.
- **It is the ONLY agent permitted to run Docker / shared-DB / fixed-port suites** — server
  integration and Playwright E2E. That ownership is what replaced the machine-wide e2e lock:
  one runner means nothing to serialize against. Lanes keep the DB-free gates.
- **Respawn it whenever it dies.** Nothing else may pick the work up, so a fleet whose tester
  is gone is blocked, not merely slower.

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

## Step 4 — Placement: there is nothing to place

**Retired.** Teammates no longer appear in the fleet's tmux session at all: the lead launches
with `WORKFLOW_TEAMMATE_MODE=detached`, which puts every teammate's TUI in a separate
`claude-swarm` session. Nothing is squeezed, nothing needs breaking out, and the fleet
session's windows stay free for a human's own use. Running a layout verb here would restructure
the user's windows for no reason.

- **To watch a teammate**, attach its session (`tmux attach -t claude-swarm`, or
  `tmux switch-client -t claude-swarm` from inside tmux) — or reach its prompt over its UDS
  socket, which is why teammates stayed real processes instead of going in-process.
- **Verification is unaffected**: `status`, `verify` and the TUI all resolve by process cwd,
  never by pane.
- **If this fleet is running `WORKFLOW_TEAMMATE_MODE=native`** (teammates split into the lead's
  window — the pre-2026-08-14 behaviour), then run `~/.claude/scripts/fleet-layout.sh reapply`
  here: it restores the remembered mode and ends in `agent-windows`, which repairs the lone
  full-width pane with no companion column and the lead's squeezed chat.

## Step 4b — Verify every teammate bound Monocle to its own lane

Monocle resolves its repo from the **MCP client's advertised roots**, and a teammate's roots
are the LEAD's — `EnterWorktree` moves the agent, not the advertised root. Unbound, a teammate's
Monocle answers about your worktree: a review it stages is invisible, and `get_feedback` returns
*"No feedback pending"* for a verdict that was actually submitted. **A wrong answer, not an
error** — which is why this is a verification step and not a footnote.

**The spawn prompt makes `set_repo({path: <lane>})` the second first-act**, right after
`EnterWorktree`, and `team-boot.sh` launches the lead with `MONOCLE_REQUIRE_SET_REPO=1` so the
whole fleet inherits strict binding and nothing else on the machine does. **Confirm each
teammate reported the root it bound to.** A teammate that says nothing about it has probably
skipped it; under strict mode its first review call will hard-fail, which is the intended
outcome but a worse place to find out.

**The lead does NOT bind — it runs no Monocle at all** (John, 2026-08-13): no engine in the
lead's lane, no TUI in its companion pane (`WORKFLOW_LEAD_CELL_COMMAND` in fleet-layout.sh
defaults the lead's companion to a bare cmdline), no `set_repo` at boot. Review traffic lives
in the LANE agents' engines; anything the lead would have staged goes to chat or ad hoc.

**Do NOT reach for `/mcp` reconnect.** It was the fix before `set_repo` existed; it needs a
human in each pane and rebinds nothing an agent can verify. If a teammate is unbound, the
answer is that it calls `set_repo` — one tool call, from where it already is.

**Historical tell, still worth recognising:** `add_annotations` rejecting entries with *"file is
not one of the review's changed files"* while `set_review_name` and `set_file_groups` accept
happily. **Its absence is not a pass** — a plan review makes no validating call at all, so an
unbound plan review looks entirely healthy. **The `set_repo` echo is the check** — it names the root it bound to. Do NOT rely on a
`review_status` prefix: measured 2026-08-03, it returns a bare "No feedback pending." with no
repo identity when no review is loaded, so it cannot tell a bound agent from an unbound one.
`MONOCLE_REQUIRE_SET_REPO=1` refusing an unbound call is the backstop.

## Step 4c — Apply the configured effort level and model

> **Check the script exists before you promise this step.** As of 2026-08-14 there is no
> `agent-tune.sh` anywhere on this machine (`find ~/git/goals-onchain ~/git/dotfiles -name
> agent-tune.sh` → nothing), so on this fleet the step is dead and the knobs below are unapplied.
> It is also **pane-typing machinery**: under `WORKFLOW_TEAMMATE_MODE=detached` a teammate's
> pane lives in the `claude-swarm` session, so any revival must target that session, not the
> fleet's. Say the level was not applied rather than reporting a step you did not run.

Teammates boot at the machine-global level, which is rarely the level you want for every lane.
Apply the project's configured values once the panes exist:

```bash
.claude/scripts/agent-tune.sh apply            # add --dry-run first if you want the plan
```

Knobs live in the project's `.claude/workflow.config` **and its gitignored, per-machine
`.claude/workflow.config.local`, which overrides it** (the environment wins last).
`agent-tune.sh` sources `_config.sh` and therefore sees all three layers; read a knob by hand
the same way (`. .claude/scripts/_config.sh && printf '%s\n' "$WORKFLOW_LANE_MODEL"`) rather
than grepping the committed file, which reports "" for anything `.local` has pinned. The set:
(`WORKFLOW_LANE_EFFORT[_N]`,
`WORKFLOW_LANE_MODEL[_N]`, and the per-subagent `WORKFLOW_*_EFFORT` set). **Empty means
inherit**, so a fleet that configures nothing is unaffected by this step and `apply` is a
no-op that reports SKIP for every lane.

**Why this is a post-spawn step and not a spawn parameter.** The Agent tool takes `model` but
has no `effort` at all, so effort can only ever be set after the fact. And a subagent
definition's `effort:` frontmatter — the obvious place to put it — is **accepted and then
ignored for teammates**; it applies only to a solo session's in-process spawn. Under
`--teammate-mode tmux` each teammate is its own process with its own TUI, which is both why
the frontmatter misses and why typing into its pane works.

**It verifies rather than assumes.** `apply` re-reads each pane's status line and reports
PASS / FAIL / REFUSED per agent, because a `send-keys` can be lost, and because both commands
raise a confirmation dialog on any session that already has history — an unanswered dialog
leaves the old value in place and looks exactly like success from the sending side. Treat a
FAIL row as "not applied", and re-run that lane; do not re-run blind.

**One hazard worth knowing even if you never touch the script:** `/effort` and `/model`
persist to `~/.claude/settings.json` as the default for NEW sessions, from a teammate's pane
as readily as the lead's. `agent-tune.sh` snapshots that file and restores it afterwards. If
you ever set a level by hand instead, you have just re-levelled every future agent on this
machine — check that file after.

## Step 5 — Run the mechanical check. It catches what steps 1.5–4 let through.

```bash
~/.claude/scripts/team-boot.sh verify
```

Every line in it is something a lead has silently skipped, and **each one fails in a way that
looks like something else** — which is why they survived as manual steps:

- **The lead unregistered.** No agent resident in its window ⇒ `_window_rank` scores it
  `300+idx` and its tab sorts **last**. That read as a layout bug for two days. The cause is a
  shutdown-then-boot in the same pane: the departing session's `SessionEnd` hook matched its
  own successor's registry entry by pane token and deleted it.
- **A lane with no engine.** `review_status` then answers *"No feedback pending."* — a wrong
  answer rather than an error, which is the worst failure this fleet produces.
- **A lane with no companion pane.** Its window closes when the agent exits, so the loss shows
  up a cycle later attached to nothing.

**Do not hand-inspect instead.** These were manual steps and they were skipped; that is the
entire reason this verb exists. Fix anything it reports before telling the user the fleet is up.

## Step 6 — Report

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
