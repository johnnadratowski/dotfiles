import argparse
import sys
import log
import json
import os
import time
import threading

import pyperclip


class ClipboardWatcher(threading.Thread):
    def __init__(self, history):
        super(ClipboardWatcher, self).__init__()
        self._history = history
        self._stopping = False

    def run(self):
        recent = ""
        while not self._stopping:
            tmp = pyperclip.paste()
            if tmp != recent:
                recent = tmp
                print("Found clipboard item: ", tmp)
                self._history.append(tmp)
            time.sleep(1)

    def stop(self):
        self._stopping = True


def load_history(history_conf):
    if os.path.exists(history_conf):
        try:
            history_file = file(history_conf, 'r')
        except:
            log.exception("Couldn't read history file")
            sys.exit(1)

        try:
            history_entries = json.load(history_file)
        except:
            log.exception("An error occurred loading history file")
            sys.exit(1)
    else:
        history_entries = []

    return history_entries


def cleanup(watcher, entries, args):
    json.dump(entries, args.history)
    watcher.stop()

def main(args):
    entries = load_history(os.path.abspath(args.history))

    watcher = ClipboardWatcher(entries)
    watcher.start()
    while True:
        try:
            print("Waiting for changed clipboard...")
            time.sleep(10)
        except KeyboardInterrupt:
            cleanup(watcher, entries, args)
            sys.exit(0)
        except:
            log.exception("An exception occurred during processing")
            cleanup(watcher, entries, args)
            sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='')
    parser.add_argument('--history', default="~/.cliphistory",
                    help='the clipboard history to load')

    args = parser.parse_args()
    main(args)
