---
name: fleet-clear
description: Clear a fleet agent's context AND restore its session name in one step. Use when the user says "clear feature-2", "clear the fleet", "clear and rename <agent>" — a bare /clear silently drops the agent's name and the SessionStart auto-rename structurally cannot restore it. Drives /clear then /rename from another pane, so the keystrokes never race the human's typing.
---

# fleet-clear — clear an agent without losing its name

`/clear` drops the agent's session name, and nothing puts it back. This does both halves in
one sequenced action.

## Why a bare `/clear` loses the name

`register-agent.sh`'s settle re-check reads the session name from
`~/.claude/sessions/<pid>.json` — **keyed by PID**. `/clear` starts a new session inside the
**same process**, so that file still holds the *old* name. The settle compares it to
`boot_name`, sees a match, and correctly concludes there is nothing to do — while Claude
Code's actual new session is unnamed.

**The check is blind to the exact case it exists for, so waiting longer never helps.**
Observed on `feature-2`: cleared at `12:44:19`, settle at `12:44:24` logged
`settled name matches boot name 'feature-2' — no-op`, name gone.

That is also why the fix is not "make the auto-rename more patient". The keystroke fallback
it would use is fragile for a second reason: after clearing an agent you are usually typing
into that pane, and a delayed `tmux send-keys` interleaves with your keystrokes.

## Invocation

```
/fleet-clear <agent> [<agent> ...]     # clear + rename the named agents
/fleet-clear --role feature            # every agent of a role
/fleet-clear <agent> --dry-run         # show what would happen, touch nothing
```

**Run it from a different pane than the target** — normally the coordinator's. That is what
removes the typing race: you issue the command in one pane, the sends land in another.

## What the backing script does

```bash
~/.claude/scripts/fleet-clear.sh <agent> [...] [--role R] [--dry-run]
```

Per target, in order:

1. **Resolve** the pane + pid from `~/.claude/running-agents/`; skip if not live.
2. **Refuse self.** Clearing the caller would destroy the session issuing the command, and
   leave nothing to send the `/rename` or verify it.
3. **Idle-gate** — skip a BUSY agent (fresh `agent-busy` marker) or a pane in copy-mode.
   Clearing mid-turn discards in-flight work. Wait for idle and re-run.
4. **Send `/clear`.**
5. **Wait for the SessionStart** that the clear fires — detected as a new line in
   `~/.claude/debug/register-agent.log` — so the rename lands on the *new* session and not
   in the teardown window. On timeout (`WORKFLOW_CLEAR_SETTLE_TIMEOUT`, default 15s) it
   sends the rename anyway and says so: the clear already happened, and an unnamed session
   is the worse outcome.
6. **Send `/rename <name>`.**
7. **Verify** against `~/.claude/sessions/<pid>.json` (the pid is unchanged across a clear,
   so the path is stable). Reports `OK`, or `WARN` with what to fix by hand.

Exit non-zero if any target was skipped or failed to verify.

## What this skill will NOT do

- Clear the calling agent (always skipped).
- Clear a BUSY agent or a scrolled-back pane (idle-gated, like `restart`/`compact`).
- Restart anything — the process is untouched, only the conversation is cleared. To reload
  machinery from disk use `agent-fanout.sh restart`.
- Touch git or origin.

## Companion skills

- **`agent-fanout`** — `restart` (kill + `claude --continue`), `compact`, `status`.
  `restart` preserves history; this discards it.
- **`agent-rename`** — rename an agent (branch, registry, tmux, session) without clearing.

## Note on `WORKFLOW_AGENT_SKIP_RENAME`

`agent-fanout restart` launches with `WORKFLOW_AGENT_SKIP_RENAME=1 claude --continue --name
"<name>"`. The `--name` sets the name at launch, so the settle never reaches its keystroke
fallback and the flag is redundant on that path. It is also actively harmful: the env var
persists in the pane's shell, so a later `/clear` inherits it — which is why
`register-agent.sh` carries a special case clearing it for `clear` sources. Dropping the
flag from the restart command removes the root cause rather than patching around it.
