#!/bin/bash
set -e

__outdir="${OUTDIR:-public}"

if ! which entr &> /dev/null; then
    echo "entr for watching not installed. Attempting to install through brew"
    brew install entr
fi

ruby server.rb &

let __pid=$!
echo "Started Server ${__pid}"

trap ctrl_c INT

function ctrl_c() {
    kill ${__pid}
    exit
}

./build.sh || {
    kill ${__pid}
    echo "Build Failed"
    exit 1
}

open 'http://localhost:52525/docs/index.html'

while true; do
    # find -E ./docs -iregex '.*/.*\.(adoc)' |  entr -p -d ./build.sh /_ || { # This can do one at a time
    find -E ./macros ./docinfo ./docs ./notes -iregex '.*/.*\..*' |  entr -p -d ./build.sh || {
        echo "Killed, restarting in 1 second"
        sleep 1
    }
done
