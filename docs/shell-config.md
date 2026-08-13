# Shell configuration — where everything goes

Every shell on this machine funnels through **one shared layer**, so a change belongs in
exactly one file. This page says which. It is a map of what exists, not a proposal.

## Load order

```
zsh                              bash
  ~/.zshrc  → _zshrc               ~/.bashrc → _bashrc
      oh-my-zsh, theme, plugins        history/prompt/bash-only bits
      │                                │
      └──────────────┬─────────────────┘
                     ▼
              ~/.shellrc → _shellrc          ← the shared layer; both shells reach it
                     │
                     ├── ~/scripts/init.sh → scripts/init.sh      ← IN THIS REPO
                     │       ├── scripts/aliases.sh
                     │       ├── scripts/env-vars.sh
                     │       ├── scripts/functions.sh
                     │       └── rbenv · nvm · fzf · ghcup · pyenv · powerline
                     │
                     ├── ~/local-startup/init.sh                   ← NOT in this repo: secrets
                     └── google-cloud-sdk path + completion
```

After the shared layer, `_zshrc` continues with the things that only make sense in an
interactive zsh: the tmux auto-attach (`exec tmux new-session -A`), the `tm()` session
switcher, and `~/.claude/fleet.env`.

`~/.profile` → `_profile` is the login-shell entry point; for bash it just sources
`~/.bashrc`, which reaches the same shared layer.

## Where to put a new thing

| You want to add… | Put it in | Tracked? |
| --- | --- | --- |
| An environment variable, or a `PATH` entry | `scripts/env-vars.sh` | yes |
| An alias | `scripts/aliases.sh` | yes |
| A shell function (bash-compatible) | `scripts/functions.sh` | yes |
| A zsh-only interactive behaviour (keybind, prompt, tmux attach) | `_zshrc` | yes |
| A helper script you want on `PATH` | `scripts/lib/` (or `scripts/`) | yes |
| **A secret** — token, key, password | `~/local-startup/init.sh` | **NO — never** |
| A machine-local path that names one checkout | `~/.claude/fleet.env` | **NO** |
| Per-repo Claude permissions | `<repo>/.claude/settings.local.json` | **NO** |

### The rule behind the table

**This repo carries machinery; the machine carries state and secrets.** Anything whose value
names one person's token, one machine's disk layout, or one product's checkout does not belong
in a repo that gets cloned onto another machine.

There are three escape hatches for that, and they work differently:

- **`~/local-startup/init.sh`** — sourced by `_shellrc` right after the shared layer, so it can
  `export` anything and override anything set above it. It lives outside the repo entirely;
  there is nothing to gitignore because there is nothing in the tree. This is where API tokens
  and PATs go.
- **`~/.claude/fleet.env`** — machine-local fleet layout (`WORKFLOW_LANES_DIR` and friends).
  Read by `_zshrc`, by `_fleet.sh`, and by the hooks, whose environment is frozen at their
  claude's launch. Every entry defers to an existing environment variable, so a per-invocation
  `export` still wins.
- **`.claude/settings.local.json`** — per-repo Claude Code permissions. Ignored globally via
  `~/.config/git/ignore`, not per-repo, so it is invisible in *every* checkout without each one
  needing a rule.

## Symlinks

`./symlink.py` owns the mapping from repo path → `$HOME` path. Nothing is copied; every target
is a symlink back into this repo, so an edit here is live in the next shell.

- `EXTRA_FILES` — whole file or whole directory. `scripts` → `~/scripts`,
  `claude-config/scripts` → `~/.claude/scripts`, `_zshrc` → `~/.zshrc`, and so on. A directory
  may only appear here when *everything* inside it is machinery.
- `GLOB_LINKS` — per-file links for a directory that mixes machinery with runtime state.
  `~/.claude/agents` is the case that forced this: subagent definitions (`*.md`, ours) share the
  directory with per-agent runtime sidecars (`<name>.cwd`, `.transcript`, `.role`, written by
  `register-agent.sh` on every SessionStart). Whole-dir linking it would have dumped live fleet
  state into a tracked tree.

Adding a new dotfile means adding a row to `symlink.py` and re-running `./symlink.py`.

### `~/.claude/settings.json` gets un-symlinked by `monocle register`

Relinked 2026-08-13 after being found as a plain, diverged file. It will happen again, and the
writer is **not** Claude Code:

    monocle register
      → adapters.WriteJSONFile
        → WriteFileAtomic: os.WriteFile(path+".tmp"); os.Rename(tmp, path)

`os.Rename` onto a symlink **replaces the link**, so the repo copy silently stops being the live
one. The signature is unmistakable when you see it: Go's `json.Marshal` sorts map keys, so the
whole file comes back alphabetised, where Claude Code (Node) preserves insertion order. Register
also re-adds monocle's hooks with the absolute `/Users/john/bin/monocle` path that
`claude-config/hooks/monocle.sh` exists to avoid, and does not recognise the wrapper form as
already-registered — so `on-stop` ended up wired twice and fired twice per turn.

Fix in monocle would be one line: `filepath.EvalSymlinks` the path before the rename, so the
write lands on the real file and the link survives.

**Until then, after any `monocle register`: check `ls -la ~/.claude/settings.json` and re-link
if it is no longer a symlink.** Edits to `claude-config/settings.json` do nothing while it is
not. Every other Claude-side path — `hooks/`, `scripts/`, `output-styles/`, `keybindings.json`,
the ccstatusline config — is a live symlink and is unaffected.

### Freezing a setting against *any* writer

Claude Code does legitimately persist `/config`, `/model` and `/theme` changes into
`~/.claude/settings.json`; that is normal and cannot be turned off. What can be done is to move
the settings that must never drift up a tier, into the admin/policy file:

    /Library/Application Support/ClaudeCode/managed-settings.json     (+ managed-settings.d/)

That tier has the highest precedence, is never written by Claude Code, and is root-owned so
nothing user-level can rewrite it. The cost is real: it needs `sudo` to edit, it applies to every
project on the machine, and a key pinned there stops being changeable from `/config` at all.
Worth it for hooks and permissions; not worth it for the theme.

## Gotchas that have already bitten

- **An alias shadows a function name at definition time.** zsh expands the command word while
  parsing, so with `alias t='tree -L 1'` in scope, `t() {` parses as `tree -L 1 () {` and takes
  the rest of `.zshrc` with it. Grep `scripts/aliases.sh` before naming a function. (This is why
  the tmux session switcher is `tm`, not `t`.)
- **`PATH` is assembled in two places.** `_zshrc` line 3 puts Homebrew first so oh-my-zsh plugins
  can find brew tools during load; `scripts/env-vars.sh` then owns the canonical ordering. Add
  new entries to `env-vars.sh`.
- **`scripts/aliases.sh` and `scripts/env-vars.sh` are `#!/bin/sh`** and are sourced by both bash
  and zsh. `scripts/functions.sh` is `#!/bin/bash`. Keep bashisms out of the first two.
