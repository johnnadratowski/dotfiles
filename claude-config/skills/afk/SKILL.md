---
name: afk
description: Drive a task to completion autonomously while the user is away: implement, review loop, test loop, then leave the work committed on the lane branch — never lands master, never opens a PR. Use for "AFK", "run this autonomously", "drive this to done", "take it from here".
---

# afk — autonomous task driver

You are about to run **unattended**. The user is away and wants this task carried to "done" with no hand-holding. Your job is to be maximally autonomous **and** maximally safe: keep moving without asking questions, but stop cleanly (and loudly) when you genuinely can't proceed.

## Invocation

```
/afk [test-first] [--todo <ID>] [--max-rounds N] [--push] [--pr-on-ship]
```

- **`test-first`** — flavor B (test/fix loop *before* review). Default is flavor A (implement first).
- **`--todo <ID>`** — the Linear issue this task ships (else infer from the task / branch; skip the issue bookkeeping if none applies).
- **`--max-rounds N`** (default `5`) — cap per loop (review, test). On reaching it, STOP and surface — never loop forever unattended.
- **`--push`** — on a clean run, `git push` the work to the **lane's own branch** on origin. **Default is local-only** — afk commits on the lane branch and stops, so you review on return. This is the only origin write afk can do, and only with this explicit opt-in. It never pushes `master` and never opens a PR.
- **`--pr-on-ship`** (alias: `--pr-on-close`, the pre-Linear name) — on a clean run, prepare a GitHub PR via `/open-pr <ID>` up to (but never past) its user-gated create step: branch, scope, gates, and the title/body package are ready; `gh pr create` itself waits for the user's return (PR creation is outward-facing — the autonomy contract's "never touch origin" exception does NOT extend to it). With this flag the issue ends at **In Review**, not Done: the eventual merge closes it. Without it, `/afk` skips the PR entirely and takes the no-PR path, closing the issue before the local-base merge.

> **Zero-prompt runs:** afk can't silence permission prompts itself — a skill can't change the
> session's permission mode mid-run. An unattended run that hits a prompt just *stops*, with
> nobody there to answer, which is the failure this note exists to prevent.
>
> **Sessions now start in `auto`, not bypass** (`team-boot.sh` launches the lead with
> `--permission-mode auto --allow-dangerously-skip-permissions`: bypass is *reachable*, not
> imposed, and teammates inherit whatever the lead has). So the useful move before a long
> unattended run is to **switch this session into bypass yourself** — shift+tab cycles modes —
> rather than relaunching. afk's own guardrails (no origin write without `--push`, no
> force-push, stay-in-scope) and the hard `deny` list still hold, so bypass + afk stays fenced.
>
> **CHECK AND WARN AT STEP 0, THEN CONTINUE.** Look for a bypass indicator in this session's
> own claude process argv:
>
> ```bash
> _p=$$; _mode=""
> for _ in 1 2 3 4 5 6 7 8; do
>   _p="$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')"; [ -n "$_p" ] && [ "$_p" != 1 ] || break
>   case "$(ps -o command= -p "$_p" 2>/dev/null)" in
>     *--dangerously-skip-permissions*) _mode=bypass; break ;;
>     *--permission-mode\ bypassPermissions*) _mode=bypass; break ;;
>   esac
> done
> [ "$_mode" = bypass ] || echo "afk: NOT in bypass mode — a permission prompt will stall this run with nobody to answer it. shift+tab to cycle into bypass, or accept the risk."
> ```
>
> **Warn and keep going — never refuse to start.** The check reads argv, so it cannot see a
> mode changed at runtime via shift+tab: a session that IS in bypass can still trip the warning.
> Treating that as a hard stop would block correct runs on a false negative, so the warning is
> advisory and afk proceeds either way.

The **task** is the work the user set up before invoking this (the current branch's in-progress changes and/or the referenced TODO). You own all the code and all the fixes; the reviewer and tester **subagents** (`.claude/agents/reviewer.md`, `.claude/agents/tester.md` — spawned via the Agent tool) are **services** you consult. Spawn them at the DEFAULT background setting so they land in the current window under your pane and stay watchable (CLAUDE.md -> "WHERE A SPAWNED AGENT GOES"); stop each one when its verdict is in, since a background agent never exits on its own. They need no liveness management: a spawn either returns a result or errors, and a dead one is respawned under the same handle with nothing lost — the lead's reviewers by name, a lane agent's by the `agentId` it recorded, per reviewer.md's spawn contract.

>  **afk never lands work.** It commits on the lane's own branch and stops. Shipping is a
> PR, which is outward-facing and user-gated, so the run ends with the work reviewed,
> tested, and committed — ready for you to open a PR on return (or with `--pr-on-close`,
> prepared right up to the create gate).

> **Plan authoring + review gate first:** author the plan via the
> `.claude/agents/planner.md` subagent (`model` = `WORKFLOW_PLAN_MODEL`; empty ⇒
> inherit — resolved by sourcing `_config.sh`, per the journal step below, never by reading
> `workflow.config`) — it writes to the gitignored staging file `.claude/plans/<ID>.md`, and under
> `/afk` plans **autonomously** (no human attaches to steer; it records open questions in the
> plan). Then, if the issue has no `Plan review:` **comment** recorded (see the `todo` skill's
> start step 4) and the plan is complex, run the gate BEFORE implementing — under `/afk` the
> gate is not shown (no human), so **4a** (the human's review) and **4c** (sign-off on the
> agents' deltas) are skipped: Q1 = **No Monocle**, Q2 = **Two reviewers** (`rev-a` + `rev-b`,
> dispatched together, both **PLAN GREEN**). The plan is posted to Linear only once that gate
> resolves, per the todo skill's start step 5 — never as a draft.

## Autonomy contract

- **`/afk` is the SOLE exception to the per-commit user-review gate.** The normal
  human-in-the-loop flow (feature.md / `/todo`) stops for the user's review of the
  uncommitted change *before every commit*; `/afk` runs unattended, so it commits on its own
  (agent review + the test sweep substitute) and the user reviews everything **on return**.
  This is the whole point of `/afk` — do not stop for per-commit user review here.
- **Do not ask questions unless genuinely blocked.** A decision with a sensible default is NOT a blocker: pick the default, **log it in the journal**, and keep going. The user reviews your choices on return.
- **Blocking question** = something whose answer changes the implementation and has no safe default. When you hit one: implement everything you safely can around it, run it through review + test anyway, then **stop before the final merge** and present the accumulated questions (see Finish → blocked path).
- **Stay in scope.** Implement the task; do not opportunistically refactor unrelated code while unsupervised.
- **Never** `--no-verify`, `--amend` published commits, force-push, run destructive git, or broadcast/fan-out to fleet agents. Reviewer/tester subagent spawns are local and always sanctioned.
- **Never touch origin** except the `git push` of the lane's own branch that runs ONLY when `--push` was passed. Never push `master`. Never open or merge a PR.

## Step 0 — Plan echo + journal

Before going dark, write a one-screen plan and open the journal so the unattended run is auditable.

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
JOURNAL="logs/afk-$BRANCH.md"   # logs/ is gitignored
mkdir -p logs
```

Print and append to `$JOURNAL`: the task, flavor (A/B), `--max-rounds`, the issue ID, the planner/reviewer/tester models in effect (`WORKFLOW_PLAN_MODEL` / `WORKFLOW_REVIEW_MODEL_A` / `WORKFLOW_REVIEW_MODEL_B` [pinned `sonnet`] / `WORKFLOW_TEST_MODEL` — resolve each and journal the **effective** model, printing "inherit" for every empty knob rather than a default that isn't set. **Resolve them ONCE, here, by sourcing the loader — never by reading `workflow.config`:** `. .claude/scripts/_config.sh && for k in WORKFLOW_PLAN_MODEL WORKFLOW_REVIEW_MODEL_A WORKFLOW_REVIEW_MODEL_B WORKFLOW_TEST_MODEL; do eval "v=\${$k:-}"; printf '%s=%s\n' "$k" "${v:-inherit}"; done`. The committed file is only the first of three layers — `.claude/workflow.config.local` (gitignored, per-machine) is sourced after it and the environment wins last — so grepping it reports "" ⇒ inherit for a knob the machine has pinned, and an unattended run spends the wrong model for hours. Every later spawn in this run uses the values journaled here), the landing policy ("commit on the lane branch; push it to origin only if --push; never land master, never open a PR"), and the exact stop conditions. Keep appending a timestamped line at every state transition, every review finding + how you resolved it, every non-blocking default you picked, and every test result. This journal is also your **resume state** if the run is interrupted (context compaction, restart) — on resume, read it to find where you left off.

## State machine

**Flavor A (default — implement first):**
1. Implement the task as far as you safely can (respecting blocking questions).
2. **Documentation sync** (§ Doc-sync) — before review.
3. **Review loop** (§ Review).
4. Commit the fixes (conventional commit; reference the issue ID).
5. **Test loop** (§ Test).
6. **Finish** (§ Finish).

**Flavor B (`test-first`):**
1. **Test loop** first — get the current state green.
2. **Documentation sync** (§ Doc-sync) — once the implementation is settled, before review.
3. **Review loop**.
4. Commit.
5. **Test loop** again (final tests).
6. **Finish**.

## Doc-sync

Before review, run the documentation-sync step (`docs/doc-sync.md`) so the docs land in the same diff the reviewer sees:

- **Encode the product/business decisions** this work made into the **product docs** — `docs/product.md` for overview, or a topic doc you see fit (e.g. `docs/vaults-and-allocations.md`) linked from `product.md`'s index — the rule/flow/limit/default you established or changed, and a sentence of *why*.
- **Reconcile every doc the changed code touched** — best-practices, testing, `architecture.md`, `docs/security/*.md`, swagger (`@swagger` JSDoc → `pnpm --filter goals dump:swagger`), the relevant `CLAUDE.md` — per the map in `doc-sync.md`.
- Keep it proportionate (a typo needs none; a behavior change almost always touches `product.md`). Log what you synced in the journal. The reviewer's doc-drift dimension will catch anything missed.

## Review loop

**Reviewers under `/afk` — No Monocle + Two reviewers, no prompt.** `/afk` never shows the
two-axis review gate (no human to answer): Q1 = **No Monocle**, Q2 = **Two reviewers** —
two independent spawns of the `.claude/agents/reviewer.md` definition
(`rev-a` + `rev-b`), dispatched together each round; the round is GREEN only when **both**
are. (Two independent readers is the unattended substitute for the human's eye.)

Repeat up to `--max-rounds`:

1. Commit any pending work first (so the reviewers see a clean SHA). **Spawn both
   reviewers at once** (Agent tool, `subagent_type: reviewer`, naming per the canonical
   contract in `.claude/agents/reviewer.md` → "How you are spawned" — the lead
   names them `rev-a`/`rev-b`, **a lane agent omits `name` and records the returned
   `agentId`**, because the roster is flat and a named spawn from a teammate hard-errors;
   `model` model-diverse: first = `WORKFLOW_REVIEW_MODEL_A`, second =
   `WORKFLOW_REVIEW_MODEL_B` (pinned `sonnet`); **each empty ⇒ omit the param**, which
   inherits this session's model — that is the default for `_A`; use the values you resolved
   and journaled at start-up via `_config.sh`, never a fresh read of `workflow.config`) with the definition's
   **mode-1 contract**: the issue id, `type: diff`, the commit SHA/range, the pin SHA,
   and any business decisions not yet in the files.
2. **Collect both verdicts.** A spawn returns its verdict as its result (or errors —
   respawn once under the same handle; a second consecutive error on the same round is a
   Stop condition). No liveness-watching, no failover pool: the Agent tool always
   resolves.
3. **Parse both — GREEN LIGHT required from each.**
   - **Both green** → exit the loop.
   - **Findings from either** → fix every blocker (and reasonable nits) from **both**; if
     a finding is itself a blocking question with no safe default, record it and address
     what you can. Append each finding + resolution to the journal. Commit the fixes,
     then loop — **resume the SAME reviewers** (SendMessage to each one's name or recorded
     `agentId`, with the fix SHA; the fix-round audit is by SHA, first-class).
4. **Cap / non-convergence.** If you reach `--max-rounds`, or the same finding keeps
   recurring (a reviewer isn't converging), **Stop** and surface the state — do not keep
   looping.

## Test loop

1. **Spawn the `.claude/agents/tester.md`** (Agent tool, `subagent_type: tester`,
   name `tester`, `model` = `WORKFLOW_TEST_MODEL` when set, else omit — the journaled value
   from the `_config.sh` resolution at start-up) **in place on the
   branch**: "Full sweep. Changed range: `origin/master..<BRANCH>`." The tester makes zero
   git/source mutations and serializes the Docker-bound phase through the machine-wide
   e2e lock (`.claude/scripts/e2e-lock.sh`) itself — long waits on the lock are normal
   when another worktree is mid-sweep; its report says what ran.
2. **Parse:** PASS → exit. Failures → **you** fix them (the tester reports; you own the
   code), commit, then re-run — resume the same `tester` (SendMessage: "re-run the failed
   gates") or respawn for a full sweep. Append results to the journal.
3. Cap at `--max-rounds`; on non-convergence Stop and surface.

(Quick local gates — `pnpm types:check`, the relevant `pnpm test:unit`, lint — are fine to run yourself in-place before spawning, to avoid burning a full-sweep round on something you can catch locally.)

## Finish

Once review is green **and** tests pass:

- **Clean run (no blocking questions accumulated):**
  1. **Set the issue's state to match how this actually lands** — the two paths differ, and getting it wrong is worse here than anywhere else because nobody is watching.
     - **Default (no PR — lands into the local base):** nothing will auto-close it, so close it here via the `todo` skill's `done` (state → Done + close comment listing the work commits; forensic writeups land in a repo doc per the skill), **before** step 2 merges. This is the surviving case of close-before-merge.
     - **With `--pr-on-ship`:** do **NOT** close. The PR carries `Fixes <ID>`, so the **merge** closes the issue; set **In Review** instead (step 3 prepares the PR). Closing here would mark the issue Done behind an unmerged PR — precisely the misreport the Linear-native flow exists to prevent.
     - Skip entirely if no issue applies.
  2. **Leave the work committed on the lane branch. Do NOT land it.**
     - There is no local trunk merge any more: work ships through a PR, and opening one is
       user-gated because it publishes outward. So afk's terminal state is
       "reviewed + tested + committed on the lane branch".
     - **`--push`:** `git push -u origin <BRANCH>` — the lane's own branch only. A
       rejection means the remote branch moved; **STOP** and report. Never force-push.
     - **Never `git push origin master`.** afk cannot open, approve, or merge a PR.
  3. If `--pr-on-ship`: run `/open-pr <ID>` up to its create gate (branch + scope + gates + package ready); the user approves `gh pr create` on return. The issue sits at **In Review** (step 1) — it is NOT closed, and the merge will close it once the user creates and lands the PR. Note the prepared package in the report.
  4. Notify + final report.

- **Blocked path (one or more blocking questions accumulated):**
  1. Do **not** merge or publish. Leave the work committed on the branch and landed-ready.
  2. Notify + final report, with the **blocking questions front and center** — clearly numbered, each with the context and the options you see, so the user can answer fast on return. Note that review + test already passed on what's implemented.

## Notify + final report

The user is AFK, so actively get their attention, then leave a complete written report.

```bash
# macOS native desktop notification (always available); also ring the bell.
osascript -e 'display notification "<one-line status>" with title "AFK run: <BRANCH>"' 2>/dev/null || true
printf '\a'   # terminal bell
```
(If the `claude-notifications` plugin is configured, use it instead/as well.)

The **final report** (terminal + appended to `$JOURNAL`):
- Outcome: **DONE — committed on <BRANCH> (+pushed?)**, or **STOPPED — needs you** (blocking questions / cap hit / subagent errors).
- What was implemented (commits: hashes + subjects).
- Review: rounds taken, every finding + how it was resolved, final GREEN (both reviewers).
- Tests: rounds, final PASS (or the failure that stopped it).
- Non-blocking defaults you chose (so the user can veto on return).
- **Blocking questions**, numbered, if any.
- Issue status, head SHA on the lane branch, push status.

## Stop conditions (always notify + report)

- A **blocking question** with no safe default — after review + test on what's implemented.
- **Cap reached** (`--max-rounds`) or a loop not converging.
- A reviewer or tester spawn **errors twice consecutively** on the same round (respawn once, then stop — something environmental is wrong).
- A **sync conflict** merging `origin/master` down, or any gate you cannot fix within scope.
- Anything that would require an action the contract forbids (origin write beyond the sanctioned publish, destructive git, out-of-scope change).

## What this skill will NOT do

- Ask questions for anything with a sensible default (pick it, log it, continue).
- Loop forever — every loop is capped.
- Touch origin except the lane-branch `git push` that runs only when `--push` was passed.
- Broadcast/fan-out to fleet agents, force-push, `--no-verify`, `--amend` published commits, or wander outside the task's scope.
- Push or prepare a PR when blocking questions remain — it stops and asks instead.

---

**Skill Version**: 2.3.0
**Category**: Workflow, Autonomous

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
