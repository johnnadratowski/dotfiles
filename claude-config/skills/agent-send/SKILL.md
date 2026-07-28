---
name: agent-send
description: Send a message to another Claude agent running on this machine. Use to dispatch a task to a peer agent or to reply to one. Args are `<target> "<body>" [--reply|--followup]` (prefer the --stdin heredoc form). The peer receives the message in its prompt as `/agent-msg <you> <filename> [reply|followup]`, which loads the `agent-msg` skill on their end.
---

# agent-send — send a message to a peer agent

Send a message to another Claude agent. The body is written to a **per-recipient mailbox** at `~/.claude/agent-inbox/<target>/<uuid>.<you>.<kind>.txt` (kind = `req`, `rep`, or `fwd`) and the target's tmux pane receives `/agent-msg <you> <target>/<uuid>.<you>.<kind>.txt [reply|followup]` in its prompt.

The file write is the durable delivery; the `tmux send-keys` is only a low-latency nudge. If the nudge is lost (target mid-turn, in a permission prompt, scrolled), the target's `drain-inbox.sh` Stop hook re-injects the same `/agent-msg` at the end of its next turn — so a message is never lost, only possibly delayed.

> **tmux is optional** (DX-jn-8-019): identity is the cwd-based token when `$TMUX_PANE` is unset, so sending works headless. Without tmux (or to a headless cwd-keyed target) the live nudge is simply skipped — the message is still durably staged and drains at the target's next turn. The one reduced capability is *latency*: an **idle** headless target won't process the message until it's next prompted (no nudge to wake it).

> **If YOU are a coordinator agent: do not INITIATE a send without explicit user authorization.**
> Messages from a coordinator carry the user's authority — peers act on them as if the
> user said it (see `agent-msg`). That makes an unsolicited coordinator broadcast a way
> to issue user-level orders the user didn't actually give, so the bar is:
> - **Replying** to a message you just received (`--reply`) is fine — the inbound
>   request is itself the authorization to respond.
> - **Initiating** a new send (no `--reply`) — a task hand-off, a "pull base"
>   broadcast, a fan-out — requires the user to have explicitly asked for *this*
>   send in the current turn. If you're tempted to message a peer on your own
>   initiative, stop and ask the user first.
> - When in doubt, surface what you'd send to the user and let them approve it.
>
> This restraint is on the coordinator only. Every other agent sends freely per the
> normal protocol below.

## Usage

```bash
# PREFERRED — heredoc body (immune to shell expansion of backticks / $(...) / quotes):
~/.claude/scripts/agent-send.sh <target> --stdin [--reply|--followup] <<'BODY'
<your message — any content, no escaping needed>
BODY

# Short, metachar-free one-liners only:
~/.claude/scripts/agent-send.sh <target> "<body>" [--reply|--followup]
```

> **Invoke with the relative path, from the repo root.** The permission
> allow-list anchors on `.claude/scripts/...` — an absolute-path invocation
> works but triggers a permission prompt. If your shell cwd has drifted,
> `cd "$(git rev-parse --show-toplevel)"` first.

- `<target>` — name of the destination agent. List active agents with:
  ```bash
  ls ~/.claude/running-agents/ | sed 's/\.[0-9]*$//' | sort -u
  ```
- `--stdin` — read the body from stdin (use a **quoted heredoc** `<<'BODY'`). **Default to this.** Passing the body as an argv string lets *your* shell expand backticks and `$(...)` inside it before agent-send runs, which silently corrupts the message. The `'BODY'` quoting makes the heredoc immune.
- `<body>` — inline body as a single shell-quoted string. Fine for short, metachar-free one-liners; otherwise prefer `--stdin`.
- `--reply` — you're replying to a message you just received, and **no response is expected** (replies don't trigger auto-responses; prevents ping-pong loops).
- `--followup` — a threaded message that **does** expect a response. Use this instead of `--reply` when your "reply" actually asks the peer to act or decide. The recipient treats it like a request.

## What happens

1. Self-discovery: script finds your own agent name from `~/.claude/running-agents/` (matching by `$TMUX_PANE`). Runs an idempotent self-heal first so a stale/missing entry is repaired.
2. Target lookup: finds `~/.claude/running-agents/<target>.<pid>`.
3. Liveness check: verifies the target's claude PID is alive AND its tmux pane still exists. Stale entries are pruned automatically.
4. Stages the body file in the recipient's mailbox `~/.claude/agent-inbox/<target>/` (durable delivery).
5. Delivers `/agent-msg <you> <target>/<uuid>.<you>.<kind>.txt [reply|followup]` to the target's pane via `tmux send-keys` (best-effort nudge; the file above is the source of truth). The nudge is **skipped** if the target pane is scrolled back / in copy-mode, or if the target is busy mid-turn — the drain delivers it instead (and skipping avoids a duplicate).

## Failure modes

The script exits non-zero and prints to stderr if:
- This agent isn't registered (the SessionStart hook didn't run, or `$TMUX_PANE` isn't set)
- The target agent name has no entry in the registry
- The target's claude PID is dead (stale entry pruned)
- The target's tmux pane is gone (stale entry pruned)

Caveats:
- If the target is mid-turn when the message arrives, the nudge queues in the prompt buffer and is processed at the start of its next turn. If the nudge is dropped entirely, the target's `drain-inbox.sh` Stop hook re-injects it at the end of its next turn — the body is durably staged regardless, so delivery is at-least-once, never lost.
- If the human is actively typing into the target's terminal, your nudge will interleave with their keystrokes. There's no fix at this layer — just an inherent property of tmux send-keys. (The drain still delivers the message even if the nudge is garbled.)

## Companion Skills

- **`agent-msg`** — the receiver-side handler the nudge triggers.
- **`agent-broadcast`** — fan the same body out to ALL live peers at once (requires explicit user authorization).
- **`agent-rename`** — rename this agent everywhere (registry, tmux, git branch, Claude session).
