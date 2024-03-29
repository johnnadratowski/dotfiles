# Allow for more file descriptors to be open by the shell.
# Helpful with node building
ulimit -n 10000

. $HOME/scripts/aliases.sh
. $HOME/scripts/env-vars.sh
. $HOME/scripts/functions.sh

# Init applications

# Ruby stuff
if which rbenv > /dev/null; then eval "$(rbenv init -)"; fi

[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" --no-use # This loads nvm

if [[ $ZSH_VERSION != "" ]]; then
  [ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
fi

[ -f ~/.ghcup/env ] && source ~/.ghcup/env

which pyenv 2>&1 > /dev/null && eval "$(pyenv init --path)"

if [ -f /usr/share/powerline/bindings/bash/powerline.sh ]; then
    powerline-daemon -q
    source /usr/share/powerline/bindings/bash/powerline.sh
fi
