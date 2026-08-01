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
