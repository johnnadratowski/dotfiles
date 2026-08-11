# Review lessons — technique and machinery

Lessons about **how to review** and about the agent machinery itself: guards that fail open,
verifications that cannot fail, config knobs that are only real where they are loaded, and
the discipline of not retracting a finding on assertion alone.

Kept in dotfiles rather than a product repo because none of it is about any particular
product — it applies to every codebase this fleet works in. The product-specific counterpart
stays with its product (e.g. `.claude/docs/review-lessons.md` in goals-onchain).

Each entry: what was missed, why it was missable, and the check that would have caught it.

## 2026-07-29 — Deleting an abstraction strands its READERS, and they fail silently

Removing the `base-*` skills deleted the `WORKFLOW_BASE_BRANCH` knob but not the **three
places that read it**, and all three survived a review and four commits:

- `unregister-agent.sh`'s session-end "unshipped work" warning resolved `base` to the empty
  string, so the whole warning **never fired again** — a guard that looks present and does
  nothing.
- `register-agent.sh` kept a block injecting role context that named four deleted skills, so
  had the knob ever been set again it would have **instructed every agent to run commands
  that do not exist**.
- `.husky/pre-push` computed its push range as `git merge-base "origin/${WORKFLOW_BASE_BRANCH:-}"`.
  `origin/` is not a ref, so the range **silently degraded to `HEAD~1..HEAD`** and every
  drift guard scoped by it examined one commit. Measured: 1 ranged, 7 actual. **This one was
  the worst, because a comment right above it explained the degraded path as intentional**
  ("in solo mode ... correct: no shared base to scope against") — accurate when the value
  could be empty by choice, false once it was always empty.

Two more of the same shape, different inputs: `statusline-fleet.sh` counted "⚠ N errored"
from a marker directory whose only writer had been deleted, so it could render nothing but 0;
and `.husky/pre-push` kept a `run_hook_suite` row for a suite that had moved out of the repo.
That function *deliberately* skips a missing file (so an absent suite can't break `git push`),
which turned the row into a **permanently green guard**. `_config.test.sh` fared better only
because it asserted a count out loud — it went red and got noticed.

**The rule:** when you delete a knob, a script, or a state directory, grep for its
**readers**, not its definition, and classify each one by failure direction. A reader of a
now-absent thing either fails OPEN (a gate that stops gating — the dangerous one) or degrades
loudly (fine). Prefer an assertion that *counts* over one that *checks presence*, because a
presence check on a deleted file is indistinguishable from success. And: a `[ -f x ] && run x`
skip is correct for robustness and lethal for coverage — if you rely on a suite, assert it
exists.

Corollary for **kept** components: when the last reader of some state disappears, the writer
becomes write-only state, which is worse than no state — it reads as a live signal to the
next person. Either delete it or document the consumer that actually justifies it. (The busy
marker was kept for exactly one surviving reason: the idle gate on `down`. The Monocle
hold marker had none left, and went.)

## 2026-07-26 — A knob in a config file is only real at the sites that LOAD that file

A busy-marker staleness window was widened from 5 to 30 minutes across six readers, and the
new `WORKFLOW_BUSY_STALE_MIN` knob was documented in `workflow.config` as *"read by
`fleet_busy` and every inline fallback."* It was not. `_config.sh` never added it to its
`export` list, and three of the six readers (`agent-send.sh`, `inbox-watcher.sh`,
`statusline-fleet.sh`) never source `_config.sh` at all. Setting it would have moved two
readers and left four on the literal default — the exact split the commit body claimed to
have rejected. Nothing was broken only because the configured value happened to equal the
hardcoded fallback.

The same commit left **four** stale "5 min" claims in the since-deleted `inter-agent-comms.md`,
including the marker's own definition row — the canonical description of the artifact being
re-specified.

**Rules.** When a constant becomes a knob: (1) **enumerate every reader** and prove the value
reaches each — grep the identifier, then check whether that file loads the config at all, and
include the `.local` sibling: a per-machine override file with the same loader splits exactly
like the tracked one, and house style points engineers straight at it; (2) a knob only some
readers can see is worse than a hardcoded literal, because it *looks* configurable; (3) pin it
with a test that reads all sites and asserts they agree, and **verify the test goes red on a
deliberate split** — a threshold change with no mutation-proof has no coverage regardless of how
many suites pass.

(4) **Scope a guard by FUNCTION or INVARIANT, never by enumeration.** The same defect recurred
three times in three rounds of one change, each time as a list that was true when written:

- *readers* — "read by `fleet_busy` and every inline fallback" (three readers couldn't see it);
- *loaders* — "only agent-fanout and fleet-layout source the config" (a third loader existed);
- *categories* — a deny row scoped to "any skill or agent definition", while most of this repo's
  gates live in `.husky/pre-push`, `ci.yml`, `commitlint.config.cjs` and hook wiring — none of
  which is either, so all four escaped the rule and the adjacent DENY-WINS prose promised a
  resolution the table could not deliver.

An enumeration is a snapshot of the world; a guard must survive the world changing. Prefer "no
config file carries this value" (a testable ban) over "these two scripts load it", and "anything
that waives a gate" over "any skill that waives a gate". When you catch yourself writing *only*,
*every*, or a comma-separated list inside a rule, that is the smell.

(5) **Grep the OLD LITERAL everywhere — code comments included — not just the expressions you
edited.** A first fix round here rewrote four stale "5 min" claims in the docs and still missed
a fifth **seven lines above a line the same commit changed**, in a comment block the author had
just walked past. The tempting diagnosis ("I grepped code and not prose") was wrong: it *was*
code. The real failure mode is that the sites you edit are precisely the ones whose surrounding
prose you stop reading — familiarity reads as verification. Grep the literal, then read what
you already "know".

## 2026-07-24 — A comment that contradicts its adjacent code is a defect in one of them; read both

Three instances surfaced in a single day, each hiding a real bug behind text that read as correct:

- `monocle-review.sh` — a comment stated live issues have no repo file and are *"skipped with a
  warning"*; the code three lines below ran `_die`. Effect: `/monocle-review plan <ID>` was
  impossible for **every** ticket created after the tracker migration.
- `_config.test.sh` — asserted a variable (`WORKFLOW_TODO_AGENT`) the implementation had deleted
  in an earlier commit. Effect: the suite ran in the pre-push hook and had been red for days,
  blocking every push while being mistaken for a lint/drift failure.
- `statusline-todo.sh` — the header promised "silent when nothing is in-progress"; the code
  printed a placeholder. Here **the code was right and the comment was stale** — an agent
  "fixed" the code and removed intended behavior.

**The rule.** When reviewing, treat a comment as an assertion to verify, not as context to
absorb — especially words like *never*, *always*, *skipped*, *non-fatal*, *cannot happen*. Where
comment and code disagree, **say so and ask which is authoritative**; do not assume the code is
the bug. The three highest-yield spots: (1) error paths described as non-fatal, (2) tests
asserting a symbol the implementation may have dropped, (3) headers describing behavior that
drifted with a later refactor.

**Why it pays.** Each of these was invisible to the happy path and to inspection of the diff that
introduced it — the contradiction only existed *across* a change boundary, so only someone
reading both sides at once could see it.

## 2026-07-21 — A doc obligation naming a specific registry is discharged only in that registry

A doc-sync phase owed a secret both "a deployment-gcp.md inventory row **+ rotation
entry**". The inventory row landed — with a thorough rotation-relevant *caveat* in its
notes — but the **Secret rotation table** gained no row, and the phase read as done. An
operator working the rotation table (the artifact that drives the cadence) would never
rotate the env's most-privileged DB credential. A note elsewhere that talks *about*
rotation is not a rotation entry.

**Rule:** when an obligation names a specific registry/table/index (rotation table,
env-var inventory, integration-notes heading, TODO index), verify discharge **in that
exact artifact** — row present, correctly keyed, mechanism stated. Prose near a related
row does not substitute, however complete it reads.

## 2026-07-20 — `typeof x === 'object'` is not a map check — a fail-closed guard that uses it fails OPEN on arrays

A fail-CLOSED config loader (SRV-jn-f4-001) meant to throw on a shapeless `tasks.yaml` guarded
with `!config.tasks || typeof config.tasks !== 'object'`. But `typeof [] === 'object'` (and
`typeof new Date() === 'object'`), so a **list-form** file — `tasks:\n  - pollAchTransfers`, the
classic map-vs-list authoring mistake — parses to `{ tasks: [...] }`, **passes the guard**, and
logs `Loaded tasks config`. Downstream `.filter(([, t]) => t.enabled)` is undefined on every
array entry → empty configured-name set → the stale-scheduler cleanup deregisters *every*
scheduler while the worker stays healthy. That is byte-for-byte the outage the guard existed to
close; it fails open on the input a human is most likely to typo.

**Rule:** when reviewing a guard whose whole job is to reject a shape, **stub each input to its
failure value** (the destroy-guard discipline, applied to validators): feed it an array, a scalar,
`null`, a Date — not just the one happy-path counterexample the author tested. `typeof x ===
'object'` admits arrays **and** Dates/Buffers, and `!Array.isArray(x)` does **not** exclude the
Date (js-yaml parses a bare `2026-01-01` to a `Date`). The check that actually means "plain map"
is a **prototype** test — `const p = Object.getPrototypeOf(x); p === Object.prototype || p ===
null` — not `!Array.isArray`. And a loader that iterates entries must also validate each **entry's**
shape (a scalar entry has no `.enabled`/`.handler` and gets silently skipped). A fail-closed guard
with a hole is worse than none — it advertises safety it doesn't have.

**Meta (the fix's first attempt was itself incomplete).** The first fix for this exact finding
shipped `!Array.isArray(x)` — which closes the array shape but still admits `Date` (js-yaml parses
a bare `tasks: 2023-01-01` to a Date) and `Buffer`/`Uint8Array` (`!!binary`), both `typeof
=== 'object'`, both non-array → a zero-entry "map" and the same silent scheduler wipe. The next
review round caught it. Lesson within the lesson: when the failure class is "a type that lies about
being a map," enumerate **every** builtin the parser can emit (array, Date, typed array), or assert
the positive shape (prototype) rather than blacklisting shapes one at a time.

## 2026-07-11 — A fix that RELOCATES a value must be re-audited against every consumer of the new location

A plan hardcoded a tmux session name, and the fix moved that value **four times** — each move
breaking a *different* consumer that the previous round's audit had cleared, and each defect
living inside the previous round's fix (the half-fix pattern, four rounds running):

1. **boot-local variable** → the cross-process consumer never saw it. `name-windows` runs from
   every agent's SessionStart as a *separate process* that never executes boot's resolution, so
   canonical ordering silently no-op'd (`_order_windows` opens with `_session_exists || return 0`).
2. **committed `workflow.config`** → every engineer but the initializer inherited a stale value.
   A machine-local value in a shared file is **worse than absent**: it looks configured.
3. **main clone's gitignored `.local`** → the value never reached the worktrees. A worktree's
   checkout holds only *tracked* files, and `_config.sh` resolves its root to the **worktree**,
   so the agents — the entire point — read nothing.
4. **`WORKFLOW_MAIN_PATH` as the seed's source** → that variable defaults to the *caller's own*
   toplevel, so an agent seeding from a `.local`-less worktree would silently seed nothing.

**Rule:** when a fix changes WHERE a value lives, re-enumerate every reader of the new location —
in other processes, other working trees, other engineers' clones — and ask whether the value is
present there *at all*. A relocation is not a fix until its new location is proven reachable by
every consumer the old one served. **Corollary:** the owning test row must exercise the real
WRITER. A row that hand-builds the state tests the reader and passes with the writer broken —
which is why a writer that lives in skill *prose* (unreachable from a shell suite) has to be
extracted into a script before its behavior can be pinned at all.

## 2026-07-10 — A helper's return status is a contract; pin the success path deliberately

A plan's helper sketch made an unguarded `send-keys` the function's last command, so the
helper's return value silently became that keystroke's exit status — a failure would have
tainted the caller's exit code with **no report line**, contradicting the same plan's
"every failure is reported" pin. Caught at the plan gate (before any code existed) by
walking the sketch's return paths against its pinned decisions.

**Rule:** a helper whose callers branch on its status owns EVERY return path — the
success path's return must be deliberate (guard the last command, or explicitly discard
its status), and any status that taints a caller must be paired with a report line.
Review check: for each helper a plan sketches, enumerate what its LAST command's failure
returns and whether the pinned decisions account for it.

## 2026-07-10 — An empty enumeration vacuously satisfies a destructive verb's success contract

A fleet-stop verb defined success as "exit 0 iff every enumerated entry is verified
stopped". A reviewer stubbed the enumeration's inputs and found that a manifest which
parses but yields ZERO entries satisfies the contract vacuously — exit 0, "fleet is
down", whole fleet still running — and the repo had already lived the mechanism that
produces that state (a rewriting verb silently dropping the per-entry fields the
enumeration keys on).

**Rule:** an exit contract quantified over an enumerated set is vacuously true of the
empty set — a destructive/deconstructive verb must pin **non-empty enumeration as a
guard input** (refuse loudly, never "nothing matched, proceed"). Review check: for
every "success = ∀ entries …" contract, ask what the verb does when the enumeration
legitimately parses to zero, and whether a test row pins that answer.

## 2026-07-10 — Structural-count calibration: executable strings are not comments

A plan tightened a "the only kill-session in the file" grep by comment-stripping the
source first — and specified "count == 1, unchanged". Two reviewers independently found
the calibrated count at the pin was 2: a hand-rolled **dry-run `printf 'tmux
kill-session …'` is executable source**, not a comment, so the check was born red on
correct code (violating "provably able to pass"), inviting a silent recalibration to 2
that would have let a rogue second invocation through. Fix: route the dry-run print
through the verb-generic `_rw` printf so the count is genuinely 1.

**Rule:** when a structural count asserts "exactly N invocations", calibrate against the
actual source AND define the counting method — comment-stripping alone does not exclude
executable strings (dry-run printfs, log messages, heredocs) that mention the verb.
Prefer making the code shape match the check (one generic dry-run printer) over widening
the expected count.

## 2026-07-10 — An exemption near a verification is itself a new guard input

A kill verb earned its success claim by post-kill observation ("a pane we attempted to
kill must be observed dead"), then a later revision added a sanctioned-survivor
exemption model ("skip-marked panes are never FAILED"). Two reviewers, alternating
rounds, found the composition reopened the exact masked-kill false-success the
observation existed to close: the exemption's only bite was on the verification path
(everywhere else it was vacuous), the marker is **mutable mid-run** (a
time-of-check/time-of-use window), and the pre-kill read of the marker used a helper
whose read-failure was indistinguishable from "unset" — killing a user-protected pane
on a flaked query.

**Rule:** scope exemptions to probes and attribution, **never to the observation that
earns a success claim** — a pane the run attempted to kill must be observed dead,
exempt or not. Any pane-level read that gates a kill must distinguish "unset" from
"unreadable" (exit status as the oracle, fail-closed on unknown), and the exemption
needs an owning test that reddens when an exemption branch appears in the verification
alone (set the exempting state MID-RUN, after the pre-kill check).

## 2026-07-10 — A skill that rewrites a shared file is a schema consumer

A plan extended a shared state file's schema (new per-entry fields consumed by a new
boot verb) and updated only the READERS. A reviewer found that a companion skill's
`--reconcile` verb rebuilds the whole file against its documented schema — it would have
silently dropped the new fields on its first run (disabling the new feature with no
error, exit 0) and its prune path stood ready to delete entries a user decision required
kept. The plan had hedged with "update the other skills *if they enumerate the fields*"
— but the rewriter never reads the new fields; it destroys them by omission.

**Rule:** when extending a shared file's schema, audit every WRITER's
rewrite/merge/prune semantics, not just the readers — anything that serializes the file
back owns the whole schema. Prefer a generic preserve rule ("carry through every field
you don't own from a fresher source") over enumerating today's fields; the enumerated
form re-arms the same gun for the next extension. Review check: for each file a change
extends, list every code path that WRITES it and ask what happens to the new fields on
each one's next run.

## 2026-07-10 — Verification commands must be provably able to fail

A plan's only automated completeness check for a repo-wide reference sweep was a grep
whose pattern used `(`/`|` without `-E` — BRE treats them as literals, so the command
returned zero hits before, during, and after the work. The plan would have reported the
sweep verified while a forgotten site landed silently. The same review found the stated
expectation ("zero hits") was wrong even for the corrected pattern: deliberate residuals
(archived records, historical mentions) exist, so "zero" could only pass if the pattern
was broken.

**Rule:** a verification command is trusted only after it has been **observed red** on a
state it must reject — run it before the work (or against a deliberately-broken state)
and watch it fail. Specify the pass condition as an explicit expected set, not "zero
hits"/"no output" (absence-shaped conditions are exactly the ones a broken matcher
fakes). Review check: for every "verify with `<command>`" step in a plan, ask what input
makes it fail, and whether the plan ever exercises that input.

## 2026-07-10 — A declared isolation contract is verified by the isolated party

A reviewer definition carried `isolation: worktree` plus instructions that begin with
`git checkout --detach` and end with `git clean -fd`. Review flagged the frontmatter key
as possibly unbound. The premise was refuted — the key is documented
(code.claude.com/docs/en/sub-agents.md, "Supported frontmatter fields") and an empirical
probe showed a spawned reviewer's toplevel in `.claude/worktrees/` — but the remedy
survived for a reason neither side held: the worktree **cwd enforcement is
version-gated** (Claude Code ≥ 2.1.203; before that, a command could run in the main
checkout), and a long-running fleet carries heterogeneous binaries, so the SPAWNER's
version is silently part of the safety contract.

**Rule:** when a definition's destructive instructions rely on an environment contract
(isolation worktree, sandbox, container), the definition itself must verify the contract
bound — fail-closed, before the first mutation — rather than trust the declaration.
And when refuting a finding's premise, re-derive its remedy independently: a wrong
premise can still name a right fix.

## 2026-07-10 — An unquoted shell split is a glob, not just a split

A registry parser word-split untrusted file content with `for w in $line`. Splitting was
the intent, but unquoted expansion ALSO pathname-expands: a corrupted line containing
`%*` matched files in the invoking CWD and emitted **filenames** as agent tokens
(repro: a file named `%3-decoy` appeared in the token list — filesystem contents, which
can pass a downstream shape check). Found by the reviewer subagent's first dry-run.

**Rule:** when shell word-splits data (as opposed to arguments), require `set -f` around
the split (or array-based splitting) — check every `for x in $var` over untrusted
content for glob metacharacter behavior, and pin it with a decoy-file regression test.
Analyze the failure *direction* too: here expansion could only add refuse-more noise,
but that's a property to prove, not assume.

## 2026-07-09 — A fix-round diff is a first-class diff (the half-fix pattern)

A fix produced by review round N re-introduced the same failure class it was fixing —
twice in one TODO: an interior-whitespace strip that merged two registry tokens
(`%3 %7` → `%3%7`), and a heartbeat moved to gate boundaries that still let a live lock
holder be reclaimed mid-gate. Both were caught only because the *fix itself* was
re-audited as a fresh diff in the next round.

**Rule:** never wave a fix commit through on the strength of the round that requested it.
Audit the fix diff with the same rigor as the original: does the fix generalize across
every instance of the class (not just the reported one), and does the mechanism of the
fix introduce a new instance of the same class? Require a mutation-proven test where the
fix guards something (delete the guard → exactly its owning test reddens).

## 2026-07-09 — Destroy-guard reviews: stub each input to its failure value

A teardown guard read several inputs (a registry file, a tmux pane list, an exit status).
Reasoning over the guard's *body* looked sound, but one input failing — an unreadable
registry file — silently produced an empty token list, and the guard **failed open**
(proceeded to destroy). Happy-path reasoning cannot see this: the body is correct for
every value the reviewer imagined; the failure lives in the value an *input* produces
when IT fails.

**Rule:** reviewing any guard on a destructive operation, enumerate the guard's inputs
and stub EACH one to its failure value (unreadable file, empty command output, nonzero
exit, missing directory, garbage content) — then ask what the guard decides. Every input
must fail **closed** (refuse), and the test suite must pin each stubbed case, not just
mutate the guard body.

## 2026-07-09 — Never retract a finding on assertion alone

A reviewer retracted a *correct* finding because the author confidently asserted the
opposite; separately, an agent confabulated its own history ("the flag file was never
created" when it had been). Authority and confidence are not evidence, and agents
(including you) assert past their evidence under pressure.

**Rule:** a finding is withdrawn only against **checkable evidence** — a file read, a
command output, a log line (e.g. `register-agent.log`'s `send-selfheal` timestamps
settled exactly such a dispute). If the author disputes a finding, ask for the artifact
that would settle it, or fetch it yourself. The same bar applies to your own claims:
cite the evidence you actually saw, and say "unverified" when you didn't.

## 2026-07-28 — a guard whose failure is unreachable is the vacuity trap wearing a disguise

**What happened.** A new `UserPromptSubmit` hook shipped with five checks that read like
guards. Mutation-testing each one — delete it, re-run the suite — showed **two could not be
made to fail**:

- `[ -f "$mailbox/$fname" ] && exit 0` ("is the message still live?") was subsumed by the
  emptiness check that followed it: a live file is *itself* one of the `*.txt` in that
  mailbox, so the mailbox is never empty when the file exists.
- `[ -n "$self_name" ] || exit 0` ("did we resolve ourselves?") was subsumed by the next
  line's `[ "$recipient" = "$self_name" ]`: the regex guarantees `$recipient` is non-empty,
  so an empty `$self_name` can never match.

Both were deleted; the reasoning that made them redundant moved into comments so the next
reader doesn't re-add them. Two genuinely-unfalsifiable lines remained (fast-path early
exits) and were **labelled as cost optimisations, not guards**.

**Why this is the same defect as the SRV-17 twin guard, not a new one.** That one was a
guard that couldn't fail *for the case it existed for*. This one is a guard that can't fail
*at all*. Both look protective, both are green forever, and both mislead the next reader into
thinking a condition is checked when nothing checks it — because the check is unreachable.

**Rules.**

1. **Mutation-test every guard, one at a time**, and require the suite to red. "All tests
   pass" proves the guards are *consistent* with the tests; only a failed mutation proves a
   guard is *load-bearing*. Rule 5 of the SRV-17 lessons says watch a guard fail — this
   extends it: watch it fail *in isolation*, or you cannot tell it apart from its neighbour.
2. **A surviving mutant is a finding, not a gap in the tests.** The instinct is to write a
   test that kills it. Ask first whether the branch can be reached at all — usually the
   honest fix is to delete it, because no test *can* exist.
3. **Keep an unfalsifiable line only when it changes cost, never outcome** — and say so in a
   comment, so it is not mistaken for a correctness guard and so nobody wastes a cycle
   trying to test it.
4. **Prefer the one predicate that actually decides.** Collapsing "is it live?" + "is
   anything queued?" into "is the mailbox empty?" made every remaining branch falsifiable and
   the intent easier to state.

## 2026-07-28 — read the log before naming a mechanism

**What happened.** A message pointer arrived four times. It was reported to the user as an
unbounded loop — the watcher and the Stop-drain "handing a dead pointer back and forth" — and
a two-line fix in both was proposed. `~/.claude/inbox-watcher.log` then showed the whole
truth in four timestamped lines: three re-nudges and the cap, all inside 82 minutes, and
nothing for the 16 hours since. The count was `1 + WORKFLOW_MAX_REDELIVER`, exactly as
designed. Both components already had the existence checks being proposed, and neither could
emit a pointer to a deleted file — both enumerate real directories. The real defect was a
different one (buffered keystrokes replaying after consumption) and needed a fix in a third
place neither component owns.

**Rule.** Before naming a mechanism in a user-facing claim — *especially* "this loops
forever" — read the artifact that records it. A repeat count is not a loop; a bounded retry
with a cap looks identical from inside a single turn and is distinguished only by timestamps.
Check whether the component you're about to fix already does the thing you're proposing:
here, both did. The cost of guessing was a wrong diagnosis delivered with confidence and a
fix aimed at two files that needed no change.

## 2026-07-31 — a rename must reach every reader, and a derived resolver makes every caller cwd-sensitive

**A rename is applied to every reader that string-matches the old value, not just the one that
ranks on it.** `fleet_resolve_role` was changed to return `team-lead` instead of `coordinator`.
`_window_rank` was updated with it; `_order_windows`' lead-demotion guard, which tested
`$4=="coordinator"` in an awk one-liner, was not — so a protective early-return became
unreachable in the same commit that introduced the new spelling. Grep the OLD value across the
whole corpus before calling a rename done; the readers that break are the ones that compare it
as a string rather than branch on it structurally.

**A resolver that derives from the caller's cwd makes every consumer cwd-sensitive, and a
destructive verb must refuse an empty enumeration rather than treat it as success.** Replacing a
hardcoded lanes path with a derivation from the git common dir removed a product name from
portable machinery — and made `LANES_DIR` answer for whatever repo the caller happened to be
standing in. From an unrelated clone it resolved to a directory that does not exist, so
`"$LANES_DIR"/*/` expanded to the literal glob, every verb enumerated nothing, and `down`
reported success having stopped nothing while the fleet was up. Resolved is not the same as
exists; an empty enumeration vacuously satisfies a destructive verb's success contract.

**Corollaries this round, each caught by mutation rather than by reading:**

- A test that stubs the function under test has no coverage of it. `alive_in` — the gate on
  every kill — was blanket-overridden by both harnesses, so its body could be replaced with
  `return 1` with the suite still green.
- A snapshot compared to itself pins nothing. The registry's identity token was written and
  read back within one run, so a uniformly WRONG token compared equal and passed.
- `grep -A | grep -vc B` prints 0 when the first grep matches nothing, so it passes on a file
  that no longer contains the thing it was protecting.
- A guard that resolves its subject from the AMBIENT process tree cannot be tested from inside
  a session that satisfies it. The lane-guard row meant to prove the no-name early return passed
  through an unrelated fail-open instead — and, because the fixture used real lane names, went
  RED ON CORRECT CODE for any agent carrying one.

## 2026-07-31 — a probe is a moment, and `cmd | head; echo $?` reads the wrong exit

**A point-in-time probe reported as a settled fact.** An agent ran the monocle liveness probe,
got "not running for this repo", and reported that as what the human's options WERE. By the time
it was read, the human had opened Monocle and reviewed there — the probe had flipped, and the
report sent him looking for something he had just done. The probe was not lying; liveness is
simply a fact with a short shelf life. **Re-check at the moment you offer, and hedge a cached
answer as cached.** The same applies to any "X is unavailable" claim: an environment claim needs
the evidence standard of a code claim, and the authoritative check is the one that calls the
thing, not the one that reads a list or a cached status.

**`cmd | head -5; echo "exit=$?"` reports head's status, not the command's.** `$?` after a
pipeline is the LAST element's exit code, so a failing command whose output is piped into `head`
reads as exit 0 — a failed verification that looks passed. In the case that surfaced it the text
happened to carry the real answer, so nothing broke; the pattern is the hazard. Use
`${PIPESTATUS[0]}`, or run the command unpiped when its exit code is the thing being asserted.
Same family as the earlier `grep -A | grep -vc B` row that printed 0 on no matches.

**Confirmed twice more in one session, 2026-08-11, and the second time it cost something.** A
`git push ... | tail -5; echo "PUSH_EXIT=$?"` recorded `PUSH_EXIT=0` for a push that had been
**rejected**; the agent went on to report the branch as published. The generalisation is worth
stating flatly, because each costume gets rediscovered separately: **a pipeline's exit code
belongs to the LAST command in it.** So does a compound block's — `{ a; b; echo done; }` exits
with the `echo` — and so does a background task's, whose "exit 0" belongs to whatever ran last
inside it, not to the thing you were watching. The two fixes are `set -o pipefail` at the top of
any script whose pipelines are assertions, or `cmd > file; rc=$?` when you want the status of one
specific command. Prefer the second when the exit code IS the finding: it leaves nothing to
reason about.

## 2026-07-31 — a retraction that lives only in the chat is not a retraction

**A commit was reverted on evidence that existed nowhere in the repo.** `aad6314e` landed a
claim ("the panel status line needs a project-scope declaration"); the claim was disproved and
retracted in conversation an hour later, but nothing durable recorded that. `f3908287` then
removed the key again — correctly, on the *real* root cause found later — while its body still
argued from the retracted premise. A reviewer reading only the repo saw a commit reverting its
grandparent and citing the very measurement its grandparent had disproved, with no record of
anything superseding it. It could not tell a corrected mistake from a regression, and was right
to flag it.

**If a landed claim turns out to be wrong, the correction has to land somewhere a reader will
hit** — the next commit body, the doc it misled, or this file. The rule the repo already states
for adjacent findings ("either way the finding lands somewhere durable") applies with more force
to *retractions*, because the wrong version is already published and will be read again.

**Related, same day: an instruction that re-opens the bug the same series just fixed.** One
commit taught a parser to stop at the first non-id line in `.claude/current-work`; two commits
later a doc told agents to record reviewer ids in that same file — in the file's TAB-separated
shape, with no format specified. `rev-1<TAB>agent_01H8xyzQ` parses as an id and renders into the
status bar. **When you add a writer to a file whose reader you just hardened, write the reader's
rule into the instruction** — here, the `#` prefix the parser skips unconditionally.

## 2026-07-31 — an instruction can only be followed by an agent that knows who to answer

**A reviewer cannot address a spawner it was never told about.** The verdict contract said
"SendMessage the agent that spawned you (`team-lead` unless told otherwise)" while the spawn
contract made a lane agent the usual spawner — and a subagent knows the name it was *given*,
never the name of whoever created it. Both of feature-2's FEAT-9 reviewers therefore reported
"team-lead is the only addressable name this tool accepts for me" and asked the lead to relay,
while the author blocked on the verdict sat idle. Two independent findings landed in the wrong
inbox before anyone noticed.

**When you change who the usual caller is, the default recipient is part of the change** — and
if the callee needs an identity to route to, the caller has to *pass* it. Enumerating the
happy-path caller is not enough; ask what the callee can actually see.

**Same shape, same day, three more times.** `## Non-repo obligations` was scoped to `/open-pr`,
so the no-PR ship path and `/open-pr --update` never read it. The planner writes that section
but its handoff never mentioned it, so the implementer never learned it existed. And the only
parser for `.claude/current-work` had its semantics changed with no test at all — under which
a file with **no trailing newline** silently yielded zero ids, because `while read` returns
non-zero at EOF-without-newline before the loop body runs. All four are the same failure:
**an obligation stated in one place, and unreachable from where it has to fire.**

## 2026-07-31 — a new required input is only real at the sites that SUPPLY it

**A change that makes something required is not finished when the consumer reads it. It is
finished when every supplier provides it.** FEAT-9 made `PONDER_URL` a required env var. The
code was correct and the reviewer still found two blockers, because the *suppliers* were not
part of the change's mental model:

- the **Docker build context** (`.dockerignore` excluded the file the new import compiles
  against — the failure is `TS2307` inside the image, not a missing-context error), and
- the **deploy template** (terraform injected the var only when non-empty, so the apply
  succeeded and the server died in envalid on the next roll).

Then the *fix* for the terraform half was itself half-done: the mechanism changed but three
`terraform.tfvars.example` files and four "two-phase" comments still taught the old ordering
— including the two comments an operator reads *at the moment they copy the value*.

**The check:** for anything newly required, enumerate every place a value enters the system —
build context, deploy template, example/tfvars files, local `.env`, test harness, CI — and
confirm each one supplies it. `git grep` the variable name and read every hit, rather than
patching the sites a reviewer happened to name.

**Corollary — verify by executing, not by inspecting.** The `.dockerignore` fix looked
obviously correct and was. Actually running `docker build` proved it *and* revealed the image
had been unbuildable for five unrelated pre-existing reasons (corepack absent from
node:25-slim, a `prepare` script hard-failing on absent `.git`, `**/build` swallowing
`server/scripts/build/` tooling source, an excluded `vaults.json`, `pnpm deploy` missing
`--legacy`) — every one already solved correctly in the sibling `subgraph/Dockerfile`. **A
build no CI job runs is a build that is already broken.** If a fix targets an artifact nothing
exercises, exercising it is part of the fix.

**And: a comment that sounds like a reason may not be one.** The same round shipped
"suppressing these triggers is safe because a test has no subscribers" — plausible, and wrong.
`DISABLE TRIGGER USER` is table- and window-wide; the actual safety rested on a pinned start
block keeping the table empty. A confident wrong rationale is worse than none, because it
stops the next reader from checking.

## 2026-07-20 — a mocked seam must reproduce the dependency's ACTUAL failure surface

**Before mocking a dependency's failure mode, read its error path.** Reproduce the failure
surface it actually exhibits — rejection, error-return, or swallowed-and-resolved. A guard test
that passes against a failure shape the real dependency cannot produce is theatre: it is green
because the mock is wrong, and it will stay green through the outage it claims to cover.
Reviewing one, trace the real dependency's catch blocks before trusting the pin.

**Corollary — an exactly-once or durable-dedupe consumer needs a delivery SIGNAL from its
egress, not the absence of an exception.** "It didn't throw" is not "it arrived."

**Second corollary, the same class one level down: for HTTP egress, delivery is
`response.ok`, never a resolved promise.** `fetch` resolves on 4xx and 5xx, so a delivery
signal that only maps rejections reads a 503 outage, a 429, or a revoked webhook as "sent".
Pin the resolve-shape failure (`{ok: false}`) alongside the rejection-shape one.

_The worked example — a mock that rejected where the real client swallowed and resolved,
permanently suppressing a critical page — is in the product repo's own review-lessons file,
which keeps the subsystem detail. Only the transferable rule lives here._

## 2026-08-02 — `git rev-parse` echoes an unresolvable rev to STDOUT; it is not a presence test

Asked for a blob that does not exist, `git rev-parse <rev>:<path>` **prints the argument back
on stdout** and exits 128 with a `fatal:` on stderr. Measured:

```
$ git rev-parse "origin/master:.claude/skills/test/SKILL.md"
fatal: path '.claude/skills/test/SKILL.md' does not exist in 'origin/master'   # stderr
origin/master:.claude/skills/test/SKILL.md                                     # STDOUT
$ echo $?
128
```

So a script that captures stdout and ignores the exit status receives **its own input, shaped
like an answer**. Comparing two such captures makes every path that is absent on both sides
compare as two different strings — i.e. as a DIFFERENCE. That is the worst direction for the
error to run: absent-on-both is the case you are most likely to be enumerating, and the
overstatement is silent.

It was caught in the field only because the resulting file list named things the author knew
had been deleted on both sides. The count was 4x too high — 26 "changed" files against a real
6 — while ruling on whether a review anchor could be advanced, i.e. on whether unreviewed work
was about to be marked reviewed.

**The check:** use `git diff --name-only <a> <b>` to ask what differs, and `git cat-file -e
<rev>:<path>` to ask whether something exists. Never infer presence from rev-parse's stdout.

**The general form, which is the transferable half:** a command that writes usable-looking text
to stdout on failure cannot be used as a predicate by reading its output. Check the exit
status, or use a command whose failure is silent. This is the same family as `cmd | head; echo
$?` reading head's status rather than cmd's.

---

## A path-shape heuristic dies the moment a human directory moves into the harness's namespace

**Found:** 2026-08-03, reviewing the change that moved the fleet's lanes into the main clone's
`.claude/worktrees/`. Found by the reviewer auditing that very change, about its own guard.

`reviewer.md`'s first act gated **every destructive operation** — the `git checkout --detach`
pin, mutation experiments, `git checkout -- . && git clean -fd` — on one test:

```
permitted only when `git rev-parse --show-toplevel` contains `/.claude/worktrees/`
```

That was sound for as long as it was true that only the harness put things there. It encoded
"am I in a throwaway isolation worktree?" as "is this path under a directory the harness owns?"
— and the second question stopped answering the first the day a human's live checkout moved
into the same directory.

**The failure is not that the guard got weaker. It is that it kept saying YES.** A reviewer
spawned into a lane whose `isolation: worktree` silently failed to bind now passes its own
check and believes it may reset the tree. The author's uncommitted work is what it would
have reset.

This was not hypothetical. It happened during the review of the moving change itself: the
reviewer's isolation did not bind, its guard passed, and only its separate instruction to run
`git rev-parse --show-toplevel` and *report the path* surfaced that it was standing in the
author's live `team-lead` checkout. Had it followed step 2 in order, the detach would have run
first.

**The check:** when a guard discriminates "mine" from "someone else's" by **where** a thing
sits, ask what else may legitimately arrive at that location. A namespace shared with a
human is not a capability. Prefer a test on the shape of the thing itself — here the basename
`agent-<hex>`, which the harness generates and a person would not choose — over a test on its
neighbourhood.

**The general form:** any predicate of the form "path contains X, therefore it is safe to
destroy" has a lifetime bounded by the first time something you did not put there appears under
X. Write it so that the diff which moves something into X is forced to notice — the same
reflex as C-12: a change that alters the *meaning* of a path must reconcile every doc that
depends on that meaning, and an agent definition is such a doc.

**Corollary, worth as much as the lesson:** the reviewer caught this only because its
definition tells it to *report* `ISOLATION UNBOUND` rather than merely branch on it. A guard
that silently takes the safe path when it fails teaches nobody. Make the guard say which branch
it took.

---

## A sweep scoped by file-KIND misses the file that selects the thing being swept

2026-08-04, the Node 24 pin. The sweep enumerated *kinds* of file — `.nvmrc`, `package.json`
engines, `Dockerfile*`, `.github/workflows/**`, docs — and every kind on that list was handled
correctly. It still missed five files, four of them the ones that actually govern the
interactive dev shell: `.envrc` carrying `use node 25`, which direnv resolves by `semver_search`
to the highest installed `v25.*` — the exact version being deleted. A `.envrc` is not a "Node
version file" by kind. It is a **toolchain selector**, and the sweep had no category for that.

**The check that finds them:** grep the **outgoing literal**, not the incoming file list. `25`
near "node" finds all five in one pass, including the ones you had no category for. An
enumeration can only cover what you already thought of; a search over the value you are removing
covers what you did not.

**The stronger fix, when it exists: delete the copy rather than syncing it.** Bare `use node`
reads `.nvmrc`; `nvm use` with no argument searches upward for it. A directive that *derives*
from the pin cannot drift from it. Prefer that to a second literal you promise to maintain —
the promise is what failed here, four times over.

---

## Verification must be able to fail for the risk THE CHANGE introduces

Same commit, and the more expensive lesson. Six gates were run and reported as evidence: format,
lint, three typecheckers, one codegen drift check. All green. **All six are static analysis, and
all six would pass identically on Node 18** — Prettier, ESLint and `tsc` never execute
application code, and the codegen module touches no native addon, no driver, no HTTP stack.

The change was a Node **major version** change. The only defect class it can introduce is a
runtime regression. So the evidence offered had zero power against the risk taken, while looking
like a thorough green.

**The check, before citing any gate as evidence:** name the defect class the change can
introduce, then ask *which of these gates executes the code that would exhibit it?* If the answer
is none, the green is decoration. Here the load-bearing gates were the ones skipped — the unit
suite (first thing to execute server code under the new runtime), the built-graph import smoke,
E2E, and the production UI build; three Docker base images changed with no `docker build` at all.

**Generalises past toolchains:** a config-only diff is not automatically low-risk. It is low-risk
*for the classes your gates can see*, and a change to the substrate everything runs on is
precisely the case where the usual gates go blind. Related in kind: a file *count* cannot see
wrong file *contents*; a test that cannot run reports as "skipped" while the pass count holds
steady. The common shape is a check whose failure mode is silence.

## An APPROVED plan still carries unverified claims — measure at implementation, don't transcribe

A human green light attests that the **approach** is sound. It does not convert the plan's
factual assertions into measured ones, and nothing downstream re-checks them.

goals-onchain DX-6: the approved plan asserted that dropping `...defaultExclude` from a vitest
config "would silently re-admit `node_modules`", citing a probe that resolved 81 files. Implemented
faithfully, that claim landed in a **guard's code comment** and, worse, was generalised into a
repo-wide rule in `docs/test-best-practices.md`. A reviewer measured it against the real config:
**37 files either way, zero `node_modules`** — the include glob (`server/**/*.integration.test.ts`)
cannot reach `node_modules` at all. The 81-file figure came from the probe's much broader glob.

**Why it was missable:** the number was real, sourced, and written down by a process that had
already been reviewed. Everything about it looked verified. The defect was that the probe's inputs
differed from the real config's — **a probe's result transfers only if the probe used the real
subject's inputs.**

**The check:** at implementation, re-measure any plan claim you are about to encode into a
durable artifact — a comment, a doc rule, a test's rationale. Plans are discarded; the artifacts
outlive the ticket and get cited by people who never read the plan. Ask "did anyone run this
against the thing I am actually changing?"

**Corollary on scope:** the damage scales with where the claim lands. A wrong sentence in a plan
dies with the plan. The same sentence promoted to a best-practices doc becomes a rule others
follow.

## The HEDGE is what gets dropped when a hedged claim is restated

When a carefully-qualified claim is restated somewhere new, the qualifier is what falls off. This
is a structural property of restatement, not a lapse of attention — so "be careful" is not a fix.

goals-onchain DX-6 ran this **four times in one ticket**, each time with the sign flipped or the
proxy swapped: docs called a live API a "sandbox"; the correction asserted a "production host"
(equally unsupported); a later edit asserted "testnet-scoped credentials" as fact in four places
while the *same diff* said "nothing in the repo establishes their scope, so don't assert it"; and
a section heading said "non-prod only" — inferring safety from an environment's NAME, in a ticket
whose entire thesis is that you cannot infer it from a HOSTNAME. That last one was a **safety
defect**: the environment named `sandbox` holds mainnet credentials, so the heading invited an
operator to run a money-moving smoke test against real funds.

**Why it is missable:** re-reading finds what you are looking for, and by then you are looking for
the *new* claim. Every catch here came from grepping the **old wording**, never from re-reading
for correctness.

**The checks, in order of reliability:**
1. **Prefer a claim that needs no hedge.** The durable fix was to state only the *chain*
   (`base_sepolia`, which is established) and stop mentioning credential scope. A claim with no
   qualifier cannot lose one.
2. **After any correction, grep the exact phrase you removed and expect zero hits.** Mechanical,
   and it has a failure mode — unlike "be careful".
3. **Extend the grep to code examples, headings, and summaries**, not just prose. A later round of
   the same ticket left the corrected prose intact while the `❌` code fence eight lines below it
   still asserted the retracted claim. Examples and headings are read *more* than the paragraph
   they illustrate.
4. **Watch for proxy-swapping.** The same error survives a correction by changing which proxy it
   infers from — hostname → environment name → variable default. Fix the *inference*, not the token.

## Editing under an in-flight review makes the reviewer look stale — and the wrong diagnosis is worse than the churn

An author who keeps fixing while a review round is open turns every finding into "you reported X
but it says Y". The reviewer read a state that was **true when it read it**; the author moved the
target. This is invisible from the author's side, where it presents as the reviewer being stale.

goals-onchain DX-6: the author edited files at least five times mid-round, then diagnosed the
mismatch as the reviewer auditing a stale `isolation: worktree` snapshot — a confident, plausible
mechanism ("a fresh `git worktree add` materializes only tracked committed files, and the work is
uncommitted"). It was propagated to the team lead and onward to three lanes before the reviewer
falsified it in one move: the pin contained a **third** string that neither party had quoted, and
`hookTimeout` — which the reviewer had quoted verbatim — appeared **zero** times at the pin. It
could only have read the live lane.

**Why the wrong diagnosis was the bigger error.** The churn costs a round. A false mechanism that
sounds right gets adopted fleet-wide, sends other lanes chasing a non-existent problem, and leaves
the real cause — authors editing under reviewers — running. It also came with an instruction that
could not be followed at all: `git -C <lane> diff` is **refused by an isolation-worktree agent's
sandbox**, so the reviewer was being told to comply with something impossible.

**The checks:**
1. **Freeze the tree for the round, or commit and hand the reviewer a SHA.** The fix is
   author-side. A review of a moving target is not a review.
2. **Before asserting a mechanism for why a peer is wrong, find the observation that would falsify
   it.** Here: does the string the reviewer quoted exist at their pin? One `git show` settles it.
   A mechanism that explains the symptom is not evidence that it occurred.
3. **A peer being wrong about one finding is not licence to discount the rest.** In the same round
   the "stale" reviewer was right about both remaining blockers, including a misattribution
   (a claim ascribed to an envalid `desc` that actually lived in a plain comment, while the `desc`
   carried a *different* formulation — so a search for one string missed the operator-facing one).
4. **File mtimes are evidence.** `diff -u` stamps them; they establish read-order against edit-order
   when memory and assertion conflict.

## One expression gating two independent obligations has 2ⁿ states — you will test the diagonal

**What happened.** A container build needed to skip developer-machine git wiring, so a repo's
`prepare` script became:

    [ -e .git ] && [ -f helper.sh ] || exit 0; husky && helper.sh

Two conditions ANDed to gate **two independent obligations**: installing commit hooks, and
registering a merge driver. The author tested "both present" and "neither present", and wrote in
the commit body that both directions were verified. Those are the two **diagonal** cells — and
they are exactly the states in which a conjunction behaves identically to no guard at all. The
off-diagonal state (`.git` present, helper absent) short-circuits the entire chain: **no commit
hooks installed, silently, exit 0.** No commitlint, no pre-push. Before the guard, husky would
have installed and the helper would have failed loudly; the change traded a loud failure for a
silent one, which is the shape of nearly every guard regression.

**The checks:**
1. **Count the states before writing the expression: n inputs, 2ⁿ rows.** Say what should happen
   in each row, then test each. If the table feels like overkill for the change, that is evidence
   the guard is gating the wrong thing — not evidence the table is unnecessary.
2. **Gate each action by its OWN precondition.** Two obligations want two statements
   (`husky; if [ -f helper ]; then helper; fi`), not one conjunction. The `&&` is what created the
   bug: it let one action's precondition suppress an unrelated action.
3. **Read the tool before wrapping it — the guard may be unnecessary AND harmful.** husky 9.1.7
   already returns `.git can't be found` and exits 0 when there is no git dir. The `.git` conjunct
   protected nothing and was itself the entire defect. A guard added "for safety" around something
   already safe is pure downside.
4. **A tool that reports failure on stdout with exit 0 can never short-circuit an `&&`.** husky
   returns *every* failure as a string and always exits 0, so `husky && next` could not detect a
   failed hook install before or after the guard. An `&&` chain asserts a dependency the runtime
   may not actually enforce — check the exit contract before relying on the operator.

## Files agreeing with each other says nothing about the runtime executing them

**What happened.** A repo pinned one toolchain version across a dozen files — `.nvmrc`,
Dockerfile `ARG`s, CI workflows, every workspace's `engines` — and added a guard asserting they
all agreed. They did. Meanwhile the shell actually running the gates resolved `node` to a version
**below** the declared floor, because non-interactive shells never load direnv. Every gate
reported green from a runtime nobody had chosen, and no file-consistency check could see it: the
guard's entire subject was files, and the defect was in the process.

**The checks:**
1. **If a toolchain's version matters enough to pin, assert the RUNNING one too.** A consistency
   guard over files is blind to the interpreter executing it. Without this, a whole green sweep
   can be produced by the wrong major and nothing in the repo notices.
2. **Assert against the RANGE, not the exact pin.** A later patch on the same major is a
   legitimate machine and must not fail; anything below the floor must. Writing the assertion
   forces you to answer which artifact is authoritative for which question — the range governs
   "may this runtime run our code", the exact pin governs "what do we build with" — and that is
   worth stating explicitly rather than leaving implied by two files that happen to agree.
3. **A declared `engines` field is not this check.** pnpm prints `[WARN] Unsupported engine` for a
   workspace's own declared range and exits 0; the one existing signal is a line in an install log
   nobody reads.
4. **Ship the remedy in the same change as the assertion.** A true-positive red with no reachable
   fix is routed around, and the route around it (`--no-verify`, `|| true`, deleting the test)
   discards every other gate travelling with it. Wire the fix into the paths that will hit the
   red — the hook, the runner, the agent instructions — and confirm you wired the path that
   actually invokes the failing gate, not an adjacent one that merely mentions it.
5. **Make the failure carry its own remedy.** `expected false to be true` tells whoever hit it
   nothing. Assert a string, so the message names the fix.

## A git hook cannot be tested from the worktree that changes it

**What happened.** A commit added Node-version resolution to `.husky/pre-push`. To verify it, the
author ran `git push --dry-run` from the lane, saw the command succeed, and reported the hook
fixed. It was not. `core.hooksPath` was an **absolute path into the main checkout**
(`/…/<repo>/.husky/_`), and husky's shim resolves the real hook as
`s=$(dirname "$(dirname "$0")")/$n` — so **every worktree's hook is the MAIN checkout's hook
file**, executed with the lane merely as cwd. A lane's own `.husky/*` never runs. The dry-run had
exercised the main checkout's unmodified hook against the lane's code, and the "success" was read
off a background wrapper whose real exit was 1.

**The checks:**
1. **Before verifying a hook, ask which file will actually execute.** `git config --get
   core.hooksPath` plus the hook-runner's resolution logic answers it in two commands. An absolute
   hooksPath means worktrees share one hook, and a per-worktree edit is inert.
2. **A hook change does not take effect for anyone until the tree it is read from advances.**
   That is a rollout dependency the branch cannot satisfy, so it belongs in the PR body as a
   sequencing note, not in the commit as a claim of "fixed".
3. **Verify it by invoking the hook the way the runner does** — reproduce the runner's own
   environment (`export PATH="node_modules/.bin:$PATH"; sh -e .husky/<hook>`) against the file you
   edited. That tests your change; pushing tests whatever file the runner picks.
4. **This is a general shape, not a husky quirk.** Any config pointing at a shared absolute path —
   hooks, lint config, a toolchain manifest — means the file you edited is not necessarily the
   file that runs. Check the resolution before trusting the experiment.

---

## A commit message that retires a claim does not retire the claim

**DX-16, 2026-08-06.** A causal explanation for Linear's `updatedAt` drift was measured, found
backwards, and disowned — in a commit body and in two documents. A **third** statement of the
same claim survived in a skill's own CHANGELOG, one hop away via its version-history link. The
reviewer found it; the author, who had written the retraction, did not.

**The shape.** Retracting a claim feels like a single act, so attention goes to the passage you
are rewriting and to explaining the retraction. But a claim that was worth stating once has
usually been stated in every place that argued from it — a changelog entry, a tool docstring, a
skill step, a commit body — and those are the copies nobody is editing. **The retraction lands;
the claim survives beside it.**

**Three things that make this worse than an ordinary stale reference:**

- **A retraction is high-confidence text**, so the file containing it reads as authoritative on
  the subject — including where it still asserts the old claim two hops away.
- **The imperative voice a tool header or a checklist wants is the voice that strips
  qualifiers.** A hedge written in prose dies on its way into a docstring, a step, or a commit
  subject, so the unqualified form is over-represented exactly where it is hardest to spot.
- **Provenance travels badly.** One unhedged sentence at the source needed correcting at four
  sites, and the agent that propagated it had faithfully reported what it was told.

**How to apply.** When you retract or narrow a claim, **grep the claim's own words across the
whole corpus before committing the retraction** — not the file you are editing, and not only the
files the map names. Include changelogs, docstrings, fixtures and commit-adjacent prose, which
are the containers that carry text nobody re-reads. Then **name a tie-break**: if two documents
state the same fact, say which one wins, so the next divergence has a resolution instead of
needing to be prevented.

---

## A check's SCOPING instruction is load-bearing, and the document that defines a marker is the first thing it misclassifies

**DX-16, 2026-08-06, measured on the plan that shipped the rule.** `reviewer.md` identifies a
migrated plan by a marker string, and says explicitly: search **inside changelog entries only,
never a whole-document text search**. DX-16's own plan contains that marker **seven times in
prose and zero times in a changelog entry** — because it is the document that *defines* the
marker and therefore discusses it constantly.

A reviewer that "simplifies" the scoped search into a plain grep classifies that plan as
**migrated**, which it is not — it was born a document — and then softens its criterion into the
"this plan predates the rules" wording. **Wrong classification, actionable-looking output, no
error anywhere.**

**The general shape: any check keyed on a string will be tripped first, and hardest, by the
document that introduced the string.** Specs, style guides, hazard notes and skill definitions
all quote the thing they govern, at a density no ordinary document reaches. So:

- **Never key a check on a bare string when a container makes it unambiguous.** "Inside a
  changelog entry" is not a stylistic refinement of "somewhere in the file" — it is the whole
  correctness of the check.
- **When you write the scoping clause, write WHY next to it**, or the next reader deletes it as
  redundant. A scoping clause looks like caution; it is usually the load-bearing half.
- **Test any string-keyed check against its own defining document first.** It is the worst case
  and it is always available.


## A mock picks the failure's SHAPE, and the wrong shape makes the defect unobservable (2026-08-10)

**The instance.** A best-effort warmup raced a browser launch against a timeout and closed the browser in `finally`. Its test mocked a hanging launch as `await new Promise(() => {})` — a launch that **never** resolves. The test passed, and it could not have failed: if the launch never resolves, no browser is ever created, so no browser can be stranded. A real starved host does not hang forever; it makes the launch **late**. The launch resolves after the race is lost, `finally` has already run and seen nothing, and the process now owns an orphan browser for the rest of the run.

**The rule.** When you mock a dependency's failure, you are choosing which of several failure SHAPES to reproduce, and that choice decides what the test can see. "Slow", "late", "never", "throws", "throws after succeeding", "resolves with garbage" are different shapes with different observable consequences. Pick the shape the real dependency actually produces, and when the failure mode you care about is a **resource leak or a cleanup obligation**, prefer the shape where the resource EXISTS. `never-resolves` is the shape in which most cleanup bugs are invisible, and it is also the easiest one to write — which is exactly why it gets chosen.

**The tell, and it is cheap.** Ask of every failure-injection test: *could this test still pass if the cleanup were deleted?* If yes, the mock is the wrong shape. Then delete the cleanup and confirm the test reddens — mutation is the only thing that separates a test that checks the behaviour from a test that merely runs it. In the instance above, the sibling tests all asserted `expect(close).toHaveBeenCalled()` and the hang test alone omitted it; a test that quietly drops the assertion its siblings carry is worth a second look, because it usually means the assertion could not have held.

**The same error in a second costume, from the same review.** A function documented "never throws" genuinely had the try/catch. But nothing called it directly — every caller went through a wrapper that did the setup work OUTSIDE any handler, so the contract held on a function no caller reached, and a malformed input threw from the wrapper. **Verify a contract on the function the CALLERS reach, not the one that advertises it.** Both failures are one thing: the check was sound and was of the wrong object. Soundness is not the property you need; aboutness is.

**A fifth instance, where the wrong object was a NUMBER (2026-08-11).** A count of how many
source files a `tsconfig` actually pulled in was taken as `tsc --listFiles | grep -c <substring>`
and came back **5**; the true answer was **55**. `--listFiles` prints files named on the command
line as **relative** paths and files reached through imports as **absolute** ones, so the
substring matched one of two populations and silently excluded the other. The number was real, it
was reproducible, and it was of the wrong set — which is why it survived being reread. **Write
what a number is OF next to the number, before you interpret it:** "5 files whose listed path
contains `src/`" invites the question that "5 files" does not. And when you correct a figure, say
what the old one actually measured, not merely that it was wrong — otherwise the next reader
re-derives the same 5 and assumes you fat-fingered it.

**Why this class survives careful review.** Neither mistake looks like an absence. There is a test, and it passes; there is a try/catch, and it works. Nothing is missing, so nothing prompts the question — the only way in is to name the object the check is OF and compare it to the object the question is ABOUT. Related: the filter lesson (a filter that makes a check look more precise is the likeliest place it stops seeing the defect) and the operation-vs-state lesson (a delta is a property of the operation; idempotence is a property of the state). Same family, third and fourth instances.

## An anti-vacuity assertion must be made PER ENUMERATED SOURCE, not on the total (2026-08-10)

A sweep that looks nowhere reports the same reassuring nothing as one that looked everywhere, so
an enumerating check has to assert it found something. That rule was already written down. **It
was then applied to the aggregate, which does not deliver it.**

The guard walked three suite roots (40 + 41 + 4 files) and asserted `files.length > 10` on the
flattened list. Any single root could vanish — `walk()` returns `[]` for a missing directory —
and the total still cleared the floor. A reviewer proved it by renaming one root: **green, with
41 files unchecked, including the file holding the original defect.**

**The assertion belongs on each source that can independently break, and its failure should NAME
the source.** A per-root `it.each` that reds as "resolves suite files under `<root>` (found 0)"
tells you which glob died; a global floor tells you nothing and usually stays green.

**The general form: a floor over N sources is satisfied by the N−1 that still work.** Any check
aggregating independent inputs — file globs, config sections, per-service health, per-shard
counts — has this shape, and the aggregate is exactly where the failure hides.

**Why it recurred inside its own fix, which is the part worth remembering.** This guard was
written *because* three separate checks had each been correct about what they examined while
their domain excluded the next defect. The guard fixed that for the addresses and reproduced it
for the roots. Writing a check against a defect class does not exempt the check from the class —
and the exemption feels strongest right after you have just written the lesson down.

## A watcher's completion event names a SHA, not "the PR" (2026-08-11)

**The instance.** A check-watcher was started against a PR, and it fired `ALL CHECKS COMPLETE`.
It was telling the truth — about the commit it had been started on. That head had since been
replaced by a new push, and the current head still had a check running. The standing instruction
was to hold if anything was red or unfinished; acting on the event would have merged under
exactly the condition the instruction existed to prevent, while reporting that the condition had
been checked.

**Why it is missable.** The event does not read as a claim about a commit. It reads as a claim
about *the PR*, because that is the object you asked about and the object you are about to act
on. The SHA is in the payload and nobody looks at it, since under the common case — nobody
pushed — the two objects coincide. The failure needs a push to land inside the watch window,
which is precisely when you are most likely to be watching.

**The rule.** A watcher started against a SHA answers only for that SHA. Before acting on its
event, **re-resolve the current head and confirm the event's SHA still equals it**; if it does
not, the event is stale by construction and a new watch is owed. Generalises past CI: any
asynchronous observation of an object that can be *replaced* while you watch — a deploy watching
a revision, a poll on a queue item that can be requeued, a review bound to a diff that can be
force-pushed — has this shape. The completion is about the identity you started with, and your
action is about the identity that exists now.

## In a git worktree, `.git` is a FILE — any check that paths through `.git/` is false by construction (2026-08-11)

**The instance.** A guard tested `test -f .git/MERGE_HEAD` to decide whether a merge was in
progress. It reported no merge while a conflicted merge sat staged in the tree. In a **worktree**,
`.git` is not a directory — it is a one-line file pointing at
`…/.git/worktrees/<name>`, so `.git/MERGE_HEAD` names a path that can never exist. The check did
not misread the state; it was incapable of reading it, and it fails in the *safe-sounding*
direction, reporting the clean case.

**The class, not the instance.** Every filesystem path under `.git/` has this defect in a
worktree: `.git/HEAD`, `.git/refs/*`, `.git/MERGE_MSG`, `.git/rebase-merge/`, `.git/index`. Some
resolve to the *main* checkout's state rather than to nothing, which is worse — a plausible wrong
answer instead of an obvious empty one.

**The rule: ask git, never the filesystem.** `git rev-parse -q --verify MERGE_HEAD`,
`git symbolic-ref -q HEAD`, `git rev-parse --git-path <name>` — these resolve correctly in a
worktree, a bare repo, and a plain clone alike, which is the whole reason porcelain exists.

**The part that decides how much this matters.** In a fleet, worktrees are not the exotic case —
they are where nearly all agent work happens. So a `.git/`-path check is wrong *exactly where it
is used*, and its correctness in the main clone is what keeps it alive: it is written and tested
somewhere it works, then deployed everywhere it cannot.

## A bare `git push` is not scoped to your branch unless push.default says so (2026-08-11)

**The instance.** A bare `git push` from a lane attempted **three refs**, not one. The machine
carried `push.default=matching`, under which a bare push sends every local branch that has a
same-named remote counterpart — including a `master` that was stale relative to origin. Only the
non-fast-forward rejection stopped superseded state from being published to the shared branch.
The command was correct-looking, habitual, and one config value away from clobbering trunk.

**The rule.** Push explicitly, always: `git push origin <branch>`. Treat a bare push in a fleet
that shares one `.git` across worktrees as unsafe **regardless of what the config currently
says** — `simple` being today's default is not protection, because config is machine state. A
fresh clone, another engineer's box, or a CI runner does not have your `~/.gitconfig`, and the
safety of a command that depends on ambient configuration cannot be verified by reading the
command.

**Generalises to every ambient-scoped verb.** `git checkout` with no path, `rm` with a bare glob,
a `kubectl` command with no `-n`, a deploy that reads its target from an env var — the scope you
believe you are operating on lives outside the text you reviewed. Write the scope into the
command so the review can see it.

## The detached-HEAD class: NAME the forbidden git operations, and verify AFTER (2026-08-11)

**The instance.** A subagent operating in a live lane was told to make **no git mutations**. It
detached HEAD anyway — its reading of "mutation" covered commits and resets but did not extend to
a checkout that only moves where HEAD points. The instruction was not disobeyed so much as it
failed to name the thing.

**The first rule: enumerate, do not characterise.** A category word in a spawn prompt is resolved
by the reader, and readers resolve generously toward what they were about to do. Name the
operations: **checkout, detach, pin, stash, reset, switch, rebase, cherry-pick, clean, branch
-f**. This is the same failure the categorical "no destructive commands" phrasings keep having,
and enumeration is the only fix that has held.

**The second rule, which is the stronger one: verify AFTER.** A pre-check ("am I allowed to be
here?") is racy and depends on the agent choosing to run it; a post-condition is not. After the
work, assert `git symbolic-ref -q HEAD` equals the expected branch — this catches a detach no
matter which verb produced it, whether the agent read the instruction at all, and whether the
environment contract bound. **Prefer an unraceable post-condition to a well-worded pre-condition
whenever you can express the invariant as a state rather than as a permission.**

**Related, and the same root.** "A declared isolation contract is verified by the isolated party"
(2026-07-10) and "A path-shape heuristic dies the moment a human directory moves into the
harness's namespace" (2026-08-03) are the two prior visits: an isolation check that live lanes
*satisfied*, so the guard said YES in the one situation it existed to catch. All three say that
a guard phrased as "am I permitted?" is answered by whoever is asking, and a guard phrased as
"is HEAD on `<branch>`?" is answered by the repository.

## An artifact cannot tell you whether its own open questions are still open (2026-08-11)

**Twice in one hour.** A dated artifact was read, checked for internal supersession, found to
carry an open question still marked open — and the question was reported as live. Both times it
had already been answered, in an artifact the source **could not** have referenced: a later
addendum past the read point in one case, and in the other a ticket filed two days after the
plan's last touch, created expressly to own that question.

**Why this is not "audit snapshots go stale".** That rule was already being applied — to the
CONTENT — and it still failed, because a question's STATUS decays by a different mechanism. The
content ages in place, where careful re-reading finds it. The status is changed by **someone
else, somewhere you are not looking**, and nothing about that is visible from inside the source.
So the reflex the staleness rule trains — read the document harder — is the wrong instrument
here; no amount of care inside the artifact can reach the fact that settles it.

**The tell, and it reads as the opposite.** "Deliberately left undecided", "pending X", "owner
TBD", "to be settled by" — each of these is a pointer to a decision expected to happen
ELSEWHERE. Treat one as a search prompt, never as a finding. **The more emphatically a gap is
flagged, the likelier it is that someone already acted on the flag**, which is exactly backwards
from how the emphasis reads.

**The rule.** Before reporting an open question as live, establish what DOWNSTREAM now owns it —
a newer ticket, a later addendum, a tracker decision, a sibling workstream. Search by the
question's **subject**, not by the document's identifiers: the artifact that closed the question
will not cite the artifact that raised it, so an id-based search is guaranteed to miss it.

**Cost direction, which is what makes it worth a rule.** The failure produces false urgency
about someone else's completed decision, and it is expensive precisely because it looks
diligent — here it escalated a resolved trap as time-critical and came close to re-opening
settled scope. Compare "A watcher's completion event names a SHA, not 'the PR'" above: same
shape, opposite direction. There the dated observation was believed about an object that had
moved on; here the dated *gap* was.
