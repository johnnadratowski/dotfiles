# claude-config

Claude Code configuration and fleet machinery, symlinked into `~/.claude` by `symlink.py`
at the repo root.

## The rule: machinery here, state on the machine

**Machinery** is anything you would want identical on a new laptop: scripts, hooks, skills,
subagent definitions, settings, keybindings. It is versioned, reviewed, and belongs in this
repo.

**State** is what a running fleet writes about itself on *this* machine: which agents are
live, what branch each considers home, which agents are mid-turn, which transcript
backs which pane. It is specific to one machine and one fleet, it changes many times a
minute, and it must **never** be committed here.

The split matters because Claude Code puts both under `~/.claude`, and in one directory it
puts them **side by side**:

| Path | Kind | Written by |
| --- | --- | --- |
| `~/.claude/settings.json`, `keybindings.json`, `output-styles/` | machinery | you (symlinked here) |
| `~/.claude/scripts/`, `commands/*.md`, `skills/<name>/` | machinery | you (symlinked here) |
| `~/.claude/agents/<name>.md` | machinery | you (symlinked here, per file) |
| `~/.claude/agents/<name>`, `<name>.cwd`, `<name>.transcript`, `<name>.role` | **state** | `register-agent.sh`, every SessionStart |
| `~/.claude/running-agents/`, `agent-busy/` | **state** | fleet tooling, continuously |
| `~/.claude/sessions/`, `projects/`, `debug/`, `*.log`, `*.pid`, `security/`, `telemetry/` | **state** | Claude Code itself |

## Two linking mechanisms, and when to use which

`symlink.py` has two maps, and picking the wrong one is how state leaks into the repo.

**`EXTRA_FILES`** — whole file or whole directory. Use it only when **everything** inside
the target is machinery. Safe: `scripts/`, `output-styles/`, an individual `skills/<name>/`.

**`GLOB_LINKS`** — per file, matched by glob. Use it when the target directory **mixes**
machinery and state. Each match is linked individually, so anything not matched is left
untouched.

`~/.claude/agents` is why `GLOB_LINKS` exists. Definitions are `<name>.md`; the fleet's
per-agent runtime records share the directory with no extension or a `.cwd` / `.transcript`
/ `.role` suffix. Linking `*.md` individually picks up exactly the definitions.

> **This was a live near-miss.** `claude-config/agents` used to be mapped whole-directory in
> `EXTRA_FILES`. It had never actually run — the target was still a real directory — but the
> next `symlink.py` would have moved the live fleet state aside to `agents.dotfiles.bak` and
> pointed `~/.claude/agents` at this repo, breaking `agent-fanout status`, the base-branch
> drift warnings, and the CTX column, and thereafter writing runtime files into a tracked
> git tree.

Definitions are **flattened** into `~/.claude/agents/`: subdirectories here (`engineering/`,
`design/`, …) are for human organisation, and only top-level `*.md` is reliably discovered.
Basenames must therefore stay unique across subdirectories.

## Adding fleet machinery

1. Put the file under `claude-config/` — scripts in `scripts/`, a skill as
   `skills/<name>/SKILL.md`, a subagent as `agents/<category>/<name>.md`.
2. Add the mapping to `symlink.py`: `EXTRA_FILES` for a pure-machinery file or directory,
   `GLOB_LINKS` for one that shares space with state.
3. Run `python3 symlink.py` (idempotent; backs up any real file it displaces to
   `<target>.dotfiles.bak`). `python3 symlink.py restore` unlinks and puts backups back.
4. Reference it from the `~` path, not a project-relative one — e.g.
   `~/.claude/scripts/fleet-clear.sh`. A project-relative path only resolves inside the
   repo that happens to carry a copy, which defeats having it here.

## What lives here today

| Path | Purpose |
| --- | --- |
| `settings.json` | user-level Claude Code settings, incl. the `SessionStart` hook that registers an agent in every project |
| `keybindings.json` | key bindings |
| `scripts/_fleet.sh` | canonical fleet helpers (`fleet_find_self`, `fleet_busy`, `fleet_resolve_role`, …) |
| `scripts/fleet-clear.sh` | run in an agent's **own** pane: clear its context and restore its session name (`/clear` alone silently drops it), or `--name-only` after clearing by hand. Self-targeting by design — nothing types into a pane you are using |
| `scripts/notify-end.sh`, `statusline-usage.sh` | statusline + notification helpers |
| `skills/fleet-clear/` | the skill wrapping `fleet-clear.sh` |
| `skills/monocle-pr-review/` | Monocle PR review skill |
| `commands/challenge.md` | the `/challenge` command |
| `agents/**/*.md` | subagent definitions, linked per file |
| `output-styles/` | output styles |

## Still vendored per-repo (not yet migrated)

Fleet machinery also exists inside consuming repos at `<repo>/.claude/` — scripts, hooks,
skills, agent roles — invoked by **repo-relative** paths (`.claude/scripts/lanes.sh`)
from skills, hook wiring, and permission allow-lists. Those copies are the ones that
actually run today.

Two consequences worth knowing before moving more of it here:

- **`scripts/_fleet.sh` now exists in both places.** This copy is canonical; the in-repo
  copy is the one that executes. They must be kept identical until the in-repo one is
  retired, or they will drift silently.
- **Propagation changes character.** In-repo machinery reaches each agent through a
  branch merge, so an agent's machinery matches the code it is working on. Machinery here
  is global and takes effect the moment it is edited — better for a hook fix, but a broken
  edit reaches every agent at once with no staging.
