#!/usr/bin/env bash

# ====================================
# IMPORTS
# ====================================

. $(dirname ${BASH_SOURCE[0]})/../lib/log.sh

# ====================================
# FUNCTIONS
# ====================================

# Get the name of the current branch
function git_getCurrentBranch () {
    git branch | grep "\*" | cut -d' ' -f2 ||
    {
        log_exitError "An error occurred getting current git branch"
    }
}

