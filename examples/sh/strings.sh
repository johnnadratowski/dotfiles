#!/bin/bash
# Contains functions for manipulating strings

toUpper() {
	echo "$1" | tr '[:lower:]' '[:upper:]'
}

toLower() {
	echo "$1" | tr '[:upper:]' '[:lower:]'
}

trim() {
	echo "$1" | xargs
}

randpass()
{
    echo `</dev/urandom tr -dc A-Za-z0-9 | head -c$1`
}

jsonfmt() {
    python -m json.tool "$1"
}

