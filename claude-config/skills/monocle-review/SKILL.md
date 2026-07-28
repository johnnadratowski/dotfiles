# monocle-review — opt-in Monocle review at the user-review gates

Offer to send a review to Monocle **when (and only when) the Monocle engine is live
for this repo**, attaching the context that isn't in the diff (the in-flight issue +
its plan) as artifacts under **stable ids** so re-sends update in place instead of
accumulating. Backed by `~/.claude/scripts/monocle-review.sh` + the declarative
`.claude/monocle-artifacts.json`.

This skill does not replace the human-in-the-loop review gate — it's the
**Monocle-flavored option** of it. The diff is reviewed by Monocle **natively**
(working tree, rendered properly); this skill adds the surrounding context and the
verdict round-trip.

> **Sending to Monocle is BLOCKING by default — you send AND wait for the verdict, then
> act on it.** Never fire-and-forget: after sending (+ grouping/annotating) you MUST
> block on `get_feedback` (wait=true) until the reviewer submits, then handle the
> feedback (approve → proceed; changes → fix, re-send, re-wait). This is the default at
> every call site (the `/todo` gates, `pr-comments`, ad-hoc "send this to monocle").
> **Fire-and-forget is opt-in only** — do it solely when the user explicitly says so
> (e.g. "just send it, don't wait"). A review you sent but didn't wait on is not a
> review — it's an ignored request.

## When to Use

- A workflow review gate is offering Monocle: the `/todo` **plan-review** step, the
  **user-review-before-commit** gate (coordinator / feature flow), or `base-pr`'s
  review point.
- The user says "send this to monocle", "review this in monocle", "send the plan to
  monocle".

**Do NOT use** when the engine is down — fall back to `git diff` / peer review (the
script tells you: `available` exits 2). And do NOT route the **diff** through it —
Monocle reviews the working-tree diff natively and renders artifacts raw; this skill
only sends **context** (issue + plan).

## Invocation

```
/monocle-review [<context>] [<ID> …]
```

- `<context>` ∈ `plan` | `todo` | `diff` (default: infer from the in-flight work —
  `plan` at a plan-review step, else `diff`/`todo`).
- `<ID> …` — the Linear issue id(s) (default: the in-flight issue). A `diff` review may name
  **multiple** issues when the working tree holds more than one workstream — each gets
  its artifacts sent and becomes a top-level workstream group (step 5).

## Procedure

1. **Detect** — `~/.claude/scripts/monocle-review.sh available`. Exit 2 ⇒ engine down:
   say so, fall back to `git diff` / peer review, stop.
2. **Preview** — `monocle-review.sh list <context> <ID>` shows exactly which
   artifacts will be sent (path + stable id). Skip-warnings (e.g. an issue with no
   plan) are surfaced, not fatal.
3. **Ask the user** — "Send to Monocle? The diff is reviewed natively; I'll attach
   for context: \<list>." Opt-in **per review** — never auto-send.
4. **Send + name the review** — on yes: `monocle-review.sh send <context> <ID>` (run
   it once per `<ID>` when the diff spans multiple issues — each call adds that issue's
   `plan:<ID>` + `todo:<ID>` artifacts). Stable ids ⇒ each artifact updates in place
   across every round (plan-review now, diff-review later) — one current plan + one
   current issue each, never `v1/v2/v3`.
   **Name the review** via the MCP `set_review_name({name})` tool (shows in Monocle's
   top bar; call it once when the review starts — it is NOT the artifact titles, which
   name individual context docs). A **single-issue** review is named for that issue (its
   id, e.g. `DX-jn-8-022`, optionally `<ID> — <title>`); a **multi-issue** review gets a
   short descriptive name *or* the issue ids joined (`DX-jn-8-022 + DX-jn-8-023`).

   **Already-committed work — set a base ref (do this BEFORE step 5).** The default
   review is the working-tree diff (uncommitted) — the normal flow reviews *before*
   committing (the `/todo` step-7 gate is pre-commit). But when the work is **already
   committed** (a committed fix round, a re-review of landed work, a peer's branch, or a
   full branch-vs-base review), the working-tree diff is empty, so call the MCP
   **`set_base_ref({ref})`** tool with the commit to diff against — the branch you
   started from, a SHA, or `HEAD~N`. Monocle then reviews everything since `<ref>` (your
   commits included) with the **full native surface** (grouping, annotations, proper
   rendering). It auto-reverts to working-tree mode once the reviewer submits, or
   `set_base_ref({reset: true})` to revert now. **Pass the SAME `<ref>` to
   `monocle-review.sh groups <ref>`** in step 5. **Anti-pattern: never send the diff as a
   raw artifact** — Monocle renders artifacts raw, losing grouping/annotations/the gutter;
   `set_base_ref` is the right tool.
5. **Group the changed files (diff context only) — ALWAYS.** Organize the changed files
   so the reviewer reads them as a story, via the MCP `set_file_groups` tool
   (`replace=true`; reviewer presses `f` to cycle to the grouped view). Monocle supports
   **N nesting levels**; we use up to two, the top one optional:
   - **Category level (always).** Run `monocle-review.sh groups` (or
     **`monocle-review.sh groups <base>`** for a committed / base-ref review — the same
     `<ref>` you passed to `set_base_ref`) — it classifies the
     diff **deterministically** into the canonical bottom-up order **infra → contracts
     → subgraph → db → types → shared → api → sdk → ui → docs → tests** (substrate → surface),
     call-hierarchy-sorted within each. This is the categorization we've always used;
     being script-derived, every agent (author OR a peer) groups identically.
   - **Workstream level (top — ONLY when the diff spans >1 issue).** With multiple issues
     under review, wrap each file's category under its **issue id** as the top level
     (`workstream → category`), ordered by issue. The **author supplies** this split —
     only the author knows which uncommitted file belongs to which issue, and nothing
     records it until the commits exist. **A single-issue review has NO workstream
     level** — just the one category level, exactly as before.
   - **Collapse singletons** — don't emit a level whose only child is a single file (a
     1-file "api" subgroup is noise); render the file directly.
   - `criticality` is a separate float-within axis — bump a higher-risk file with
     `"criticality": <n>`. New files only group if Monocle's native diff sees them —
     `git add` (stage) any untracked changed files first. (Plan/todo-only contexts have
     no diff — skip this step.)
6. **Annotate the non-obvious ranges (diff context only) — author-only.** After
   grouping, attach short one-line rationale notes to the changed ranges via the MCP
   `add_annotations` tool, so the reviewer sees *what each range does* with a
   click-through to the doc that explains *why*. These are a write-only reviewer aid
   (never returned as feedback) — generated by the **authoring agent** (semantic, not
   script-derived like grouping, so a peer-sent review won't reproduce them).
   - **Selective, not exhaustive.** Annotate only ranges where the *why* is
     non-obvious; skip self-explanatory code (C-7). **Prefer** ranges whose rationale
     you encoded in a doc during doc-sync (C-12/C-13) — `product.md` / a topic doc /
     `integration-notes.md` / `architecture.md` / the plan / the issue.
   - **Entry shape — bound the EXACT code the note explains.**
     `{file (a changed file), line_start, line_end, summary (one line), refs[]}`.
     `line_start`/`line_end` must tightly bracket the specific changed lines the note
     is about (new-file line numbers, 1-based, read straight from the diff you're
     reading) — **not** the whole file, **not** an approximate span: Monocle draws a
     gutter bar over exactly that range, so a sloppy range mislabels unrelated code.
     Single-line note ⇒ `line_start == line_end`. Each ref is
     `{kind: 'file'|'artifact', doc, label, start_line, start_col, end_line, end_col}`
     (doc lines 1-based, cols 0-based) pointing at the passage — `kind:'file'` → a repo
     doc at its **post-edit** line range; `kind:'artifact'` → a `plan:<ID>` /
     `todo:<ID>` artifact already sent in step 4. **Summary-only is allowed** (a ref is
     preferred, not required).
   - **Send with `replace=true`, then read the response.** The tool reports accepted
     vs **rejected entries (with reasons)** and **warnings for refs that don't
     resolve** — fix those and resend until clean (the channel validates upstream; it
     will not silently swallow a bad range/ref).
   - **Rounds:** a fix re-sent *within* a round repeats this step with `replace=true`
     (annotations are line-static — no in-round auto-rebase). *Across* rounds the
     reviewer submitting **auto-clears** them, so just re-annotate against the new code.
   - (Plan/todo-only contexts have no diff — skip this step.)
7. **Report the review stats — ALWAYS, right after staging.** Once the review is sent
   (+ grouped/annotated for a diff), emit a one-block summary so the user sees exactly
   what was staged before the verdict wait:
   - **Review name** — the `set_review_name` value
   - **Base ref** — the `set_base_ref` ref, or `working tree (HEAD)` when none
   - **Files in review** — count of changed files (the `set_file_groups` entries; `0`/n-a for a plan/todo-only context)
   - **Context artifacts** — count sent (`plan:`/`todo:` pairs)
   - **Additional files** — count added via the `add_files` tool (extra context beyond the diff; `0` if none)
   - **TODOs** — the `<ID>`(s) included in the review

   ```
   📋 Monocle review staged — "DX-jn-8-022 + DX-jn-8-023 · review-skill dogfood"
      base ref: working tree (HEAD) · files: 9 · artifacts: 4 · added files: 0 · TODOs: DX-jn-8-022, DX-jn-8-023
   ```
8. **Wait for the verdict — MANDATORY (the blocking default; never skip).** After
   sending, block via the normal Monocle path (so a long human review doesn't hit a
   Bash-tool timeout): the MCP `get_feedback` tool with `wait=true` (or
   `/get-feedback-wait`, or the `on-stop` hook). Do not move on to other work / end the
   turn while a sent review is unanswered — you sent it, you wait for it. Act on the
   feedback; for change requests, fix → re-send (step 4 updates in place; re-run step 5
   if the file set changed; re-run step 6 to re-annotate the new code) → re-wait until
   approved. (Only skip the wait if the user explicitly asked for fire-and-forget.)

## Contract for the gates (two independent axes — human review + agent review)

**Both** review gates — the `/todo` **plan** gate and the **implementation/diff** gate —
work the same way: the agent asks the user **via the `AskUserQuestion` tool** (native
multiple-choice, NOT options printed as text). It is **two independent questions asked
together, never one merged choice.** The old single "Monocle / peer / skip" prompt was
wrong: it let picking Monocle silently drop agent review (and let "skip" drop everything).
The two axes are orthogonal — **choosing a human-review method must NEVER drop agent
review, and declining agent review must NEVER drop the Monocle human review:**

> **Q1 — Human review (header "Monocle"): _Monocle, or not._**
> **Monocle** = `/monocle-review <plan|diff> <ID>` (this skill sends the context artifacts,
> groups + annotates the diff, blocks on `get_feedback`). **No Monocle** = the user reviews
> the plain plan / `git diff` in the terminal instead. Offer the Monocle choice **only when
> the engine is live** (`monocle-review.sh available`); when it's down, Q1 is not asked and
> the axis is "No Monocle".
>
> **Q2 — Agent review (header "Reviewers"): _two reviewers, one, or none._**
> **Two reviewers** = two independent spawns of the
> [`reviewer`](../../agents/reviewer.md) definition (Agent tool, names `rev-a`/`rev-b`),
> dispatched together — both must go GREEN · **One reviewer** = a single spawn (`rev-a`)
> · **None**. Spawn prompt = the definition's **mode-1 contract**: issue id, review type
> (plan/diff), target (SHA / range / `working` with the diff inline; uncommitted plan
> docs inline), business decisions not yet in the files, and the pin SHA. **Model —
> MODEL-DIVERSE:** `rev-a` runs `WORKFLOW_REVIEW_MODEL_A` (**empty by default ⇒ inherits this
> session's model**), `rev-b` runs `WORKFLOW_REVIEW_MODEL_B` (**pinned `sonnet`**) — that pin is
> the whole mechanism making the two reviewers audit on **different** models. A **single**
> reviewer (Q2 = One, and the range/PR audits in `/base-pr` / `/pr-comments`) runs
> **`WORKFLOW_REVIEW_MODEL_B`**, so a lone reviewer is never left on whatever the session
> happens to be. Pass each as the Agent `model` param; an **empty** knob ⇒ omit ⇒ inherit.
> **Fix rounds RESUME the same named reviewer** (SendMessage with the fix SHA) — a fresh
> spawn under the same name is for the NEXT issue (that's the per-issue context clear).

Ask **both questions in a single `AskUserQuestion` call** (the tool takes multiple
questions). The answers **compose independently** — any of *Monocle + Two*, *No Monocle +
One*, *Monocle + None*, etc. Monocle is the **human**-review engine; the reviewer spawns
are **agent** corroboration that runs before the human's terminal sign-off — **one is
never a substitute for the other.** Whatever the answers, **the human is the terminal
reviewer of every loop** (a "No Monocle + None" pick still ends with the user's go, just
reviewed as a plain diff — it is not "no review").

**Under `/afk`:** no prompt — Q1 = **No Monocle** (no human present), Q2 = **Two
reviewers**. (Full gate wiring: the `/todo` skill's plan gate + step 7.)

## Declarative artifact set

`.claude/monocle-artifacts.json` maps **roles** (path + stable id + syntax type) to
**contexts** (which roles to send). Adding "also always send X" is a one-line data
edit there — no script or skill change.

## Caveat

Monocle renders artifact markdown/diffs **raw** (no pretty render). Fine for context
files (TODO, plan read fine raw); it's the reason the diff is left to native review
rather than sent as an artifact.

## Companion

- **`/review-plan` / `/review-plan-wait` / `/get-feedback` / `/get-feedback-wait`** —
  the lower-level MCP commands; this skill is the issue-context-aware, detection-gated
  layer on top.
- **`/todo`**, **`base-pr`** — the gates that call into this skill.

---

**Skill Version**: 1.9.0
**Category**: Workflow, Review
_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
