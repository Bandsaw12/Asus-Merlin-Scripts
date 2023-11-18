#!/bin/sh
# Last Revised June 15, 2022
FILE="/tmp/UPSNotice.txt"
UPSEVENTFILE="/opt/var/log/ups-notifications.txt"
UPSMESSAGE=$1
UPSCODE=${UPSMESSAGE:0:6}
MODE="1"

echo "**** $(date): $1" >> $UPSEVENTFILE

case "$UPSCODE" in
	"Code 0")
		SUBJECT="UPS Notice: AC Power has been restored"
		;;
	"Code 1")
		SUBJECT="UPS **WARNING** AC Power Lost - UPS on Battery"
		;;
	"Code 2")
		SUBJECT="UPS **WARNING** UPS Battery is getting low"
		MODE="0"
		if ! [ -f "/tmp/upsbattlow.txt" ]; then
			echo "$(date): UPS Battery has already reported low for first time" > /tmp/upsbattlow.txt
		else
			DT1=$(date +%s)
			DT2=$(date -r /tmp/upsbattlow.txt +%s)
			
			if [ $((DT1 - DT2)) -gt 21600 ]; then
				echo "$(date): UPS Battery has reported low (Subsequent Notification)" > /tmp/upsbattlow.txt
			else
				exit 1
			fi
		fi
		;;
	"Code 3")
		SUBJECT="UPS **WARNING** UPS Forced Shutdown in process"
		;;
	"Code 4")
		SUBJECT="UPS Notice: Communications with UPS established"
		MODE="0"
		;;
	"Code 5")
		SUBJECT="UPS Notice: Communications with UPS lost"
		MODE="0"
		;;
	"Code 6")
		SUBJECT="UPS Notice: Auto logout and shutdown proceeding"
		MODE="0"
		;;
	"Code 7")
		SUBJECT="UPS Notice: UPS Battery requires replacement"
		MODE="0"
		;;
	"Code 8")
		SUBJECT="UPS **WARNING** Unable to communicate with UPS"
		;;
	"Code 9")
		SUBJECT="UPS Notice: upsmon parent process died - shutdown impossible"
		MODE="0"
		;;
	*)
		SUBJECT="UPS Notice: unknown event reported by UPS"
		MODE="0"
		;;
esac

echo "Message received from Router re UPS Status" > $FILE
echo "" >> $FILE
echo "Message received on "$(date) >> $FILE
echo "" >> $FILE
echo "Message: "${UPSMESSAGE} >> $FILE
echo "" >> $FILE

if [ $MODE = "1" ];then
	/jffs/addons/young/smail.sh "$FILE" "$SUBJECT" "ja.young@live.ca 7056900128@msg.telus.com"
else
	/jffs/addons/young/smail.sh "$FILE" "$SUBJECT"
fi
