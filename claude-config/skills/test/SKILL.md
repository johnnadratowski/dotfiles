---
name: test
description: Get the full TS/JS quality-gate sweep run. In a fleet you do NOT run it yourself — you send a request to the STANDING TESTER, the one agent that owns Docker, the shared DB and the fixed test ports; solo, you spawn the tester subagent in place. Also documents how to test another branch or PR (the CALLER arranges the tree; the tester never mutates git). Use for "run the tests", "test my branch", "run the gates".
---

# test — hand the sweep to the agent that owns the test stack

The sweep itself lives in the project's `.claude/agents/tester.md` definition (the gate
catalog G-8…G-18 + G-22/G-23, server integration, Playwright E2E, the known gotchas). This
stub is about **who runs it**, which changed on 2026-08-14.

## In a fleet: ask the standing tester. Do not run it, do not spawn one.

The fleet has one **standing tester teammate** — `<prefix>tester` (goals: `g-tester`) — and it
is the only agent permitted to touch Docker, the shared test database, or a fixed host port.
`SendMessage` it:

```
worktree: /abs/path/to/your/lane      # required — it cd's here; it never moves itself
suite:    unit | integration | full   # required
range:    origin/master..HEAD         # optional — for the post-GREEN missing-tests advisory
```

It runs requests **one at a time, in arrival order**, and reports the verdict back to you
(CC'ing the lead on FAIL). **Queued is not stuck.** If you have not heard back, ask it for its
queue position rather than starting anything yourself.

- **Never `pnpm --filter goals test:integration`, `pnpm test:e2e` or Playwright in your lane**,
  and never spawn a tester subagent — a second runner is the entire failure this design
  removes.
- **DB-free gates stay yours**: format, lint, typecheck, unit (server + UI). Run them in place
  before you ask for a sweep; they cost the tester's queue nothing and catch most reds.
- **`suite: unit` is a legitimate request** (e.g. you want an independent run), but the tester
  will tell you those are gates you can run yourself.

### Why ownership, and not the lock it replaced

The isolated stack binds fixed machine resources — `goals-test-postgres` (:5434),
`goals-test-redis` (:6380), server :3100, UI :3101 — and a run's **teardown stops the shared
container and Docker Desktop itself**. Two worktrees testing at once therefore kill each
other's runs, with an error in the victim that looks like its own bug; that happened three
times on 2026-08-14. A machine-wide lock file (`e2e-lock.sh`, retired) made every worktree
responsible for remembering to take it, and covered E2E only — the integration suite, which
caused those collisions, took no lock at all.

**One runner needs no lock.** The invariant now lives in a single agent's serial queue instead
of in every caller's discipline. Scale throughput by making the sweep faster, never by adding
a second runner.

## Solo (no fleet): spawn the tester subagent, in place

With no standing tester on the machine, spawn it yourself — Agent tool, `subagent_type:
tester`, `model` = `WORKFLOW_TEST_MODEL` when set (else omit ⇒ inherit). **Resolve the knob by
sourcing the loader, never by reading `workflow.config`:**
`. .claude/scripts/_config.sh && printf '%s\n' "${WORKFLOW_TEST_MODEL:-inherit}"` — the
committed file is only the first of three layers (`.claude/workflow.config.local`, then the
environment, override it), so grepping it reports "" ⇒ inherit for a knob the machine has
pinned. Prompt: what to run (default: the full sweep) and the **changed range** for the
post-GREEN missing-tests advisory (e.g. `origin/master..HEAD`). It tests **whatever is checked
out, in place** — uncommitted work included — and makes zero git/source mutations.

**You are then the single runner by construction — so check that you are.** Before the
Docker-bound phase, confirm no other worktree is mid-sweep (`docker ps` showing
`goals-test-postgres` busy, or a live fleet with a `…-tester` in
`~/.claude/running-agents/`). If a fleet is up, the answer is the section above, not this one.

## The caller arranges the tree (retired modes)

An older version checked targets out itself and merged the trunk in. **Retired** — the tester
never mutates git, so the REQUESTER sets the tree up first:

- **Test the current branch as-is** (old `--as-is`): just ask.
- **"Will this be green once it lands on master?"** (old `--with-base` default):
  sync first, then ask, and say in the request that the range includes the merge:
  ```bash
  git fetch origin master
  git merge --no-commit origin/master          # --no-commit: see the regen note below
  .claude/project/hooks/regen-artifacts.sh "$PWD"   # merge=ours artifacts, staged
  git commit
  ```
- **Test another local branch / SHA / tag** (old `<target>`): check it out in a worktree that's
  free for it — your own (commit first) or a scratch worktree (`git worktree add`) — and name
  THAT path as the request's `worktree:`.
- **Test a GitHub PR** (old `--pr <n>`): `gh pr checkout <n>` in a **scratch** worktree, point
  the request at it, remove the worktree after.
- **"Test master"**: never check out `master` in a lane (a worktree sitting on it blocks
  `git worktree add master` everywhere else). Use the sync recipe above, or a scratch worktree.

## Scope (unchanged)

The project's TS/JS workspaces — the tester definition (project-owned) defines the exact gate
set + in/out-of-scope areas. Manual/browser QA is a separate, explicit request per the repo's
testing docs.

## Companions

- **`.claude/agents/tester.md`** — owns the catalog and the report shape. The standing tester
  reads it **from the worktree it is testing**, because it is versioned with that branch.
- **`~/.claude/scripts/team-boot.sh spawn-prompt --tester`** — the standing tester's boot
  prompt (the `/staff` skill hands it over verbatim).
- **[`review`](../review/SKILL.md)** — the review counterpart.

---

**Skill Version**: 7.0.0
**Category**: Quality / Test Gate

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
