#!/bin/bash

callmee() (

	_init() {
		foo=1
		bar=2
	}

	_init

	printf "FOO: %s BAR: %s\n" "$foo" "$bar"

	for i in $@; do
		echo "$i"
	done
	for i in $*; do
		echo "$i"
	done
	echo "$@"
	echo "$*"
)
