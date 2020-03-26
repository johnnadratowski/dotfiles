#!/usr/bin/env bash
set -e

function main() {
    [[ -v $1 ]] && echo 'Must provide clone url' && exit 1

    local repoName
    repoName="$(echo $1 | sed -E 's/^git\@github\.com\:[^\/]+\/(.*)\.git$/\1/g')"

    local plugin="${2:-${repoName}}"
    echo "Adding plugin ${repoName}"
    git submodule add "${1}" "_vim/pack/john/start/${plugin}"
    echo "Adding module"
    git add .gitmodules "_vim/pack/john/start/${plugin}"
}

main "$@"
