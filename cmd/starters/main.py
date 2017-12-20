#!/usr/bin/env python
# Starter Projects
import argparse
import logging
import os
import shutil

import jinja2
from slugify import slugify

from lib import shell


def get_conf(args):
    proj_name = os.path.basename(args.outdir).strip()
    proj_name = proj_name or os.path.basename(os.path.dirname(args.outdir))

    shell.print_section(shell.GREEN, 'Project Configuration Wizard')
    proj_name = shell.ask(
        'Project Name', color=shell.MAGENTA, default=proj_name)

    slug = slugify(proj_name)

    build_target = shell.ask('Build Target (if applicable)', color=shell.MAGENTA,
                             default=f'./{slug}')

    return dict(PROJECT_NAME=proj_name, BUILD_TARGET=build_target)


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
    common = os.path.join(TEMPLATE_DIR, 'common')
    starter = os.path.join(TEMPLATE_DIR, args.starter)

    if not os.path.exists(starter):
        raise ValueError(f'Invalid starter {starter}.')

    conf = get_conf(args)

    copy_dir(common, args.outdir, conf)
    copy_dir(starter, args.outdir, conf)


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
