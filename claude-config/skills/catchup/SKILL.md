# catchup — you stepped away; here is what matters

The user has been away and does not want to read the backlog. **They want two things and
nothing else: what changed, and what they have to decide.**

This skill exists because the failure it fixes is real and repeated: a lead relays every
teammate message as it arrives, the user returns to a wall of text, and the decisions that were
actually waiting on them are buried inside it. **Volume is the defect. Treat length as the thing
being minimised, not the thing being justified.**

## Invocation

```
/catchup                                    # everything since the user's last real message
/catchup on <topic> [and <topic> …]         # only those threads, in full
```

**Bare `/catchup`** covers **since the user's last real message** — not since the last report,
not since some interval.

**`/catchup on <topic>`** narrows to the named threads and changes the output shape: the
five-bullet cap and the one-line-per-bullet limit are **lifted for the named topics only**,
because the user is asking for the description they did not get the first time. Everything
else about the skill still binds — no mechanism, no agent-internal reasoning, no relaying.

Topics are named the way the user names them ("the address issue", "the seeder claim",
"SRV-11") — resolve each by **re-reading the source**, never from conversation memory. A topic
you cannot resolve is reported as unresolved, not guessed at. Output becomes:

```
**<topic, in the user's words>** — <what it is, plainly>
- <what it means for the product; what breaks if it is wrong>
- <its status: whose it is, what it blocks, what it is waiting on>
```

Then the queue, unchanged, filtered to items those topics gate. Skip "What happened" entirely
— a scoped catchup is a description request, not a status sweep.

## Step 1 — Gather live state, do not summarise from memory

Conversation context tells you what happened; it does **not** tell you what is true now. Both go
in the output and they are gathered differently.

```bash
~/.claude/scripts/team-boot.sh status
for l in <lanes>; do cat "<lane>/.claude/needs-input"; done
for l in <lanes>; do head -1 "<lane>/.claude/current-work"; done
gh pr list --json number,title,isDraft,mergeable
```

**Reconcile the panel against reality, and fix it before reporting.** A `needs-input` line for a
decision the user already made is worse than a missing one — it makes the live asks look equally
uncertain. The lead owns those files; a stale entry found here gets rewritten in this step, not
mentioned in the output.

**Anything you assert about repo or code state gets checked against `origin/master`**, not your
tree. A lane behind master reports confident, checkable, wrong answers.

## Step 2 — What happened

**At most five bullets. One line each.** Outcomes only.

- **Group by lane or by thread, not by topic** — the user thinks in terms of who is doing what.
- **State the outcome, never the path to it.** "F2 fixed and merged" — not the mutation proof,
  the review rounds, or who caught what.
- **A correction or a reversal earns a bullet**; process that ended where it started does not.
- **Cut any bullet that does not change what the user does next.** If four agents spent an hour
  converging on a docs paragraph and it landed, that is one bullet or zero, never four.
- **Nothing happened is a valid answer.** Say it in one line and go to step 3.

## Step 3 — The queue

**Numbered, ordered, one to three sentences each.** This is the part the user actually came back
for, so it is the part that gets the words.

**Order by what unblocks the most**, in this priority:

1. Someone is idle or blocked waiting on this answer.
2. It gates work that is otherwise ready to ship.
3. It is a decision with a deadline or a cost that grows.
4. Everything else.

**Each item states, in this order:**

- **What is being decided** — as a choice, not a topic. "Merge on local evidence or wait for CI",
  not "the CI situation".
- **What it unblocks or costs.** Who is standing still, or what gets more expensive.
- **Your recommendation, if you have one**, in a clause. Not a paragraph, and not a survey of
  alternatives.

**Do not include items the user cannot act on.** A thing you are handling is not their task; a
thing an agent is mid-way through is not their task. If the queue is empty, say so — that is a
good report, not an incomplete one.

## Hard limits

These are checkable, which is the point:

- **≤ 5 bullets** in "what happened". Over five means you are relaying, not summarising.
- **One line per bullet.** No sub-bullets.
- **No mechanism above the queue** — no file paths, no line numbers, no function names, no
  commands, no agent-internal reasoning. If the user wants the detail they will ask, and the
  detail lives in the plan, the ticket, or the commit body where it can be checked.
- **No preamble.** No "here's a summary of what happened while you were away".
- **The whole thing fits on one screen.** If it does not, the "what happened" section is too long
  — never the queue.

## Shape

```
📌 <one line: the single most important thing that changed>

**What happened**
- **<lane or thread>** — <outcome, one line>
- …

**Your queue**
1. **<the decision>** — <what it unblocks; recommendation if any>
2. …
```

## What this skill will NOT do

- Relay teammate messages, quote them, or attribute findings to agents by name unless the
  attribution changes the user's decision.
- Report its own verification work, gates run, or checks performed.
- Include a "next steps" section — the queue *is* the next steps.
- Pad the queue with items the user cannot act on, or drop one because it is awkward.

---

**Skill Version**: 1.0.0
**Category**: Reporting / Fleet

_Companions: `.claude/scripts/fleet-status.sh` (the lead's live view), the per-lane
`needs-input` files (the panel this skill both reads and repairs)._
