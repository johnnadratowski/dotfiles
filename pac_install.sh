sudo pacman -S zsh rake mlocate vim gvim tmux gvim python2 git pgadmin3 guake meld python2-pip vagrant yaourt ack nodejs python-pip virtualbox qt4 vde2 virtualbox-host-dkms linux-headers linux-lts-headers docker
#sudo pip2 install virtualenv virtualenvwrapper watchdog fabric django ipython uwsgi fabtools fabuild 

# Install Hub
cd ~/git/
git clone https://github.com/github/hub.git
cd hub
sudo rake install prefix=/usr/local

# Install NVM
curl https://raw.githubusercontent.com/creationix/nvm/v0.19.0/install.sh | bash
