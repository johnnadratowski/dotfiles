sudo apt-get install zsh rake locate vim tmux vim-gtk python2.7 python2.7-dev python-pip git pgadmin3 guake meld python-pip virtualbox
sudo pip install virtualenv virtualenvwrapper watchdog fabric django ipython uwsgi fabtools fabuild shutter nodejs

cd ~/git/
git clone https://github.com/github/hub.git
cd hub
sudo rake install prefix=/usr/local

curl https://raw.githubusercontent.com/creationix/nvm/v0.19.0/install.sh | bash
