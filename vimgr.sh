#!/usr/bin/env bash
set -e

ProgName=$(basename $0)
  
sub_help(){
    echo "Usage: $ProgName <subcommand> [options]\n"
    echo "Subcommands:"
    echo "    add    - Add plugins"
    echo "    remove - Remove Plugins"
    echo ""
    echo "For help with each subcommand run:"
    echo "$ProgName <subcommand> -h|--help"
    echo ""
}
  
sub_add(){
    [[ -v $1 ]] && echo 'Must provide clone url' && exit 1

    local repoName
    repoName="$(echo $1 | sed -E 's/^git\@github\.com\:[^\/]+\/(.*)\.git$/\1/g')"

    local plugin="${2:-${repoName}}"
    echo "Adding plugin ${repoName}"
    git submodule add "${1}" "_vim/pack/john/start/${plugin}"
    echo "Adding module"
    git add .gitmodules "_vim/pack/john/start/${plugin}"
}
  
sub_remove(){
    [[ -v $1 ]] && echo 'Must provide plugin name' && exit 1

    local p="_vim/pack/john/start"
    local fp="${p}/${1}"
    
    git submodule deinit -f $fp
    git rm -rf $fp
    rm -Rf .git/modules/$fp
}
  
subcommand=$1
case $subcommand in
    "" | "-h" | "--help")
        sub_help
        ;;
    *)
        shift
        sub_${subcommand} $@
        if [ $? = 127 ]; then
            echo "Error: '$subcommand' is not a known subcommand." >&2
            echo "       Run '$ProgName --help' for a list of known subcommands." >&2
            exit 1
        fi
        ;;
esac
