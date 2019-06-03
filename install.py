#!/usr/bin/env python
import os
import sys
from distutils.spawn import find_executable
import shutil
from subprocess import call
import platform
import shutil

from lib.python import shell

SOURCE_BASE = os.path.abspath(os.path.curdir)
TARGET_BASE = os.path.expanduser("~")

EXTRA_FILES = {
    'scripts': None,
    'zsh-custom/themes/unicandy.zsh-theme': ".oh-my-zsh/themes/unicandy.zsh-theme",
    '_zsh-theme': ".oh-my-zsh/themes/mine.zsh-theme",
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
            shell.warning(
                "Target exists. Backing up {target} to {bak_file}",
                target=target,
                bak_file=bak_file)
            shutil.move(target, bak_file)
        else:
            shell.info(
                "Source {source} already linked from target {target}",
                source=source,
                target=target)
            return

    shell.info("Linking {source} to {target}", source=source, target=target)

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
            shell.warning(
                "Recovering backup file {bak_file}", bak_file=bak_file)
            shutil.move(bak_file, target)


def run_files(fn, **extra):
    for f in os.listdir(SOURCE_BASE):
        if f.startswith("_"):
            fn(f)

    for extra_source, extra_target in extra.items():
        fn(extra_source, target_name=extra_target)


def update_submodules():
    if not find_executable('git'):
        shell.error("Git not installed - unable to update submodules")
        return
    call(["git", "submodule", "update", "--init", "--recursive"])
    call([
        "git", "submodule", "foreach", "--recursive", "git", "pull", "origin",
        "master"
    ])


def make_dirs(dirs):
    for dir_ in dirs:
        dir_ = os.path.abspath(os.path.expanduser(dir_))
        if not os.path.exists(dir_):
            shell.info("Creating directory {dir}", dir=dir_)
            os.makedirs(dir_)


def main():
    update_submodules()

    if 'restore' in sys.argv:
        run_files(unlink_file, **EXTRA_FILES)
        return

    make_dirs(DIRS)

    run_files(link_file, **EXTRA_FILES)

    if 'install' in sys.argv:
        if platform.system() == 'Darwin':
            call(['sudo', os.path.abspath('./brew_install.sh')])
        elif shutil.which('pacman'):
            call(['sudo', os.path.abspath('./pac_install.sh')])
        else:
            call(['sudo', os.path.abspath('./apt_install.sh')])

        call(['sudo', os.path.abspath('./install.sh')])


if __name__ == '__main__':
    main()
