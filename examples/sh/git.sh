#!/bin/bash
# Contains functions for working with git

gitBranch() {
	cd $1; git branch | grep "*" | cut -d " " -f 2; cd - &> /dev/null
}
