# pseudocode — show the fix as before/after pseudocode

The user asked what a change actually does, and prose was not landing. **Show it as two small
blocks of pseudocode — the shape today, and the shape after — with the defect visible in the
first and gone in the second.**

This exists because it worked: a slippage-guard fix that had survived three prose explanations
without landing was understood instantly as ~10 lines of before/after. The pseudocode did what
the paragraphs could not — it put the two independent lookups next to each other so the reader
could see nothing tied them together.

## Invocation

```
/pseudocode <topic>
```

The topic is a fix, a finding, a plan phase, or a proposed change — named however the user
names it. **Resolve it by re-reading the source** (the plan, the ticket, the actual code),
never from conversation memory. If the real code differs from what you remember, the
pseudocode follows the code.

## What pseudocode means here — and does not

This is **illustration, not implementation**. The reader is deciding whether the fix is right,
not reviewing a patch:

- **Invent a clean vocabulary.** `goal.contract.deposit(...)`, `vaultConfig[vaultId]` — names
  that say what things are, not the codebase's actual identifiers if those are noisy. Drop
  branded types, error plumbing, async ceremony, imports.
- **Keep only the lines where the point lives.** Every kept line either participates in the
  defect or in the fix. If a line survives from habit, cut it.
- **The defect must be visible in the BEFORE block** — ideally as two lines the reader can see
  are unconnected, a comparison that cannot be true, an order that loses. If the before block
  looks fine to a careful reader, the pseudocode has failed; rework it until the flaw shows.
- **Language-agnostic by default.** Real syntax only when the construct is the point.

## Shape

```
**Before** — <one clause naming the flaw>:

    <5–15 lines; the flaw visible, flagged with a short comment>

<one or two sentences: what goes wrong, and when>

**After** — <one clause naming the change>:

    <5–15 lines, same vocabulary, the delta obvious>

<one or two sentences: the properties gained — name them, e.g. "fails closed",
"single source of truth", "divergence is loud">
```

Rules that make the comparison do the work:

- **Same vocabulary in both blocks.** The reader diffs them by eye; renamed variables destroy
  that. The after block should differ only where the fix is.
- **Comments mark the load-bearing lines** — `// NEW`, `// executes via whatever the CONTRACT
  routes to`. Two or three per block, never running commentary.
- **CAPS for the one contrast that matters**, at most one pair per example (`CONFIG's adapter`
  vs `the CONTRACT's`).
- **≤ 15 lines per block.** Over that, the topic is more than one fix — split it or narrow to
  the half the user asked about.

## Delivery — contrasts go to Monocle, single blocks stay here

**When the output contrasts two states** — before/after, or the two-options variant — **send
it to Monocle as a real file diff** so the user reads it side-by-side. **A single block with
no counterpart is chat output**; a diff viewer adds nothing to an example that contrasts with
nothing, so print it and stop.

Monocle renders *file diffs*, not documents — a markdown artifact full of diff markers shows
raw symbols. So the contrast must be staged as an actual changed file in the repo:

1. Scratch path: `.claude/pseudocode/<topic>.pseudo` (the directory is gitignored-adjacent
   scratch; keep it out of real commits' way).
2. Write the **before** block to the file and commit it locally — this commit exists only to
   give the diff a left-hand side, and step 6 removes it.
3. Overwrite the file with the **after** block, uncommitted. The working-tree change against
   the scratch commit *is* the side-by-side.
4. For the two-options variant: one file per option (`<topic>-reject.pseudo`,
   `<topic>-proceed.pseudo`), each committed with the shared before and overwritten with its
   option, so every option renders as its own before/after diff.
5. `set_review_name` to `pseudocode: <topic>` and tell the user it is staged.
6. **After the user has looked: revert the scratch** — restore the file, then drop the scratch
   commit (`git reset` of the one top commit, verifying first that nothing else landed on the
   branch meanwhile). The lane branch must end byte-identical to how it started.

**Two standing hazards, both non-negotiable:**

- **`set_review_name` silently replaces the repo's open review.** If a real review is staged
  or awaiting a verdict — check `review_status` first — do NOT send pseudocode; print it in
  chat and say why. A plan review clobbered by an illustration is a real loss for a cosmetic
  gain.
- **Never do the commit/reset dance with unrelated uncommitted work in the tree**, and never
  in a lane that is mid-review-round — the tree must stay frozen under an in-flight reviewer.
  When in doubt, chat output is always correct.

## Variants

- **No before-state** (a new capability, not a fix): a single block, plus one line on what is
  newly possible.
- **Two live options** (an open decision): one shared before block, then one block per option,
  each tagged with its consequence — `// fails closed: deposit rejected` vs `// proceeds:
  config drift only warns`. This turns a design question into something the user can pick
  from by eye, which is the strongest use of this skill.
- **A data shape rather than control flow**: show the two shapes as literal example values,
  not code — one row before, one row after, wrong field visible.

## Hard limits

- **One topic per invocation.** A second topic is a second invocation.
- **No file paths, line numbers, or real function signatures** unless the user asks for the
  real code — at which point they want a diff, not this skill.
- **Never present pseudocode as the implementation.** If the plan or code does something
  subtler than the illustration, say so in one line under the block rather than complicating
  the block.
- **Prose stays in the sentences, not the code.** The blocks carry the structure; the two
  sentences carry the meaning. Neither substitutes for the other.

---

**Skill Version**: 1.0.0
**Category**: Reporting

_Companions: [`/go-deeper`](../go-deeper/SKILL.md) — one level down in prose; this skill is
the level below that, reached when structure explains what sentences cannot._
