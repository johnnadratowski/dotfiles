# shutdown — changelog

- **1.1.0** — **Takes targets.** `/shutdown feature-2` stops exactly that agent and skips step 4
  entirely, so the lead and the rest of the fleet keep running. Cycling one agent is now
  `/shutdown <lane>` then [`/staff`](../staff/SKILL.md) `<lane>`, with no fleet-wide restart.
  The ordering invariant is not opt-out-able by a target list: naming the lead still stops
  teammates first.

- **1.0.0** — Initial. Codifies the ordered fleet shutdown first run by hand on 2026-07-30,
  after `tmux kill-server` was rejected as the blunt instrument it is (it would have taken
  two unrelated Claude sessions in other windows).

  Three findings from that run are baked in rather than left to be rediscovered:

  1. **The native `shutdown_request` / `shutdown_response` protocol** (a `SendMessage` tool
     call) lets each agent decide from inside its own turn whether stopping is safe. Because
     it is a tool call, the orchestration cannot live in `team-boot.sh` — hence a skill.
  2. **It beats SIGTERM on accuracy, not politeness.** `team-boot.sh down` gates on the busy
     marker fail-closed; all four teammates carried ~4-hour-stale markers while idle, so
     `down` would have skipped the entire fleet. The agent's own reply is the only accurate
     liveness signal. `down --force` stays as the fallback for non-responders.
  3. **Teammate windows close themselves** (`remain-on-exit off`), so a lingering window is
     evidence the process did not exit — not something to clean up separately.

  Also fixes the lead's own exit: `respawn-pane -k` on its pane id, so the window survives at
  a shell instead of being destroyed with the last `kill-pane`.
