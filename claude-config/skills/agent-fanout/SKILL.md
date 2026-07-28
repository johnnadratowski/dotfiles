---
name: agent-fanout
description: Orchestrate the agent fleet — show fleet status, fan a message or canned action out to a targeted set of peers (by role), and optionally force-restart idle agents (kill the pane's claude, relaunch with `claude --continue` to preserve context). Backed by `~/.claude/scripts/agent-fanout.sh` (one allow-listed command per action). High blast-radius; every fan-out needs explicit user authorization and every restart is confirmed first. Use for "show me the fleet", "tell the feature agents to merge down", "restart feature-2".
---

# agent-fanout — fleet orchestration

A higher-level wrapper over `/agent-send` / `/agent-broadcast` that knows the fleet's
**roles** (feature / coordinator, plus legacy review / test names — derived from agent names the same way
`register-agent.sh` does) so you can target a fan-out, see the fleet before acting, and
force-restart agents safely.

This is **high blast-radius**. Two hard gates:

- **Message fan-outs** need the user to have asked for *this* fan-out in the current turn
  (same rule as `/agent-broadcast`). If you merely think one would help, propose it with
  `status` / `--dry-run` and let the user approve.
- **Restarts ALWAYS ask first** — never kill+relaunch an agent without an explicit confirmation
  in this turn, even when relaying a coordinator instruction.

## Backing script

The mechanics live in **`~/.claude/scripts/agent-fanout.sh`** — one allow-listed command per
action, so you don't re-prompt on ad-hoc bash. Subcommands:

```
~/.claude/scripts/agent-fanout.sh status
~/.claude/scripts/agent-fanout.sh merge-down [--role R] [--exclude a,b] [--dry-run]
~/.claude/scripts/agent-fanout.sh send  [--role R] [--only a,b] [--exclude a,b] [--dry-run] --stdin <<'BODY' … BODY
~/.claude/scripts/agent-fanout.sh restart --yes [--clean] [--role R] [--only a,b] [--exclude a,b] [--dry-run]
~/.claude/scripts/agent-fanout.sh compact --yes [--threshold N] [--role R] [--only a,b] [--exclude a,b] [--dry-run]
```

The script always excludes self, idle-gates `restart`/`compact` (skips BUSY / copy-mode panes),
and `restart` relaunches with `claude --continue --name "<name>"` (no session-id needed — it
resumes the pane's latest conversation, name set at launch). **`restart` and `compact` refuse to run without `--yes`** — the human gate
below decides when to pass it; the allow-list removes the bash prompt, NOT the confirmation.

## Modes

```
/agent-fanout status                              # read-only fleet snapshot (no auth needed)
/agent-fanout msg --role <r> --stdin <<'BODY'…    # fan a message out to a role/set
/agent-fanout merge-down [--role all]             # canned: peers run /base-merge down
/agent-fanout restart [--role <r>|<names>]        # idle-gated, confirmed, claude --continue
/agent-fanout compact [--threshold N]             # idle-gated, confirmed, inject /compact into full agents
/agent-fanout resume-errored                      # nudge StopFailure-errored agents (e.g. rate-limited) to continue
```

**`resume-errored`** nudges agents that hit a `StopFailure` (rate-limit / overloaded /
server error) to **continue** — the common Anthropic-rate-limit case. Such an agent is
stopped at its prompt but alive; `mark-error.sh` cleared its busy marker and wrote
`~/.claude/agent-error/<name>`, so this action finds those and sends each a direct
"continue" nudge (no `--yes` — it only touches the narrow errored set; honours
`--role`/`--only`/`--exclude`, custom continue-text via `--stdin`). This is the **manual /
on-demand** path — the same sweep runs **automatically and continuously** in the
coordinator's always-on `inbox-watcher` (kept alive by the `cc-watcher-keepalive` hook),
which nudges **only retriable** categories (rate-limit / overloaded / server-error),
per-agent throttled (~2 min), so stuck agents self-heal without manual action. Use this
action to nudge *now* rather than wait for the next poll, or to override the category
filter / target set. **Blind spot (marker-based, by design):** an agent whose session
predates the `StopFailure` hook writes no marker — it's covered only after it merges-down
+ restarts.

Targeting flags (all modes): `--role feature|review|test|coordinator|all` · `--only name1,name2`
explicit list · `--exclude a,b` · `--dry-run`. `compact` adds `--threshold N` (default 80).

Roles are derived from the agent name via **dash-delimited segment matching** — the canonical
patterns live in `role_of()` in `agent-fanout.sh` / `resolve_role()` in `register-agent.sh`
(kept identical; a `test` segment → test, a `pr`/`review` segment → review, a `cc`/`coordinator`
segment → coordinator, else feature — `x-print` is NOT review). **You are never a target of your
own fan-out** (self is excluded by identity token).

## Mode: `status` (read-only — start here)

```bash
~/.claude/scripts/agent-fanout.sh status
```

No authorization needed; do this before any fan-out so you (and the user) see who's live, busy
(the busy window and role classification are the script's — do not re-derive them inline), and
on what branch. Report live agents grouped by role, flag STALE entries, and note who's BUSY or
ERR. This is the "look before you leap" step for the other modes.

> `agent-fanout.sh status` also prints a **`CTX`
> column** — each agent's main-loop context usage as `NN%` of its model's context window (`⚠`≥80%,
> `🔴`≥90%, `—` if unknown). It finds each agent's transcript **without requiring tmux**: it reads
> the `~/.claude/agents/<name>.transcript` / `<name>.cwd` sidecars that `register-agent.sh` records
> on every SessionStart, derives the project dir from the cwd, and takes the newest `*.jsonl`; tmux
> `pane_current_path` is only an **optional fallback** for agents that haven't re-registered since
> the sidecars were introduced. The window comes from `$WORKFLOW_CTX_WINDOW` (a global override)
> or, failing that, from the model id: an explicit window marker (`[1m]`) wins, else opus/sonnet
> at major version **≥ 4** → 1M, else 200k. (Deliberately not version-pinned — the earlier
> `"opus-4" in m` test sent every newer model to the 200k default and reported nonsense, e.g. a
> 1M-window session at 714k tokens shown as **357%**.) Use this to spot who is filling up and
> decide a `compact` (below) or a fanout.

## Mode: `msg` / canned actions — targeted message fan-out

The deliberate version of "broadcast, but only to the agents that should act."

1. **Resolve the audience.** From `status`, filter to the requested `--role` / names, drop self +
   `--exclude`. **Show the resolved recipient list and the exact body to the user and get explicit
   go** (unless they already named this exact fan-out this turn). `--dry-run` prints the list and stops.
2. **Deliver** by reusing the durable mailbox — one `/agent-send` per recipient (so each gets the
   at-least-once drain guarantee), or `/agent-broadcast` with `--exclude` for "all":
   ```bash
   for peer in $RECIPIENTS; do
     ~/.claude/scripts/agent-send.sh "$peer" --stdin <<'BODY'
   <the message>
   BODY
   done
   ```
   Use `--followup` instead of the default request-kind when you expect each peer to reply.
3. **Report** per-peer delivery (agent-send prints nudged/queued/failed).

**Canned actions** encode the rituals teams actually use:

- `merge-down` → body: "local `<base>` advanced — please `/base-merge down` to pick it up."
  Default audience: all feature/review/test peers (not the coordinator — it refreshes its own
  `cc` on demand). This is the standard **post-`/base-push` sync** — still gated on the
  user asking; after a push, *propose* it, don't auto-fire.
- `pause "<reason>"` → body: "pause — <reason> (e.g. rebasing the base). I'll ping when clear."

## Mode: `restart` — force-restart agents (idle-gated, always confirmed)

Kill an agent's `claude` in its pane and relaunch it with **`claude --continue --name "<name>"`**,
which resumes the pane's most recent conversation (no session-id lookup needed) — so context is
preserved, and the session name is set at launch (not by a post-launch `/rename` keystroke that a
high-context startup modal could swallow — DX-jn-8-024).
Useful when an agent is wedged, on a stale version of the skills/hooks, or needs a clean reload
without losing history.

> **Never restart without an explicit confirmation in this turn.** Restart kills the live process.
> Always show the plan and ask first.

How to run it: confirm with the user (show the candidate list — `agent-fanout.sh restart
--dry-run [targeting]` prints it), then:

```bash
~/.claude/scripts/agent-fanout.sh restart --yes [--role R] [--only a,b] [--exclude a,b]
```

What the script does per target (sequential, fail-contained):

1. **Idle-gate** — skips any agent with a fresh `~/.claude/agent-busy/<name>` marker or a pane in
   copy-mode (killing mid-turn loses in-flight work). To wait for a busy agent instead of skipping,
   poll with the **Monitor** tool until idle, then re-run.

   > **Recovery escape.** "Fresh" means newer than `WORKFLOW_BUSY_STALE_MIN` (default **30 min**),
   > and `restart`/`compact` have **no `--force`** — so an agent that CRASHED mid-turn without
   > clearing its marker is un-restartable for that whole window, which is a real cost for the
   > verb whose purpose is recovery. When you have confirmed the agent is genuinely dead (no
   > live pid in `~/.claude/running-agents/<name>.*`, pane idle), clear the marker by hand and
   > re-run: `rm ~/.claude/agent-busy/<name>`. Do **not** do this to skip the gate on an agent
   > that is merely slow — a long tool call is exactly what the window was widened to cover.
2. **Kill** — `tmux send-keys C-c` twice, then waits for the pid to exit. In current Claude Code the
   double-`C-c` often does NOT exit, so the script falls back to `kill <pid>` once the grace window
   passes. (SessionEnd fires either way → unregisters.)
3. **Relaunch** — `tmux send-keys 'claude --continue --name "<name>"' Enter` in the same pane.
   `--name` sets the session name at launch, which settles it before the hook's settle-recheck
   runs, so the fallback `/rename` keystroke is never reached.
   > There used to be a `WORKFLOW_AGENT_SKIP_RENAME=1` prefix here. It was redundant — `--name`
   > already makes the fallback unreachable — and harmful: it rides in the pane's shell
   > environment, so it outlived the startup it was scoped to and suppressed the fallback on
   > every later `/clear` in that pane. Removed (it needed a special case in `register-agent.sh`
   > just to undo itself). To fix a cleared agent's name, run `fleet-clear.sh` in its pane. The hook re-registers the agent (new
   pid) and re-injects its role context; `--continue` resumes the prior conversation. No session-id
   lookup needed.

   **`--clean` drops `--continue`** so the agent returns with a **fresh conversation**. Reach for it
   when shedding stale in-context state is the *point* of the restart — after a workflow or role
   change, resuming would carry the old assumptions forward and defeat the exercise. It **discards
   that agent's history**, so confirm it explicitly and separately from an ordinary restart; the
   role context is re-injected either way, and committed work is unaffected (it's in git).
4. **Verify** — polls for a NEW `<name>.<newpid>` registry entry on that pane; prints OK or a WARN
   (with the pane) if it didn't come back.

**Never restarts the caller** (self is always excluded). A coordinator on `cc` keeps its
`cc` name across `--continue` (the session `.name` persists), so no re-`/agent-rename` is needed.

## Mode: `compact` — partial-fanout compaction (idle-gated, always confirmed)

Inject `/compact` into the panes of agents whose context usage is **at/above a threshold** — the
"who's full → compact exactly those" action, paired with the `CTX%` column. `/compact` is a pane
action (not something the mailbox can trigger), so it's delivered via `tmux send-keys`, like `restart`.

```bash
~/.claude/scripts/agent-fanout.sh compact --dry-run [--threshold N]      # list who WOULD be compacted (+ their %)
~/.claude/scripts/agent-fanout.sh compact --yes [--threshold N] [targeting]
```

- **Audience** = live, non-self agents with `CTX% ≥ N` (default `N=80`). Below-threshold and
  context-unknown agents are listed as skipped, not compacted.
- **Idle-gated** — skips any BUSY / copy-mode pane (compacting mid-turn would interrupt in-flight
  work). To compact a busy agent, wait (Monitor until idle) and re-run.
- **Always confirmed** — like `restart`, it refuses without `--yes`. Show the user the `--dry-run`
  list (each target + its %), get explicit go, then pass `--yes`.
- Composes with the targeting flags and with `merge-down` (e.g. "merge-down, then compact the full
  ones"). **Never compacts the caller** (self excluded).

> **Why this matters:** an agent near its window auto-compacts on its own schedule (losing your
> control over *when*); a deliberate `compact` at a quiet moment (e.g. right after a merge-down,
> before handing out new work) keeps the summary boundary where you want it.

## Other useful behaviors (built in / suggested)

Built in (in `agent-fanout.sh`): read-only `status` (no auth), role/`--only`/`--exclude` targeting,
`--dry-run` everywhere, self-exclusion, idle-gating (skip BUSY/copy-mode), sequential restart via
`claude --continue` with re-registration verification, and the `--yes` tripwire on `restart`.

Worth considering (ask the user before adding — out of scope unless requested):

- **Auto-prune stale entries** during `status` (currently it only *reports* them).
- **Restart-on-version-drift**: detect agents whose `.claude/` is behind the local base (they
  haven't merged down the latest hooks/skills) and offer a targeted `merge-down` + restart.
- **Ack-collection**: for a `--followup` fan-out, watch each recipient's `*.rep.txt` and summarize
  who has/hasn't replied (reuse the `/afk` receipt-watching pattern via Monitor).
- **A background crash-watcher** that notices a `claude` pid vanished without `SessionEnd` and offers
  to relaunch — deliberately NOT built (a daemon doesn't belong in a hook, and it would still need
  the never-without-asking gate).

## What this skill will NOT do

- Fan out a message, restart, or compact anything without explicit user authorization in the current turn (the script's `restart`/`compact` refuse without `--yes`, which you pass only after confirming).
- Kill, restart, or compact a BUSY agent (idle-gated — skipped).
- Restart or compact the caller (self is always excluded).
- Touch `origin` (it only sends messages + manages local panes). Publishing stays `/base-push`.

## Companion skills

- **`agent-send`** / **`agent-broadcast`** — the delivery primitives this reuses.
- **`agent-msg`** — how recipients handle what you fan out.
- **`add-worktree`** — creates the agents (incl. the coordinator worktree on `cc`).
- **`afk`** — the receipt-watching / Monitor patterns the ack-collection idea would reuse.
