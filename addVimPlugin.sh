#!/usr/bin/env bash
set -e

function main() {
    [[ -v $1 ]] && echo 'Must provide clone url' && exit 1

    local plugin
    plugin="$(echo $1 | sed -E 's/^git\@github\.com\:[^\/]+\/(.*)\.git$/\1/g')"

    echo "Adding plugin ${plugin}"
    git submodule add "${1}" "_vim/pack/john/start/${plugin}"
    echo "Adding module"
    git add .gitmodules "_vim/pack/john/start/${plugin}"
}

main "$@"
