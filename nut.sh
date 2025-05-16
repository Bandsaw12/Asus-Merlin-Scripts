#!/bin/sh
# Last Modified 2025-02-12
#
# Script used to start all UPS NUT services.
#
# Entware packages required are;	nut-common, nut-server, nut-driver-usbhid-ups, nut-upsmon, nut-upsc
#					nut-upscmd, nut-upslog, nut-upssched, nut-upsrw
#
# Configure NUT configuration files in "/opt/etc/nut" as required
#
# Remove execute permission on "/opt/etc/init.d" NUT startup files installed by entware.
# Do not remove the pre-installed scripts as they will be overwritten by the next entware update.
# Start NUT services by running this script, or create a new Entware startup script to call this script.
#
# Kernel Modules Required
# AC86U, AX88U
#	input-core.ko, hid.ko, usbhid.ko
# AX86U Pro
#	usbcore.ko, usbhid.ko
#
# Revision
#     2024-08-12 - Consolidate start-nut.sh and stop-nut.sh into one entware complient nut.sh script
#     2024-12-24 - Modified required kernel modules to make NUT work on the AX86U Pro
#	  2025-02-12 - Added command to turn off beeper
#	  2025-03-14 - Added debuging to upsdrvctl command, and run command regradless
######################################################################################################


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

Start() {
	readonly KERN=$(uname -r)
	UPS=$(grep "\[" $UPSCONF | sed 's/\[//g' | sed 's/\]//g')
	USER=$(grep "\[" $UPSUSERS | sed 's/\[//g' | sed 's/\]//g')
	PASS=$(grep "password" $UPSUSERS | cut -f2 -d"=")
	PDFLAG=$(grep "POWERDOWNFLAG" $UPSMONCONF | cut -f2 -d" ")
	SYSUSER=$(nvram get http_username)

	if [ "$WAIT" = "true" ];then
		echo "Waiting for 120 seconds before starting NUT"
		sleep 120
	fi	

	{
		echo "----------------------------------------------------------------------------"

		if [ $(find /lib -name usbcore.ko | wc -l) -eq 0 ]; then KERNALPASS="FALSE";fi
		if [ $(find /lib -name usbhid.ko | wc -l) -eq 0 ]; then KERNALPASS="FALSE";fi
	
		if [ "$KERNALPASS" = "FALSE" ];then	
			echo "$(date):  Aborting NUT setup - one or more required kernel modules do not exist"
			echo "----------------------------------------------------------------------------"
			return 1
		fi
	
		echo "$(date):  Starting NUT Services (system startup Script)"

		if [ -f "$PDFLAG" ]; then
			echo "     - Power down flag file detected, deleting"
			rm "$PDFLAG"
		fi

		modprobe usbcore
#		modprobe hid
		modprobe usbhid
	
		echo 
		echo "Executing upsdrvctl command with SYSUSER as ${SYSUSER}"
		upsdrvctl -D -u ${SYSUSER} start
		if [ "$?" -eq 0 ]; then
			sleep 10

			echo
			echo "Executing upsd command with SYSUSER as ${SYSUSER}"
			upsd -u ${SYSUSER}
			sleep 10
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

			# Turn UPS Beeper off
			BEEPER=$(upsc ${UPS}@localhost ups.beeper.status)
			if ! [ "$BEEPER" = "disabled" ]; then
				upscmd -u ${USER} -p ${PASS} ${UPS}@localhost beeper.disable
			fi
		else	
			echo "ERROR: UPSDRVCTL exited with error code "$?""
		fi
		
		echo "$(date):  End of NUT Startup Script"
		echo "----------------------------------------------------------------------------"
	} 2>&1 | tee -a $LOGFILE #>> $LOGFILE 2>&1
	
	return 0
}

Stop() {

	upsdrvctl -u "${SYSUSER}" stop

	if [ -n "`pidof upsd`" ]; then
		upsd -c stop		
	else
		echo -e "Process upsd is already dead"
	fi

	if [ -n "`pidof upsmon`" ]; then
		upsmon -c stop		
	else
		echo -e "Process upsmon is already dead"
	fi

}

Check() {
	STAT="OK"
	for PROC in upsd upsmon
	do
		if [ -n "`pidof $PROC`" ]; then
			echo -e "Process $PROC is alive"
		else
			echo -e "Process $PROC is dead"
			STAT="DEAD"
		fi
	done
	if [ $STAT = "OK" ]; then
		echo "UPS NUT System is functioning"
		return 0
	else
		echo "UPS NUT System is is NOT functioning"
		return 1
	fi

}


## Start of main program


STATUS="0"
WAIT="false"

if [ "$2" = "wait" ];then
	WAIT="true"
fi

case $1 in
	start)
		echo "Starting NUT system"
		Start
		STATUS="$(echo $?)"
		echo "Details about NUT's startup can be found at $LOGFILE"
	;;
	stop)
		echo "Stopping NUT system"
		Stop
	;;
	restart)
		echo "Restarting NUT system"
		Stop
		sleep 5
		Start
		STATUS="$(echo $?)"
		echo "Details about NUT's startup can be found at $LOGFILE"
	;;
	check)
		Check
		STAT="$(echo $?)"
		if [ "$STAT" -eq "1" ]; then 
			exit 1
		else
			exit 0
		fi
	;;
	*)
		echo "No arguments given - usage $0 {start|stop|restart|check}"
		echo
		Check
		STAT="$(echo $?)"
		if [ "$STAT" -eq "1" ]; then 
			exit 1
		else
			exit 0
		fi
	;;
esac

exit $STATUS
