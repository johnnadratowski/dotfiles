#!/usr/bin/env zsh

readonly GREEN="\033[0;32m"
readonly END="\033[0m"

function log () {
  echo -e "${GREEN}\n======== $1\n${END}"
}

log "install oh my zsh"
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

log "Installing files"

./install.py

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

