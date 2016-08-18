#!/bin/sh
# .bashrc

dpShare=~/mnt/dpShare
scrPath=$dpShare/scripts

if [ ! -d $dpShare ]; then
	echo "Creating DPShare folder"
	mkdir -p $dpShare
fi

if  mount|grep $dpShare &> /dev/null; then
	echo "DPShare Already Loaded"
else
	echo "Loading dpShare"
	sshfs root@dimepickers:/opt/share ~/mnt/dpShare
	echo "DPShare loaded"
fi

echo "Running scripts..."

. ~/mnt/dpShare/scripts/load-all.sh $scrPath

echo "Scripts completed. Welcome!"
