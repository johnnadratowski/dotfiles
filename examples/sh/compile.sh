#!/bin/bash
# Compile the bash script into a single file

compile() {
	if [[ -e $1 ]]; then
		local sourceData=`cat $1`
		local scriptPath=${1%/*}
	else
		local sourceData=$1
		local scriptPath=$2
	fi

	while read -r line; do
		if [[ "$line" == .\ * || "$line" == source\ * ]]; then
			local fileName=$scriptPath/${line#*/}
			fileName=${fileName/\"/}
			echo ""
			echo "# From Source: $fileName"
			echo ""
			echo "`compile \"$(cat $fileName)\" $scriptPath`"
			echo ""
		else
			echo $line
		fi
	done <<< "$sourceData"
}

compile $1
