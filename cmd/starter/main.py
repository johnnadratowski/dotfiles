#!/usr/bin/env python
# Starter Projects
import argparse
import logging
import os
import shutil
import subprocess

import jinja2
from slugify import slugify

from lib import shell


def validate_args(args):
    os.makedirs(OUTDIR, exist_ok=True)
    if not os.path.exists(GIT_DIR):
        shell.info('Initializing git in output directory')
        subprocess.check_call(['git', 'init', OUTDIR])

    common = os.path.join(TEMPLATE_DIR, 'common')
    starter = os.path.join(TEMPLATE_DIR, args.starter)

    if not os.path.exists(starter):
        raise ValueError(f'Invalid starter {starter}.')

    return common, starter


def get_golang_conf(args, ans):

    golang_version = shell.ask(
        'Golang Version',
        color=shell.MAGENTA,
        default='1.9.2'
    )

    default_path = None
    gopath = os.getenv('GOPATH')
    if gopath and args.outdir.startswith(gopath):
        srcpath = os.path.join(gopath, 'src', '')
        default_path = OUTDIR[len(srcpath):]

    import_path = shell.ask(
        'Import Path (relative to GOPATH)',
        color=shell.MAGENTA,
        default=default_path
    )

    build_target = shell.ask(
        'Build Target (if applicable)',
        color=shell.MAGENTA,
        default=f'./{ans["PROJECT_SLUG"]}'
    )

    return dict(
        GOLANG_VERSION=golang_version,
        IMPORT_PATH=import_path,
        BUILD_FILE=os.path.basename(build_target),
        BUILD_TARGET=build_target
    )


def get_js_conf(args, ans):

    node_version = shell.ask(
        'Node Version',
        color=shell.MAGENTA,
        default='9.3.0'
    )

    return dict(NODE_VERSION=node_version)


def get_python_conf(args, ans):

    python_version = shell.ask(
        'Python Version',
        color=shell.MAGENTA,
        default='3.6.4'
    )

    return dict(PYTHON_VERSION=python_version)


def get_conf(args):

    shell.print_section(shell.GREEN, 'Project Configuration Wizard')

    proj_name = shell.ask(
        'Project Name',
        color=shell.MAGENTA,
        default=FOLDER_NAME
    )

    description = shell.ask(
        'Description',
        color=shell.MAGENTA,
        default=''
    )

    slug = slugify(proj_name)

    answers = dict(
        FOLDER_NAME=FOLDER_NAME,
        PROJECT_NAME=proj_name,
        PROJECT_SLUG=slug,
        DESCRIPTION=description,
    )

    proj_func = globals().get(f'get_{args.starter}_conf')
    if proj_func:
        shell.print_subsection(
            shell.GREEN,
            f'{args.starter.upper()} questions'
        )
        answers.update(proj_func(args, answers))

    shell.info("Wizard complete")

    return answers


def copy_file(f, out, conf):
    TEMPLATE_ENV.get_template(f).stream(**conf).dump(out)


def get_output_dir(parent, name):
    return os.path.join(parent, name)


def get_output_file(parent, name):
    if name == 'gitignore':
        name = '.gitignore'
    return os.path.join(parent, name)


def copy_dir(d, outdir, conf):
    os.makedirs(outdir, exist_ok=True)

    for item in os.listdir(d):
        i = os.path.join(d, item)

        if os.path.isdir(i):
            out = get_output_dir(outdir, item)
            copy_dir(i, out, conf)
        elif os.path.isfile(i):
            out = get_output_file(outdir, item)
            copy_file(i, out, conf)
        else:
            shutil.copy2(i, out)


def main(args):
    common, starter = validate_args(args)

    conf = get_conf(args)

    shell.info(f'Generating project output to {OUTDIR}')

    copy_dir(common, OUTDIR, conf)
    copy_dir(starter, OUTDIR, conf)

    shell.info('Project generated')

    os.chdir(OUTDIR)


if __name__ == '__main__':
    PARSER = argparse.ArgumentParser(
        description="Project Starter",
        epilog="Starts Projects",
        fromfile_prefix_chars='@')
    PARSER.add_argument(
        "starter",
        help="The starter project folder to use",
        metavar="STARTER")
    PARSER.add_argument(
        "outdir",
        help="The output directory",
        metavar="OUTDIR")
    PARSER.add_argument(
        "-v",
        "--verbose",
        help="increase output verbosity",
        action="store_true")
    ARGS = PARSER.parse_args()

    LOGLEVEL = logging.DEBUG if ARGS.verbose else logging.INFO
    logging.basicConfig(
        format="%(asctime)s %(levelname)s: %(message)s",
        level=LOGLEVEL)

    OUTDIR = os.path.abspath(os.path.expanduser(ARGS.outdir))
    GIT_DIR = os.path.join(OUTDIR, '.git')
    FOLDER_NAME = os.path.basename(OUTDIR)
    CUR_DIR = os.path.dirname(os.path.realpath(__file__))
    TEMPLATE_DIR = os.path.join(CUR_DIR, 'templates')
    LOADER = jinja2.FileSystemLoader(searchpath=['/', TEMPLATE_DIR])
    TEMPLATE_ENV = jinja2.Environment(loader=LOADER)

    try:
        main(ARGS)
    except KeyboardInterrupt:
        logging.info("Process interrupted by user")
    except SystemExit:
        pass
    except:
        logging.exception("An error occurred in main process")
