#!/bin/sh
# This contains all of the custom functions
# to be included in a new bash shell session

function vl () {
	if [ -e /Applications/MacVim.app/Contents/Resources/vim/runtime/macros/less.sh]; then
		/Applications/MacVim.app/Contents/Resources/vim/runtime/macros/less.sh "${@}"
	else
		less "${@}"
	fi
}

function bytesIn {
	python -c "import pprint;pprint.pprint(list(zip(('Byte', 'KByte', 'MByte', 'GByte', 'TByte'), (1 << 10*i for i in range(5)))))"
}

function sizeOf {
	python -c 'print("\n".join("%i Byte = %i Bit = largest number: %i" % (j, j*8, 256**j-1) for j in (1 << i for i in range(8))))'
}

function explain {
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

#-------------------------------------------------------------
# File & string-related functions:
#-------------------------------------------------------------

# Find files bigger than 50 MB
function findbig { 
	find $1 -type f -size +50000k -exec ls -lh {} \; | awk '{ print $9 ": " $5 }' 
}

# Find a file with a pattern in name:
function ff() { find . -type f -iname '*'$*'*' -ls ; }

# Find a file with pattern $1 in name and Execute $2 on it:
function fe()
{ find . -type f -iname '*'${1:-}'*' -exec ${2:-file} {} \;  ; }

# Find a pattern in a set of files and highlight them:
# (needs a recent version of egrep)
function fstr()
{
	OPTIND=1
	local case=""
	local usage="fstr: find string in files.
Usage: fstr [-i] \"pattern\" [\"filename pattern\"] "
	while getopts :it opt
	do
		case "$opt" in
		i) case="-i " ;;
		*) echo "$usage"; return;;
		esac
	done
	shift $(( $OPTIND - 1 ))
	if [ "$#" -lt 1 ]; then
		echo "$usage"
		return;
	fi
	find . -type f -name "${2:-*}" -print0 | \
	xargs -0 egrep --color=always -sn ${case} "$1" 2>&- | more 

}

function cuttail() # cut last n lines in file, 10 by default
{
    nlines=${2:-10}
    sed -n -e :a -e "1,${nlines}!{P;N;D;};N;ba" $1
}

function lowercase()  # move filenames to lowercase
{
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


function swap()  # Swap 2 filenames around, if they exist
{                #(from Uzi's bashrc).
    local TMPFILE=tmp.$$ 

    [ $# -ne 2 ] && echo "swap: 2 arguments needed" && return 1
    [ ! -e $1 ] && echo "swap: $1 does not exist" && return 1
    [ ! -e $2 ] && echo "swap: $2 does not exist" && return 1

    mv "$1" $TMPFILE 
    mv "$2" "$1"
    mv $TMPFILE "$2"
}


tarview() 
{
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

function extract()      # Handy Extract Program.
{
     if [ -f $1 ] ; then
         case $1 in
             *.tar.bz2)   tar xvjf $1     ;;
             *.tar.gz)    tar xvzf $1     ;;
             *.bz2)       bunzip2 $1      ;;
             *.rar)       unrar x $1      ;;
             *.gz)        gunzip $1       ;;
             *.tar)       tar xvf $1      ;;
             *.tbz2)      tar xvjf $1     ;;
             *.tgz)       tar xvzf $1     ;;
             *.zip)       unzip $1        ;;
             *.Z)         uncompress $1   ;;
             *.7z)        7z x $1         ;;
             *)           echo "'$1' cannot be extracted via >extract<" ;;
         esac
     else
         echo "'$1' is not a valid file"
     fi
}

#-------------------------------------------------------------
# Process/system related functions:
#-------------------------------------------------------------


function my_ps() { ps $@ -u $USER -o pid,%cpu,%mem,bsdtime,command ; }
function pp() { my_ps f | awk '!/awk/ && $0~var' var=${1:-".*"} ; }


function killps()                 # Kill by process name.
{
    local pid pname sig="-TERM"   # Default signal.
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "Usage: killps [-SIGNAL] pattern"
        return;
    fi
    if [ $# = 2 ]; then sig=$1 ; fi
    for pid in $(my_ps| awk '!/awk/ && $0~pat { print $1 }' pat=${!#} ) ; do
        pname=$(my_ps | awk '$1~var { print $5 }' var=$pid )
        if ask "Kill process $pid <$pname> with signal $sig?"
            then kill $sig $pid
        fi
    done
}

#-------------------------------------------------------------
# Misc utilities:
#-------------------------------------------------------------

function my_ip_mac()
{
    ipconfig getifaddr en0
}

function repeat()       # Repeat n times command.
{
    local i max
    max=$1; shift;
    for ((i=1; i <= max ; i++)); do  # --> C-like syntax
        eval "$@";
    done
}


function ask()          # See 'killps' for example of use.
{
    echo -n "$@" '[y/n] ' ; read ans
    case "$ans" in
        y*|Y*) return 0 ;;
        *) return 1 ;;
    esac
}

function corename()   # Get name of app that created a corefile.
{ 
    for file ; do
        echo -n $file : ; gdb --core=$file --batch | head -1
    done 
}

function mcd()        # Make a directory and CD into it
{ 
    if [ -n "$1" ] ; then 
        if [ ! -d "$1" ] ; then 
            mkdir -p "$1" && cd "$1" 
        else 
            echo "mcd: will not create directory \`$1': directory exists"
        fi 
    fi 
}

function randpass()
{
    echo `</dev/urandom tr -dc A-Za-z0-9 | head -c$1`
}

function hs()
{
    history | grep -i "$@"
}

function pgr()
{
    px | grep -i "$@"
}

function largest-files()
{
    du -h | sort -hr| head -n $@
}

function updatedns()
{
    echo "Updating DNS"
    ./update-freedns-unified.sh
    echo "DNS Updated"
}

function srv()
{
    sudo /etc/init.d/$1 $2
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
    git rev-list --objects --all | sort -k 2 | cut -f 2 -d\  | uniq
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

# Define a timestamp function
timestamp_ms() {
  if which 'python' &> /dev/null; then
	  python -c 'import time; print(int(time.time()*1000))'
  else
	  date +"%s000"
  fi
}

timestamp() {
  date +"%s"
}

jsonfmt() {
    python -m json.tool "$1"
}

cloneHTMLDocs() {
	if [[ $1 == "" ]]; then
		echo "No website specified"
		return
	fi

	wget --no-parent --recursive --page-requisites --html-extension --convert-links $1
}

vimdo() {
	local CMD=$1
	shift

	for f
	do
		vim -N -u NONE -n -c "set nomore" -c ":execute \"norm! $CMD\"" -cwq! $f
	done
}
