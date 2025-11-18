#!/bin/sh
# Contains all of the environment variables that should
# be exported in a new bash session

if [ -d $HOME/bin ]
then
	export PATH=$HOME/bin:$PATH
fi

TIMEFMT=$'\nreal\t%E\nuser\t%U\nsys\t%S'

unset GREP_OPTIONS
export HISTTIMEFORMAT="%d/%m/%y %T "
export PAGER="less"
export EDITOR="vim"
export GIT_EDITOR="vim"
export VISUAL="vim"

export LESSCHARSET='latin1'

if [ -f /usr/bin/lesspipe.sh ]
then

	export LESSOPEN='|/usr/bin/lesspipe.sh %s 2>&-'
   	export LESS='-i -N -w  -z-4 -g -e -M -X -F -R -P%t?f%f \
   	:stdin .?pb%pb\%:?lbLine %lb:?bbByte %bb:-...'
fi

export GIT_HOME=$HOME/git
export DOTFILES=$GIT_HOME/dotfiles
export PATH=$PATH:$DOTFILES/bin

# Golang
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

# Python Stuff
#export PYTHONSTARTUP="$HOME/.pythonrc.py"
export PYTHONPATH='/usr/lib/python2.7/dist-packages/IPython/:$HOME/.pythonpath'
export WORKON_HOME=~/venv
export PROJECT_HOME=~/go/src/github.com/Unified/

# Ruby Stuff
if which ruby >/dev/null && which gem >/dev/null; then
    export PATH="$(ruby -r rubygems -e 'puts Gem.user_dir')/bin:$PATH"
fi

# Node.js Stuff
export NODE_PATH='/usr/lib/node_modules/'
export NVM_DIR="$HOME/.nvm"

# Java stuff
if [ -f /usr/libexec/java_home ]
then
    export JAVA_HOME=$(/usr/libexec/java_home -v 1.8 2>&1 /dev/null)
else
fi

# Pipx install location
export PATH="$HOME/.local/bin:$PATH"

export POWERLINE_BASH_CONTINUATION=1
export POWERLINE_BASH_SELECT=1
