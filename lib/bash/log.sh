#!/usr/bin/env bash

# ====================================
# IMPORTS
# ====================================

. $(dirname ${BASH_SOURCE[0]})/shell.sh
. $(dirname ${BASH_SOURCE[0]})/time.sh


# ====================================
# CONFIGURATION
# ====================================

if ! shell_isSet "__log_LAST_SECTION_ELAPSED" ; then
     __log_LAST_SECTION_ELAPSED="${time_SCRIPT_START}"
fi


# ====================================
# FUNCTIONS
# ====================================

# Write a log message. Echos to stderr
function log_log () {
    echo -e "$@" 1>&2
}

# Write info log to stderr, with timestamp
function log_info () {
    log_log "[$(time_now)] $@"
}

# Write a debug log message. Only
# if 'verbose' set in DEBUG. Echos to stderr
function log_debug () {
    if shell_debugParam "verbose"; then
        log_info "${shell_COLOR_LIGHT_CYAN}[DEBUG]" ${@} "${shell_COLOR_END}"
    fi
}

# Write a debug log for variables, prints out variable
# using `cat -v` which can view non-printable chars
function log_debugVariables () {
    local args=("${@}")

    if [[ "${#args}" == "0" ]]; then
        log_exitError "You forgot to pass variable names to the debug variable call"
    fi

    local msg="Debug information for: ${args[@]}\n\n"
    for arg in "${args[@]}"; do
        local value="${!arg}"
        msg="${msg}Variable ${arg} (Length: ${#value}):\n$(echo "${value}" | od -a)\n\n"
    done

    log_debug "${msg}"
}

# Write ok log to stderr, with timestamp
function log_ok () {
    log_info "${shell_COLOR_LIGHT_GREEN}[OK] ${@} ${shell_COLOR_END}"
}

# Write warn log to stderr, with timestamp
function log_warn () {
    log_info "${shell_COLOR_LIGHT_YELLOW}[WARN] ${@} ${shell_COLOR_END}"
}

# Write error log to stderr, with timestamp
function log_error () {
    log_info "${shell_COLOR_LIGHT_RED}[ERROR] ${@}${shell_COLOR_END}"
}

# Write out the info for a "section"
# of work the script needs to do.
# Logs current timestamp and time elapsed
# since last section
function __log_section () {
    local now="$(time_timestamp)"

    log_log "----------------------------------------------------------"
    log_info "[ELAPSED: $((${now} - ${__log_LAST_SECTION_ELAPSED})) seconds]"
    log_log $@
    log_log "----------------------------------------------------------"

    __log_LAST_SECTION_ELAPSED=${now}
}

function log_section () {
    log_log "${shell_COLOR_LIGHT_MAGENTA}"
    __log_section "${@}"
    log_log "${shell_COLOR_END}"
}

# Write log at beginning of script
function log_begin () {
    local message="${1}"
    shift
    local configs=("${@}")

    log_log "${shell_COLOR_LIGHT_BLUE}"
    log_log "%%%%%%%%%%%%%%%%%%%%%%% BEGIN %%%%%%%%%%%%%%%%%%%%%%%%%%%%"
    log_log
    log_info "Starting ${message}"
    log_log

    if shell_isSet configs && [[ ${#configs[@]} != 0 ]]; then
        log_log "CONFIGURATION:"
        log_log
        for i in ${configs[@]}; do
            log_log "\t ${i}=${!i:-"<NOT SET>"}"
        done
        log_log
    fi

    log_log "%%%%%%%%%%%%%%%%%%%%%%% ENDBEGIN %%%%%%%%%%%%%%%%%%%%%%%%%"
    log_log "${shell_COLOR_END}"
}

# Write error log to stderr, exit with last
# error code or error code 1
function __log_exitError () {
    local errCode="${1}"
    shift
    local stack="${1}"
    shift

    local elapsed="$(($(time_timestamp) - ${time_SCRIPT_START}))"

    local msg="An error occurred during processing!\nTotal Elapsed time: ${elapsed} seconds"

    if [[ ${#@} > 0 ]]; then
        msg="${msg}\n\n${@}"
    fi

    if shell_isSet "stack"; then
        msg="${msg}\n\n${stack}"
    fi

    log_log "${shell_COLOR_LIGHT_RED}"
    log_log "!!!!!!!!!!!!!!!!!!!!!!! ERROR !!!!!!!!!!!!!!!!!!!!!!!!!!!"
    __log_section "${msg}"
    log_log "!!!!!!!!!!!!!!!!!!!!!!! ENDERROR !!!!!!!!!!!!!!!!!!!!!!!!"
    log_log "${shell_COLOR_END}"
    [[ "${errCode}" == "0" ]] && exit 1
    exit "${errCode}"
}

# Alias the log_exitError function so it can properly
# Include the source and line number of the error
alias log_exitError='__log_exitError "$?" "$(eval shell_getStack)"'

# Write final success section, denoting
# a successful job and exiting with code 0
function log_exitSuccess () {
    local elapsed="$(($(time_timestamp) - ${time_SCRIPT_START}))"

    log_log "${shell_COLOR_LIGHT_GREEN}"
    log_log '$$$$$$$$$$$$$$$$$$$$$$ SUCCESS $$$$$$$$$$$$$$$$$$$$$$$$$$$'
    __log_section "${1} completed successfully!\nTotal Elapsed time: ${elapsed} seconds\n\n ${@:2}"
    log_log '$$$$$$$$$$$$$$$$$$$$$$ ENDSUCCESS $$$$$$$$$$$$$$$$$$$$$$$$'
    log_log "${shell_COLOR_END}"
    exit 0
}

