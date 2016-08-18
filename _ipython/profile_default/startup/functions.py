import sys

###########################
# JSON Methods
###########################

import json
json.l = json.load
json.d = json.dump
json.ls = json.loads
json.ds = json.dumps

def prettydump(obj):
    json.d(obj, indent=4, sort_keys=True)
json.prettydump = json.pd = prettydump

def prettydumps(obj):
    json.ds(obj, indent=4, sort_keys=True)
json.prettydumps = json.pds = prettydumps


###########################
# Useful Methods
###########################


def ask(*args):
    """Wraps the input call so that it goes to stderr.

    This is so you can redirect the stdout to a file

    """
    old_stdout = sys.stdout
    try:
        sys.stdout = sys.stderr
        return input(*args)
    finally:
        sys.stdout = old_stdout


def re_ask(name, choices, default=None):
    while not default:
        default = ask("\n\t{}\n\nPlease choose the {}: ".format("\n\t".join(choices), name)).strip().lower()
        if not default in choices:
            print_err("Unrecognized {}: {}".format(name, default))
            default = None
    return default


def print_output(output, printit=True):
    """Print the output to the command line."""
    formatted = json.dumps(output, sort_keys=True, indent=4, separators=(',', ': '))
    if printit:
        print(formatted)
    return formatted


def print_err(output):
    print(output, file=sys.stderr)


