## Fleet ops (lead)

- Up = `/staff`, down = `/shutdown`; both take targets. Shell side is
  `~/.claude/scripts/team-boot.sh` (`boot [--session NAME]` · `status` · `down`).
- **`status` is the only liveness proof** — it resolves by process cwd. Busy markers go stale;
  a send proves nothing. **Teammates first, lead last.** Never `tmux kill-server`.
- Arrangement: `fleet-layout.sh`. What the team is doing: `fleet-status.sh` — the agent panel
  structurally cannot show it.

Detail: `~/.claude/agent-roles/reference/fleet-ops.md`.

## Refer to lanes by their labels

Every lane has a short speakable label — `ess` (lead), `vii`, `ott`, `woo`, `jaa`, … — from
`fleet_lane_display_name` in `_fleet.sh`. They appear in tmux window names and in
`fleet-status`.

**Use them when talking to the user about the fleet:** "ott hit a conflict", not "feature-2 hit
a conflict". The user reads a tab bar and a status console, and a one-syllable name is what is
legible there.

**Never use them as an address.** `SendMessage` routes by `feature-N` and nothing resolves a
label back to an agent. Say "ott (feature-2)" the first time in a report, then the label — the
same rule as a ticket id: resolvable on first use, short thereafter.
