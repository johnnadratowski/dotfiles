#!/usr/bin/env zsh

readonly GREEN="\033[0;32m"
readonly END="\033[0m"

function log () {
  echo -e "${GREEN}\n======== $1\n${END}"
}

log "install oh my zsh"
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

log "Installing files"

./symlink.py

./brew_install.sh

log "Install NVim Python Modules"
pipx install --upgrade pynvim

log "Symlinking bin folders"
ln -s ~/scripts/lib/ocr ~/bin/ocr

log "Install powerline fonts"
(
  tmp="$(mktemp -d)"
  git clone git@github.com:Lokaltog/powerline-fonts.git "$tmp"
  $tmp/install.sh
)

log "Update PIP"
pip3 install --upgrade pip

log "Install favorite python packages"
pip3 install -r ./requirements.txt

log "Install NVM"
mkdir -p ~/.nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash

log "Install Cheat Sheet"
curl https://cht.sh/:cht.sh > ~/bin/cht.sh
chmod +x ~/bin/cht.sh

log "Install Claude Code"
curl -fsSL https://claude.ai/install.sh | bash

# Monocle is a LOCAL command, not a project resource, so it belongs to this machine rather
# than to any repo's `.mcp.json` -- and MCP servers cannot live in settings.json, so an
# install step is the only way dotfiles can own it. `-s user` writes `~/.claude.json`,
# which is machine state and deliberately not symlinked.
#
# The 2h timeout is the point of doing this at all: `get_feedback(wait=true)` blocks until
# a human answers, and at the default 1800s of MCP silence the wait aborted BEFORE the
# verdict rather than after it -- indistinguishable from an empty inbox, so an agent could
# read a dead listener as "no feedback" and walk past a gate nobody answered. Per-server,
# because long silence is correct for this one server and a hang everywhere else.
log "Register the Monocle MCP server (user scope, long wait timeout)"
claude mcp remove monocle -s user 2>/dev/null || true
claude mcp add-json monocle '{"command":"monocle","args":["serve-mcp","--experimental-channels"],"timeout":7200000}' -s user

curl https://cheat.sh/:zsh > ~/scripts/zsh/plugins/_cht

log "Setup Git Config"
git config --global user.email "john.nadratowski@gmail.com"
git config --global user.name "John Nadratowski"

log "install tpm"
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

log "installing tpm plugins"
~/.tmux/plugins/tpm/scripts/install_plugins.sh

log "compiling tmux-thumbs"
(
  cd ~/.tmux/plugins/tmux-thumbs
  cargo build --release
)

