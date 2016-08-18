#!/bin/bash
# Install spf-13 vim
sh <(curl https://j.mp/spf13-vim3 -L)
vim +BundleInstall! +qall

# Install powerline fonts
cd /tmp/; git clone git@github.com:Lokaltog/powerline-fonts.git; cd powerline-fonts; ./install.sh; cd -

# asdf
# Install tern_for_node
#$cd ~/.vim/bundle/tern_for_vim/; npm install
