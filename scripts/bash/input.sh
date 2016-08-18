# File containing all Readline and Bash options
# to set for a new bash shell session

set editing-mode vi
#set #common-prefix-display-length 1

# Adds punctuation as word delimiters
set bind-tty-special-chars off

set completion-display-width 2
set completion-ignore-case on
set completion-map-case on
set completion-query-items 200
set expand-tilde on
set mark-symlinked-directories on
set match-hidden-files on
set menu-complete-display-prefix on
set show-all-if-ambiguous on
set show-all-if-unmodified on
set visible-stats on

# Proper ALT key combinations
set meta-flag on
set input-meta on
set convert-meta on
set convert-meta off

$if mode=vi
    set keymap vi-command
    "gg": beginning-of-history
    "G": end-of-history

    set keymap vi-insert
    "\C-l": clear-screen
    "\C-w": backward-kill-word
    # auto-complete from the history
    "\C-p": history-search-backward
    "\C-n": history-search-forward
    "\C-s": yank-last-arg
    "\C-a":yank-last-arg
$endif

# IPython needs this to appear at the bottom of the
# file for clear-screen to work
set keymap vi
