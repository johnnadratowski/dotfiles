# base-test — changelog

- **5.0.0** — (DX-jn-cc-005) **Tester-subagent cutover.** The gate catalog, gotchas,
  and report shape moved into `.claude/agents/tester.md`; this skill is now an
  invocation stub. The `<target>`/`--pr <n>` checkout choreography is RETIRED — the
  caller arranges the tree (own branch, or a scratch worktree + `gh pr checkout`) and
  spawns the tester there; `--with-base` is replaced by `/base-merge down` first, then
  test as-is. Docker-bound phase now serialized by the machine-wide liveness lock
  `.claude/scripts/e2e-lock.sh` (hermetic test: `e2e-lock.test.sh`).

- **4.3.0** — (DX-jn-8-015) **Missing-test coverage pass (step 6), GREEN only.** After all
  gates pass, an advisory pass flags production code changed in the run that has no
  corresponding test (no sibling `*.test.ts`/`*.t.sol`, or a new export unreferenced by any
  test). Reported as a distinct "Missing tests" section; NEVER flips PASS to fail. Report
  renumbered to step 7. Mirrored in the testing-agent role.
- **4.2.0** — **Branch-flexible target, symmetric with `base-pr`.** The skill now
  takes an optional `<target>` (omitted → current branch; a local branch / SHA /
  tag → checked out in this worktree; `--pr <n>` → fetched PR head, detached) so
  it can test ANY branch, not just the current one — the afk test-loop's "test
  branch `<BRANCH>`" flows straight through. The base-merge is demoted to an
  optional modifier `--with-base` (**default ON** — "usually if something hits
  base it's already tested"); `--as-is` (alias of the old "skip the sync" / "test
  as-is" phrases) tests the target exactly. **Special case: the literal base
  branch is NEVER checked out** (a worktree on `<base>` breaks `git worktree add
  <base>` for every other agent) — "test the base" falls back to today's model
  (merge local `<base>` into the current feature branch and test). New step 2
  checks out the target; the old step-2 merge becomes step 3 (gates → 4,
  diagnose → 5, report → 6). **Testing mutates the worktree** (it's left on the
  target — unlike review, which is read-only). The `merge-helpers.sh` source,
  the `git merge --abort` recovery, and the full gate list (4a–4j) are unchanged.
- **4.1.0** — (DX-jn-8001) Step 1 now **sources `.claude/scripts/merge-helpers.sh`**
  — the fix for step 2 calling `regen_merged_artifacts` that previously lived
  inline in `base-push` and was never sourced here (`command not found`
  mid-merge). Step 2's clean-merge regen failure and the conflict path now point
  at `git merge --abort` (resets to `PRE_MERGE_SHA`); `regen_merged_artifacts`
  also regenerates the role-permissions seed when the merge touched
  `shared/js/role-permissions.js`, so step 3e's drift-guard can't red on a stale
  `merge=ours` seed.
- **4.0.0** — Renamed `john-test` → `base-test`; the merge source is now the
  configured base branch (`WORKFLOW_BASE_BRANCH` from `.claude/workflow.config`,
  loaded via `.claude/scripts/_config.sh`) instead of a hardcoded `john`,
  matching the upstream `claude-workflow` framework. The goals-specific gate
  list (3a–3j) is unchanged and remains project-owned.
- **3.2.0** — Purely-local coordination: dropped the `git fetch origin` from step 2 (the merge source was already local `<base>`; the fetch only fed a drift report, now computed from the cached `origin/<base>` ref with no network). `/john-pull` was removed fleet-wide — origin is write-only via `/base-push` — so companion/difference sections drop it.
- **3.1.0** — Merge source switched from `origin/<base>` to local `<base>`, so unpushed commits on local `<base>` are included in the test sweep. Preflight gains a `git rev-parse --verify john` check with a recovery hint. Final report surfaces the count of unpushed commits when applicable so the user sees whether the run measured pre-publication work.
- **3.0.0** — (prior versions: see git history)
