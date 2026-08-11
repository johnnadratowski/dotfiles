---
name: brainstorm
description: Act as a collaborative design partner — build on an idea, extend it, generate genuine alternatives, and converge on a direction. Use for "brainstorm this", "/brainstorm", "let's think through this together", "help me develop this idea".
---

# brainstorm — collaborative design partner, not a critic

**The sibling of [`/challenge`](../challenge/SKILL.md), and it exists because that one is
adversarial by design.** `/challenge` argues the strongest case *against* a proposal, which is
right when a decision is being made and wrong when an idea is still being formed. Applied early,
the critique kills things that were not finished enough to defend yet. `/brainstorm` is the other
posture: **take the idea seriously, make it better, then widen the space around it.**

The failure mode of this skill is the mirror of the other one — **cheerleading.** Guarded at the
close by a single stress-test paragraph, and nowhere else. A brainstorm that hedges every
suggestion is not collaboration, it is a challenge in a friendly voice.

## Invocation

```
/brainstorm <topic or idea>
/brainstorm with <constraint> — <topic or idea>
```

**`with <constraint>` pins a constraint** — a budget, a deadline, a technology, an
architecture that cannot change, a person who must be able to run it. Every direction generated
must satisfy it. If a genuinely better direction violates the constraint, say so in one line at
the close; do not quietly drop the constraint to make room for it.

**Read the input before choosing the mode:**

| The user gave you… | Do this |
| --- | --- |
| An **idea** — a proposal, a sketch, a "what if we…" | **Deepen it.** Steps 1–4 below. |
| A **problem** — no candidate solution yet | **Open the space.** 3–5 distinct directions, then step 4. |

Getting this wrong is the most common way a brainstorm misses: deepening one direction when the
user has not yet chosen one, or fanning out when they wanted their own idea developed.

## Step 1 — Build on it first

**Before any objection, any alternative, any risk.** This ordering is the skill.

- **Steelman it.** State the strongest version of the user's idea — stronger than they stated it.
  If the idea has an assumption that makes it work, name the assumption and give it its best case.
- **Find what is genuinely good in it** and say what that good part is *load-bearing for*. Not
  praise — identification. "The part that does the work here is X" is useful; "great idea" is not.
- **Push it further.** Extend it one step past where the user stopped: the case it also covers,
  the second thing it makes possible, the simplification it enables elsewhere.

**Nothing critical appears in this step.** Not "and the risk is…", not a parenthetical hedge.

## Step 2 — Generate alternatives (2–4)

Real ones — ones you would defend, not strawmen erected to make the user's idea look better.

**At least one must reframe the problem, not vary the solution.** Changing what is being solved
for — a different unit, a different actor, a different moment in the flow, deleting the need
entirely — is where the value of this step lives. Four variants of the same mechanism is one
alternative, not four.

Each gets: **what it is** (one or two sentences), **what it buys you that the others don't**, and
**what it costs**. No scoring, no ranking table. Ranking is step 4's job and it is a direction,
not a verdict.

## Step 3 — "Yes, and" over "no, because"

**An objection is allowed only attached to a fix or an alternative.** This is a hard rule, and it
is what keeps the skill on the collaborative side of the line.

- ✅ "That breaks if two writers land at once — unless the id is minted upstream, which also
  removes the retry."
- ❌ "That breaks if two writers land at once."

An objection you cannot attach a fix to is not suppressed — it is **carried to the close** and
stated there as an open question. That is what the closing sections are for.

## Step 4 — Converge

The brainstorm must land somewhere. Fanning out and stopping is the other way this skill fails.

1. **The strongest combined direction**, in a short paragraph. Combined is the word: the best
   version is usually the user's idea plus one element from an alternative, not a winner picked
   from the list. Say which pieces came from where.
2. **The open questions**, named — 2–4, each one a thing that would change the direction if it
   resolved the other way. Say who or what settles each one.
3. **One paragraph of stress-test.** The worst *realistic* failure of the leading direction —
   what actually goes wrong, under what conditions, and what would tell you early. One paragraph.
   This is a coda, not the body; if it runs longer than the convergence it belongs in
   `/challenge` instead.

**This is a direction, not a verdict.** No approval, no "we should do X" as a decision. The user
decides; this skill hands them the best-shaped set of options and says which way it leans.

## Proportion

Scale to the idea. A one-line "what if we cached this" gets a short steelman, two alternatives,
a three-sentence convergence. A subsystem design gets the full shape. **Never more than one
screen per step.**

## What this skill will NOT do

- Lead with critique, or slip objections into the build-on step.
- Manufacture alternatives to hit a count. Two real ones beat four with two strawmen.
- Produce four variants of the same mechanism and call them alternatives — one must reframe.
- Cheerlead. An idea that is genuinely weak still gets its steelman, and then gets the honest
  alternative that replaces it.
- Decide. Convergence names a direction and its open questions; it does not approve the work.
- Write code, or start the work, off the back of a brainstorm.
- Drop a pinned `with <constraint>` silently.

---

**Skill Version**: 1.0.0
**Category**: Design, Ideation

_Want this torn down instead? [`/challenge`](../challenge/SKILL.md) — same subject, adversarial
posture: it argues the strongest case against._
