#!/usr/bin/env bash
set -e
sudo add-apt-repository universe
sudo apt-get update
sudo apt-get install --yes zsh rake locate vim tmux vim-gtk python git meld virtualbox nodejs npm tree silversearcher-ag python-pip python3 python3-pip
sudo pip install ipython ipdb
sudo pip3 install ipython ipdb
curl https://pyenv.run | bash

sudo npm install -g diff-so-fancy


echo "Setting up powerline fonts for WSL: https://devpro.media/install-powerline-windows/#edit-your-powerline-configuration"
echo "Install ripgrep"
