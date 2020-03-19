#!/usr/bin/env bash
sudo add-apt-repository universe
sudo apt-get install --yes zsh rake locate vim tmux vim-gtk python git meld virtualbox nodejs npm tree silversearcher-ag
sudo pip install virtualenv virtualenvwrapper watchdog fabric django ipython uwsgi fabtools fabuild shutter nodejs

sudo npm install -g diff-so-fancy

echo "Setting up powerline fonts for WSL: https://devpro.media/install-powerline-windows/#edit-your-powerline-configuration"

