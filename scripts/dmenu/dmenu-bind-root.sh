#!/bin/bash
exe=`dmenu_path | dmenu -i -b -nb '#FF0000' -nf '#d8d8d8' -sb '#d8d8d8' -sf '#151617'` && eval "exec gksudo $exe"
