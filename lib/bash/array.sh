#!/usr/bin/env bash

# ====================================
# FUNCTIONS
# ====================================

# Determine if an array contains an item
function array_contains () {
  local e match="${1}"
  shift
  for e; do
    [[ "${e}" == "${match}" ]] && return 0;
  done
  return 1
}

# Sum up array of numbers
function array_sum () {
    local output=0
    for e; do
        (( output += ${e} ))
    done
    printf "%d" "${output}"
}

# Print an associative array. Useful for debugging
# Use it like `array_printAssocArray ${!array[@]} ${array[@]}`
function array_printAssocArray () {
    local args=("${@}")
    local len="${#args[@]}"
    if [[ ${len} == 0 ]]; then
        echo "<EMPTY>"
        return 0
    fi

    local half="$(( ${len} / 2 ))"

    for i in $(seq 0 "$((${half} - 1))"); do
        local valIndex="$(( ${i} + ${half} ))"
        printf "%s=%s\n" "${args[${i}]}" "${args[${valIndex}]}"
    done
}

