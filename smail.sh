#!/bin/sh

# Send mail alert to administrator
#
# Date last Modified: November 17, 2023
#
# usage:
#    smail.sh text_body subject_line <recipients>
#
#    Optional recipients is a list of space deliminated valid email addresses


# Change the below variables as required.
# PASSWORDFILE is a base64 encoded file. File can be created with me "makepassword.sh" script

FROM="RTAC86UYoung@gmail.com"					# Name in the from field of email to send
AUTH="RTAC87UYoung@gmail.com"					# Username used for gmail authentication
PASSWORDFILE="/jffs/keys/password_email"		# File that contains the base64 encoded gmail password
FROMNAME="RT AX88U Young Router"				# Long name of sender used in the email header
LOCKFILE="/tmp/smail.lock"						# filename of the lockfile
MAILFILE="/tmp/mail"							# filename of the text file that contains the body of the email to be send

NTP_Ready(){
	if [ "$(nvram get ntp_ready)" -eq 0 ]; then
		ntpwaitcount=0
		Check_Lock
		while [ "$(nvram get ntp_ready)" -eq 0 ] && [ "$ntpwaitcount" -lt 600 ]; do
			logger -s -t smail.sh "NTP is not ready, waiting for 15 seconds (to a max of 600 seconds)"
			ntpwaitcount="$((ntpwaitcount + 30))"
			sleep 30
		done
		if [ "$ntpwaitcount" -ge 600 ]; then
			Clear_Lock
			logger -s -t smail.sh "ERROR: Waited for 600 seconds for NTP to be ready.... Exiting"
			exit 1
		else
			Clear_Lock
			return 0
		fi
	fi
}

Check_Lock(){
	if [ -f "${LOCKFILE}" ]; then
		ageoflock=$(($(date +%s) - $(date +%s -r "${LOCKFILE}")))
		while [ "$ageoflock" -lt 600 ]; do
			logger -s -t smail.sh "WARNING: Lock file found.... waiting for 15 seconds for a maximum of 600 seconds ("$ageoflock")"
			sleep 15
			if [ -f "${LOCKFILE}" ]; then
				ageoflock="$((ageoflock + 15))"
			else
				echo "$$" > "${LOCKFILE}"
				return 0
			fi
		done
		
		logger -s -t smail.sh "WARNING: Found lock file that is greater older than 600 seconds, killing process and proceeding"
		kill "$(sed -n '1p' "${LOCKFILE}")" >/dev/null 2>&1
		Clear_Lock
		echo "$$" > "${LOCKFILE}"
		return 0
	else
		echo "$$" > "${LOCKFILE}"
		return 0
	fi
}

Clear_Lock(){
	rm -f "${LOCKFILE}" 2>/dev/null
	return 0
}

### Main Program starts here ####


if ! [ $# -ge 2 ] && [ $# -le 3 ]
then
	printf "Not enough Arguments\n\n"
	printf "Usage: smail.sh <email_body> <subject_line> [<addresses>]\n\n"
	printf "       addresses is a list of space deliminated email addresses\n\n"
	exit
fi

logger -c -t smail.sh "Custom sendmail script executing......" 

if [ -e "$PASSWORDFILE" ]; then
	printf "Encrypted password file can not be found\n"
	printf "Maybe you need to make one (a base64 encoded file)\n"
fi

if ! [ -e $1 ]
then
	logger -s -t smail.sh "ERROR: text file ${1}to email could not be found..... Exiting"
	exit
fi

if [ $# -eq 3 ]; then
	TO=$3
else
	TO="ja.young@live.ca"
fi

NTP_Ready
Check_Lock

if [ -f "${MAILFILE}" ]; then
	rm -f "${MAILFILE}"
fi

(
	echo "Subject: "$2
	echo "From: $FROMNAME <$FROMNAME>"
	echo "Date:  $(date -R)\n"

	cat $1

	echo ""
) > "${MAILFILE}"
PASS="$(cat "${PASSWORDFILE}" | openssl enc -d -base64 -A)"

cat "${MAILFILE}" | /usr/sbin/sendmail \
    -H "exec openssl s_client -quiet \
		-starttls smtp \
		-connect smtp.gmail.com:587  \
		-no_ssl3 -no_tls1" \
    -f ${FROM} -au${AUTH} -ap${PASS} -t ${TO} -v

Clear_Lock

