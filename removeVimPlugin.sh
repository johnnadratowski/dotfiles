#!/usr/bin/env bash
set -e

function main() {
    [[ -v $1 ]] && echo 'Must provide plugin name' && exit 1

    local p="_vim/pack/john/start/"
    local fp="${p}/${1}"
    git submodule deinit $fp
    git rm $fp
    rm -Rf .git/modules/$fp
}

main "$@"
