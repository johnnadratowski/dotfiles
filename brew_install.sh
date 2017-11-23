#!/user/bin/bash
ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
brew update
brew install git mercurial zsh tmux vim python3 hammerspoon node npm

pip3 install -r ./requirements.txt
# Install Hub
cd ~/git/
git clone https://github.com/github/hub.git
cd hub
sudo rake install prefix=/usr/local

# Install NVM
curl https://raw.githubusercontent.com/creationix/nvm/v0.19.0/install.sh | bash

# Install native node apps
npm install -g nativefier

# Install custom electron apps
./apps/run.sh