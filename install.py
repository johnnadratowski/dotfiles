#!/usr/bin/env python3
import os
import sys
from distutils.spawn import find_executable
import shutil
from subprocess import call
import platform
import shutil

SOURCE_BASE = os.path.abspath(os.path.curdir)
TARGET_BASE = os.path.expanduser("~")

EXTRA_FILES = {
    'scripts': None,
    'nvim': '.config/nvim',
    'zsh-custom/plugins/zsh-vim-mode.plugin.zsh': "./zsh-vim-mode/zsh-vim-mode.plugin.zsh",
    'zsh-custom/themes/agkozak.zsh-theme': "./agkozak-zsh-prompt/agkozak-zsh-prompt.plugin.zsh",
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


def run_files(fn, **extra):
    for f in os.listdir(SOURCE_BASE):
        if f.startswith("_"):
            fn(f)

    for extra_source, extra_target in extra.items():
        fn(extra_source, target_name=extra_target)


def update_submodules():
    if not find_executable('git'):
        print("Git not installed - unable to update submodules")
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
            print("Creating directory {dir}".format(dir=dir_))
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
