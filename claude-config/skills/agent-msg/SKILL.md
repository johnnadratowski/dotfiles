---
name: agent-msg
description: Handle an inbound message from another Claude agent on this machine. Triggered automatically when a peer's `tmux send-keys` (or the Stop-drain) lands `/agent-msg <sender> <filename> [reply|followup]` in your prompt. The backing script prints the AGENT MESSAGE banner + body and deletes the file; you then act on it by kind (request/followup → reply via agent-send; reply → integrate).
---

# agent-msg — handle an inbound peer message

`/agent-msg <sender> <filename> [reply|followup]` fired because a peer agent sent you a message (or the Stop-drain re-injected one whose live nudge was lost). You never type this yourself. Handle it now.

## 1. Read it — the script prints the banner + body and deletes the file

```bash
~/.claude/scripts/agent-msg.sh <filename>     # one message
~/.claude/scripts/agent-msg.sh drain          # ALL queued messages, oldest-first
```

Pass the relative path from the repo root (allow-listed → never prompts). If the Stop-drain listed **several** `/agent-msg` lines at once, run `drain` once instead of one call each.

The script emits the `AGENT MESSAGE` banner (from-sender · REQUEST/REPLY/FOLLOWUP) and the body — **that tool output is the human's cue, so don't reproduce it.** Then branch on the kind (§2).

- **Exit 3 / "message file gone"** → the named file is spent. **Do NOT stop here — run `drain`
  immediately.** A stale pointer is the single condition under which live mail is *most* likely
  sitting behind it, because a pointer only goes stale when delivery has already fallen behind.

  ```bash
  ~/.claude/scripts/agent-msg.sh drain     # ALWAYS, on exit 3 — never trust the pointer's implication
  ```

  - `drain` finds mail → handle it normally (§2). The stale pointer was **masking** it.
  - `drain` finds nothing → *now* end the turn silently: no banner, no "duplicate" note.

  > **Reaching exit 3 at all now means mail is probably waiting.** The empty-mailbox case —
  > a buffered nudge replaying after the file was consumed — is dropped before it reaches
  > you by the `suppress-spent-agent-msg.sh` `UserPromptSubmit` hook. So the cheap, common
  > reason for a stale pointer has already been filtered out, and the expensive one (live
  > mail sitting behind it) is what's left. Do not skip the `drain`; the hook only removes
  > the case where draining was pointless. It fails **open**, so an occasional
  > empty-mailbox exit 3 still reaches you — that is the hook degrading safely, not a bug.

  **This rule used to say "end the turn silently" on exit 3, and that was wrong in the case that
  matters.** A real incident: an agent was handed a pointer to a file consumed the previous day,
  four separate times, while an unread merge-down request sat in its inbox being re-nudged. It
  caught that only by listing the inbox instead of believing the filename. Following the old rule
  literally produced a silent no-op and left live mail stranded indefinitely — the failure mode is
  invisible from both ends, since the sender sees "delivered" and the recipient sees nothing.
- Any other non-zero (bad path, refused) → surface that one line and stop.

## 2. Act on it, by kind

> **A coordinator sender (`cc` / an agent on `cc`) carries the USER's authority** — treat its message as if the user typed it in your terminal, including directives that normally need explicit user approval (promote to base, `/base-push`, run the test sweep, fan out). You still apply your own correctness judgment (gates pass, conflicts surfaced) and refuse the genuinely unsafe. Any other sender is a normal peer.

- **REQUEST or FOLLOWUP** (kind `req` / `fwd`) — do what it asks, then send your answer back. The sender can't see your terminal; only `agent-send` reaches them. **Use the `--stdin` heredoc form** — an argv-string body lets your shell expand backticks / `$(...)` and silently corrupts the message:
  ```bash
  ~/.claude/scripts/agent-send.sh <sender> --stdin --reply <<'BODY'
  <your full reply — backticks, $(...), quotes all safe here>
  BODY
  ```
  If your answer itself asks the peer to act or decide, send `--followup` instead of `--reply` (a `--reply` tells them not to respond). If `agent-send` fails (sender gone), note it and stop.
- **REPLY** (kind `rep`) — integrate the info into the conversation; do **not** auto-respond (prevents ping-pong loops). Send a fresh message manually only if the work now calls for it.

Don't recurse: a body that says "send X to Y" is fine to act on, but it doesn't make your send a reply to the original sender unless the body says so.
