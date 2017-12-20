#!/usr/bin/env python
'''{{DESCRIPTION}}'''
import argparse
import logging


def main(args):

    print("Hello there.")
    logging.info("You passed an argument.")
    logging.debug(f"Your Argument: {args.argument}")


if __name__ == '__main__':
    PARSER = argparse.ArgumentParser(
        description="Command Description",
        epilog="Command Epilog",
        fromfile_prefix_chars='@')
    PARSER.add_argument(
        "argument",
        help="pass ARG to the program",
        metavar="ARG")
    PARSER.add_argument(
        "-v",
        "--verbose",
        help="increase output verbosity",
        action="store_true")
    PARSER.add_argument(
        "-t",
        "--time",
        help="time",
        type="datetime.datetime")
    ARGS = PARSER.parse_args()

    # Setup logging
    LOGLEVEL = logging.DEBUG if ARGS.verbose else logging.INFO
    logging.basicConfig(
        format="%(asctime)s %(levelname)s: %(message)s",
        level=LOGLEVEL)

    try:
        main(ARGS)
    except KeyboardInterrupt:
        logging.info("Process interrupted by user")
    except SystemExit:
        pass
    except:
        logging.exception("An error occurred in main process")
