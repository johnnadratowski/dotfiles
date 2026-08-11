# whats-next — three things you could do right now

The user has a free moment and wants to spend it well. **Give them exactly three items they
can personally act on, ranked by what each unblocks.** This is the forward-looking sibling of
`/catchup`: catchup says what changed; whats-next says where to spend the next block of time.

## Invocation

```
/whats-next                       # three items, any kind, ranked by unblock value
/whats-next <kind> [<kind> …]     # only these kinds
/whats-next quick                 # only items doable in ~5 minutes
/whats-next 5                     # override the count (still capped at 7)
/whats-next for <TICKET|PR>       # only what gates THAT item (see "For a ticket")
/whats-next by age                # ordering override (see "Orderings")
```

**Kinds** match the 4ME tags plus two practical extras:

| kind | what qualifies |
|---|---|
| `review` | a diff, plan, or PR waiting on the user's eyes |
| `ship` | a create/merge/land action that is one word away |
| `product` | a product or design decision only the user can make |
| `triage` | a finding needing a file-or-park ruling |
| `plan` | a plan gate or scope question |
| `quick` | anything above estimated ≤ ~5 minutes of the user's time |
| `waiting` | items blocked on a third party (Patrick, CI, a vendor) — EXCLUDED by default; this kind opts them in |
| `deep` | ONE meaty design question instead of three unblocks — for an hour, not five minutes |

Kinds compose (`/whats-next review ship` = union). An unknown kind is reported, not guessed.

## For a ticket — `/whats-next for DX-18`

Scope inverts: instead of "what can the user do across the fleet", answer **"what stands
between THIS item and done, and which of those the user can move."** The target can be a
Linear id, a PR number, or a thing named the user's way ("the yield work") — resolve it by
re-reading the source (the issue, its plan doc, the PR, the lane's state), never from memory.

- List **every** live blocker in dependency order — decisions, reviews, third-party waits,
  gated steps — and mark each as **yours** (the user can act) or **not yours** (an agent's, or
  a third party's, with who).
- The count cap does not apply here: completeness beats brevity when the scope is one item.
- End with the single next action that moves it, even when that action is not the user's —
  "nothing is yours until the plan review lands" is a valid and useful answer.

## Orderings

Default is unblock-rank (below). The user may name another; keep the filter, change the sort:

| ordering | sort |
|---|---|
| `by age` | oldest ask first — surfaces what has been waiting longest |
| `by size` | smallest user-effort first — clear the cheap ones |
| `by lane` | grouped by which lane each item frees |

When a non-default ordering is used, still mark the item the default ranking would have put
first (e.g. "← biggest unblock"), so choosing a different lens never hides the priority call.

## Step 1 — Gather live candidates, never from memory

The candidate pool is assembled fresh each invocation:

```bash
cat <main clone>/.claude/needs-input-fleet          # fleet-level asks, kind-tagged
for l in <lanes>; do cat "<lane>/.claude/needs-input"; done
gh pr list --json number,title,isDraft,mergeable    # open PRs; check check-runs per head, not summaries
```

Plus anything the lead is holding in-conversation (a staged PR awaiting "create", a plan gate,
an unanswered ruling). **Verify each candidate is still live before offering it** — an item the
user already answered, or that a lane resolved since, is repaired in the panel first and never
shown. Third-party-blocked items stay out unless `waiting` was asked for: the list is things
*the user* can move, not things the user must wait on.

## Deferrals — "not now" is recorded, not just heard

When the user pushes an offered item off ("later", "not until X", "skip that one"), the
deferral is **written into the source list in the same turn**, not merely remembered:

- **Fleet-level asks**: move the line to the **bottom** of `needs-input-fleet` and append
  `(deferred <date>[ — until <condition>])`. The file's order now IS the priority memory.
- **Lane-owned asks**: tell the owning lane to move it to the bottom of its queue, with the
  same stamp.
- A deferral with a condition ("until its blockers merge") **re-surfaces on its own** when the
  condition is met — offer it again then, and say why it is back.
- Deferred items sink to the bottom of the default ranking but are never hidden: they still
  appear under `by age` (stamped), and `/whats-next for <ticket>` still lists them as blockers.
- **Verification is unconditional**: every offered item is re-checked as still open at ask
  time; a resolved item is removed from the source list, never re-offered.

## Step 2 — Rank

Same priority as catchup's queue, because it answers the same question from the other side:

1. A person or lane is idle right now waiting on this.
2. It gates work otherwise ready to ship.
3. Its cost grows with delay (a decaying review, a drifting branch, a growing conflict).
4. Everything else, most-valuable first.

When two items tie, prefer the one that frees a whole lane over the one that frees a task.

## Step 3 — Present

**Exactly the asked-for count (default 3), numbered, one short block each:**

```
📌 <one line: where the biggest unblock is>

1. **<the action, imperative>** — <what it unblocks / who is idle> <— recommendation clause if any>
2. …
3. …
```

- **Lead with the verb**: "Approve the SRV-24 plan", "Merge #148", "Rule on the SKIP_TS flag" —
  never a topic heading the user has to decode into an action.
- Every ticket/PR reference is a markdown link (tracker URL from the API, never hand-built).
- One to three sentences per item. The detail lives in the plan, the PR body, or the ticket.
- **Fewer real items than asked for? Say so and stop.** Padding with things the user cannot
  act on, or with the lead's own tasks, is the failure this skill exists to avoid.
- If the pool is empty: one line saying the queue is clear, plus the single most useful
  optional thing (e.g. "nothing blocks anyone; #144 is still parked on Patrick").

## What this skill will NOT do

- Offer an item the user already ruled on, or one only an agent can act on.
- Hide an awkward item because it is stale or contentious — staleness is stated, not filtered.
- Turn into a status report. No "what happened" section; that is `/catchup`.
- Exceed the count. Three means three.

---

**Skill Version**: 1.2.0
**Category**: Reporting / Fleet

_Companions: `/catchup` (backward-looking sibling), the 4ME list
(`<main clone>/.claude/needs-input-fleet` — the kind tags this skill filters on), the per-lane
`needs-input` files._
