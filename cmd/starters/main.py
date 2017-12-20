#!/usr/bin/env python
# Starter Projects
import argparse
import logging
import os
import shutil

import jinja2

from lib import shell


def get_conf(args):
    default_proj_name = os.path.basename(args.outdir)
    shell.info('Project Configuration', end='\n\n')
    proj_name = shell.ask('Project Name', default=default_proj_name)

    return dict(PROJECT_NAME=proj_name)


def copy_file(f, out, conf):
    TEMPLATE_ENV.get_template(f).stream(**conf).dump(out)


def copy_dir(d, outdir, conf):
    os.makedirs(outdir, exist_ok=True)

    for item in os.listdir(d):
        i = os.path.join(d, item)
        out = os.path.join(outdir, item)

        if os.path.isdir(i):
            copy_dir(i, out, conf)
        elif os.path.isfile(i):
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

    # Setup logging
    if ARGS.verbose:
        LOGLEVEL = logging.DEBUG
    else:
        LOGLEVEL = logging.INFO

    logging.basicConfig(
        format="%(asctime) %(levelname)s: %(message)s", level=LOGLEVEL)

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
