# dotfiles

NOTE: This repo supports Mac only!  It could be fairly easily updated for Linux variants by adding a file for installing requirements replacing [brew_install.sh](brew_install.sh).  Some of the commands in aliases and functions in the `scripts` folder are mac specific too so you might be playing whack-a-mole with them.

To install: `./install.sh`

## Installation

- All files/dirs starting with `_(name)` get symlinked to `~/.(name)`.
- To explicitly symlink other objects, update [EXTRA_FILES](https://github.com/johnnadratowski/dotfiles/blob/master/symlink.py#L12) in [symlink.py](symlink.py).
- To explicitly create directories, update [DIRS](https://github.com/johnnadratowski/dotfiles/blob/master/symlink.py#L22) in [symlink.py](symlink.py).

## Shell

Uses [tmux](https://github.com/tmux/tmux/wiki) and [zsh](https://www.zsh.org/) with [oh-my-zsh](https://ohmyz.sh/).

The shell startup is in [.zshrc](_zshrc) calling [.shellrc](_shellrc) which will run [~/scripts/init.sh](scripts/init.sh) and a `~/local-startup/init.sh` for
startup files that shouldn't be in git.

Supports vim mode, but also has emacs type bindings when you navigate.

### Prompt

Uses the [agkozak](https://github.com/agkozak/agkozak-zsh-prompt) prompt with git integration.

## Vim

Extensively configures vim (vimscript) and neovim:

- vim-plug
- Using netrw with vim-vinegar
- CoC
- Leaderf
- Custom [Molokai theme](https://github.com/johnnadratowski/molokai)
- startify

## Hammerspoon

Extensively uses Hammerspoon for Mac automation.  I use Karabiner to map
CapsLock to Shift+ctrl+option+cmd for all the tools keybindings.
The tools are either ran using a hotkey or they run in the toolbar.

The [init.lua](_hammerspoon/init.lua) is the entry points.

List of tools:

- Caps + 4		- Use the mac screenshot tool to draw a screenshot, OCR any text in the screenshot and put it into the clipboard
- Caps + D		- Diff between last 2 copied texts (currently uses Pycharm, customizable using diff/diffargs constants)
- Caps + G		- Quick Google Search - Bring forward chrome in a new tab to start search
- Caps + P		- Run a ping command to 8.8.8.8, and output the delay in an alert
- Caps + C		- Open mac osx system color palette picker
- Caps + V		- Force pasting into a textbox by emulating keystrokes
- Caps + X		- If you have a string on your clipboard that's escaped with a lot of slashes, this will replace the slashes with their proper values and copy it to the clipboard
- Caps + Arrows - Tile window to halves and thirds
- Caps + 1,2,3  - Move current window to monitor 1, 2, or 3
- Caps + M		- Maximize current window
- Caps + T		- If there is a timestamp on the clipboard, show the date for that timestamp and copy that date to clipboard.  Else, show current timestamp and copy that to clipboard.
- Caps + L		- Lorem Ipsum Sentence Generator
- Caps + U		- Generate a new UUID4 and copy to clipboard
- Caps + N		- If you have a string on the clipboard which is a big number, hold this hotkey to format it in a human readable way
- Caps + B		- If you have a string on the clipboard which is number representing a file size, show the file size human readable
- Caps + S		- If you have a string on the clipboard which is a number representing seconds, show it in human readable format
- Caps + J		- Snippets
- Caps + K		- Notes - opens my notes.md file in my dropbox in macvim
- Caps + Z		- Toggle Docks
- Caps + Space  - Open/Show Terminal
- Caps + Return - Open/Show VSCode
- Caps + Tab	- Open/Show browser
- Caps + H		- Show Help
- Caps + `		- Show Hammerspoon Console
- Caps + R		- Reload Hammerspoon

List of toolbar tools:

- Caffienate icon in toolbar to keep laptop awake
- Mic icon in toolbar for enabling/disabling mic
