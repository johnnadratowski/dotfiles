# go-deeper — one level down, with an example

The user read a summary and it did not land. **They want the next level of detail and a
concrete example — not the whole topic re-explained, and not the bottom of it.**

This skill exists because most of the instructions governing these reports push *upward*:
summarise, stay at architecture level, cut mechanism. That is right by default and wrong when
the summary was too thin to act on. `/go-deeper` is the release valve, and it has to be a
controlled one — an unbounded "explain more" produces the wall of text the summarising rules
were written to prevent.

**The failure this prevents is going too deep, not too shallow.** One level with an example
beats four levels without one.

## Invocation

```
/go-deeper <topic>
/go-deeper <topic> — <what specifically is unclear>
```

The topic is named however the user names it. **Resolve it by re-reading the source** — the
plan, the ticket, the file, the review — never from conversation memory. A topic you cannot
resolve is reported as unresolved rather than reconstructed.

If the user said what was unclear, **that phrase is the whole assignment.** Answer it. Do not
re-explain the parts that already landed.

## Step 1 — Locate the level the last answer sat at

Depth is a ladder. Name where the previous answer stood, then step down **exactly one rung**:

| Level | What it sounds like |
| --- | --- |
| 1. Product | What a user or the business experiences |
| 2. Behaviour | What the system does, and under what condition it does the wrong thing |
| 3. Named artifact | The specific table, API route, config value, contract, column, job |
| 4. Mechanism | The comparison, the query, the ordering, the actual line |

Most summaries sit at 1 or 2. So most `/go-deeper` calls land on 2 or 3. **Level 4 is reachable
only by a second `/go-deeper` on the same topic**, never on the first.

**Going down one rung is the constraint that makes this skill safe.** Skipping to 4 because it
is the most complete answer is the failure mode — it is also the wall of text.

## Step 2 — Write it

Per topic, in this order, and nothing else:

1. **The claim in one sentence**, restated at the new level.
2. **A concrete example — mandatory.** The smallest thing that makes it real: two actual
   values that should match and don't, one scenario with names in it, a before/after pair. **An
   explanation with no example has not gone deeper, it has gone longer.** If you cannot produce
   an example, that is a signal the claim is not yet understood well enough to explain — say
   so.
3. **What a fix looks like** — when the topic is a defect or an open decision. Shape, not a
   patch: what changes, where the change belongs, and why there rather than at the symptom.
   One alternative, only if it is genuinely live.
4. **What is still unsettled**, if anything, in one line.

Code is allowed here and was not allowed in the summary — but **the smallest fragment that
carries the point**. A comparison, a signature, two literal values. Never a function body,
never a diff, never a file dump.

## Hard limits

- **One level down. Not two.** The next `/go-deeper` is how the user asks for more.
- **One example per topic, minimum one, maximum two.**
- **Under a screen per topic.** Two topics means two short sections, not one long one.
- **No new topics.** If something adjacent needs saying, one line at the end, flagged as
  adjacent.
- **No re-litigating the summary.** Assume everything already said still stands; add to it.
- **No provenance.** Which agent found it, how it was verified, which round it came from — all
  still cut. Depth is about the subject, not about the investigation.
- **A correction is not depth.** If going deeper reveals the summary was wrong, say that
  plainly in one sentence and give the corrected version — do not narrate the discovery.

## Shape

```
**<topic, in the user's words>** — <the claim at the new level, one sentence>

<the example — values, names, a scenario>

**A fix:** <shape of it; where it belongs; why there>

<one line of what is still open, if anything>
```

## What this skill will NOT do

- Explain the whole topic from the top again.
- Reach level 4 on a first invocation, or paste a function, a diff, or a file.
- Substitute more words for an example.
- Add caveats, alternatives, or adjacent findings the user did not ask about.
- Report its own reading, searching, or verification.

---

**Skill Version**: 1.0.0
**Category**: Reporting

_Companion: [`/catchup`](../catchup/SKILL.md) — the opposite direction; `catchup on <topic>`
gives the description, `go-deeper` gives the level below it._
