# afk — changelog

- **2.3.0** — (DX-11) **Model knobs: no invented defaults.** The skill claimed the planner and
  rev-a default to `fable`; the config has both **empty**, and empty means *inherit the spawning
  session's model*. Only `WORKFLOW_REVIEW_MODEL_B` is pinned (`sonnet`), and only to keep the two
  reviewers model-diverse. The journal now records each subagent's **effective** model, printing
  "inherit" for an empty knob instead of a default that was never set. (Also brings the SKILL
  version footer back in sync — it read `2.0.0` while this changelog was at `2.2.0`.)

- **2.2.0** — (DX-jn-cc-019) **Model-diverse reviewers.** The two `/afk` reviewers now run
  different models: rev-a = `WORKFLOW_REVIEW_MODEL_A` (`fable`), rev-b =
  `WORKFLOW_REVIEW_MODEL_B` (`sonnet`). Journal logs both.

- **2.1.0** — (DX-jn-cc-016) **Planner authors the plan.** The plan phase now spawns the
  `planner` subagent (`WORKFLOW_PLAN_MODEL`, default `fable`) to author the plan doc; under
  `/afk` it plans **autonomously** (no human attaches — open questions go in the plan). The
  plan-review-gate note + the Step-0 journal now name the planner model alongside
  reviewer/tester.

- **2.0.0** — (DX-jn-cc-005) **Subagent cutover.** `--pr <agent>` / `--test <agent>`
  retired: the review loop spawns two `reviewer` subagents (`rev-a`+`rev-b`, both GREEN
  to pass), the test loop spawns the `tester` in place. The whole mailbox
  receipt-watch / liveness / failover protocol is deleted — a spawn returns a result or
  errors (respawn once, then stop). Solo mode no longer degrades the loops (they're
  identical solo and fleet); only Finish differs.

- **1.x** — pre-cutover history: peer-agent review/test loops with receipt-watching,
  reviewer failover pools, and the `WORKFLOW_TESTING_AGENT` default (see git history).
