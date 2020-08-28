# Allow for more file descriptors to be open by the shell.
# Helpful with node building
ulimit -n 10000

. $(dirname "$0")/aliases.sh
. $(dirname "$0")/env-vars.sh
. $(dirname "$0")/functions.sh

# Init applications

# Ruby stuff
if which rbenv > /dev/null; then eval "$(rbenv init -)"; fi

[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" --no-use # This loads nvm

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

[ -f ~/.ghcup/env ] && source ~/.ghcup/env

#[ -f /usr/local/bin/virtualenvwrapper.sh ] && source /usr/local/bin/virtualenvwrapper.sh

# added by travis gem
[ -f /Users/johnnadratowski/.travis/travis.sh ] && source /Users/johnnadratowski/.travis/travis.sh

which pyenv 2>&1 > /dev/null && eval "$(pyenv init -)"

if [ -f /usr/share/powerline/bindings/bash/powerline.sh ]; then
    powerline-daemon -q
    source /usr/share/powerline/bindings/bash/powerline.sh
fi
