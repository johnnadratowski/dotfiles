---
name: monocle-pr-review
description: Review a GitHub PR in the Monocle human-review engine. Use for "review PR <n> in monocle".
---

# monocle-pr-review — review a GitHub PR in Monocle

Load a GitHub pull request into Monocle for a proper local read: the PR's changes shown as a
native diff, **the PR's own inline review comments surfaced as annotations on the code they point
at**, plus **the agent's own annotations linking non-obvious ranges to the repo's docs**. Then
block on the reviewer's verdict.

This is for reviewing *a PR* (someone else's, or your own before merge) with the existing
discussion pulled in — distinct from sending your in-flight uncommitted work to Monocle. It drives
the Monocle MCP tools directly and needs nothing repo-specific; it works on any repo whose PR you
can reach with `gh`.

> **Blocking by default — you stage AND wait.** After staging the review you MUST block on
> `get_feedback(wait=true)` until the reviewer submits, then act on it. A review you staged but
> never waited on is not a review. (Fire-and-forget only if the user explicitly says "just stage
> it, don't wait".)

## Prerequisites

- The **Monocle MCP server** is connected (the `mcp__monocle__*` tools are available). If they
  aren't, stop and tell the user Monocle isn't live — there's nothing to stage a review on.
- **`gh`** is authenticated for the PR's repo (`gh auth status`), and you're inside a local clone
  of that repo.

## Invocation

```
/monocle-pr-review [<pr>]
```

- `<pr>` — a PR number, a full PR URL, or omitted to use the PR for the current branch
  (`gh pr view` with no arg). A URL for a *different* repo: `cd` into that repo's clone first —
  Monocle diffs the local working tree, so the PR's commits must be checkoutable there.

## Procedure

### 1. Resolve the PR

```bash
gh pr view <pr> --json number,title,url,headRefName,baseRefName,state,isDraft
```

Capture `number`, `title`, `headRefName`, `baseRefName`. Stop if the PR can't be resolved (bad
number, wrong repo, `gh` unauthenticated) — surface the `gh` error verbatim.

### 2. Check out the PR locally

Monocle reviews the **local** working tree, so the PR's commits must be checked out:

```bash
git status --porcelain           # dirty? STOP and ask — never stash silently
gh pr checkout <number>          # puts you on the PR's head branch
git fetch origin <baseRefName>   # make the base ref current locally
```

If the working tree is dirty, stop and ask (checking out the PR would collide) — this skill does
not stash or discard work.

### 3. Point Monocle at the PR diff

Compute the merge-base so Monocle shows **exactly the PR's changes** — not base commits that landed
after the PR forked:

```bash
git merge-base HEAD "origin/<baseRefName>"
```

Call the `set_base_ref` tool with `{ref: "<merge-base-sha>"}`. Monocle now renders every file the
PR changed as a diff, with grouping / annotations / the gutter. (It auto-reverts to working-tree
mode when the reviewer submits; `set_base_ref({reset: true})` reverts now.)

> **Name the review (step 4) BEFORE this if you are doing both in one pass.** Monocle holds exactly
> ONE review per repo, and `set_review_name` with a new name silently replaces the open one —
> which is known to drop artifacts sent beforehand. Whether it also clears the base ref is
> unverified, so do not find out on a live review: the safe order is
> `set_repo → set_review_name → set_base_ref → annotations → groups`.

### 4. Name the review

`set_review_name({name: "PR #<number> — <title>"})` — once, at the start. (Re-running with the same
name is a no-op; don't rename mid-review.)

### 5. Surface the PR's own inline comments as annotations

Fetch the PR's **inline review comments** — the ones anchored to a file + line — and map each onto
the code it references:

```bash
gh api --paginate "repos/{owner}/{repo}/pulls/<number>/comments"
```

Each element has `path`, `line` / `start_line` (position on the **new** side, `side: "RIGHT"`),
`original_line`, `body`, `user.login`, `in_reply_to_id`, `diff_hunk`. Build one `add_annotations`
entry per comment — or per **thread**, grouping replies that share an anchor (`in_reply_to_id`):

- `file` = `path`; `line_start`/`line_end` = `start_line`..`line` (fall back to `line` for a
  single-line comment; when `line` is null use `original_line` and add an `(outdated)` marker to
  the summary).
- `summary` = one line: `💬 @<user.login>: <first sentence / condensed body>` (a thread →
  `💬 @a → @b: <gist>`). The summary is **one line** — condense; never paste a multi-paragraph body.
- `refs` = none for PR-comment annotations (they carry the discussion, not doc links).

Send them with `add_annotations({entries, replace: true})`, read the response, and fix any rejected
entries (bad range / file not in the review) before continuing. **Left-side (deletion) comments**
whose new-side line can't be resolved: skip them, and report the count so the reviewer knows some
were dropped.

### 6. Add the agent's own doc-linking annotations

Now read the PR's changed code yourself and, **selectively**, annotate the ranges whose *why* is
non-obvious with a link to the repo doc that explains it. **Append** to step 5's entries (send one
combined set with `replace: true`; don't clear the PR-comment annotations away):

- Discover the repo's docs generically — a `docs/` tree, `README`, `ARCHITECTURE`, `CONTRIBUTING`,
  a package's own docs. Link the passage that motivates the code.
- Entry shape:
  `{file, line_start, line_end, summary: "<one line: what this range does>",
    refs: [{kind: "file", doc: "<repo-relative doc path>", label: "<link text>",
            start_line, start_col: 0, end_line, end_col: 0}]}` (doc lines 1-based, cols 0-based).
- **Selective, not exhaustive** — skip self-explanatory code; annotate where a doc genuinely
  clarifies intent, a constraint, or a gotcha. Prefer ranges the PR description or a design doc
  explains.
- Re-send the combined set with `add_annotations({entries: [...both...], replace: true})`, read the
  response, and fix any refs that don't resolve.

### 7. Group the changed files — ONE COMMAND, and it applies the grouping itself

```bash
monocle-review.sh groups <merge-base-sha>     # the SAME ref you passed to set_base_ref
```

It classifies the PR's files deterministically into the canonical bottom-up order
(**infra → contracts → subgraph → db → types → shared → api → sdk → ui → docs → tests**,
call-hierarchy-sorted within each), **applies** the grouping, and prints the count it grouped.
Being script-derived, every agent groups the same PR identically.

> **Do NOT call `set_file_groups` by hand here.** This step used to say to, and that made grouping
> an unverified second step nothing checked — measured 2026-08-04, one lane had never called it on
> any review and nothing ever objected, because an ungrouped review reads as a Monocle limitation
> rather than a missed step. If the command prints a count, grouping is applied. If it prints
> `0 changed files`, your base ref is wrong — fix that rather than reaching for the manual call.

Hand-built entries remain correct only for the **workstream** level (a PR spanning several issues,
nesting `workstream → category`), which is not script-derivable. A single-purpose PR needs only
the one level this command produces. If you do layer custom labels or orders on top, say so in
your step-8 summary — otherwise a review that renders oddly cannot be told apart from the general
case.

### 8. Report + wait for the verdict

Emit a one-line summary — review name, base ref, file count, PR-comment annotations added, own
annotations added — then **block**: `get_feedback({wait: true})`. Act on the verdict:

- **Approved** → report it, done.
- **Changes requested** → relay them. This skill *reviews* a PR; it doesn't own the fix unless the
  user then asks you to address the comments.

## Failure handling

- **Monocle tools absent** → stop: "Monocle isn't connected — nothing to stage a review on."
- **`gh` can't resolve the PR / unauthenticated** → surface the error, stop.
- **Dirty working tree** at checkout → stop and ask (never stash silently).
- **Annotations rejected** (bad range, file not in the review, unresolved ref) → the tool lists
  them with reasons; fix and re-send until clean.
- **A comment's line can't be mapped** (outdated position, left-side deletion) → skip it, count it,
  report the count.

## What this skill will NOT do

- Post anything back to GitHub — it's **read-only** on the PR (it pulls comments in, never writes
  them out).
- Fix the PR's code — it stages the review + surfaces the discussion; addressing comments is a
  separate, user-directed step.
- Stash or discard uncommitted work to check out the PR.
- Send the diff as a raw artifact — Monocle diffs the checked-out tree natively (that is what
  `set_base_ref` is for); raw artifacts lose grouping / annotations / the gutter.

## Companion

- The Monocle MCP tools it drives: `set_base_ref`, `set_review_name`, `add_annotations`,
  `set_file_groups`, `get_feedback`.

---

**Skill Version**: 1.0.0
**Category**: Review, GitHub
_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
