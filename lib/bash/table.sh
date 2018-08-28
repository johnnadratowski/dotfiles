#!/usr/bin/env bash

# ====================================
# PREAMBLE
# ====================================

readonly PROGNAME="$(basename ${BASH_SOURCE[0]})"
readonly PROGDIR="$(dirname ${BASH_SOURCE[0]})"
readonly PROGARGS=("$@")
readonly PROGUSAGE=$(cat <<- EOF

    USAGE: $PROGNAME COLUMN_SPEC [COLUMN_SPEC*]

    Print out stream as a table, formatted as specified by
    the COLUMN_SPEC.

    COLUMN_SPEC is defined as:
    '(COLUMN_NAME):(COLUMN_WIDTH)[:(PRINTF_MODIFIERS)[:(PRINTF_FORMAT)]]'

    If not specified, PRINTF_FORMAT defaults to 's' and PRINTF_MODIFIERS to ''.
    The column data is passed to printf using these options before it's written


    OPTIONS:
       -s --separator=$IFS      The column separator. If not specified, defaults to
                                separating using IFS
       -t --truncate            Truncate data not fitting into column width vs wrapping
       -n --no-header           Do not print header on table

    ENV:
       HORIZ_PADDING=0                spaces to add to front+back of column string
       VERT_PADDING=0                 spaces to add to top+bottom of column string
       HORIZ_CHAR                     Horizontal table border char to print
       VERT_CHAR                      Vertical table border char to print
       JOIN_CHAR                      Table border char with 4 corners
       LEFT_JOIN_CHAR                 Table border char on left with no corners
       RIGHT_JOIN_CHAR                Table border char on right with no corners
       TOP_JOIN_CHAR                  Table border char on top with no corners
       BOTTOM_JOIN_CHAR               Table border char on bottom with no corners
       TOP_LEFT_JOIN_CHAR             Table border char on top left corner
       TOP_RIGHT_JOIN_CHAR            Table border char on top right corner
       BOTTOM_LEFT_JOIN_CHAR          Table border char on bottom left corner
       BOTTOM_RIGHT_JOIN_CHAR         Table border char on bottom right corner


    EXAMPLES:
       Print table with foo, bar, and baz columns,
       data separated by comma:
       $PROGNAME -s=',' 'foo:20' 'bar:10' 'baz:11'

       Given "asdf,foo,123\nfdsa,bar,456"
       outputs a table with three columns and two rows, named as expected
       from the column spec
EOF
)

# ====================================
# IMPORTS
# ====================================

. ${PROGDIR}/../lib/log.sh
. ${PROGDIR}/../lib/shell.sh
. ${PROGDIR}/../lib/strings.sh


# ====================================
# CONFIGURATION
# ====================================

shell_processParams COLUMN_SPECS

readonly HORIZ_PADDING="${HORIZ_PADDING:-0}"
readonly VERT_PADDING="${VERT_PADDING:-0}"

readonly HORIZ_CHAR="${HORIZ_CHAR:-─}"
readonly VERT_CHAR="${VERT_CHAR:-│}"
readonly JOIN_CHAR="${JOIN_CHAR:-┼}"
readonly LEFT_JOIN_CHAR="${LEFT_JOIN_CHAR:-├}"
readonly RIGHT_JOIN_CHAR="${RIGHT_JOIN_CHAR:-┤}"
readonly TOP_JOIN_CHAR="${TOP_JOIN_CHAR:-┬}"
readonly BOTTOM_JOIN_CHAR="${BOTTOM_JOIN_CHAR:-┴}"
readonly TOP_LEFT_JOIN_CHAR="${TOP_LEFT_JOIN_CHAR:-┌}"
readonly TOP_RIGHT_JOIN_CHAR="${TOP_RIGHT_JOIN_CHAR:-┐}"
readonly BOTTOM_LEFT_JOIN_CHAR="${BOTTOM_LEFT_JOIN_CHAR:-└}"
readonly BOTTOM_RIGHT_JOIN_CHAR="${BOTTOM_RIGHT_JOIN_CHAR:-┘}"

readonly COLUMNS=${COLUMNS:-$(tput cols)}

# ====================================
# FUNCTIONS
# ====================================

function validateInput () {
    if [[ ! ${#HORIZ_CHAR} == 1 ]]; then
        log_exitError "HORIZ_CHAR must be a string of 1 character. Got ${HORIZ_CHAR}"
    fi

    if [[ ! ${#VERT_CHAR} == 1 ]]; then
        log_exitError "VERT_CHAR character must be a string of 1 character. Got ${VERT_CHAR}"
    fi

    if [[ ! ${#JOIN_CHAR} == 1 ]]; then
        log_exitError "JOIN_CHAR must be a string of 1 character. Got ${JOIN_CHAR}"
    fi

    for index in ${!COLUMN_SPECS[@]}; do
        local spec="${COLUMN_SPECS[$index]}"
        local specVals
        strings_split ":" 'specVals' ${spec}

        columnNames[$index]="${specVals[0]}"
        columnWidths[$index]="${specVals[1]}"
        columnModifiers[$index]="${specVals[2]:-}"
        columnFormats[$index]="${specVals[3]:-s}"

        if [[ -z columnNames[${index}] ]]; then
            log_exitError "You must specify a column name for ${spec}"
        fi

        if [[ -z columnWidths[${index}] ]]; then
            log_exitError "You must specify a column width for ${spec}"
        fi
    done

    local totalWidth=$(array_sum ${columnWidths[@]})
    if (( ${totalWidth} > ${COLUMNS} )); then
        log_exitError "Width of columns ${totalWidth} exceeds terminal width ${COLUMNS}"
    fi
}

function detectColumns () {
    local line="${1}"

    local columns
    strings_split "${sep}" columns "${line}"

    local perWidth=$(( (${COLUMNS} / ${#columns[@]}) - (2 + ${HORIZ_PADDING}) ))
    for index in ${!columns[@]}; do
        columnNames[$index]="${index}"
        columnWidths[$index]="${perWidth}"
        columnModifiers[$index]=""
        columnFormats[$index]="s"
    done
}

function writeHeader () {
    writeHorizDivider 'top'

    sep=' ' VERT_PADDING_OVERRIDE=0 writeRow "${columnNames[@]}"
}

function writePadding () {
    for i in $(seq 0 $(( ${VERT_PADDING} - 1 ))); do
        printf "${VERT_CHAR}"

        for width in ${columnWidths[@]}; do
            strings_multiply ' ' "${width}"

            printf "${VERT_CHAR}"
        done
        printf "\n"
    done
}

function getFmtWidth () {
    local data="${1}"
    local width="${2}"
    local count=${#data}
    local byteCount=$(printf "%s" "${data}" | wc -c)

    echo $(( ${width} + (${byteCount} - ${count}) ))
}

function writeColumn () {
    strings_multiply ' ' "${HORIZ_PADDING}"

    local column="${1}"
    local width="${2}"
    local modifiers="${3}"
    local format="${4}"

    local fmtWidth=$(getFmtWidth "${column}" "${width}")
    local fmt="%${modifiers}${fmtWidth}${format}"
    printf "${fmt}" "${column}"

    strings_multiply ' ' "${HORIZ_PADDING}"

    printf "${VERT_CHAR}"
}

function writeTruncatedRow () {
    printf "${VERT_CHAR}"

    local line="${1}"
    local columns
    strings_split "${sep}" columns "${line}"


    for index in "${!columns[@]}" ; do
        local column="${columns[$index]}"
        if (( ${index} >= ${#columnNames[@]} )); then
            log_exitError "Expected ${#columnNames[@]} columns. A row in the input had too many columns: ${line}"
        fi

        local width="$(( ${columnWidths[$index]} - (${HORIZ_PADDING} * 2) ))"
        local colData="$(strings_truncate "${column}" "${width}" '...')"

        writeColumn \
            "${colData}" \
            "${width}" \
            "${columnModifiers[$index]}" \
            "${columnFormats[$index]}"
    done

    printf "\n"
}

function writeWrappedRow () {
    local line="${1}"

    local columns
    strings_split "${sep}" columns "${line}"


    local lineCount=1
    for index in "${!columns[@]}" ; do
        local column="${columns[$index]}"
        if (( ${index} >= ${#columnNames[@]} )); then
            log_exitError "Expected ${#columnNames[@]} columns. A row in the input had too many columns: ${line}"
        fi

        local width="$(( ${columnWidths[$index]} - (${HORIZ_PADDING} * 2) ))"

        declare -n colWrapped="column${index}"

        strings_wrap "${column}" "${width}" "column${index}"

        if (( ${#colWrapped[@]} > ${lineCount} )); then
            lineCount=${#colWrapped[@]}
        fi
    done

    for line in $(seq 0 $(( ${lineCount} - 1 ))); do
        printf "${VERT_CHAR}"

        for index in "${!columns[@]}" ; do
            local width="$(( ${columnWidths[$index]} - (${HORIZ_PADDING} * 2) ))"

            declare -n cur="column${index}"
            writeColumn \
                "${cur[$line]:-}" \
                "${width}" \
                "${columnModifiers[$index]}" \
                "${columnFormats[$index]}"
        done

        printf "\n"
    done
}

function writeRowData () {
    if shell_hasFlag "t" "truncate"; then
        writeTruncatedRow "${1}"
    else
        writeWrappedRow "${1}"
    fi
}

function writeRow () {
    local padding="${VERT_PADDING_OVERRIDE:-${VERT_PADDING}}"
    local fullLine="${@}"

    if (( ${padding} > 0)); then
        writePadding
    fi

    writeRowData "${fullLine}"

    if (( ${padding} > 0)); then
        writePadding
    fi
}

function writeHorizDivider () {
    if array_contains 'top' ${@}; then
        printf "${TOP_LEFT_JOIN_CHAR}"
    elif array_contains 'bottom' ${@}; then
        printf "${BOTTOM_LEFT_JOIN_CHAR}"
    else
        printf "${LEFT_JOIN_CHAR}"
    fi

    local maxI=$(( ${#columnNames[@]} - 1 ))
    for i in $(seq 0 ${maxI}); do
        strings_multiply "${HORIZ_CHAR}" "${columnWidths[$i]}"

        if (( ${i} < ${maxI} )); then

            if array_contains 'top' ${@}; then
                printf "${TOP_JOIN_CHAR}"
            elif array_contains 'bottom' ${@}; then
                printf "${BOTTOM_JOIN_CHAR}"
            else
                printf "${JOIN_CHAR}"
            fi
        fi
    done

    if array_contains 'top' ${@}; then
        printf "${TOP_RIGHT_JOIN_CHAR}"
    elif array_contains 'bottom' ${@}; then
        printf "${BOTTOM_RIGHT_JOIN_CHAR}"
    else
        printf "${RIGHT_JOIN_CHAR}"
    fi
    printf "\n"
}

# ====================================
# MAIN
# ====================================

function main () {
    local sep="${sep:-"$(shell_getFlagDefault "${IFS}" "s" "separator")"}"

    local columnNames=()
    local columnWidths=()
    local columnFormats=()
    local columnModifiers=()

    # Also sets columnNames and columnWidths for convenience
    validateInput

    local headerWritten=false
    while IFS=$'\n' read -r line; do
        if (( ${#columnNames[@]} == 0 )); then
            detectColumns "${line}"
        fi

        if ! strings_truthy "${headerWritten}"; then
            if shell_hasFlag "n" "no-header"; then
                writeHorizDivider 'top'
            else
                writeHeader
                writeHorizDivider
            fi
            headerWritten=true
        else
            writeHorizDivider
        fi


        writeRow "${line}"
    done

    writeHorizDivider 'bottom'

}

main

