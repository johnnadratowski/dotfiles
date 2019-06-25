#!/bin/sh

# =====================================
# SHELL
# =====================================

botch () {
    while true; do
        local tmp=$(mktemp)
        (
            ${@} | while read oLine; do
                printf "%s\n" "${oLine}"
            done
        ) &> $tmp
		if [[ ${CLEAR:-1} == "1" ]]; then
			echo -en '\033[H'
		fi
        printf "${shell_COLOR_LIGHT_BLUE}%s " "${@}"
        echo -e '\033[K'
        printf "${shell_COLOR_END}%s" "$(date)"
        echo -e '\033[K'
        echo -e '\033[K'
        while read -r line; do
            printf "%s" "$line"
            echo -e '\033[K' 
        done < $tmp
		if [[ ${CLEAR:-1} == "1" ]]; then
			echo -e '\033[J'
		else
			echo
			echo "#============================================================#"
			echo
		fi
        sleep ${WAIT:-2}
		rm -f "${tmp}"
    done
}
alias botch='botch '

function shell_explain {
	# base url with first command already injected
	# $ explain tar
	#   => http://explainshel.com/explain/tar?args=
	url="http://explainshell.com/explain/$1?args="

	# removes $1 (tar) from arguments ($@)
	shift;

	# iterates over remaining args and adds builds the rest of the url
	for i in "$@"; do
		url=$url"$i""+"
	done

	# opens url in browser
	open $url
}

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

# Get a stack trace
function shell_getStack () {
    if [ ${#FUNCNAME[@]} -gt 2 ]; then
        printf "%s" "STACK TRACE (Subshell Level: ${BASH_SUBSHELL}):\n\n"
        for ((i=1;i<${#FUNCNAME[@]}-1;i++)); do
           printf "%s" " $i: ${BASH_SOURCE[$i+1]}:${BASH_LINENO[$i]} ${FUNCNAME[$i]}(...)\n"
        done
    fi
}

# Colors
if ! shell_isDeclared "shell_COLOR_END" ]]; then
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

# =====================================
# LOG
# =====================================

# Write a log message. Echos to stderr
function log_log () {
    echo -e "$@" 1>&2
}

# Write info log to stderr, with timestamp
function log_info () {
    log_log "[$(time_now)] $@"
}
# Write warn log to stderr, with timestamp
function log_warn () {
    log_info "${shell_COLOR_LIGHT_YELLOW}[WARN] ${@} ${shell_COLOR_END}"
}

# Write error log to stderr, with timestamp
function log_error () {
    log_info "${shell_COLOR_LIGHT_RED}[ERROR] ${@}${shell_COLOR_END}"
}

# ====================================
# STRINGS
# ====================================

# Runs a bash variable substitution on a string
function strings_varSubstitute () {
    eval echo "$1"
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

# Multiply a string the given number of times
function strings_multiply () {
    local toMultiply="${1}"
    local by="${2}"

    local output=''
    local i
    for i in $(seq 1 ${by}); do
        output+="${toMultiply}"
    done

    printf "%s" "${output}"
}

# ====================================
# TIME
# ====================================

# Get unix timestamp, in seconds
function time_timestamp () {
    date +"%s"
}

# get a datetime string of the current time
function time_now () {
    date '+%Y-%m-%d %H:%M:%S'
}

# get a date string of the current date
function time_today () {
    date +%Y-%m-%d
}

# get a date string representing the given timestamp in seconds
function time_timestampToDate () {
    local ts="${1:-$(cat -)}"
    date -d "@${ts}" 2> /dev/null || date -r "${ts}" 2> /dev/null
}

# get a date string representing the given timestamp in milliseconds
function time_timestampMsToDate () {
    local ts="${1:-$(cat -)}"
    time_timestampToDate "$(( ${ts} / 1000 ))"
}

# This contains all of the custom functions
# to be included in a new bash shell session

function vl () {
	if [ -e /Applications/MacVim.app/Contents/Resources/vim/runtime/macros/less.sh ]; then
		/Applications/MacVim.app/Contents/Resources/vim/runtime/macros/less.sh "${@}"
	else
		less "${@}"
	fi
}

# ====================================
# HELP
# ====================================

function help_bytesIn {
	python -c "import pprint;pprint.pprint(list(zip(('Byte', 'KByte', 'MByte', 'GByte', 'TByte'), (1 << 10*i for i in range(5)))))"
}

function help_sizeOf {
	python -c 'print("\n".join("%i Byte = %i Bit = largest number: %i" % (j, j*8, 256**j-1) for j in (1 << i for i in range(8))))'
}

# ====================================
# FILES
# ====================================

# Converts a byte count to a human readable format in IEC binary notation (base-1024),
# rounded to two decimal places for anything larger than a byte.
# switchable to padded format and base-1000 if desired.
# https://unix.stackexchange.com/questions/44040/a-standard-tool-to-convert-a-byte-count-into-human-kib-mib-etc-like-du-ls1
function fs_humanBytes () {
    local L_BYTES="${1:-0}"
    local L_PAD="${2:-no}"
    local L_BASE="${3:-1024}"
    echo $(awk -v bytes="${L_BYTES}" -v pad="${L_PAD}" -v base="${L_BASE}" 'function human(x, pad, base) {
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
      BEGIN{print human(bytes, pad, base)}')
	
    return $?
}

# Find files bigger than 50 MB
function fs_findBig {
	find $1 -type f -size +50000k -exec ls -lh {} \; | awk '{ print $9 ": " $5 }' 
}

function fs_largest() {
	du -h | sort -hr | head -n $@
}

# move filenames to lowercase
function fs_lowercase() {
	for file ; do
		filename=${file##*/}
		case "$filename" in
			*/*) dirname==${file%/*} ;;
			*) dirname=.;;
		esac
		nf=$(echo $filename | tr A-Z a-z)
		newname="${dirname}/${nf}"
		if [ "$nf" != "$filename" ]; then
			mv "$file" "$newname"
			echo "lowercase: $file --> $newname"
		else
			echo "lowercase: $file not changed."
		fi
	done
}

# Swap 2 filenames around, if they exist
function fs_swap() {
	local TMPFILE=tmp.$$ 

	[ $# -ne 2 ] && echo "swap: 2 arguments needed" && return 1
	[ ! -e $1 ] && echo "swap: $1 does not exist" && return 1
	[ ! -e $2 ] && echo "swap: $2 does not exist" && return 1

	mv "$1" $TMPFILE 
	mv "$2" "$1"
	mv $TMPFILE "$2"
}

# Display contents of tar file
function fs_tarview() {
	echo "Displaying contents of file(s): $@ "
	for file in $@
	do
		echo -n "Checking file ${file}"

		if [ ${file##*.} = tar ]
		then
			echo "(Uncompressed Tar)"
			tar tvf $file
		elif [ ${file##*.} = gz ]
		then
			echo "(Compressed Tar)"
			tar tzvf $file
		elif [ ${file##*.} = bz2 ]
		then
			echo "(BZip2 Compressed Tar)"
			cat ${file} | bzip2 -d | tar tvf -
		else
			echo "Unknown tar type"
		fi
	done
}

# Extract Anything
function fs_extract() {
	local file="${1}"
	if [[ ! -f ${file} ]]; then
		echo "'${file}' is not a valid file"
		return 1
	fi
	
	local fileName="$(basename ${file})"

	local outputDir="${2}"
	if [[ ! -z "${outputDir}" ]]; then
		mkdir -p ${outputDir}
		cp ${file} ${outputDir}
		cd ${outputDir}
		extract "${fileName}"
		local retVal=$?
		rm -f ${fileName}
		return $retVal
	fi

	case ${file} in
		*.tar.bz2)   tar xvjf ${file}     ;;
		*.tar.gz)    tar xvzf ${file}     ;;
		*.bz2)       bunzip2 ${file}      ;;
		*.rar)       unrar x ${file}      ;;
		*.gz)        gunzip ${file}       ;;
		*.tar)       tar xvf ${file}      ;;
		*.tbz2)      tar xvjf ${file}     ;;
		*.tgz)       tar xvzf ${file}     ;;
		*.zip)       unzip ${file}        ;;
		*.jar)       unzip ${file}        ;;
		*.war)       unzip ${file}        ;;
		*.Z)         uncompress ${file}   ;;
		*.7z)        7z x ${file}         ;;
		*)           echo "'${file}' cannot be extracted via >extract<" ;;
	esac
}


# ====================================
# PROCESS
# ====================================

function my_ip_mac() {
	ipconfig getifaddr en0
}

# Repeat n times command.
function repeat() {
	local i max
	max=$1; shift;
	for ((i=1; i <= max ; i++)); do  # --> C-like syntax
		eval "$@";
	done
}

# Prompt user for answer
function ask() {
	echo -n "$@" '[y/n] ' ; read ans
	case "$ans" in
		y*|Y*) return 0 ;;
		*) return 1 ;;
	esac
}

# Make a directory and CD into it
function mcd() { 
	if [ -n "$1" ] ; then 
		if [ ! -d "$1" ] ; then 
			mkdir -p "$1" && cd "$1" 
		else 
			echo "mcd: will not create directory \`$1': directory exists"
			cd "$1"
		fi 
	fi 
}

function randpass() {
	echo `</dev/urandom LC_ALL=C tr -dc A-Za-z0-9 | head -c$1`
}

function hs() {
	history | grep -i "$@"
}

function pgr() {
	px | grep -i "$@"
}

#-------------------------------------------------------------
# Dev utilities:
#-------------------------------------------------------------

function git-fullreset() {
	git reset --hard; git clean -df
}

function gac()
{
	git add .; git commit -m "$@"
}

function gacnv()
{
	git add .; git commit --no-verify -m "$1"
}

function gacpm()
{
	git add .; git commit -m "$1"; git push
}

function gmv()
{
	[[ $1 != "" ]] || echo "Must pass branch"; exit 1
	git add .; git stash; git checkout -b $1; git stash pop
}

function git-all-files()
{
	git rev-list --objects --all | sort -k 2
}

function git-unique-files()
{
	git rev-list --objects --all | sort -k 2 | cut -f 2 -d' '  | uniq
}

function git-big-files()
{
	git gc && git verify-pack -v .git/objects/pack/pack-*.idx | egrep "^\w+ blob\W+[0-9]+ [0-9]+ [0-9]+$" | sort -k 3 -n -r
}

function git-purge-files()
{
	if [ $# -eq 0 ]; then
		echo "missing file args"
		exit 0
	fi

	# make sure we're at the root of git repo
	if [ ! -d .git ]; then
		echo "Error: must run this script from the root of a git repository"
		exit 1
	fi

	# remove all paths passed as arguments from the history of the repo
	local files=$@
	git filter-branch --index-filter "git rm -rf --cached --ignore-unmatch $files" HEAD

	# remove the temporary history git-filter-branch otherwise leaves behind for a long time
	rm -rf .git/refs/original/ && git reflog expire --all &&  git gc --aggressive --prune
}

function git-truncate-history()
{
	[[ $1 != "" ]] || echo "Must pass branch"; exit 1
	git checkout --orphan temp $1
	git commit --allow-empty -m "Truncated history"
	git rebase --onto temp $1 master
	git branch -D temp
	git gc --prune
}

function swap_py2()
{
	sudo rm /usr/bin/python
	sudo ln -s /usr/bin/python2 /usr/bin/python
}

function swap_py3()
{
	sudo rm -f /usr/bin/python
	sudo ln -s /usr/bin/python3 /usr/bin/python
}

function jsonfmt() {
	python -m json.tool "$1"
}

function cloneHTMLDocs() {
	if [[ $1 == "" ]]; then
		echo "No website specified"
		return
	fi

	wget --no-parent --recursive --page-requisites --html-extension --convert-links $1
}

function vimdo() {
	local CMD=$1
	shift

	for f
	do
		vim -N -u NONE -n -c "set nomore" -c ":execute \"norm! $CMD\"" -cwq! $f
	done
}

# Swap out AWS Access Keys and delete the old ones
function swap_aws_access_keys () {
	local backupAwsKey=$(mktemp)
	log_info "Making backup of Aws Credentials"
	cp -f ~/.aws/credentials $backupAwsKey
	log_info "Made backup of aws keys: $backupAwsKey"
	local oldAccessKey
	oldAccessKey=$(cat ~/.aws/credentials | grep aws_access_key_id | cut -d' ' -f3) || { 
		log_error "failed"
		return 1 
	}

	log_info "Old Access Key: $oldAccessKey"
	local filename="$(mktemp)"
	log_info "Getting new Access Key. Temp New Cred File: $filename"
	aws iam create-access-key > $filename || { 
		log_error "failed"
		return 1
	}

	log_info "New Creds:$(cat $filename)"
	local accessKeyID
	accessKeyID=$(cat $filename | jq -r .AccessKey.AccessKeyId) || { 
		log_error "failed"
		return 1
	}

	log_info "New Access Key ID: $accessKeyID"
	local accessKeySecret
	accessKeySecret=$(cat $filename | jq -r .AccessKey.SecretAccessKey) || { 
		log_error "failed"
		return 1
	}

	log_info "New Access Key Secret: $accessKeySecret"
	local tmpCreds=$(mktemp)
	log_info "Replacing credentials file. Old file:\n\n$(cat ~/.aws/credentials)\n\n"
	sed "s/^aws_access_key_id = .*$/aws_access_key_id = $accessKeyID/" ~/.aws/credentials > $tmpCreds || { 
		log_error "failed"
		return 1
	}

	mv -f $tmpCreds ~/.aws/credentials || { 
		log_error "failed"
		return 1
	}

	sed "s|^aws_secret_access_key = .*$|aws_secret_access_key = $accessKeySecret|g" ~/.aws/credentials > $tmpCreds || { 
		log_error "failed"
		return 1
	}

	mv -f $tmpCreds ~/.aws/credentials || { 
		log_error "failed"
		return 1
	}

	log_info "New credentials file:\n\n$(cat ~/.aws/credentials)\n\n"

	log_info "Process completed successfully. Now run:\n\naws iam delete-access-key --access-key-id $oldAccessKey || { echo \"failed to delete key\" }"
	# log_info "Checking credentials worked"

	# aws sts get-caller-identity || { log_error "failed"; return 1}

	# log_info "Deleting old access key"
	# aws iam delete-access-key --access-key-id $oldAccessKey || { log_error "failed"; return 1}
}

function gen_ssl_cert () {
	local outPath="${1:-./}"
	local name="${2:-server}"

	log_info "Generating self-signed ssl cert ${outPath}/${name}"

	if [ ! -d "${outPath}" ] ; then 
		mkdir -p "${outPath}" || {
			log_error "Failed to create output path ${outPath}"
			return 1
		}
	fi

	if [ -e ]
	openssl genrsa -des3 -passout pass:x -out ${outPath}/${name}.pass.key 2048 || {
		log_error "Failed generating server pass key ${outPath}/${name}.pass.key"
		return 1
	}

	openssl rsa -passin pass:x -in ${outPath}/${name}.pass.key -out ${outPath}/${name}.key || {
		log_error "Failed generating server key ${outPath}/${name}.key"
		return 1
	}

	openssl req -new -key ${outPath}/${name}.key -out ${outPath}/${name}.csr || {
		log_error "Failed generating server csr ${outPath}/${name}.csr"
		return 1
	}

	openssl x509 -req -sha256 -days 365 -in ${outPath}/${name}.csr -signkey ${outPath}/${name}.key -out ${outPath}/${name}.crt || {
		log_error "Failed generating server crt ${outPath}/${name}.crt"
		return 1
	}

	log_info "Successfully generated ${outPath}/${name}.crt and ${outPath}/${name}.key."
}