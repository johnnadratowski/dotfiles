#!/bin/sh
# Loads all the custom scripts that should be ran 
# for a new bash shell session

echo "Loading all startup scripts"

mkdir -p ~/tmp/log

source $1/aliases.sh $1
source $1/env-vars.sh $1
source $1/functions.sh $1
source $1/binds.sh $1
source $1/mounts.sh $1
if [ $SHELL = "/bin/sh" ]; then
    # Only run the django bash-completion script if in bash
    source $1/django_bash_completion.sh $1
fi

echo "Startup scripts loaded"
