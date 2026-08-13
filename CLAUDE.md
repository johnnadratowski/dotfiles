# dotfiles — working notes for Claude

macOS dotfiles, installed by symlink. Nothing is copied: `./symlink.py` points `$HOME` paths at
files in this repo, so an edit here is live in the next shell. Files named `_foo` link to
`~/.foo`; anything else needs a row in `symlink.py`'s `EXTRA_FILES`.

## Before adding a config change, read this

**[docs/shell-config.md](docs/shell-config.md)** — the load order (`.zshrc` → `.shellrc` →
`~/scripts/init.sh`), a table saying which file a new env var / alias / function / secret goes
in, and the gotchas that have already cost a broken shell. Consult it rather than guessing a
file; several of them look interchangeable and are not.

The one rule it exists to enforce: **this repo carries machinery, the machine carries state and
secrets.** Secrets go in `~/local-startup/init.sh`, machine-local fleet paths in
`~/.claude/fleet.env`, per-repo Claude permissions in `.claude/settings.local.json` — none of
which are in this tree. Nothing that names one person's token, one machine's disk layout, or one
product's checkout is committed here.

`claude-config/` has its own [README](claude-config/README.md) applying the same split to
`~/.claude`, where machinery and runtime state share a directory.

## Conventions

- **Tests sit beside the thing they test**, as `<name>.test.sh` / `<name>.test.py`, hermetic
  (throwaway `$HOME`, temp dirs) and runnable directly: `bash claude-config/scripts/foo.test.sh`.
  `claude-config/exec-bit.test.sh` checks that every script that needs `+x` has it.
- **Comments carry the reasoning, not the mechanics.** The prevailing style in
  `claude-config/scripts` is a header block explaining *why the obvious implementation is wrong*
  — which failure it was written after, which alternative was tried. Match it; do not strip it.
- **Statusline widgets** (`claude-config/scripts/statusline-*.sh`) are ccstatusline
  `custom-command` entries in `ccstatusline-config/settings.json`. Contract: read the StatusJSON
  on stdin, print one short line, **always exit 0**, stay fast — they run on every repaint of
  every pane. Silence is the correct output when there is nothing to say.
- **Shell dialect**: `scripts/aliases.sh` and `scripts/env-vars.sh` are `#!/bin/sh` and are
  sourced by bash *and* zsh. `scripts/functions.sh` and the `claude-config` scripts are bash.
