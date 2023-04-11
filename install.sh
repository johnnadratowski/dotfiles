#!/usr/bin/env zsh

readonly GREEN="\033[0;32m"
readonly END="\033[0m"

function log () {
  echo -e "${GREEN}\n======== $1\n${END}"
}

log "Installing files"

./install.py

if [[ "$OSTYPE" == "linux-gnu" ]]; then
	if which apt-get; then
		./apt_install.sh
	elif which pacman; then
		./pac_install.sh
	else
		echo "UNKNOWN PACKAGE MANAGER"
		exit 1
	fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
	./brew_install.sh
else
	echo "UNKNOWN OS $OSTYPE"
	exit 1
fi

log "Symlinking bin folders"
ln -s ~/scripts/lib/ocr ~/bin

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
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.3/install.sh | bash

log "Install Cheat Sheet"
curl https://cht.sh/:cht.sh > ~/bin/cht.sh
chmod +x ~/bin/cht.sh

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

log "install languagetool"
(
  cd ~
  wget https://languagetool.org/download/LanguageTool-5.9.zip
  unzip LanguageTool-5.9.zip
)

