#!/usr/bin/env bash

# ====================================
# FUNCTIONS
# ====================================

# Translate the given value to a string suitable
# for an env var name. Example: no-emr-ssh -> NO_EMR_SSH
function strings_varNameify () {
    local name="${1//-/_}"
    echo "${name^^}"
}

# Returns 0 if string is a 'truthy' value,
# like true, 1, yes, ok
function strings_truthy () {
    if [[ -z "${1:-}" ]]; then
        return 1
    fi

    case "${1^^}" in
    "YES"|"TRUE"|"T"|"Y"|"OK"|"OKAY"|"1")
        return 0
        ;;
    "NO"|"FALSE"|"F"|"N"|"0")
        return 1
        ;;
    *)
        return 1
        ;;
    esac
}

# Remove ALL whitespace from a string
function strings_removeWhitespace () {
    local cur="${1:-$(cat -)}"
    printf "%s" "${cur//[[:space:]]/}"
}

# Remove whitespace from the left side of a string
function strings_trimLeft () {
    local cur="${1:-$(cat -)}"
    printf "%s" "${cur}" \
        | sed -e "s/^[[:space:]]*//"
}

# Remove whitespace from the right side of a string
function strings_trimRight () {
    local cur="${1:-$(cat -)}"
    printf "%s" "${cur}" \
        | sed -e "s/[[:space:]]*$//"
}

# Remove whitespace from both sides of a string
function strings_trim () {
    local cur="${1:-$(cat -)}"

    strings_trimLeft "${cur}" | strings_trimRight
}

# Split a string based on a delimiter
function strings_split () {
    IFS=${1} read -ra ${2} <<< "${3}"
}

# Join an array of strings with the first parameter
function strings_join () {
    local join="${1}"
    shift

    local output=""
    for part in "${@}"; do
        if [[ "${output}" == "" ]]; then
            output="${part}"
        else
            output="${output}${join}${part}"
        fi
    done

    echo "${output}"
}

# Multiply a string the given number of times
function strings_multiply () {
    local toMultiply="${1}"
    local by="${2}"

    if (( $by == 0 )); then
        return 0
    fi

    local output=''
    local i
    for i in $(seq 1 ${by}); do
        output+="${toMultiply}"
    done

    printf "%s" "${output}"
}

# Truncates the string to the given length,
# optionally replacing characters at the end
# with an indicator of the truncation
function strings_truncate () {
    local str="${1}"
    local len="${2}"
    local end="${3:-}"

    if (( ${#str} <= ${len} )); then
        printf "${str}"
        return 0
    fi

    if [[ -z "${end}" ]]; then
        echo "${str:0:$len}"
    else
        local truncateTo=$(( $len - ${#end} ))
        echo "${str:0:${truncateTo}}${end}"
    fi
}

# Takes a string and a character width, and
# breaks it up into an array of lines
# that fit into that width
function strings_wrap () {
    local str="${1}"
    local width="${2}"
    local retChar="${RET_CHAR-⏎}"
    # Bash named references. Fill in given array
    declare -n output="${3}"
    output=()

    local words
    strings_split "${IFS}" 'words' "${str}"

    local half=$(( width / 2))

    local cur=""
    for word in ${words[@]}; do

        # As we get words that are in the width, add them
        # to the current buffer
        if (( ${#cur} + ${#word} + 1 <= ${width} )); then
            if [[ "${cur}" == "" ]]; then
                cur="${word}"
            else
                cur="${cur} ${word}"
            fi
            continue
        fi

        # Once we overrun width, either break at word if we
        # have more than half the width filled, or forcibly
        # break a long word up
        if (( ${#cur} <= ${half} )); then
            if [[ ${cur} == "" ]]; then
                local left=$(( ${width} - ${#retChar} ))
                output+=("${word:0:${left}}${retChar}")
            else
                local left=$(( ${width} - (${#cur} + 1 + ${#retChar}) ))
                output+=("${cur} ${word:0:${left}}${retChar}")
            fi
            cur="${word:${left}}"
        else
            output+=("${cur}")
            cur="${word}"
        fi

        # If the current word is still longer than width,
        # chunk it up into lines of the width
        while (( ${#cur} > ${width} )); do
            local left=$(( ${width} - ${#retChar} ))
            output+=("${cur:0:${left}}${retChar}")
            cur="${cur:${left}}"
        done
    done

    while (( "${#cur}" > 0 )); do
        if (( ${#cur} > ${width} )); then
            local left=$(( ${width} - 1 ))
            output+=("${cur:0:${left}}${retChar}")
            cur="${cur:${left}}"
        else
            output+=("${cur}")
            cur=""
        fi
    done
}
