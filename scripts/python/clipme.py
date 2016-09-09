#!/usr/bin/env python3
import argparse
import json
import logging
import os
import subprocess
import tkinter as tk
import time



DATA = {
    'clips': []
}

ROOT = None


class ClipList(tk.Listbox):
    def __init__(self, *args, **kwargs):
        super().__init__(selectmode=tk.BROWSE, *args, **kwargs)
        for data in DATA['clips']:
            self.insert(tk.END, data['data'].strip())
        self._create_binds()

    def _create_binds(self):
        self.bind("<Double-Button-1>", self.take_item)
        self.bind("<Return>", self.take_item)

    def move_down(self, event):
        self.move(1)

    def move_up(self, event):
        self.move(-1)

    def move(self, num):
        selection = self.curselection()
        if selection:
            self.select_clear(selection[0])
            new_selection = selection[0] + num
            if new_selection < 0 or new_selection >= self.size():
                new_selection = 0
        else:
            new_selection = 0

        self.activate(new_selection)
        self.select_set(new_selection)

    def take_item(self, event):
        selection = self.curselection()
        if selection:
            write_clipboard(DATA['clips'][selection[0]]['data'])
            ROOT.destroy()


class UI(tk.Tk):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

        self._create_widgets()
        self._create_binds()

        self.attributes("-topmost", True)
        self.focus_force()

    def _create_widgets(self):
        self.clipList = ClipList(self)
        self.clipList.pack()

    def _create_binds(self):
        self.bind("<Control-j>", self.clipList.move_down)
        self.bind("<Control-k>", self.clipList.move_up)
        self.bind("<Return>", self.clipList.take_item)

# Create a Qt application
app = QApplication(sys.argv)

# Our main window will be a QListView
list = QListView()
list.setWindowTitle('Example List')
list.setMinimumSize(600, 400)


def read_clipboard():
    return subprocess.check_output(
        'pbpaste', env={'LANG': 'en_US.UTF-8'}).decode('utf-8')


def write_clipboard(output):
    process = subprocess.Popen(
        'pbcopy', env={'LANG': 'en_US.UTF-8'}, stdin=subprocess.PIPE)
    process.communicate(output.encode('utf-8'))


def poll_clipboard(max_clips=1000, data_path='~/.clip.me'):
    contents = read_clipboard()
    if not contents:
        return
    if DATA['clips'] and DATA['clips'][0]['data'] == contents:
        return

    logging.info("Got new clip: %s", contents)

    DATA['clips'].insert(0, {
        'data': contents,
        'at': int(time.time())
    })
    DATA['clips'] = DATA['clips'][:max_clips]

    with open(os.path.expanduser(data_path), 'w') as data_file:
        json.dump(DATA, data_file)


def start_server(args):
    while True:
        try:
            poll_clipboard(max_clips=args.max, data_path=args.data)
            time.sleep(0.3)
        except Exception as ex:
            print("Exception occurred in server loop: %s" % ex)


def start_server_async(args):
    from threading import Timer
    timer = Timer(args.poll, poll_clipboard, kwargs={'max_clips': args.max, 'data_path': args.data})
    timer.start()


def start_ui():
    global ROOT
    try:
        ROOT = UI()
        ROOT.mainloop()
    finally:
        try:
            ROOT.destroy()
        except:
            pass


def setup_args():

    parser = argparse.ArgumentParser()
    argument = parser.add_argument("--max", default=1000, type=int,
                                   help='The limit on the number of clips. Defaults to 1000.')
    parser.add_argument(
        '--poll',
        help="The polling interval in seconds. Defaults to 0.3.",
        default=0.3,
        type=float)
    parser.add_argument(
        '--data',
        help="The data file to use. Defaults to ~/.clip.me",
        default='~/.clip.me')
    parser.add_argument(
        '--ui',
        help="Run the UI",
        action="store_true")

    return parser.parse_args()


def start(args):
    global DATA

    try:
        data_path = os.path.expanduser(args.data)
        if os.path.exists(data_path):
            with open(data_path, 'r') as data_file:
                DATA = json.load(data_file)

        if args.ui:
            start_ui()
        else:
            start_server(args)
    except SystemExit:
        pass
    except:
        logging.exception("Exception occurred in main method")


if __name__ == "__main__":
    args = setup_args()
    start(args)
