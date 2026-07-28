#!/usr/bin/env python3
import os
import sys
import shutil
from subprocess import call
import platform
import shutil

SOURCE_BASE = os.path.abspath(os.path.curdir)
TARGET_BASE = os.path.expanduser("~")

# Whole-file / whole-directory links. A directory may only appear here when EVERYTHING
# inside it is machinery -- see GLOB_LINKS below for the state/machinery rule.
EXTRA_FILES = {
    'scripts': None,
    'nvim': '.config/nvim',
    'zsh-custom/plugins/zsh-vim-mode.plugin.zsh': "./zsh-vim-mode/zsh-vim-mode.plugin.zsh",
    'zsh-custom/themes/agkozak.zsh-theme': "./agkozak-zsh-prompt/agkozak-zsh-prompt.plugin.zsh",
    'claude-config/settings.json': '.claude/settings.json',
    'claude-config/keybindings.json': '.claude/keybindings.json',
    'claude-config/commands/challenge.md': '.claude/commands/challenge.md',
    'claude-config/scripts': '.claude/scripts',
    'claude-config/output-styles': '.claude/output-styles',
    'claude-config/skills/monocle-pr-review': '.claude/skills/monocle-pr-review',
    'claude-config/skills/fleet-clear': '.claude/skills/fleet-clear',
    'ccstatusline-config/settings.json': '.config/ccstatusline/settings.json',
}

# Per-FILE links for directories that mix machinery with runtime state.
#
# THE RULE: dotfiles carries machinery; runtime state stays on the local machine. When a
# directory holds both, it must NOT be whole-dir linked -- link the machinery files
# individually and leave everything else alone.
#
# `~/.claude/agents` is the case that forced this. Claude Code reads subagent definitions
# from `<name>.md` there, but the fleet tooling ALSO writes its per-agent runtime records
# into the same directory: `<name>` (home branch), plus `<name>.cwd` / `<name>.transcript`
# / `<name>.role` sidecars that `register-agent.sh` rewrites on every SessionStart. That
# state is specific to one machine's fleet and must never land in this repo.
#
# This used to be `'claude-config/agents': '.claude/agents'` in EXTRA_FILES. Running it
# would have moved the live fleet state aside to `.dotfiles.bak` and pointed the directory
# at this repo -- silently breaking `agent-fanout status`, the base-branch drift warnings,
# and the CTX column, and thereafter dumping runtime writes into a tracked git tree. It had
# never actually run (the target was still a real directory), so the damage was pending
# rather than done.
#
# Definitions are FLATTENED into the target: the subdirectories here are for human
# organisation, and only top-level `*.md` is reliably discovered. Verified collision-free.
#
#   source-dir: (target-dir, glob, {basenames to skip})
GLOB_LINKS = {
    'claude-config/agents': ('.claude/agents', '*.md', {'README.md'}),
}

DIRS = [
    '~/bin',
    '~/git/',
    '~/go/',
    '~/tmp/vim-swap',
    '~/venv',
    '~/tmp/ipython',
]


def link_file(name, target_name=None):
    source = os.path.join(SOURCE_BASE, name)

    target_name = target_name or name
    if target_name.startswith("_"):
        target_name = target_name.replace('_', '.', 1)

    target = os.path.join(TARGET_BASE, target_name)

    if os.path.lexists(target):
        if not os.path.islink(target) or os.path.abspath(
                os.readlink(target)) != os.path.abspath(source):
            bak_file = target + ".dotfiles.bak"
            print(
                "Target exists. Backing up {target} to {bak_file}".format(
                target=target,
                bak_file=bak_file))
            shutil.move(target, bak_file)
        else:
            print(
                "Source {source} already linked from target {target}".format(
                source=source,
                target=target))
            return

    print("Linking {source} to {target}".format(source=source, target=target))

    if not os.path.exists(os.path.dirname(target)):
        os.makedirs(os.path.dirname(target))

    os.symlink(source, target)


def unlink_file(name, target_name=None):
    target_name = target_name or name

    if target_name.startswith("_"):
        target_name = target_name.replace('_', '.', 1)

    target = os.path.join(TARGET_BASE, target_name)

    if os.path.islink(target) and os.path.abspath(
            os.readlink(target)).startswith(SOURCE_BASE):
        os.unlink(target)

        bak_file = target + ".dotfiles.bak"
        if os.path.exists(bak_file):
            print(
                "Recovering backup file {bak_file}".format(bak_file=bak_file))
            shutil.move(bak_file, target)


def iter_glob_links():
    """Yield (source_rel, target_rel) for every GLOB_LINKS match, flattened.

    Walks recursively so organisational subdirectories work, but the link always lands at
    the top level of the target -- that is the only place Claude Code reliably discovers
    `*.md` definitions.
    """
    import fnmatch

    for source_dir, (target_dir, pattern, skip) in GLOB_LINKS.items():
        abs_source_dir = os.path.join(SOURCE_BASE, source_dir)
        if not os.path.isdir(abs_source_dir):
            continue
        for root, _dirs, files in os.walk(abs_source_dir):
            for f in sorted(files):
                if f in skip or not fnmatch.fnmatch(f, pattern):
                    continue
                rel = os.path.relpath(os.path.join(root, f), SOURCE_BASE)
                yield rel, os.path.join(target_dir, f)


# Entries that start with "_" but are NOT dotfiles to link. The leading-underscore
# convention collides with Python's own artifacts: `__pycache__` was being linked to
# `~/._pycache__` on every run.
SKIP_UNDERSCORE = {'__pycache__'}


def run_files(fn, **extra):
    for f in os.listdir(SOURCE_BASE):
        if f.startswith("_") and f not in SKIP_UNDERSCORE:
            fn(f)

    for extra_source, extra_target in extra.items():
        fn(extra_source, target_name=extra_target)

    for glob_source, glob_target in iter_glob_links():
        fn(glob_source, target_name=glob_target)


def update_submodules():
    call(["git", "submodule", "update", "--init", "--recursive"])
    call([
        "git", "submodule", "foreach", "--recursive", "git", "pull", "origin",
        "master"
    ])


def make_dirs(dirs):
    for dir_ in dirs:
        dir_ = os.path.abspath(os.path.expanduser(dir_))
        if not os.path.exists(dir_):
            print("Creating directory {dir}".format(dir=dir_))
            os.makedirs(dir_)


def main():
    update_submodules()

    if 'restore' in sys.argv:
        run_files(unlink_file, **EXTRA_FILES)
        return

    make_dirs(DIRS)

    run_files(link_file, **EXTRA_FILES)


if __name__ == '__main__':
    main()
