#!/bin/sh
# Last Modified 2023-11-18
#
# Script used to start all UPS NUT services.
#
# Entware packages required are;	nut-common, nut-server, nut-driver-usbhid-ups, nut-upsmon, nut-upsc
#									nut-upscmd, nut-upslog, nut-upssched, nut-upsrw
#
# Configure NUT configuration files in "/opt/etc/nut" as required
#
# Remove execute permission on "/opt/etc/init.d" NUT startup files installed by entware.
# Do not remove the pre-installed scripts as they will be overwritten by the next entware update.
# Start NUT services by running this script, or create a new Entware startup script to call this script.
#

# Location of log file used to track startup progrss of NUT Services
readonly LOGFILE="/opt/var/log/ups-startup-log.txt"

# Location of various configuration files.  You should not need to alter these locations
readonly UPSCONF="/opt/etc/nut/ups.conf"
readonly UPSUSERS="/opt/etc/nut/upsd.users"
readonly UPSMONCONF="/opt/etc/nut/upsmon.conf"

UPS=""
USER=""
PASS=""
PDFLAG=""
SYSUSER=""
KERNALPASS="TRUE"

readonly KERN=$(uname -r)
UPS=$(grep "\[" $UPSCONF | sed 's/\[//g' | sed 's/\]//g')
USER=$(grep "\[" $UPSUSERS | sed 's/\[//g' | sed 's/\]//g')
PASS=$(grep "password" $UPSUSERS | cut -f2 -d"=")
PDFLAG=$(grep "POWERDOWNFLAG" $UPSMONCONF | cut -f2 -d" ")
SYSUSER=$(nvram get http_username)

{
	echo "----------------------------------------------------------------------------"
	
	if [ $(find /lib -name input-core.ko | wc -l) -eq 0 ]; then KERNALPASS="FALSE";fi
	if [ $(find /lib -name hid.ko | wc -l) -eq 0 ]; then KERNALPASS="FALSE";fi
	if [ $(find /lib -name usbhid.ko | wc -l) -eq 0 ]; then KERNALPASS="FALSE";fi
	
	if [ "$KERNALPASS" = "FALSE" ];then	
		echo "$(date):  Aborting NUT setup - one or more required kernel modules do not exist"
		echo "----------------------------------------------------------------------------"
		exit
	fi
	
	echo "$(date):  Starting NUT Services (system startup Script)"

	if [ -f "$PDFLAG" ]; then
		echo "     - Power down flag file detected, deleting"
		rm "$PDFLAG"
	fi

	modprobe input-core
	modprobe hid
	modprobe usbhid
	
	sleep 2
	echo 
	echo "Executing upsdrvctl command with SYSUSER as ${SYSUSER}"
	upsdrvctl -u ${SYSUSER} start
	sleep 10

	echo
	echo "Executing upsd command with SYSUSER as ${SYSUSER}"
	upsd -u ${SYSUSER}
	sleep 2
	echo
	echo "Executing upsmon command"
	upsmon -p
	sleep 5
	
	echo
	BATTLOW=$(upsc ${UPS}@localhost battery.charge.low)
	if ! [ "$BATTLOW" = "25" ]; then
		echo "     - Setting UPS Battery Low level to 25%"
		upsrw -s battery.charge.low=25 -u ${USER} -p ${PASS} ${UPS}@localhost
	fi
	
	RUNTIMELOW=$(upsc ${UPS}@localhost battery.runtime.low)
	if ! [ "$RUNTIMELOW" = "600" ]; then
		echo "     - Setting UPS Low Batt Run Time to 600 seconds"
		upsrw -s battery.runtime.low=600 -u ${USER} -p ${PASS} ${UPS}@localhost
	fi
	
	echo "$(date):  End of NUT Startup Script"
	echo "----------------------------------------------------------------------------"
} >> $LOGFILE 2>&1
