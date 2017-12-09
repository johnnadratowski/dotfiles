#!/bin/sh
# Contains all of the aliases that should be
# loaded in a new bash shell session

# zsh specific aliases
if which zstyle &> /dev/null; then
  # Make zsh know about hosts already accessed by SSH
  alias zshrc='vim ~/.zshrc' # Quick access to the ~/.zshrc file
  zstyle -e ':completion:*:(ssh|scp|sftp|rsh|rsync):hosts' hosts 'reply=(${=${${(f)"$(cat {/etc/ssh_,~/.ssh/known_}hosts(|2)(N) /dev/null)"}%%[# ]*}//,/ })'

  # Command line head / tail shortcuts
  alias -g H='| head'
  alias -g T='| tail'
  alias -g G='| grep'
  alias -g L="| less"
  alias -g M="| most"
  alias -g LL="2>&1 | less"
  alias -g CA="2>&1 | cat -A"
  alias -g NE="2> /dev/null"
  alias -g NUL="> /dev/null 2>&1"
  alias -g P="2>&1| pygmentize -l pytb"
fi

# sudo aliases
alias please='sudo $(fc -ln -1)'
alias _='please'

#-------------------------------------------------------------
## The 'ls' family (this assumes you use a recent GNU ls)
##-------------------------------------------------------------
alias ls='ls -hFG' # add colors for filetype recognition
alias ll="ls -l"
alias l="ll"
alias ldot='ls -ld .*'    # show only hidden files
alias la='ll -A'          # show hidden files
alias lag='la | g '       # grep for patter of name in current dir
alias lx='ll -XB'         # sort by extension
alias lk='ll -Sr'         # sort by size, biggest last
alias lc='ll -tcr'        # sort by and show change time, most recent last
alias lu='ll -tur'        # sort by and show access time, most recent last
alias lt='ll -tr'         # sort by date, most recent last
alias lm='ll -a |more'    # pipe through 'more'
alias lr='ll -R'          # recursive ls
alias lmr='ll -aR |more'  # recursive pipe through 'more'

# Tree Aliases
alias tree='tree --dirsfirst -C'
alias t='tree -L 1'
alias ta='t -a'
alias t2='tree -L 2'
alias t2a='t2 -a'
alias t3='tree -L 3'
alias t3a='t3 -a'

#scrolling aliases
alias less='less -R'
alias more='less'
alias m='less'

# file command aliases
alias rm='rm -i'
alias mv='mv -i'
alias cp='cp -i'
alias rmf='rm -f'
alias rmrf='rm -rf'
alias mvf='mv -f'
alias cpf='cp -f'
alias mkdir='mkdir -p'

# git aliases
alias gfp='git fetch --all; git pull'
alias gfpm='git fetch --all; git checkout master; git pull; git checkout -'
alias gmm='gfpm; git merge master'
alias gfpm='git fetch --all; git checkout develop; git pull; git checkout -'
alias gmd='gfpm; git merge develop'
alias gcob='gco -b '
alias gst='git st'
alias gacp='gadd && gci && gpush'
alias gacpwip='gacpm "WIP"'
alias gitdot='cdd && gacpwip && cd -'

# networking aliases
alias ports='netstat -tulpn'

# history/command aliases
alias h='history'
alias hgrep="fc -El 0 | grep"
alias help='man'

# jobs aliases
alias j='jobs -l'

# directory movement
alias cd~='cd ~'
alias cd-='cd -'
alias cdsop='cd ~/git/sop/unified_platform/'
alias cdgo='cd ~/go/src/github.com/Unified'
alias cds='cd ~/scripts/'
alias cdg='cd ~/git/'
alias cdd='cd ~/git/dotfiles/'
alias cdb='cd ~/bin/'
alias ..='cd ..'
alias ..2='cd ../..'
alias ..3='cd ../../../'
alias ..4='cd ../../../../'
alias ..5='cd ../../../../../'
alias ..6='cd ../../../../../../'
alias ..7='cd ../../../../../../../'
alias ..8='cd ../../../../../../../../'
alias ..9='cd ../../../../../../../../../'

#command admin util aliases
alias du='du -kh'       # Makes a more readable output.
alias df='df -kTh'

# command aliases
alias lns='ln -s'
alias px='ps aux'
alias sur='sudo su -'
alias rbProf='source ~/.zshrc'

#MAC stuff
alias setJdk6='export JAVA_HOME=$(/usr/libexec/java_home -v 1.6)'
alias setJdk7='export JAVA_HOME=$(/usr/libexec/java_home -v 1.7)'
alias setJdk8='export JAVA_HOME=$(/usr/libexec/java_home -v 1.8)'

#when ran from a location, shares out that location on port 8000
alias pysrv='python -m SimpleHTTPServer'
alias setPython2='export PY_PATH=$(which python); sudo rm -f $PY_PATH && sudo ln -s $(which python2) $PY_PATH'
alias setPython3='export PY_PATH=$(which python); sudo rm -f $PY_PATH && sudo ln -s $(which python3) $PY_PATH'

venwrap=`command -v virtualenvwrapper.sh`
VIRTUALENVWRAPPER_PYTHON=/usr/local/bin/python3
if [ "$venwrap" != "" ]; then
    source $venwrap
fi
