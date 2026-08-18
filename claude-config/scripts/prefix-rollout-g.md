# Fleet agent-name prefix rollout — `g-` (goals)

**Status: PREPARED, NOT APPLIED.** Every step below is to be executed at a **fleet-down
boundary** (no `claude` process alive in any lane of any project). Nothing here may be
applied while agents are running: several steps change the name an agent answers to.

Prepared 2026-08-14. Verified against the live machine state on that date.

---

## 0. Why — the collision is real and already happening

Three teams were live on this machine at preparation time, **each with a lead named
`team-lead`**, in three different repos:

| team session | lead cwd |
|---|---|
| `session-bcead1f1` | `/Users/john/git/dotfiles` |
| `session-75c6b4d4` | `/Users/john/git/monocle` |
| `session-aa3abee7` | `/Users/john/git/goals-onchain` |

What does and does not collide:

| store | keyed by | collides? |
|---|---|---|
| `~/.claude/teams/session-*/` (config + inboxes) | session id | **No** — SendMessage routing is per-team |
| `~/.claude/running-agents/<name>.<pid>` | name **+ pid** | No clobber on write… **but see below** |
| `~/.claude/agents/<name>.cwd` | bare name | **Yes** — last writer wins |
| `~/.claude/agents/<name>.transcript` | bare name | **Yes** |
| `~/.claude/agents/<name>.role` | bare name | **Yes** (none exist today) |
| `~/.claude/agents/<name>` (base branch) | bare name | **Yes** |
| `~/.claude/agent-busy/<name>` | bare name | **Yes** |

**The sharpest one is not the `.cwd` clobber — it is a wildcard delete.**
`register-agent.sh:716` runs

```sh
rm -f "$HOME/.claude/running-agents/$name".*
```

and `register-agent.sh:317` runs the same thing on the settle-swap path. With three projects
each registering `team-lead`, **the last one to boot deregisters the other two's leads.** The
pid suffix does not protect anything, because the glob ignores it. Same hazard for
`feature-1`..`feature-4`.

Downstream readers of the clobbered sidecars: `lane-guard.sh` (decides whether a write is
allowed), `fleet-layout.sh` (window naming / placement), `statusline-role.sh`,
`agent-identity.sh`, `_fleet.sh:fleet_busy`.

---

## 1. The design — two identity spaces, only one gets the prefix

This is the load-bearing decision. Do not collapse it.

| space | members | scope | prefix? |
|---|---|---|---|
| **LANE** — directory, branch, tmux window, port block, hostname | `team-lead`, `feature-1..4` | repo-local; `.claude/worktrees/<lane>` | **NO** |
| **AGENT NAME** — registry, sidecars, busy marker, SendMessage address, `--name` | `g-team-lead`, `g-feature-1..4` | **machine-global** | **YES** |

Rationale: lane names are paths inside one clone and cannot collide across projects.
Prefixing them would mean renaming worktrees and branches — enormous blast radius, zero
benefit. Every global, name-keyed store is in the second column, and that is exactly what
`WORKFLOW_AGENT_NAME_PREFIX` already feeds.

Consequence: **anywhere a lane name is used as an agent name, or vice versa, needs an
explicit conversion.** Section 3 enumerates every such site.

---

## 2. Verified: `g-` classifies clean (mostly)

Run against the live `_fleet.sh` on 2026-08-14:

```
$ source ~/.claude/scripts/_fleet.sh
$ for n in ...; do printf '%-18s role=%-10s id=%s\n' "$n" "$(fleet_resolve_role "$n")" "$(fleet_agent_id "$n")"; done
team-lead          role=team-lead  id=0
g-team-lead        role=team-lead  id=0     ✅ via  *-team-lead
g-feature-1        role=feature    id=f1    ✅ via  *-[0-9]
g-feature-2        role=feature    id=f2    ✅
g-feature-3        role=feature    id=f3    ✅
g-feature-4        role=feature    id=f4    ✅
g-prefix-rollout   role=other      id=a1    ✅ (task subagent — correct)
g-reviewer         role=other      id=a1    ❌ should be review
g-tester           role=other      id=a1    ❌ should be test
g-planner          role=other      id=a1    ❌ should be review
```

**Lanes are clean. Subagent role names are NOT.** The classifier matches `reviewer`,
`tester`, `planner` only as **bare literals**; there is no `*-reviewer` / `*-tester` /
`*-planner` alternative. Prefixing silently demotes all three to `other`. This is a new
finding — it is not in the prior audit — and it is why step 3.4 exists.

Consequence if unfixed: `agent-fanout --role review|test` stops matching the subagents;
`fleet_agent_id` labels them `a1` instead of `pr1`/`test1`; `fleet-layout` names their
windows from the `other` branch. Nothing is destroyed, but the fleet loses sight of them.

Also verified prefix-immune (no change needed):

- `alive_in()` / `lane_agent()` / `fleet_agent_in_dir` — **process-cwd based**, never name
  based. Liveness detection is entirely unaffected.
- `lanes.sh:59 lane_num()` and `agent-tune.sh:287 lane_num_of()` — both take a **directory
  basename**, which stays unprefixed. Ports (`8080+N`, `3000+N`, `35729+N`) and hostnames
  (`goals-N.localhost`) resolve unchanged for lanes 0–4.
- `~/.claude/teams/*/inboxes/` — per-session, no cross-project collision.

### `_window_label` — the tmux tab

`_window_label` (`fleet-layout.sh:336`) short-circuits on **role**, so `g-team-lead` still
prints the literal `team-lead`; the tab does **not** gain the prefix. `g-feature-2` resolves
role `feature` → lane 2 → the display label `ott`, unchanged.

**Recommendation (John's call, not made here):** keep the tabs bare. The tmux *session* is
the per-project boundary — each fleet runs in its own session — so a tab named `team-lead` is
already unambiguous, and the tab is the thing a human navigates by name. Prefix the tabs only
if you ever intend to run two fleets inside **one** tmux session, which nothing today does.
If you do want them prefixed, the one-line change is in step 3.7 (commented out).

---

## 3. The edits

Ordered. Apply all of them or none — several are interdependent.

### 3.1 Turn the prefix on — `/Users/john/git/goals-onchain/.claude/workflow.config`

Committed file, project-generic value → belongs here, not in `.local`.

```diff
@@ # ── Fleet machinery ────────────────────────────────────────────────────────
+# ── Agent name prefix ──────────────────────────────────────────────────────
+# Every agent NAME this project registers is prefixed `g-` (goals), so several
+# Claude fleets can run on one machine without colliding in the MACHINE-GLOBAL,
+# name-keyed stores: ~/.claude/agents/<name>.{cwd,transcript,role}, ~/.claude/
+# agent-busy/<name>, and ~/.claude/running-agents/<name>.<pid> — whose stale-entry
+# cleanup is `rm -f running-agents/<name>.*`, i.e. a bare-name wildcard that
+# deregisters ANOTHER project's agent of the same name. Observed live 2026-08-14
+# with three concurrent `team-lead`s (dotfiles, monocle, goals-onchain).
+#
+# LANE names are NOT prefixed and must never be: the lane is a directory, a branch,
+# a tmux window and a port block inside ONE clone, so it cannot collide. The lane
+# stays `feature-2`; the agent living in it is named `g-feature-2`.
+WORKFLOW_AGENT_NAME_PREFIX="g-"
+
 # The command each agent cell's top-right companion pane runs at boot. [...]
 WORKFLOW_CELL_COMMAND="monocle"
```

Applied by `register-agent.sh:_normalize_name()` (`:221`), which already carries the
double-application guard (`case "$n" in "$prefix"*)`), so `claude --continue` and `/rename`
cannot produce `g-g-team-lead`. Verified present, unchanged.

### 3.2 `team-boot.sh` — split `LEAD_LANE` into lane vs agent name  **[MISROUTING]**

`LEAD_LANE` is currently used for *both* purposes. Line 91:

```diff
 SESSION="${WORKFLOW_FLEET_SESSION:-main}"
-LEAD_LANE="team-lead"
+# LEAD_LANE is a PATH/tmux identity (LANES_DIR/team-lead, the window name) and is never
+# prefixed. LEAD_AGENT is the REGISTRY identity — what the lead is launched as and what
+# the registry, the sidecars and SendMessage know it by. Keeping one variable for both
+# is what breaks under WORKFLOW_AGENT_NAME_PREFIX: the lead would register as
+# `g-team-lead` while `verify` looked for `running-agents/team-lead.*` and reported a
+# live lead as unregistered.
+LEAD_LANE="team-lead"
+AGENT_PREFIX="${WORKFLOW_AGENT_NAME_PREFIX:-}"
+LEAD_AGENT="${AGENT_PREFIX}${LEAD_LANE}"
```

`AGENT_PREFIX` must be read **after** the project config is sourced. Verify that ordering
when applying; if the config load happens later in the file, move these two lines down to
just after it.

Line 342 — the launch flag (**this is the one that decides the registered name**):

```diff
-  local launch="MONOCLE_REQUIRE_SET_REPO=1 claude --teammate-mode tmux --permission-mode auto --allow-dangerously-skip-permissions --name $LEAD_LANE"
+  local launch="MONOCLE_REQUIRE_SET_REPO=1 claude --teammate-mode tmux --permission-mode auto --allow-dangerously-skip-permissions --name $LEAD_AGENT"
```

Note this is belt-and-braces: `_normalize_name` would prefix a bare `team-lead` anyway.
Passing the final name explicitly means boot and the registry agree without depending on
hook order, and it makes the launch command self-documenting in `ps`.

Line 680 — registry lookup in `verify` (**misroutes today under a prefix**):

```diff
-  if ls "$HOME/.claude/running-agents/$LEAD_LANE".* >/dev/null 2>&1; then
+  if ls "$HOME/.claude/running-agents/$LEAD_AGENT".* >/dev/null 2>&1; then
```

**Leave lines 153, 167, 199, 216, 260, 263, 264, 286, 305, 308, 389, 402, 594, 688, 702
alone** — every one is a path (`$LANES_DIR/$LEAD_LANE`), a tmux window name, or a
directory-basename comparison from `for d in "$LANES_DIR"/*/`. Those are LANE identity and
are correct as-is. Classified: **safe**.

### 3.3 `team-boot.sh:~524` — the teammate spawn prompt  **[MISROUTING]**

`cmd_spawn_prompt` takes a **lane** name and emits a prompt that names the teammate's
**agent** identity and its reply address. Both need the prefix; the `EnterWorktree` path and
the branch must not get it.

```diff
 cmd_spawn_prompt() {
   local name="${1:-}"; [ -n "$name" ] || die "spawn-prompt needs a lane name"
   local p; p="$(lane_path "$name")"
   [ -d "$p" ] || die "no lane at $p"
+  # The lane name is the PATH and the BRANCH; the agent name is the REGISTRY identity the
+  # lead spawns it under and the address its report must go to. Under a name prefix these
+  # differ, and the prompt needs both — an unprefixed reply address is a report nobody
+  # receives, which is the exact failure the last paragraph of this prompt warns about.
+  local agent="${AGENT_PREFIX}${name}"
```

then, in the heredoc:

```diff
-You are teammate \`$name\`, working lane $name.
+You are teammate \`$agent\`, working lane $name.
```

```diff
-Report with SendMessage to \`team-lead\`: your lane, your branch, and either the issue you
+Report with SendMessage to \`$LEAD_AGENT\`: your lane, your branch, and either the issue you
 are resuming or "no work in flight" — then stand by.
```

The `EnterWorktree` line already interpolates `$p` and the branch line already says
`branch $name` — both are lane identity, both stay. Dynamic resolution throughout; no
literal is swapped for another literal.

**Also check the `/staff` skill** before applying: it spawns teammates via the Agent tool's
`name` parameter. If it passes a hardcoded `feature-N`, `_normalize_name` will still prefix
the registration, but the lead's own `SendMessage({to: ...})` calls will use the unprefixed
name it thinks it spawned. Grep it and align it with `$agent` the same way.

### 3.4 `_fleet.sh:265` — classifier gaps the prefix opens  **[MISROUTING]**

```diff
 fleet_resolve_role() {
   case "$1" in
     team-lead|*-team-lead|team-lead-*) echo team-lead ;;
     cc|coordinator|*-cc|*-coordinator|*-coordinator-*|coordinator-*) echo team-lead ;;
-    test|tester|*-test|*-test-*|test-*|tester-*)                       echo test ;;
+    test|tester|*-test|*-test-*|test-*|tester-*|*-tester|*-tester-*)   echo test ;;
-    review|reviewer|rev|rev-*|*-rev|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*|planner|plan-*)
+    review|reviewer|rev|rev-*|*-rev|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*|planner|plan-*|*-reviewer|*-reviewer-*|*-planner|*-plan-*)
                                                                        echo review ;;
     *-[0-9]|*-[0-9][0-9]|*-[0-9][0-9][0-9])                            echo feature ;;
     *)                                                                 echo other ;;
   esac
 }
```

Why: `reviewer`, `tester`, `planner` are matched **only as bare literals**. Every other role
word already has a `*-` form; these three do not, so a prefix demotes them to `other`.
Verified by direct invocation — see §2.

### 3.5 `_fleet.sh:214` — correct a false comment

The comment claims `team-lead` is a hardcoded Claude Code constant. It is not: it is the
value of our own `--name` flag at `team-boot.sh:342`. Left uncorrected it argues against
exactly the change this runbook makes.

```diff
-# `team-lead` is the ONLY name Claude Code will let the lead answer to — it is a
-# [...rest of the paragraph...]
+# `team-lead` is OUR name for the lead, not the harness's: it is the value team-boot.sh
+# passes to `claude --name` (:342), and `WORKFLOW_AGENT_NAME_PREFIX` may prepend to it
+# (this project registers `g-team-lead`). Nothing in Claude Code requires the string.
+# What IS fixed is the ROLE word: many names resolve here (prefixed forms, `cc`,
+# per-agent .role overrides, historical ids) but they all RESOLVE to `team-lead`, so
+# there is exactly one role name downstream and one role doc: agent-roles/team-lead.md.
```

Read the surrounding lines when applying — the existing 228–229 sentences say the second
half of this already and should not be duplicated.

### 3.6 `_fleet.sh:366` — `fleet_lane_display_name` lead case  **[cosmetic]**

```diff
   case "$agent" in
-    team-lead) n=0 ;;
+    team-lead|*-team-lead) n=0 ;;
```

Without it, `fleet_lane_display_name g-team-lead` falls to the `*)` degrade branch and
returns `g-team-lead` instead of lane 0's label. `_window_label` short-circuits on role
before reaching here, so the tmux tab is already correct — this only fixes **direct**
callers, e.g. the `label=` line in `cmd_spawn_prompt`.

### 3.7 `fleet-layout.sh:361,368` — durable-role filter  **[cosmetic, pre-existing]**

Independent of the prefix; folded in because it is a one-word fix to a bug seen today (a
task-named subagent renamed the lead's tab to `other-team-lead`).

```diff
-  durable="$(printf '%s\n' "$roles" | grep -vxE 'review|test' || true)"
+  # `other` is a task-named subagent — no lane, therefore never durable. Omitting it here
+  # let a subagent stacked under the lead rename its window `other-team-lead`.
+  durable="$(printf '%s\n' "$roles" | grep -vxE 'review|test|other' || true)"
```

and the matching recount at line 368:

```diff
-      residents="$(for n in "$@"; do _role_of "$n"; done | grep -vxE 'review|test' | grep -c .)"
+      residents="$(for n in "$@"; do _role_of "$n"; done | grep -vxE 'review|test|other' | grep -c .)"
```

Both must change together — filtering the roles but not the resident count would make the
lead's window read `team-leads`.

<!-- OPTIONAL, only if John wants prefixed tmux tabs (see §2 recommendation — default is NO):
     fleet-layout.sh:338
-    team-lead|coordinator) printf 'team-lead'; return ;;
+    team-lead|coordinator) printf '%s' "${WORKFLOW_AGENT_NAME_PREFIX:-}team-lead"; return ;;
-->

### 3.8 The two duplicated classifiers  **[MISROUTING]**

`agent-identity.sh:36` and `statusline-role.sh:65` each carry their **own copy** of the
name→role patterns. They are already drifted from `_fleet.sh` (neither knows `tester`,
`reviewer`, `planner`, `rev`, or `plan-*` at all), and `agent-identity.sh`'s fallback is
`feature` rather than `other`, so today it calls a tester a lane agent.

Apply the §3.4 pattern set to both, and change `agent-identity.sh`'s final `*)` from
`feature` to the lane-shape discriminator `statusline-role.sh` already uses:

```diff
     test|*-test|*-test-*|test-*)                                     echo test ;;
     review|pr|*-pr|*-pr-*|pr-*|*-review|*-review-*|review-*)          echo review ;;
-    *)                                                               echo feature ;;
+    *-[0-9]|*-[0-9][0-9]|*-[0-9][0-9][0-9])                          echo feature ;;
+    *)                                                               echo other ;;
```

**Better, and the reason to prefer it:** delete both copies and source `_fleet.sh`. Three
copies of one rule is how this drifted in the first place, and this rollout would otherwise
need the same edit in three places again. Sourcing is what `register-agent.sh:508` already
does (`resolve_role() { fleet_resolve_role "$1"; }`). Treat de-duplication as the intended
fix and the pattern patch as the fallback if a hard startup-latency constraint on the
statusline forbids sourcing.

### Literal audit summary

| file | `team-lead` literals | classification |
|---|---|---|
| `_fleet.sh` | 12 | 10 safe (role words, comments) · 1 comment **wrong** (3.5) · 1 **cosmetic** (3.6) |
| `fleet-layout.sh` | 19 | all safe (role comparisons + the deliberate tab exception) · 2 **cosmetic** unrelated (3.7) |
| `agent-identity.sh` | 3 | safe as literals; the **classifier around them** is wrong (3.8) |
| `statusline-role.sh` | 3 | safe as literals; **classifier** wrong (3.8) |
| `team-boot.sh` | 4 + `LEAD_LANE`×18 | 2 **MISROUTING** (3.2 launch, 3.2 verify) · 1 **MISROUTING** (3.3 prompt) · rest safe (paths/tmux/basenames) |
| `register-agent.sh` | 3 | safe (all inside comments) |
| `agent-fanout.sh` | 1 | safe (usage text: `--role team-lead` is the ROLE, unchanged) |
| `mark-busy.sh` | 1 | safe (comment) |
| repo `lanes.sh` | ~8 | **all safe** — every one takes a directory basename |
| repo `agent-tune.sh` | 2 | safe (`:124` matches `agentType`, a role; `:287` takes a basename) |
| repo `agent-roles/team-lead.md` | — | role-doc filename, keyed by ROLE not name — safe |

**Total misrouting sites: 3, all in `team-boot.sh`.** Plus 3 classifier defects (3.4, 3.8×2)
that the prefix exposes rather than causes.

---

## 4. Sidecar / registry migration

**Nothing needs renaming. Everything needs orphan-sweeping.**

On the first boot after the flip, every agent registers under its new `g-` name and writes a
complete fresh set of sidecars. The old bare-name files are simply never read again. They are
not stale-harmful (no reader iterates the directory looking for lanes — `lane-guard.sh` and
friends all look up a *specific* name), but they are exactly the cross-project landmines this
rollout exists to remove, so sweep them.

**The trap: do NOT blanket-delete `~/.claude/agents/team-lead.*`.** That file may currently
belong to the `dotfiles` or `monocle` fleet, which are not being prefixed. Sweep by
**content**, not by name — `.cwd` says which project owns the entry:

```sh
# Fleet-down, all projects. DRY RUN FIRST — this prints, deletes nothing.
for f in ~/.claude/agents/*.cwd; do
  n="$(basename "$f" .cwd)"
  case "$n" in g-*) continue ;; esac                 # already migrated, keep
  grep -q '^/Users/john/git/goals-onchain' "$f" || continue   # not ours, KEEP
  echo "orphan: $n  ->  $(cat "$f")"
done
```

Then, once the listing is only goals-onchain lanes and subagents:

```sh
for f in ~/.claude/agents/*.cwd; do
  n="$(basename "$f" .cwd)"
  case "$n" in g-*) continue ;; esac
  grep -q '^/Users/john/git/goals-onchain' "$f" || continue
  rm -f ~/.claude/agents/"$n" \
        ~/.claude/agents/"$n".cwd \
        ~/.claude/agents/"$n".transcript \
        ~/.claude/agents/"$n".role \
        ~/.claude/agent-busy/"$n"
  rm -f ~/.claude/running-agents/"$n".*      # safe ONLY at fleet-down
done
```

Per-store notes:

- **`running-agents/<name>.<pid>`** — these are liveness entries. At a true fleet-down they
  should already be gone (`unregister-agent.sh` removes them on exit). Any survivor is a
  crash leftover. At preparation time there were 6 entries, of which `feature-1.47684`,
  `feature-2.52544`, `feature-3.58734`, `feature-4.46161`, `team-lead.41003` and
  `prefix-rollout.5435` — **re-check liveness before deleting any**, because the sweep above
  cannot tell a crash leftover from a live agent. `ps -p <pid>` is the check.
- **`agents/<name>.role`** — **none exist today** (verified: `ls ~/.claude/agents/*.role` →
  no matches). If any are created before the flip they must be renamed, not deleted, since
  they are hand-authored overrides. Re-check at apply time.
- **`agents/<name>`** (base-branch state) — regenerated on next boot from the live branch;
  safe to drop.
- **`agent-busy/<name>`** — transient by definition. At preparation time: `feature-1`,
  `feature-4`, `prefix-rollout`. All should be gone at fleet-down; delete any survivor.
- **`teams/session-*/`** — **leave entirely alone.** Session-keyed, already collision-free,
  and old sessions are the lead's `--continue` history. New sessions get `g-` members
  automatically.
- **Transcripts themselves** (`~/.claude/projects/...`) — not name-keyed. Untouched.

### Task-named subagents (`prefix-rollout`, `tmux-naming`, `audit-money`, …)

They register through the same pipeline (`register-agent.sh:495` routes **every** name
through `_normalize_name`), so they get `g-` for free and need no per-name handling. They are
the **least** collision-prone class — a name like `prefix-rollout` is unlikely to be chosen
concurrently in another repo — but they are not immune, and they benefit from the same
`rm -f running-agents/<name>.*` protection. The `~/.claude/agents/` listing at preparation
time held ~46 such entries, most long dead; the §4 sweep collects them all.

---

## 5. Verification

Run in order. Steps 1–3 need no fleet.

1. **Classifier, all names:**
   ```sh
   source ~/.claude/scripts/_fleet.sh
   for n in g-team-lead g-feature-1 g-feature-2 g-feature-3 g-feature-4 \
            g-reviewer g-tester g-planner g-prefix-rollout; do
     printf '%-18s role=%-10s id=%s\n' "$n" "$(fleet_resolve_role "$n")" "$(fleet_agent_id "$n")"
   done
   ```
   Expect: `g-team-lead`→team-lead/0 · `g-feature-N`→feature/f`N` ·
   **`g-reviewer`→review/pr1 · `g-tester`→test/test1 · `g-planner`→review/pr1** (these three
   are the §3.4 fix; they read `other`/`a1` before it) · `g-prefix-rollout`→other/a1.

2. **The three classifiers agree** — the §3.8 check. Run the same loop against
   `agent-identity.sh role` and `statusline-role.sh`; every name must resolve identically in
   all three. If you took the de-duplication option this is true by construction.

3. **Existing test suites** — these exist and cover this machinery; run them before booting
   anything:
   ```sh
   ~/.claude/hooks/register-agent.test.sh
   ~/.claude/scripts/statusline-role.test.sh
   ~/.claude/scripts/team-boot.test.sh
   ```
   `fleet-layout.test.sh` is **excluded deliberately** — it must be run manually and has
   corrupted a worktree twice; scratch-git tests must `unset GIT_DIR` first.

4. **Boot the lead alone**, then:
   ```sh
   ls ~/.claude/running-agents/          # expect g-team-lead.<pid>, and NO bare team-lead.*
   cat ~/.claude/agents/g-team-lead.cwd  # expect .../goals-onchain/.claude/worktrees/team-lead
   ~/.claude/scripts/team-boot.sh verify # expect "ok lead registered" — this is the 3.2:680 fix
   tmux list-windows                     # expect the tab still reads `team-lead`
   ```
   Check `~/.claude/register-agent.log` for `applied prefix: g-team-lead` and for the absence
   of any `prefix already present` on a **first** boot.

5. **Staff one lane**, then:
   ```sh
   ls ~/.claude/running-agents/   # expect g-feature-1.<pid>
   ```
   and confirm the teammate's report actually **arrives** — that is the live test of the §3.3
   reply address. A teammate that reports into the void is the exact symptom of an
   unprefixed `SendMessage to team-lead`.

6. **Ports and hosts unchanged** (proves lane identity survived):
   ```sh
   cd <lane>; .claude/scripts/lanes.sh list   # feature-2 must still read lane 2 / 8082 / 3002
   ```

7. **Cross-project non-interference — the whole point.** With the goals fleet up, boot the
   `monocle` or `dotfiles` lead and confirm *both* leads stay registered:
   ```sh
   ls ~/.claude/running-agents/   # expect BOTH g-team-lead.<pid> AND team-lead.<pid>
   ```
   Before this change, the second boot deleted the first's entry. **This is the only step
   that verifies the actual objective** — everything above only verifies nothing broke.

---

## 6. Rollback

Cheap and complete, because nothing is destroyed by the flip itself.

1. Fleet down.
2. Delete or comment `WORKFLOW_AGENT_NAME_PREFIX` in `.claude/workflow.config`.
3. `git checkout` the `team-boot.sh` / `_fleet.sh` / `fleet-layout.sh` /
   `agent-identity.sh` / `statusline-role.sh` edits.
4. Sweep the now-orphaned `g-*` sidecars with the §4 script, inverting the `case` guard
   (`case "$n" in g-*) ;; *) continue ;; esac`).
5. Boot. Names revert to bare on first registration.

**The §3.4 and §3.8 classifier fixes are worth keeping even on rollback** — they are correct
independently of the prefix (they fix `reviewer`/`tester`/`planner` and
`agent-identity.sh`'s `feature` fallback), and they break nothing when no prefix is set.
Same for §3.5 and §3.7.

**Point of no return: none.** The one genuinely irreversible step is the §4 orphan sweep, and
only for hand-authored `.role` overrides — of which there are currently zero. Take a
`tar czf ~/claude-agents-backup-<date>.tgz ~/.claude/agents ~/.claude/agent-busy
~/.claude/running-agents` before step 4 anyway; it is a few KB.

---

## 7. Open questions for John

1. **Tmux tabs: bare or prefixed?** §2 recommends bare (the tmux session is already the
   per-project boundary). The alternative diff is in §3.7, commented out.
2. **De-duplicate the three classifiers, or patch all three?** §3.8 recommends
   de-duplication; the fallback patch is written out in case statusline latency forbids
   sourcing `_fleet.sh`.
3. **Do the other two fleets get prefixes too** (`m-` for monocle, `d-` for dotfiles)? Not
   required — one prefixed fleet is enough to stop *this* project colliding with them — but
   `monocle` and `dotfiles` will still collide **with each other**, since both currently
   register a bare `team-lead`. This runbook is written to be re-runnable with a different
   prefix letter against a different repo's `workflow.config`.
