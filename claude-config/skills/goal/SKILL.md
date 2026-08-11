---
name: goal
description: Set, report, or clear the fleet's STANDING GOAL — one objective that outranks everything else the fleet could do, with the dependency chain that reaches it. While a goal is set, reports lead with chain progress, idle lanes are pulled onto the chain, and anything off-goal is parked in 4ME rather than started. Use for "/goal", "set the goal to X", "what's the goal", "clear the goal", "what's blocking the goal".
---

# goal — one objective the whole fleet is pointed at

A fleet with no standing goal does whatever arrived most recently. That is the failure this
skill exists to end: **the newest message is not the most important thing, and a lead with no
written objective cannot tell the difference.** The goal is the tiebreaker, written down where
every surface can read it.

**It is a priority, not a scope.** Work outside the goal is not forbidden — it is *ranked
below the goal*, and it is **parked in writing** rather than carried in conversation.

## The file

`<main clone>/.claude/fleet-goal` — beside the fleet ask list (`needs-input-fleet`), and owned
by the **lead alone**. Lane agents never write it.

```
<the objective, in one line>
<chain link 1>
<chain link 2>
…
```

- **Line 1 is the objective**, and it is one line by contract — every renderer shows that line
  and nothing else. If it needs two lines it is a project, not a goal; name the outcome.
- **Every line after it is the dependency chain**, in order: what must land, and in what
  sequence, for line 1 to be true. One link per line, each naming its ticket/PR and its owner
  where there is one.
- Blank lines and `#` comments are skipped, so the file can carry annotations.
- **Absent file = no goal**, and every surface renders that as *nothing at all*. There is no
  "no goal set" state to display.

## Verbs

### `/goal set <objective>`

1. **Write the objective** as line 1, in the user's words. Do not editorialise it into
   something more impressive or more hedged.
2. **Derive the chain from live state, never from memory** — what is actually open, in which
   lane, at what status. Each link: what it is, who holds it, what it is waiting on.
3. **Confirm the chain back to the user, and stop there.** The chain is a claim about
   dependencies, and a wrong one silently mis-ranks every report that follows. The user
   corrects it or accepts it; only then is the fleet re-pointed.
4. **Re-rank immediately** — the 4ME list, the lanes, and the next report all sort by the
   chain from this turn on. Re-pointing is not a future step.

Setting a goal while one exists **replaces** it. Say what it replaced, in one line.

### `/goal` — report

The objective, then the chain with **live state per link**, then the one thing that would move
it fastest.

```
🎯 <the objective>

1. **<link>** — <state now> · <who holds it> <· what it waits on>
2. …

**Fastest move:** <the single next action, and whose it is>
```

- **Every link's state is read fresh** (lane status, PR, tracker, branch) — a link reported
  from conversation memory is the failure mode of the whole skill.
- A link that is **done** stays visible, marked done. The chain is progress, and a chain that
  deletes its finished links looks like it never moves.
- A link **nobody holds** is stated as unowned. That is usually the fastest move.
- **Off-chain work gets one line at the bottom, in total** — "3 items parked (see 4ME)" — never
  an itemised second report.

### `/goal clear`

Delete the file. Say in one line what the goal was and whether it was reached. Everything
parked in 4ME **stays** in 4ME — clearing the goal un-ranks the parked work, it does not
discard it.

## The rules the goal imposes, while one is set

These are the whole point. A goal that does not change what the lead does is decoration.

- **Reports lead with the chain.** `/catchup`, `/whats-next` and every status update open with
  goal-chain state, then everything else. Off-chain items rank below on-chain ones of equal
  urgency.
- **Idle lanes get pulled onto the chain.** A free lane is offered chain work first. If nothing
  on the chain can be parallelised, say so explicitly rather than filling the lane with
  whatever is next in the backlog.
- **New unrelated work is parked, not started.** It goes to 4ME with its kind tag, and the user
  is told it was parked. Parking is a written act; "I'll remember it" is not parking.
- **THE SINGLE-TURN RULE.** Anything arriving from an agent that is **not addressed within the
  turn it arrives** is written to `needs-input-fleet` in that same turn. Nothing off-goal may
  live only in the conversation — a finding held in chat is invisible to every other surface
  and dies at the next `/clear`, and the goal is exactly what makes something "not now".
- **In-flight unrelated work runs to completion, and gets no successors.** Killing started work
  wastes it; queueing more of it is what actually competes with the goal. When that lane
  finishes, it comes to the chain.
- **A blocked chain does not license drift.** If the chain is fully blocked on a human or a
  third party, say so and *ask* — an unblock request outranks starting off-goal work.

## What this skill will NOT do

- **Invent or expand the objective.** The goal is the user's sentence, not a better one.
- **Report a chain link's state from memory.** Every link is re-read at report time.
- Create tracker issues, start work, or re-assign lanes as a side effect of `set` — it writes
  one file and re-ranks; the actual moves are separate, gated actions.
- Delete, hide, or "clean up" parked work when the goal is set or cleared.
- Print a "no goal" line when no goal exists. Absent is absent, everywhere.

---

**Skill Version**: 1.0.0
**Category**: Fleet / Prioritisation

_Companions: `/catchup` and `/whats-next` (both lead with the chain when a goal is set), the
4ME list (`<main clone>/.claude/needs-input-fleet` — where off-goal work is parked), and the
fleet panel, which carries the objective on its header._
