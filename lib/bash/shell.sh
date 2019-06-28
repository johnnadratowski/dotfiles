#!/usr/bin/env bash

# ====================================
# IMPORTS
# ====================================

. $(dirname ${BASH_SOURCE[0]})/array.sh
. $(dirname ${BASH_SOURCE[0]})/strings.sh

# =====================================
# FUNCTIONS
# =====================================

# Returns 0 if this is currently running on mac
function shell_isMac () {
    [[ "$(uname)" =~ "Darwin" ]]
}

# Determine if a flag was turned on in DEBUG env var
# Or if specific debug param env var was declared like
# DEBUG_VERBOSE
function shell_debugParam () {
    local envVarName="DEBUG_$(strings_varNameify "${1}")"

    # If there is a variable name like DEBUG_*
    # We return whether or not it's a truthy value
    if shell_isDeclared "${envVarName}"; then
        strings_truthy "${!envVarName}"
        return $?
    fi

    local debugArgs
    if ! shell_isSet DEBUG; then
        return 1
    fi

    read -ra debugArgs <<< ${DEBUG:-''}
    array_contains "${1}" "${debugArgs[@]}"
}

# Return a string representation of the debug param
function shell_debugParamStr () {
    if shell_debugParam "${1}"; then
        echo "${2-true}"
    else
        echo "${3-false}"
    fi
}

# This is a convenience alias to easily dump a command's
# stderr if verbose isn't set
alias shell_verboseStderr='shell_debugParamStr "verbose" "" "2>/dev/null"'

# Determine if variables have been declared (not necessarily set)
function shell_isDeclared () {
    local var
    for var in "${@}"; do
        if ! declare -p ${1} &>/dev/null; then
            return 1
        fi
    done
}

# Determine if variables have been set
function shell_isSet () {
    if ! shell_isDeclared "${@}"; then
        return 1
    fi

    local var
    for var in "${@}"; do
        if [[ ! -v "${1}" ]]; then
            return 1
        fi
    done
}

# Determine if a set of commands exist
function shell_commandsExist () {
    local command
    for command in "${@}"; do
        if ! type "${command}" &> /dev/null; then
            log_exitError "Required command missing: ${command}"
        fi
    done
}

# Get a stack trace
function shell_getStack () {
    if [ ${#FUNCNAME[@]} -gt 2 ]; then
        printf "%s" "STACK TRACE (Subshell Level: ${BASH_SUBSHELL}):\n\n"
        for ((i=1;i<${#FUNCNAME[@]}-1;i++)); do
           printf "%s" " $i: ${BASH_SOURCE[$i+1]}:${BASH_LINENO[$i]} ${FUNCNAME[$i]}(...)\n"
        done
    fi
}

function shell_hasFlag () {
    for name in "${@}"; do
        if [ ${shell_FLAGS["$name"]+_} ]; then
            return 0
        fi
    done
    return 1
}

function shell_getFlag () {
    local output=()
    for name in "${@}"; do
        if shell_hasFlag "$name"; then
            output+=("${shell_FLAGS[$name]}")
        fi
    done

    if [[ ${#output[@]} == 0 ]]; then
        return 1
    else
        echo "${output[@]}"
        return 0
    fi
}

function shell_getFlagDefault () {
    local default="${1}"
    shift

    if ! shell_getFlag "${@}"; then
        echo "${default}"
    fi
}

# Process command line arguments and set the given parameters
function shell_setParams () {
    local ctr=1
    for name in "${@}"; do
        if (( $ctr == ${#@} )); then
            eval "readonly $name=(${shell_PARAMS[@]:$ctr})"
        else
            eval "readonly $name='${shell_PARAMS[$ctr]}'"
        fi
        ((ctr+=1))
    done
}

# Process command line arguments and take list of parameter names
# parameter names get set to their values based on parameter position
# If there are more parameters than names, the last name gets the
# remaining parameter array
function shell_processParams () {
    if ! shell_isDeclared PROGARGS; then
        echo "You must define PROGARGS before calling shell_processParams"
        exit 1
    fi

    for arg in "${PROGARGS[@]}"; do
        case "$arg" in
            -h|--help) # Print usage info, if any exists
            if shell_isSet PROGUSAGE; then
                echo "${PROGUSAGE}"
                echo ""
                exit 0
            else
                echo "No usage information found for this script"
                exit 0
            fi
            ;;

            --*=*)
            local key="${arg%=*}"
            key="${key#--*}"
            local val="${arg#--*=}"
            if shell_hasFlag "${key}"; then
                shell_FLAGS["${key}"]=("$(shell_getFlag "${key}")" "$val")
            else
                shell_FLAGS["${key}"]="${val}"
            fi
            ;;

            --*)
            local key="${arg#--*}"
            if shell_hasFlag "${key}"; then
                shell_FLAGS["${key}"]=$(( $(shell_getFlag "${key}")+1 ))
            else
                shell_FLAGS["${key}"]=1
            fi
            ;;

            -*=*)
            local key="${arg%=*}"
            key="${key#-*}"
            local val="${arg#-*=}"
            if shell_hasFlag "${key}"; then
                shell_FLAGS["${key}"]=("$(shell_getFlag "${key}")" "$val")
            else
                shell_FLAGS["${key}"]="${val}"
            fi
            ;;

            -*)
            local key="${arg#-*}"
            if shell_hasFlag "${key}"; then
                shell_FLAGS["${key}"]=$(( $(shell_getFlag "${key}")+1 ))
            else
                shell_FLAGS["${key}"]=1
            fi
            ;;

            --) # end argument parsing
            break
            ;;

            *) # preserve positional arguments
            shell_PARAMS+=("$arg")
            ;;
        esac
    done

    shell_setParams "$@"
}

# ====================================
# CONFIGURATION
# ====================================

## Allow for using aliases in scripts
shopt -s expand_aliases

## Always make failures exit unless explicitly handled
set -e

## If 'disable-error-failure' debug param, disable `set -e`
if shell_debugParam 'disable-error-failure'; then
    set +e
fi

## Disallow using unset variables
set -u

## If 'allow-unset' debug param, disable `set -u`
if shell_debugParam 'allow-unset'; then
    set +u
fi

## Fail jobs in pipeline if any job along the way fails
set -o pipefail

## If 'disable-pipefail' debug param, disable `set -o pipefail`
if shell_debugParam 'disable-pipefail'; then
    set +o pipefail
fi

## If 'trace' debug param is set, print out all commands
if shell_debugParam 'trace'; then
    set -x
fi

## If 'force-error' debug param, forcibly exit the script to simulate failure
if shell_debugParam 'force-error'; then
    exit 1
fi

if ! shell_isDeclared "shell_PARAMS"; then
    declare -a shell_PARAMS=("")
    declare -A shell_FLAGS
fi

# Colors
if ! shell_isDeclared "shell_COLOR_END"; then
    readonly shell_COLOR_END="\033[0m"
    readonly shell_COLOR_DEFAULT="\033[0;39m"
    readonly shell_COLOR_DEFAULT_BG="\033[0;49m"
    readonly shell_COLOR_DEFAULT_BOLD="\033[1;39m"
    readonly shell_COLOR_LIGHT_GRAY="\033[0;37m"
    readonly shell_COLOR_LIGHT_GRAY_BG="\033[0;47m"
    readonly shell_COLOR_LIGHT_GRAY_BOLD="\033[1;37m"
    readonly shell_COLOR_DARK_GRAY="\033[0;90m"
    readonly shell_COLOR_DARK_GRAY_BG="\033[0;100m"
    readonly shell_COLOR_DARK_GRAY_BOLD="\033[1;90m"
    readonly shell_COLOR_BLACK="\033[0;30m"
    readonly shell_COLOR_BLACK_BG="\033[0;40m"
    readonly shell_COLOR_BLACK_BOLD="\033[1;30m"
    readonly shell_COLOR_WHITE="\033[0;97m"
    readonly shell_COLOR_WHITE_BG="\033[0;107m"
    readonly shell_COLOR_WHITE_BOLD="\033[1;97m"
    readonly shell_COLOR_RED="\033[0;31m"
    readonly shell_COLOR_RED_BG="\033[0;41m"
    readonly shell_COLOR_RED_BOLD="\033[1;31m"
    readonly shell_COLOR_LIGHT_RED="\033[0;91m"
    readonly shell_COLOR_LIGHT_RED_BG="\033[0;101m"
    readonly shell_COLOR_LIGHT_RED_BOLD="\033[1;91m"
    readonly shell_COLOR_GREEN="\033[0;32m"
    readonly shell_COLOR_GREEN_BG="\033[0;42m"
    readonly shell_COLOR_GREEN_BOLD="\033[1;32m"
    readonly shell_COLOR_LIGHT_GREEN="\033[0;92m"
    readonly shell_COLOR_LIGHT_GREEN_BG="\033[0;102m"
    readonly shell_COLOR_LIGHT_GREEN_BOLD="\033[1;92m"
    readonly shell_COLOR_YELLOW="\033[0;33m"
    readonly shell_COLOR_YELLOW_BG="\033[0;43m"
    readonly shell_COLOR_YELLOW_BOLD="\033[1;33m"
    readonly shell_COLOR_LIGHT_YELLOW="\033[0;93m"
    readonly shell_COLOR_LIGHT_YELLOW_BG="\033[0;103m"
    readonly shell_COLOR_LIGHT_YELLOW_BOLD="\033[1;93m"
    readonly shell_COLOR_BLUE="\033[0;34m"
    readonly shell_COLOR_BLUE_BG="\033[0;44m"
    readonly shell_COLOR_BLUE_BG_BG="\033[0;104m"
    readonly shell_COLOR_BLUE_BOLD="\033[1;34m"
    readonly shell_COLOR_LIGHT_BLUE="\033[0;94m"
    readonly shell_COLOR_LIGHT_BLUE_BOLD="\033[1;94m"
    readonly shell_COLOR_MAGENTA="\033[0;35m"
    readonly shell_COLOR_MAGENTA_BG="\033[0;45m"
    readonly shell_COLOR_MAGENTA_BOLD="\033[1;35m"
    readonly shell_COLOR_LIGHT_MAGENTA="\033[0;95m"
    readonly shell_COLOR_LIGHT_MAGENTA_BG="\033[0;105m"
    readonly shell_COLOR_LIGHT_MAGENTA_BOLD="\033[1;95m"
    readonly shell_COLOR_CYAN="\033[0;36m"
    readonly shell_COLOR_CYAN_BG="\033[0;46m"
    readonly shell_COLOR_CYAN_BOLD="\033[1;36m"
    readonly shell_COLOR_LIGHT_CYAN="\033[0;96m"
    readonly shell_COLOR_LIGHT_CYAN_BG="\033[0;106m"
    readonly shell_COLOR_LIGHT_CYAN_BOLD="\033[1;96m"
fi
