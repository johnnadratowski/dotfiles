#!/usr/bin/env bash

# ====================================
# IMPORTS
# ====================================

. $(dirname ${BASH_SOURCE[0]})/shell.sh
. $(dirname ${BASH_SOURCE[0]})/log.sh

# ====================================
# CONFIGURATION
# ====================================

if ! shell_isDeclared "__fs_TEMP"; then
    declare -A __fs_TEMP=()
fi

# ====================================
# FUNCTIONS
# ====================================

# Concatenate file paths, ensuring proper amount of
# separators.
function fs_joinPath () {
    local output="${1}"
    shift

    for part in ${@}; do
        if [[ "${output}" =~ ^(.*[^/])(/+)$ ]]; then
            output="${BASH_REMATCH[1]}"
        fi

        if [[ "${part}" =~ ^(/+)(.*)$ ]]; then
            part="${BASH_REMATCH[2]}"
        fi

        output="${output}/${part}"
    done

    echo "${output}"
}

# Get the absolute path of the given path
function fs_getAbsolutePath () {
    cd "$1" && pwd
}

# Converts a byte count to a human readable format in IEC binary notation (base-1024),
# rounded to two decimal places for anything larger than a byte.
# switchable to padded format and base-1000 if desired.
# https://unix.stackexchange.com/questions/44040/a-standard-tool-to-convert-a-byte-count-into-human-kib-mib-etc-like-du-ls1
function fs_humanBytes () {
    local L_BYTES="${1:-0}"
    local L_PAD="${2:-no}"
    local L_BASE="${3:-1024}"
    echo "$(awk -v bytes="${L_BYTES}" -v pad="${L_PAD}" -v base="${L_BASE}" 'function human(x, pad, base) {
         if(base!=1024)base=1000
         basesuf=(base==1024)?"iB":"B"

         s="BKMGTEPYZ"
         while (x>=base && length(s)>1)
               {x/=base; s=substr(s,2)}
         s=substr(s,1,1)

         xf=(pad=="yes") ? ((s=="B")?"%5d   ":"%8.2f") : ((s=="B")?"%d":"%.2f")
         s=(s!="B") ? (s basesuf) : ((pad=="no") ? s : ((basesuf=="iB")?(s "  "):(s " ")))

         return sprintf( (xf " %s\n"), x, s)
      }
      BEGIN{print human(bytes, pad, base)}')"
    return $?
}

# Given a list of files, returns ok if they are the same
function fs_filesSame () {
    if [[ "$#" < 2 ]]; then
        echo "Must pass more than 1 file"
        return 100
    fi

    local checksum="$(md5 -q $1)"
    shift

    while (( "$#" )); do
        if [[ "${checksum}" != "$(md5 -q $1)" ]]; then
            echo "${checksum}"
            echo "$(md5 -q $1)"
            return 1
        fi
        shift
    done
    return 0
}

# Given a file name, gets the timestamp of the modification time
function fs_modifiedTimestamp () {
    local file="${1}"
    if shell_isMac; then
        stat -f '%m' "${file}" ||
        {
            log_exitError "An error occurred getting timestamp for ${file}"
        }
    else
        stat -c '%Y' "${file}" ||
        {
            log_exitError "An error occurred getting timestamp for ${file}"
        }
    fi
}

# Wrap mktemp to handle cleanup
function fs_mktemp () {
    local name="${1}"
    shift

    if [[ -z "${name}" ]]; then
        log_exitError "Temp name ${name} already retrieved. Please use unique names"
    fi

    local tmp
    tmp=$(mktemp "${@}") ||
    {
        log_exitError "An error occurred making temp filesystem object: mktemp ${@}"
    }

    __fs_TEMP["${name}"]="${tmp}"

    log_debug "CREATED TEMP FILE: ${name}: ${tmp}"

    eval "${name}=${tmp}"
}

# This function is used to clean up any temp files/folders
# created with fs_mktemp.  This function is called on script exit
function __fs_cleanupOnExit () {
    if [[ -z "${!__fs_TEMP[@]}" ]]; then
        return 0
    fi

    local msg="Performing exit cleanup on:\n\n"
    for key in "${!__fs_TEMP[@]}"; do
        msg+="\t${key}: ${__fs_TEMP[${key}]}\n"
    done

    log_section "${msg}"

    if shell_debugParam "skip-cleanup"; then
        log_warn "Skipping cleanup based on 'skip-cleanup' DL_DEBUG flag"
        return 0
    fi

    for key in "${!__fs_TEMP[@]}"; do
        log_debug "Deleting ${key}"
        local tmpFile="${__fs_TEMP[${key}]}"
        if [ -e "${tmpFile}" ]; then
            rm -rf "${tmpFile}"
        fi
        log_debug "${key} deleted"
    done
}
trap __fs_cleanupOnExit EXIT



