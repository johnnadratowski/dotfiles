#!/bin/sh
# This contains all of the custom functions
# to be included in a new bash shell session

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
function findbig { find ${1} -type f -size +50000k -exec ls -lh {} \; | awk '{ print $9 ": " $5 }' }

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

function gac()
{
    git add .; git commit -m "$1"
}

function gacpm()
{
    git add .; git commit -m "$1"; git push
}

function gmv()
{
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
        exit 0are still
    fi

    # make sure we're at the root of git repo
    if [ ! -d .git ]; then
        echo "Error: must run this script from the root of a git repository"
        exit 1
    fi

    # remove all paths passed as arguments from the history of the repo
    files=$@
    git filter-branch --index-filter "git rm -rf --cached --ignore-unmatch $files" HEAD

    # remove the temporary history git-filter-branch otherwise leaves behind for a long time
    rm -rf .git/refs/original/ && git reflog expire --all &&  git gc --aggressive --prune
}

function git-truncate-history()
{
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
    sudo rm /usr/bin/python
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

hammer() {
	local start=`timestamp`
	local throttle_calls=${THROTTLE_CALLS:-0}
	local throttle_time=${THROTTLE_TIME:-60}
	local concurrency=${CONCURRENCY:-50}
	local output_file=${OUTPUT_FILE:-/tmp/hammer.$start.tsv}
	local open_output=${OPEN_OUTPUT:-0}
	local dump_file=${DUMP_FILE:-/tmp/hammer.$start.dump.tsv}
	local server=${HAMMER_SERVER:-"local"}
	local iterations=${ITERATIONS:-100}
	local calls="`cat`"
	local default_prefix="curl --w '%{http_code}\t%{time_total}\t%{time_connect}\t%{time_namelookup}\t%{time_pretransfer}\t%{time_redirect}\t%{time_starttransfer}\t%{size_download}\t%{size_upload}\t%{size_request}\t%{size_header}\t%{speed_download}\t%{speed_upload}\t%{num_connects}\t%{num_redirects}\t%{redirect_url}\t%{url_effective}'"
	local cmd_prefix=${CMD_PREFIX:-$default_prefix}

	if [[ $cmd_prefix == $default_prefix ]]; then
		echo "Hammer Server\tStart Time (ms)\tEnd Time (ms)\tCall\tExit Code\tHTTP Code\tTotal Time (sec)\tTime To Connect (sec)\tTime for Name Lookup (sec)\tTime Pretransfer (sec)\tTime Redirected (sec)\tTime Start Transfer (sec)\tSize Downloaded (bytes)\tSize Uploaded (bytes)\tSize of Request (bytes)\tSize of Header (bytes)\tSpeed of Download (bytes/sec)\tSpeed of Upload (bytes/sec)\tNumber of Connections\tNumber of Redirects\tRedirect URL\tEffective URL" > $output_file
	else
		echo "Hammer Server\tStart Time (ms)\tEnd Time (ms)\tCall\tExit Code\tTotal Time(sec)" > $output_file
	fi

	local counter=1
	local cur_throttle_count=0
	local num_throttle=0
	declare -a pids
	echo "HAMMERING with $iterations and max $concurrency concurrency."
	if [[ $throttle_calls > 0 ]]; then
		echo "throttling $((throttle_calls / throttle_time)) calls/s."
	fi

	for i in `seq 1 $iterations`; do
		while read -r call; do

			if (( throttle_calls > 0 )); then 
				local run_time=$((`timestamp` - start))
				throttle_count=$((run_time / throttle_time))
				local throttle_reset=$(((cur_throttle_count + 1) * throttle_time))
				echo "RUNTIME: $run_time, CUR THROTTLE COUNT: $cur_throttle_count, THROTTLE_COUNT: $throttle_count, THROTTLE_RESET: $throttle_reset, NUM_THROTTLE: $num_throttle"

				if (( $throttle_count > $cur_throttle_count )); then
					echo "RESET THROTTLE: $next_throttle > $cur_throttle"
					cur_throttle_count=$throttle_count
					num_throttle=0
				fi

				if (( num_throttle >= throttle_calls )); then
					local time_to_throttle=$((throttle_reset - run_time))
					echo "THROTTLING FOR $time_to_throttle seconds"
					sleep $time_to_throttle
					num_throttle=0
				fi
			fi

			if (( `jobs -pr | wc -l` >= $concurrency )); then
				local pid_to_wait=${pids[$((counter-concurrency))]}
				echo "WAITING FOR PID $pid_to_wait: MAX CONCURRENCY HIT: $counter"
				wait $pid_to_wait
			fi

			{
				local start_call=`timestamp_ms`
				local index=$counter
				local local_dump=`mktemp`
				if [[ $cmd_prefix == $default_prefix ]]; then
					#echo "Running: $cmd_prefix -o $local_dump $call"
					local cmd_output="`eval "$cmd_prefix -o $local_dump $call" 2> /dev/null`"
					local exit_code=$?
					local end_call=`timestamp_ms`
					echo "$server\t$start_call\t$end_call\t$call\t$exit_code\t$cmd_output" >> $output_file
					echo "$server\t$start_call\t$end_call\t$call\t$exit_code\t$(cat $local_dump)" >> $dump_file
				else
					local time_output
					time_output=`(time (eval "$cmd_prefix $call" > $local_dump) )2>&1`
					local exit_code=$?
					cur_time=`echo $time_output | cat | grep real | cut -f 2 | sed "s/.$//"`
					local end_call=`timestamp_ms`
					echo "$server\t$start_call\t$end_call\t$call\t$exit_code\t$cur_time" >> $output_file
					echo "$server\t$start_call\t$end_call\t$call\t$exit_code\t$(cat $local_dump)" >> $dump_file
				fi
				rm -f $local_dump
			} &
			pids[$counter]=$!
			counter=$((counter + 1))
			num_throttle=$((num_throttle + 1))
		done <<< "$calls"
	done
	[[ $((`jobs -rp |wc -l`)) > 0 ]] && echo "WAITING TO CLEAN UP PROCS" && wait

	local elapsed=$((`timestamp` - $start))
	echo "Completed $(($counter-1)) calls in $elapsed seconds. Saved output to $output_file and dump to $dump_file."
	if [[ $open_output == 1 ]]; then
		echo "Opening output file: $output_file"
		open $output_file
	fi
}

hammerPMN() {
	hammer << 'END'
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/goals
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/markets
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/regions
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/properties
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/companies
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/brands
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/initiatives
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/line_items
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/users
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/families
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/saved_reports
-H "X-Unified-IdentityID: amadmin" http://localhost:8082/makeMeAnError
END
}
