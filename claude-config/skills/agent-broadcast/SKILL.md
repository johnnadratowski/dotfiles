---
name: agent-broadcast
description: Broadcast one message to ALL live peer Claude agents on this machine in a single command (instead of a manual per-agent agent-send loop). Reuses agent-send per recipient, so delivery is the same durable per-recipient mailbox + nudge + drain. Use for fan-outs like "everyone merge down base" or "pause, rebasing base". High blast radius — requires explicit user authorization first.
---

# agent-broadcast — send one message to every live peer

Sends the same body to every registered agent whose claude PID **and** tmux pane
are still alive, except yourself and any `--exclude` names. Each delivery goes
through `agent-send.sh`, so it lands in the recipient's durable per-recipient
mailbox and is drained reliably — a broadcast is just a fan-out of normal sends.

## STOP — authorization gate

A broadcast reaches every agent at once, so it can issue de-facto orders to the
whole fleet. **Do NOT invoke this on your own initiative.** Only run it when:

- the **user explicitly asked for this fan-out in the current turn**, OR
- you are relaying a coordinator instruction that explicitly said to broadcast.

If you merely *think* a broadcast would help (e.g. after a merge), **surface the
proposed recipients and body to the user and let them approve first** — use
`--dry-run` to show who would receive it. After a `/base-push` or merge, do not
auto-broadcast; ask who to include (or whether to skip).

## Usage

```bash
# PREFERRED — heredoc body (immune to shell expansion):
~/.claude/scripts/agent-broadcast.sh --stdin [--followup] [--exclude a,b] <<'BODY'
<message to every peer — backticks / $(...) / quotes all safe>
BODY

# Preview recipients without sending anything:
~/.claude/scripts/agent-broadcast.sh --dry-run [--exclude a,b]
```

- `--stdin` — read the body from a quoted heredoc. Default to this (same reason as `agent-send`).
- `--followup` — send each as a followup (recipients are expected to respond). Default is a request.
- `--exclude a,b` — comma-separated agent names to skip (agents that shouldn't act on the fan-out).
- `--dry-run` — print the resolved recipient list and exit without sending. Use this to get user sign-off on the audience.

## What happens

1. Resolves your own name via `$TMUX_PANE` (so you're never in the list).
2. Enumerates registered agents, dedups by name, and keeps only those whose PID and tmux pane are both live.
3. Drops yourself and any `--exclude` names.
4. For each remaining peer, pipes the body to `agent-send.sh <peer> --stdin [--followup]`.
5. Reports per-peer success/failure and a final tally.

## Notes

- Exit status is non-zero if any individual send failed (the tally lists which).
- It does NOT collect replies — peers reply individually via `agent-send --reply`, which reach you through the normal `agent-msg` path.
- For a one-off to a single agent, just use `agent-send` directly; this is only worth it for true fan-outs.
