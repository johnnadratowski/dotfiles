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
it through Monocle's `send_diff` tool** so the user reads it side-by-side. **A single block
with no counterpart is chat output**; a diff viewer adds nothing to an example that contrasts
with nothing, so print it and stop.

`send_diff` takes the contents directly — nothing on disk is read, no git command runs, so it
is safe with a dirty tree, under an in-flight reviewer, and beside a staged review, none of
which was true of the commit/reset workaround it replaced (removed 2026-08-10; do not
reintroduce it):

1. `set_repo` first if this session has not already bound its lane — the standing Monocle
   rule, unchanged.
2. One call: `send_diff({ name: "pseudocode: <topic>", pairs: [...] })`. One pair for a
   before/after; for the options variant, one pair per option sharing the same `before`, so
   each option renders as its own switchable diff. `label` names the pane (it need not be a
   real file), `lang` is an optional highlight hint, and an empty `before` renders as
   all-new — which is the delivery for the no-before-state variant too, when the user asks to
   see it rendered.
3. Tell the user it is up, under what name. Re-sending the same name/label updates the
   comparison in place, so an amended illustration replaces itself rather than stacking.

**Fallbacks, in order:** no engine running, or `send_diff` unavailable (older Monocle) → chat
output, with one line saying why. Chat is always correct when in doubt — the diff view is a
comfort, not a gate.
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
