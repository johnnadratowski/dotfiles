#!/usr/bin/python
import os
import sys
import shlex
import shutil
from subprocess import call

SOURCE_BASE = os.path.abspath(os.path.curdir)
TARGET_BASE = os.path.expanduser("~")


def link_file(name, target_name=None):
    source = os.path.join(SOURCE_BASE, name)
    target_name = target_name or name.replace('_', '.', 1) if name.startswith("_") else name
    target = os.path.join(TARGET_BASE, target_name)
    if os.path.islink(target):
        return

    bak_file = target + ".jn.bak"
    if os.path.exists(target) and not os.path.islink(target):
        shutil.move(target, bak_file)

    print("Linking %s to %s" % (source, target))

    os.symlink(source, target)


def unlink_file(name, target_name=None):
    target_name = target_name or name.replace('_', '.', 1) if name.startswith("_") else name
    target = os.path.join(TARGET_BASE, target_name)

    bak_file = target + ".jn.bak"
    if os.path.islink(target):
        os.unlink(target)
        if os.path.exists(bak_file):
            shutil.move(bak_file, target)


def run_files(fn, start_char="_", **extra):
    for f in os.listdir(SOURCE_BASE):
        if f.startswith(start_char):
            fn(f)
        elif f in extra and extra[f]:
            fn(f, target_name=extra[f])
        elif f in extra:
            fn(f)


def main():
    if 'restore' in sys.argv:
        if os.path.exists(os.path.join(TARGET_BASE, ".oh-my-zsh/themes/mine.zsh-theme")):
            os.unlink(os.path.join(TARGET_BASE, ".oh-my-zsh/themes/mine.zsh-theme"))
        run_files(unlink_file, scripts=None)
    else:
        run_files(link_file, scripts=None)

        print("Updating submodules recursitvely")
        call(["git", "submodule", "update", "--init", "--recursive"])
        print("Pulling submodules recursitvely")
        call(["git", "submodule", "foreach", "--recursive", "git", "pull", "origin", "master"])

        source = os.path.join(SOURCE_BASE, "_zsh-theme")
        target = os.path.join(TARGET_BASE, ".oh-my-zsh/themes/mine.zsh-theme")

        if not os.path.exists(target):
            print("Linking %s to %s" % (source, target))
            os.symlink(source, target)

        source = os.path.join(SOURCE_BASE, "zsh-custom/themes/unicandy.zsh-theme")
        target = os.path.join(TARGET_BASE, ".oh-my-zsh/themes/unicandy.zsh-theme")

        if not os.path.exists(target):
            print("Linking %s to %s" % (source, target))
            os.symlink(source, target)


        if 'only-files' in sys.argv:
            return

        if not 'no-install' in sys.argv:
            call(shlex.split('mkdir -p '
                             '~/bin '
                             '~/git/ '
                             '~/opt '
                             '~/var/log/ '
                             '~/tmp/vim-swap '
                             '~/.pythonpath '
                             '~/venv '
                             '~/tmp/ipython'))

            if 'installer' in sys.argv:
                if 'apt' in sys.argv:
                    call(['sudo', os.path.abspath('./apt_install.sh')])
                elif 'brew' in sys.argv:
                    call(['sudo', os.path.abspath('./brew_install.sh')])
                else:
                    call(['sudo', os.path.abspath('./pac_install.sh')])

            call(['sudo', os.path.abspath('./install.sh')])

if __name__ == '__main__':
    main()
