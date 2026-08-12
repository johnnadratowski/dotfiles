---
name: test
description: Run the full TS/JS quality-gate sweep by spawning the tester subagent IN PLACE on the current worktree. The tester owns the gate catalog (G-8…G-18 + integration + Playwright E2E) and the machine-wide e2e lock; this stub documents the invocation recipe — including how to test another branch or PR (the CALLER arranges the tree; the tester never mutates git). Use for "run the tests", "test my branch", "run the gates".
---

# test — spawn the tester on this worktree

The sweep lives in the `.claude/agents/tester.md` definition (gate catalog
G-8…G-18, server integration, Playwright E2E, the machine-wide e2e lock, the known
gotchas). This stub is the invocation recipe.

## Invocation

**Spawn the tester** — Agent tool, `subagent_type: tester`, `model` =
`WORKFLOW_TEST_MODEL` when set (else omit ⇒ inherit). **Resolve the knob by sourcing the
loader, never by reading `workflow.config`:**
`. .claude/scripts/_config.sh && printf '%s\n' "${WORKFLOW_TEST_MODEL:-inherit}"` — the
committed file is only the first of three layers (`.claude/workflow.config.local`, then the
environment, override it), so grepping it reports "" ⇒ inherit for a knob the machine has
pinned. Prompt: what to run (default:
the full sweep) and the **changed range** for the post-GREEN missing-tests advisory
(e.g. `origin/master..HEAD`). It tests **whatever is checked out, in place** — uncommitted
work included — and makes zero git/source mutations. Fix failures yourself and re-run
(resume the same `tester` via SendMessage for the failed gates, or respawn for a full
sweep).

Same spawn everywhere — the tester is a subagent, never a fleet peer.

> **Placement — leave `run_in_background` at its default (background).** A tester is
> task-scoped, so it belongs **in the current window**, stacked under the pane that spawned it
> and selectable in the agent list. The `SubagentStart` hook places it automatically
> (`fleet-layout subagents`). This matters more for a tester than a reviewer: a full sweep runs
> long, and watching it is how you catch a gate wedged on the e2e lock instead of discovering it
> an hour later. `run_in_background: false` would run it in-process with no pane and no row —
> right for a one-shot lookup, wrong here. **It will not exit on its own**: stop it once its
> verdict is in. Canonical rule: CLAUDE.md → "WHERE A SPAWNED AGENT GOES".

## The caller arranges the tree (retired modes)

An older version checked targets out itself and merged the trunk in. **Retired** — the
tester never mutates git, so YOU set the tree up first:

- **Test the current branch as-is** (old `--as-is`): just spawn.
- **"Will this be green once it lands on master?"** (old `--with-base` default):
  sync first, then spawn, and say in the request that the range includes the merge:
  ```bash
  git fetch origin master
  git merge --no-commit origin/master          # --no-commit: see the regen note below
  .claude/project/hooks/regen-artifacts.sh "$PWD"   # merge=ours artifacts, staged
  git commit
  ```
- **Test another local branch / SHA / tag** (old `<target>`): check it out in a
  worktree that's free for it — your own (commit/stash first) or a scratch worktree
  (`git worktree add`) — and spawn the tester there.
- **Test a GitHub PR** (old `--pr <n>`): `gh pr checkout <n>` in a **scratch** worktree,
  spawn the tester there, remove the worktree after.
- **"Test master"**: never check out `master` in a lane (a worktree sitting on it blocks
  `git worktree add master` everywhere else). Use the sync recipe above, or a scratch
  worktree.

## Concurrency

The Docker-bound phase (integration + E2E) uses the project's fixed test-stack host
resources (containers + ports the tester owns) — machine-wide, one at a time. The tester serializes it itself through
`.claude/scripts/e2e-lock.sh` (liveness-heartbeat lock;
hermetic test: `.claude/scripts/e2e-lock.test.sh`). A long wait usually means another
worktree is mid-sweep — `~/.claude/e2e.lock/` names the holder
(`e2e-lock.sh status`). Scale throughput by adding feature agents, not by breaking the
lock.

## Scope (unchanged)

The project's TS/JS workspaces — the tester (project-owned) defines the exact gate set +
in/out-of-scope areas. Manual/browser QA is a separate, explicit request per the repo's
testing docs.

## Companions

- **`.claude/agents/tester.md`** — owns the catalog, the lock, the report shape.
- **[`review`](../review/SKILL.md)** — the review counterpart.

---

**Skill Version**: 6.0.0
**Category**: Quality / Test Gate

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
