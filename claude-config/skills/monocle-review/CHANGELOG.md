# monocle-review — changelog

## Changelog

- **1.9.0** — (DX-jn-cc-005) "Contract for the gates": Q2 is now **Two reviewers / One
  reviewer / None** — spawns of `.claude/agents/reviewer.md` (mode-1 contract, fix
  rounds resume the same named reviewer) — replacing Both/Only-peer/Only-subagent.
  `/afk` default: No Monocle + Two reviewers.

- **1.8.0** — Added a **`shared`** category to the `groups` classifier — plain-ESM value
  modules under `shared/` (imported by BOTH server + UI; introduced by CMP-001) get their
  own group ordered **right after `types`** (foundational shared code, ahead of the
  api/sdk/ui that consume it), instead of falling through to the `infra` fallback.
  Canonical order is now infra → contracts → subgraph → db → types → **shared** → api →
  sdk → ui → docs → tests.
- **1.7.0** — After staging a review, **always emit a stats block** (new procedure step 7,
  before the verdict wait): review name, base ref, # files in review, # context artifacts,
  # additional files (`add_files`), and the TODOs included — so the user sees exactly what
  was sent. Verdict-wait renumbered to step 8.
- **1.6.0** — **Send-and-wait is now the explicit BLOCKING default.** Sending to Monocle
  means send AND block on the verdict (`get_feedback` wait=true), then act on it — never
  fire-and-forget — at every call site (`/todo` gates, `pr-comments`, ad-hoc sends).
  Fire-and-forget is opt-in only (the user explicitly says "don't wait"). Added the
  top-of-skill rule + marked step 7 MANDATORY. (Agents were firing reviews and moving on.)

- **1.5.0** — **Review already-committed work via `set_base_ref`.** When the diff is
  committed (a committed fix round, re-review of landed work, a peer branch, full
  branch-vs-base), call the MCP `set_base_ref({ref})` tool so Monocle reviews everything
  since `<ref>` with the full native surface (it auto-reverts after the reviewer submits;
  `reset:true` to revert now). `monocle-review.sh groups` gained an optional `<base>` arg
  (diffs `<base>` vs the working tree) so committed reviews group too. Codified the
  **anti-pattern**: never send a diff as a raw artifact (renders raw, loses
  grouping/annotations/gutter) — use `set_base_ref`. (Dogfooded on the busy-marker fix.)
- **1.4.0** — The gate contract is now an explicit **3-option review-path prompt** —
  **1) Send to Monocle · 2) Send to peer review · 3) Skip review → implementation/commit**
  — presented at the `/todo` **plan** gate AND the **implementation/diff** gate. Monocle is
  **option 1**, offered only when the engine is live (omitted when down); `/afk` doesn't
  prompt and defaults to peer review. Replaces the prior one-line "offer Monocle" hook.

- **1.3.0** — Grouping is now **N-level**: the bottom-up **category** order we've always
  used (infra→…→tests, script-derived) becomes the inner level, and when a `diff` review
  spans **>1 TODO** an optional **workstream** (TODO id) top level wraps it
  (`workstream → category`, author-supplied — not script-derivable pre-commit). A
  single-TODO review is unchanged (just the category level). Singleton sublevels are
  collapsed. Reviews are now **named** (shows in Monocle's top bar) — single-TODO → the
  TODO id, multi-TODO → a descriptive name or the joined ids (via the `set_review_name`
  MCP tool). Annotation entries must **bound the exact code range** they
  explain (gutter bar = that range; single-line ⇒ `line_start == line_end`). Invocation
  takes multiple `<ID>`s for multi-workstream diffs. (DX-jn-8-022 dogfood.)
- **1.2.0** — Diff reviews now also **annotate the non-obvious changed ranges** (new
  procedure step 6, after grouping): the **authoring agent** attaches one-line
  `summary` notes via the MCP `add_annotations` tool, each preferring a `refs` link
  into the doc passage that explains the *why* (the C-12/C-13 docs we already write).
  Selective (not exhaustive — skip self-explanatory code, C-7); summary-only allowed.
  Author-only/semantic — unlike grouping it is **not** script-derived, so a peer-sent
  review won't reproduce it (hence no script subcommand). Send with `replace=true` and
  **read the response** — Monocle validates upstream (rejected entries + unresolved-ref
  warnings) and **auto-clears on round advance**, so within a round re-send to refresh
  line-static notes, across rounds just re-annotate. (DX-jn-8-022.)
- **1.1.0** — Diff reviews now **always group the changed files bottom-up** (new
  procedure step 5). The send-path script gained a `groups` subcommand that
  classifies the working-tree diff deterministically into the canonical order —
  infra → contracts → subgraph → db → types → api → sdk → ui → docs → tests — and
  emits `set_file_groups` entries the agent pipes to the MCP (the script can't call
  the MCP itself). Deterministic classification is what makes a peer agent's send
  group identically to the author's (the prior cross-agent inconsistency). (INF-1004
  dogfood.)
- **1.0.0** — Initial (DX-jn-8-017): detection-gated, TODO-context-aware Monocle
  send with stable per-role artifact ids (update-in-place, anti-clutter); diff left
  to native review; verdict wait via the existing MCP/hook path.
