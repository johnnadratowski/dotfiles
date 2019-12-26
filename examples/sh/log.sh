#!/bin/bash
# Contains functions for logging output in scripts
GREEN="$(tput setaf 10)"
RED="$(tput setaf 9)"
ORANGE="$(tput setaf 220)"
PURPLE="$(tput setaf 93)"
BLUE="$(tput setaf 21)"
RESET="$(tput sgr0)"

LOG_LEVEL=${LOG_LEVEL:-INFO}

gitBranch() {
	cd $1; git branch | grep "*" | cut -d " " -f 2; cd - &> /dev/null
}

# Write a debug to stderr
debug() {
	if [[ $LOG_LEVEL != "DEBUG" ]] ; then
		return 0
	fi

    local MSG=$1
    echo "${BLUE}$MSG${RESET}" 1>&2
}

# Write an info to stderr
info() {
	if [[ $LOG_LEVEL != "INFO" ]] && [[ $LOG_LEVEL != "DEBUG" ]] ; then
		return 0
	fi

    local MSG=$1
    echo "${GREEN}$MSG${RESET}" 1>&2
}

# Write a warning to stderr
warning() {
	if [[ $LOG_LEVEL != "INFO" ]] && [[ $LOG_LEVEL != "DEBUG" ]] && [[ $LOG_LEVEL != "WARNING" ]] ; then
		return 0
	fi

    local MSG=$1
    echo "${ORANGE}$MSG${RESET}" 1>&2
}

# Write an error to stderr
error() {
    local MSG=$1
    echo "${RED}$MSG${RESET}" 1>&2
}

LOG_LEVEL="`toUpper $LOG_LEVEL`"
if [[ $LOG_LEVEL != "INFO" ]] && [[ $LOG_LEVEL != "DEBUG" ]] && [[ $LOG_LEVEL != "WARNING" ]] && [[ $LOG_LEVEL != "ERROR" ]]; then
	echo "INVALID LOG LEVEL: $LOG_LEVEL"
	echo "MUST BE ONE OF [DEBUG, INFO, WARNING, ERROR]"
	kill 0
fi

ensureAWSCli() {
    if ! which aws > /dev/null ; then
        warning "AWS cli not found. Installing prerequisite AWS cli using brew"
        brew install awscli || {
            error "An error occurred using brew to install AWS cli. If not on mac osx install AWS cli manually."
            kill 0
        }
    fi

    if ! aws configure get aws_access_key_id > /dev/null ; then
        warning "AWS cli not configured. Starting configuration wizard"
        aws configure || {
            error "An error occurred configuring AWS cli."
            kill 0
        }
    fi
}

ensureJQ() {
    if ! which jq > /dev/null ; then
        warning "jq not found. Installing prerequisite jq using brew"
        brew install jq || {
            error "An error occurred using brew to install jq. If not on mac osx install jq manually: https://stedolan.github.io/jq/"
            kill 0
        }
    fi
}

