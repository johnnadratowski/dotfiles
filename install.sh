#!/usr/bin/env zsh

readonly GREEN="\033[0;32m"
readonly END="\033[0m"

function log () {
  echo -e "${GREEN}\n======== $1\n${END}"
}

log "Install spf-13 vim"
sh <(curl https://j.mp/spf13-vim3 -L)

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
curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.33.11/install.sh | bash

log "Install native node apps"
npm install -g nativefier

log "Install custom electron apps"
(
  cd ./apps/
  ./run.sh
)

log "Install Cheat Sheet"
curl https://cht.sh/:cht.sh > ~/bin/cht.sh
chmod +x ~/bin/cht.sh

curl https://cheat.sh/:zsh > ~/scripts/zsh/plugins/_cht

log "install tpm"
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

log "link table script to bin"
ln -s ~/git/dotfiles/lib/bash/table.sh ~/bin/table
