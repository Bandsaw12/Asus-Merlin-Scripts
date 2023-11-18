#!/bin/sh

# Date last revised: November 18, 2023

# Usage
#
# makepassword.sh
#
# Quick utility to create encoded passphrase file for use in other scripts.
# I wrote this an I can never remember the syntex for using openssl enc command

echo ""
read -rp 'Enter phrase to be encoded : ' PASSPHRASE
read -rp 'Enter filename where encrypted passphrase is to be stored : ' FNAME

DIRNAME=$(dirname $FNAME)
if [ ! -d $(dirname $FNAME) ]; then
	echo "Directory $(dirname $FNAME) does not exist"
	exit
fi

echo "$PASSPHRASE" | openssl enc -base64 -A > "$FNAME"
echo ""

if [ -f "$FNAME" ]; then
	echo "File created OK"
else
	echo "There was an error in creating the file"
fi