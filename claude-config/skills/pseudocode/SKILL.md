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
