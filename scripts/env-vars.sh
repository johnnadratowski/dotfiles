#!/bin/sh
# Contains all of the environment variables that should
# be exported in a new bash session

# Allow for more file descriptors to be open by the shell.
# Helpful with node building
ulimit -n 10000

if [ -d /opt/scripts/bash ]
then
	export PATH=$PATH:/opt/scripts/bash
fi

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
export DEFAULTPS1=${debian_chroot:+($debian_chroot)}\u@\h:\w\$

export PS1old="\n\e[33;1m###\e[0m \e[32;1m\w\e[0m | 
\e[34;1m\d \@\e[0m \e[33;1m###\e[0m \e[36m 
Unified Standard Dev Environment\e[0m\n\u@\H|(\e[31;1m\j\e[0m)\$>"

export LESSCHARSET='latin1'

if [ -f /usr/bin/lesspipe.sh ]
then

	export LESSOPEN='|/usr/bin/lesspipe.sh %s 2>&-'
   	export LESS='-i -N -w  -z-4 -g -e -M -X -F -R -P%t?f%f \
   	:stdin .?pb%pb\%:?lbLine %lb:?bbByte %bb:-...'
fi

export GIT_HOME=$HOME/git
export LIB_HOME=$HOME/lib
export CLASSPATH=$CLASSPATH:$LIB_HOME/closurecompiler:$LIB_HOME/

# Golang
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

# Python Stuff
#export PYTHONSTARTUP="$HOME/.pythonrc.py"
export PYTHONPATH='/usr/lib/python2.7/dist-packages/IPython/:$HOME/.pythonpath'
export WORKON_HOME=~/venv
export PROJECT_HOME=~/go/src/github.com/Unified/
export VIRTUALENVWRAPPER_PYTHON=/usr/local/bin/python3

# Ruby Stuff
if which ruby >/dev/null && which gem >/dev/null; then
    export PATH="$(ruby -rubygems -e 'puts Gem.user_dir')/bin:$PATH"
fi

# Node.js Stuff
export NODE_PATH='/usr/lib/node_modules/'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # This loads nvm

# Java stuff
export JAVA_HOME='/usr/lib/jvm/default'
