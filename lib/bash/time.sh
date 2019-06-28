#!/usr/bin/env bash

# ====================================
# IMPORTS
# ====================================

. $(dirname ${BASH_SOURCE[0]})/shell.sh

# ====================================
# FUNCTIONS
# ====================================

# Get unix timestamp, in seconds
function time_timestamp () {
    date +"%s"
}

# get a datetime string of the current time
function time_now () {
    date +%Y-%m-%d\ %H:%M:%S
}

# get a date string of the current date
function time_today () {
    date +%Y-%m-%d
}

# get a date string representing the given timestamp in seconds
function time_timestampToDate () {
    local ts="${1:-$(cat -)}"
    local format="${TIME_FORMATTER:-%Y-%m-%d %H:%M:%S}"
    if shell_isMac; then
        date -r "${ts}" +"${format}" 2> /dev/null
    else
        date -d "@${ts}" +"${format}" 2> /dev/null
    fi
}

# get a date string representing the given timestamp in milliseconds
function time_timestampMsToDate () {
    local ts="${1:-$(cat -)}"
    time_timestampToDate "$(( ${ts} / 1000 ))"
}

# get a timestamp in seconds from a date
function time_dateToTimestamp () {
    local fromDate="${1}"
    local format="${2:-%Y-%m-%d}"
    if shell_isMac; then
        time_datetimeToTimestamp "${fromDate} 00:00:00" "${format} %H:%M:%S"
    else
        time_datetimeToTimestamp "${fromDate}"
    fi
}

# get a timestamp in seconds from a datetime
function time_datetimeToTimestamp () {
    local fromDate="${1}"
    local format="${2:-%Y-%m-%d 00:00:00}"
    if shell_isMac; then
        date -j -u -f "${format}" "${fromDate}" "+%s"
    else
        date -d "${fromDate}" +"%s"
    fi
}

# ====================================
# CONFIGURATION
# ====================================

if ! shell_isSet "time_SCRIPT_START" ; then
    readonly time_SCRIPT_START="$(time_timestamp)"
fi
