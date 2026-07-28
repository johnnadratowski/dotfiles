---
name: agent-rename
description: Rename this Claude agent everywhere — registry file, tmux pane title, Claude session name (via the built-in `/rename`), git branch, and the durable mailbox. The tmux window label is then recomputed by `fleet-layout.sh name-windows`, which owns window names. Use when the default name (current git branch at startup) isn't meaningful enough, or to disambiguate two agents on the same branch.
---

# agent-rename — rename this agent

```bash
~/.claude/scripts/agent-rename.sh <new-name>
```

## Effects

- Renames `~/.claude/running-agents/<old>.<pid>` to `~/.claude/running-agents/<new>.<pid>`.
- Renames the local git branch — tries the agent's recorded base branch first (from `~/.claude/agents/<old>`) via `git branch -m <base> <new>`; if no base recorded, falls back to renaming the currently-checked-out branch. Failures (branch already exists, checked out elsewhere) are reported but don't abort the rename of the agent identity.
- Moves the persistent base-branch file `~/.claude/agents/<old>` to `~/.claude/agents/<new>` and writes the new name into it. This is what the SessionStart hook uses to warn about "wrong branch" drift on future restarts. **Name-keyed sidecars migrate too** — `~/.claude/agents/<old>.role` (role override, honored by `register-agent.sh`, `agent-identity.sh`, `statusline-role.sh` and `cc-watcher-keepalive.sh`) and `~/.claude/agents/<old>.cwd` (cwd→self identity for the statusline, and the key `fleet-layout.sh` attributes companion panes by) are moved to `<new>.*`, so an override-classified agent keeps its role after the next SessionStart and both the statusline and the layout script follow the new name.
- Sets the current tmux **pane title** to `<new-name>` (right granularity when two Claudes share a window via splits). Pane titles show in the pane border if you've set `pane-border-status top|bottom` — turn it on with `tmux set -g pane-border-status top` if you want to see them.
- Recomputes the tmux **window** label by calling `~/.claude/scripts/fleet-layout.sh name-windows`, the sole owner of window names (DX-jn-cc-001). It derives each window's name from **all** of its resident live agents — one agent → its name, several of one role → the plural (`features`), mixed roles → sorted and hyphenated (`review-test`) — so a renamed agent's window updates without this pane stamping its own name over any co-tenants'. `register-agent.sh` calls the same function at SessionStart.
- Types `/rename <new-name>` + Enter into the current pane so Claude's own session name updates too (shown in the prompt box, `/resume` picker, and terminal title).
- Removes any prior `<new-name>.*` entries to honor the overwrite policy.

## Constraints

- `<new-name>` is sanitized: alphanumerics, dashes, and underscores. Slashes and other chars collapse to dashes. Empty after sanitization → error.
- **tmux is optional** (DX-jn-8-019): the registry / base-branch / mailbox rename works headless (identity is the cwd-based token when `$TMUX_PANE` is unset). Only the tmux pane/window title and the built-in `/rename` keystroke are skipped without tmux — the output says so.

## Examples

```bash
# Make a more descriptive name than the branch
~/.claude/scripts/agent-rename.sh researcher

# Disambiguate two agents on the same branch
~/.claude/scripts/agent-rename.sh main-coder
~/.claude/scripts/agent-rename.sh main-reviewer
```
