# base-pr — changelog

- **5.0.0** — (DX-jn-cc-005) **Reviewer-subagent cutover.** The audit methodology
  (corpus, dimensions A–E, nemesis escalation, verdict tokens) moved into the
  `.claude/agents/reviewer.md` definition; this skill slims to range-resolution +
  reviewer spawn (mode 2) + anchor advance. `WORKFLOW_REVIEW_BRANCH` survives as a
  branch POINTER (never checked out — `git branch -f` on GREEN); the snapshot
  checkout / fix-apply / promote machinery is deleted (fixes flow through the authors'
  normal `/todo` loop). `--no-fix` → `--no-advance`. `--pr <n>` GitHub mode kept,
  now spawning the reviewer with the PR diff inline.

- **4.2.0** — (DX-jn-8004) base-pr now operates on a **dedicated review branch**
  (`WORKFLOW_REVIEW_BRANCH`, default `<base>-review`, per-base): step 1 switches to
  (or creates) it on a clean tree and **refuses on a feature branch with uncommitted
  changes**, so the step-10 promotion can never push a feature branch's *unreviewed*
  commits into `<base>` (the prior in-place model only refused `base`/`master`/`main`
  by name). Makes the `<base>-review` reservation in `/base-push` + `/base-merge` real
  again. The read-only `--pr <n>` GitHub mode is unaffected.
- **4.1.0** — (DX-jn-8001) Step 1 now **sources `.claude/scripts/merge-helpers.sh`**
  (the helper was extracted there from `base-push`; this skill never sourced
  `base-push`, so the step-10 promotion call had no definition). Step 10 now also
  routes return code **3** (post-merge regen/commit failure) alongside 0/1/2.
- **4.0.0** — Renamed `john-pr` → `base-pr`; the base branch is now configuration
  (`WORKFLOW_BASE_BRANCH` from `.claude/workflow.config`, loaded via
  `.claude/scripts/_config.sh`) instead of a hardcoded `john`, matching the
  upstream `claude-workflow` framework. Goals-specific audit content (Tier 1/2
  corpus, branded-types recipe, nemesis triggers) unchanged. Commit trailer
  removed per GH-2.
- **3.5.0** — Best-practices docs (`docs/server-best-practices.md`, `docs/frontend-coding-standards.md`, etc.) are now a Tier 1 corpus the audit ALWAYS loads when the diff touches the matching workspace, and Design alignment (section A) is reframed around them. The audit is bidirectional: A.1 reports code that violates an existing best-practices scenario as a Design finding (referencing the scenario by name + the rule sentence the code breaks); A.3 reports new patterns in the diff that the doc *should* capture but doesn't, as coverage-gap recommendations to update the doc. Section C also explicitly checks Tier 1 best-practices accuracy — renamed function, moved file, removed scenario, changed signature, etc. Step 6 now distinguishes code-change fixes (A.1) from doc-update fixes (A.3 + C drift) and asks whether to bundle them.
- **3.4.0** — Audit range sourced from local `<base>` instead of `origin/<base>`, so unpushed local commits on the base are in scope for review. Promotion still goes via origin (the helper does the right thing), with a new pre-flight check that warns + offers to push if local `<base>` is ahead of `origin/<base>`. Re-anchor (step 11) now FF's local `<base>` to the post-promotion `origin/<base>` before re-anchoring the snapshot.
- **3.3.0** — (prior versions: see git history)
