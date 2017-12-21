#!/bin/bash

##############################################
######### SETUP
##############################################

UPDATED=0
if ! command -v git >/dev/null 2>&1; then
    echo "INSTALL GIT"
    (( UPDATED  == 0 )) && apt-get update
    UPDATED = 1
    apt-get -y install git
fi

if ! command -v hg >/dev/null 2>&1; then
    echo "INSTALL MERCURIAL"
    (( UPDATED  == 0 )) && apt-get update
    UPDATED = 1
    apt-get -y install mercurial
fi

###############################################
######### BUILD STEPS
###############################################

if ! command -v go >/dev/null 2>&1; then
    echo "INSTALLING GO"
    cd /tmp/
    wget -q https://storage.googleapis.com/golang/go{{GOLANG_VERSION}}.linux-amd64.tar.gz
    tar -C /usr/local -xzf go{{GOLANG_VERSION}}.linux-amd64.tar.gz
    ln -s /usr/local/go/bin/go /usr/bin/go
    mkdir -p /go/src/github.com/Unified
    ln -s /srv/unified/task-monitor/ /go/src/github.com/Unified/task-monitor
    
    chown -R vagrant:vagrant /go/
    chown -R vagrant:vagrant /srv/
    
    # Helps when ssh'ing into the box
    echo "export PATH=$PATH:/go/bin" >> /home/vagrant/.bashrc
    echo "export GOPATH=/go/" >> /home/vagrant/.bashrc
    
    echo "cd /{{FOLDER_NAME}}" >> /home/vagrant/.bashrc
fi

# echo "BUILDING Task Monitor"
# cd /go/src/github.com/Unified/task-monitor
# GOPATH=/go/ /go/bin/godep go build -o ./task-monitor-linux-amd64