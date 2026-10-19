#!/usr/bin/bash

umask 022

if [[ $# < 2 ]]
then
	echo "Usage: $0 <who> <outfile>" > /dev/stderr
	echo > /dev/stderr
	exit 1
fi

WHO=$1
OUTFILE=$2
DELAY=0.2

regen() {
	figlet -f script Hello from
	tr a-z A-Z <<<"$1" | figlet -f big
	#date +"%a %b %d %r" | figlet -f bubble -w 120
	date +"%a %b %d %r"
  echo
}

while true
do
	regen "$WHO" > "$OUTFILE.tmp"
	mv "$OUTFILE.tmp" "$OUTFILE"
	sleep "$DELAY"
done
