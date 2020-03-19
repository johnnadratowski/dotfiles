#!/usr/bin/env bash
set -e

function main() {
  git submodule update --recursive --remote --merge
}

main "$@"
