---
name: review
description: Review what's new since the last review, incrementally. Reviews the branch you are ON against its merge base with the PR target, from the WORKFLOW_REVIEW_ANCHOR pointer (default <branch>-review — a branch POINTER, never checked out), spawns the reviewer subagent (mode 2) on it, and advances the anchor on GREEN LIGHT. --pr <n> reviews a GitHub PR read-only the same way. Reports findings; applying fixes is the caller's normal /todo flow.
---

# review — audit what's new since the last review

Incremental review of a branch. The audit itself is the
`.claude/agents/reviewer.md` definition — this skill only resolves the range,
spawns it, and advances the anchor.

**Why an anchor.** Without one, every review round re-reads the whole branch, so the
reviewer's cost grows with history and the same findings resurface. The anchor is a
**branch pointer** marking where the branch stood at the last GREEN review; a round
reviews only what landed since. It is **never checked out** — nothing may sit on it.

Default target is **`master`**; `--branch <name>` reviews any other branch (a lane, say).
One anchor per target (`<target>-review`), so each derives its own.

> This is *not* the PR-review skill. `/open-pr` and `/pr-comments` review a PR's full diff
> against its target, once. This reviews **work in progress**, in slices. Both exist
> because they answer different questions; don't collapse them.

## Invocation

```
/review                        # review <anchor>..<this branch>, advance the anchor on GREEN
/review --branch <name>        # same flow against another branch
/review --no-advance           # review only; leave the anchor where it is
/review --pr <number>          # review a GitHub PR (read-only, reports in terminal)
```

## Procedure (local range mode)

1. **Resolve the target + anchor:**
   ```bash
   source "$(git rev-parse --show-toplevel)/.claude/scripts/_config.sh"
   PR_TARGET="${WORKFLOW_PR_TARGET_BRANCH:-master}"
   TARGET="${TARGET:-$(git rev-parse --abbrev-ref HEAD)}"   # THIS branch — see below
   ANCHOR="${WORKFLOW_REVIEW_ANCHOR:-${TARGET}-review}"
   git rev-parse --verify "$TARGET" >/dev/null || exit 1
   # First run seeds the anchor at the MERGE BASE with the PR target, never at $TARGET itself.
   # `origin/$PR_TARGET`, not the bare local ref: nothing updates a worktree's local `master`,
   # so it sits wherever it was cloned and the merge base comes out far too early. Still purely
   # local — a remote-tracking ref reads from disk, no fetch.
   BASE_REF="$(git rev-parse --verify -q "origin/$PR_TARGET" >/dev/null && echo "origin/$PR_TARGET" || echo "$PR_TARGET")"
   git rev-parse --verify "$ANCHOR" >/dev/null 2>&1 ||
     git branch "$ANCHOR" "$(git merge-base "$TARGET" "$BASE_REF" 2>/dev/null || echo "$BASE_REF")"
   ```

   > **TARGET is the branch you are ON, not the PR target.** It used to default to
   > `WORKFLOW_PR_TARGET_BRANCH`, so a lane with unlanded work reviewed `master-review..master`
   > — *master's* new commits, not its own — and on the first run the anchor was seeded at
   > `master`, making the range EMPTY. `/review` then reported "nothing new to review" and
   > stopped. A gate that returns green having read nothing is worse than no gate, because it
   > is indistinguishable from a clean pass. Observed on lane feature-3 with 60 unlanded
   > commits, 2026-07-31. Standing on `master` still reviews master, because that is then the
   > current branch — the old behaviour survives exactly where it was correct.
   >
   > Seeding at the merge base is the other half: an anchor seeded at `$TARGET` makes the
   > FIRST review of a lane's own work empty for the same reason.
2. **Resolve the range** (purely local — no fetch): `git log --no-merges --oneline
   $ANCHOR..$TARGET`. Empty ⇒ "nothing new to review", stop. Anchor diverged from the
   target (not an ancestor) ⇒ surface `git log --left-right --oneline $ANCHOR...$TARGET`
   and ask. Report upfront: N commits, M files.
3. **Spawn the reviewer** — Agent tool, `subagent_type: reviewer`, **mode 2
   (range/bundle)**: the range `$ANCHOR..$TARGET`, the pin SHA (`git rev-parse $TARGET`),
   and any context the caller supplied.

   > **Placement — leave `run_in_background` at its default (background).** A reviewer is
   > task-scoped, so it belongs **in the current window**, stacked under the pane that spawned
   > it and selectable in the agent list, where you can watch and steer it mid-review. The
   > `SubagentStart` hook places it automatically (`fleet-layout subagents`). Do NOT use
   > `run_in_background: false` here — that runs in-process with no pane and no agent-list row,
   > which is right for a one-shot lookup and wrong for a review you may want to interrupt.
   > **It will not exit on its own**: stop it once its verdict is in. Canonical rule: CLAUDE.md
   > → "WHERE A SPAWNED AGENT GOES". Model from `WORKFLOW_REVIEW_MODEL_B` (the
   single-reviewer / stronger knob, default `sonnet`; empty ⇒ omit ⇒ inherit) — **resolve it
   by sourcing the loader, never by reading `workflow.config`:**
   `. .claude/scripts/_config.sh && printf '%s\n' "${WORKFLOW_REVIEW_MODEL_B:-inherit}"`, since
   the committed file is only the first of three layers (`.claude/workflow.config.local`, then
   the environment, override it) and reports "" ⇒ inherit for a knob the machine has pinned. The
   definition owns the entire audit (corpus, dimensions A–E, nemesis escalation, verdict
   tokens).
4. **Relay the verdict** to the user. Findings are **reported, not fixed here** — fixes
   belong to their authors' normal `/todo` flow (or an issue minted for them).
5. **Advance the anchor on GREEN LIGHT** (skip with `--no-advance`):
   ```bash
   git branch -f "$ANCHOR" "$TARGET"   # pointer move only — nothing is checked out
   ```
   NOT GREEN ⇒ leave the anchor: the next run re-reviews the same range plus whatever
   landed since, so findings stay in view until resolved or explicitly waved through by
   the user (who can advance manually with the same command).

## Mode: review a GitHub PR (`--pr <number>`)

Read-only; ignores `--branch`; never touches the anchor; never posts to GitHub.
Prereq: `gh` authenticated.

1. `gh pr view <n> --json number,title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,url`
   and `gh pr diff <n>` — report the PR upfront (title, author, size).
2. **Spawn the reviewer** — mode 2 with the **PR number + body + the diff artifact
   inline** (the reviewer's isolation worktree can also run `gh pr diff` itself; inline
   guards against auth differences). Deep review (gates against the PR head) is the
   caller's business: `gh pr checkout` in a scratch worktree, then spawn the tester there.
3. **Relay the verdict in the terminal** as a recommendation to the human
   (approve / request-changes / comment) — never posted to GitHub.

## What this skill will NOT do

- Check out any branch, apply fixes, merge, push, or fetch.
- Advance the anchor past a NOT-GREEN review (that requires the user's explicit call).
- Post anything to GitHub in `--pr` mode.

## Companions

- **`.claude/agents/reviewer.md`** — owns the audit methodology + verdicts.
- **[`test`](../test/SKILL.md)** — the test counterpart (tester spawn recipe).
- **`/open-pr`** — PR-scoped review, a different moment entirely.

---

**Skill Version**: 6.0.0
**Category**: Code Review / Git Workflow

_Version history: see [CHANGELOG.md](./CHANGELOG.md)._
