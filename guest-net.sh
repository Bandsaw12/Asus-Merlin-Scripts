#!/bin/sh

# Script to create a seperate guest wifi network with the option of adding a ethernet port to the network
# Inspired by the script YazFi by JackYaz (snbForums.com)
#
# Version 2.10.00	Dated May 4, 2025	- Cleanup and automate crude script I was using to add eth port to guest network
#
# User must set script parameters below.  In addition, the following scripts must be created or altered;
#
#		/jffs/configs/dnsmasq.conf.add			# Add DHCP server setup for the bridge that you used
#		/jffs/scripts/firewall-start			# Call this script with the option "firewall" as $1
#		/jffs/scripts/nat-start					# Call this script with the option "nat" as $1
#		/jffs/scripts/services-start			# Call this script with no options to setup bridge
#		/jffs/scripts/services-event-end		# Trap event "wireless" or "net_and_phy" on "restart", then run this script with no options
#												# Trap event "firewall" on "start" or "restart" and run script with firewall option

# set -x

# Start of System Set up.  Edit these values according to your needs
#
# CIDR IP Address of the new guest LAN interface on the router (This will be the gateway as well for this LAN)
GUESTNETWORK="192.168.2.2/24"

# Guest Wifi interface name that will be moved.  This interface needs to be already setup via the GUI
# List only one interface.  This script only supports the setup of one interface
GUESTIF="wl0.2"

# Name of the new bridge that will be created.
GUESTBR="brg"

# List of lan ports, space seperated, that will be moved brom br0 into the new bridge
LANPORTS="eth0"

# Do you wish two way comms between br0 and the new bridge? (true or false)
TWOWAY="false"

# Do you wish one way comes?  true or false (br0 > new bridge)
ONEWAY="true"

# Is access to the internet to be blocked on the new bridge (true or flase)
BLOCKINTERNET="false"

# Are clients on the new bridge to be isolated? (true or false)
CLIENTISOLATE="false"

# These options are planned, but not used in the script as of yet.
DNS1="8.8.8.8"
DNS2="8.8.4.4"
FORCEDNS="false"

################# End of Configuration ##################################

#------------------------------------------
readonly SCRIPT_NAME="guestnet"
readonly SCRIPT_DIR="/jffs/addons/$SCRIPT_NAME"
readonly LAN_IP="$(nvram get lan_ipaddr)"
readonly LAN_NETMASK="$(nvram get lan_netmask)"
readonly USER_SCRIPT_DIR="$SCRIPT_DIR/scripts"
ENABLED_WINS="$(nvram get smbd_wins)"
ENABLED_SAMBA="$(nvram get enable_samba)"
INTNTPD="$(nvram get ntpd_enable)"

### Start of output format variables ###
readonly CRIT="\\e[41m"
readonly ERR="\\e[31m"
readonly WARN="\\e[33m"
readonly PASS="\\e[32m"
readonly BOLD="\\e[1m"
readonly SETTING="${BOLD}\\e[36m"
readonly CLEARFORMAT="\\e[0m"
### End of output format variables ###

if [ "$(nvram get wan0_proto)" = "pppoe" ] || [ "$(nvram get wan0_proto)" = "pptp" ] || [ "$(nvram get wan0_proto)" = "l2tp" ]; then
	IFACE_WAN="ppp0"
else
	IFACE_WAN="$(nvram get wan0_ifname)"
fi

ENABLED_NTPD=0
if [ -f /jffs/scripts/nat-start ]; then
	if [ "$(grep -c '# ntpMerlin' /jffs/scripts/nat-start)" -gt 0 ]; then ENABLED_NTPD=1; fi
fi
if [ "$INTNTPD" -ne 0 ]; then ENABLED_NTPD=1; fi

Check_Lock(){
	if [ -f "/tmp/$SCRIPT_NAME.lock" ]; then
		ageoflock=$(($(date +%s) - $(date +%s -r /tmp/$SCRIPT_NAME.lock)))
		if [ "$ageoflock" -gt 600 ]; then
			Print_Output true "Stale lock file found (>600 seconds old) - purging lock" "$WARN"
			kill "$(sed -n '1p' /tmp/$SCRIPT_NAME.lock)" >/dev/null 2>&1
			Clear_Lock
			echo "$$" > "/tmp/$SCRIPT_NAME.lock"
			return 0
		else
			t="0"
			while [ "$t" -le 60 ]
			do
				Print_Output true "Lock file found (age: $ageoflock seconds) - waiting 10 seconds, then try to continue. (Max 60s)" "$WARN"
				sleep 10
				if ! [ -f "/tmp/$SCRIPT_NAME.lock" ]; then
					break
				else
					let "t=t+10"
				fi
			done
			Print_Output true "Sixty (60) seconds has passed, still locked.  Killing stuck process and continuing..." "$WARN"
			kill "$(sed -n '1p' /tmp/$SCRIPT_NAME.lock)" >/dev/null 2>&1
			Clear_Lock
			echo "$$" > "/tmp/$SCRIPT_NAME.lock"
			return 0
		fi
	else
		echo "$$" > "/tmp/$SCRIPT_NAME.lock"
		return 0
	fi
}

Clear_Lock(){
	Print_Output true "Clearing lock file" "$PASS"
	rm -f "/tmp/$SCRIPT_NAME.lock" 2>/dev/null
	return 0
}

# $1 = print to syslog, $2 = message to print, $3 = log level
Print_Output(){
	if [ "$1" = "true" ]; then
		logger -t "$SCRIPT_NAME" "$2"
	fi
	printf "${BOLD}${3}%s${CLEARFORMAT}\\n\\n" "$2"
}

int_to_ip4() {
  echo "$(( ($1 >> 24) % 256 )).$(( ($1 >> 16) % 256 )).$(( ($1 >> 8) % 256 )).$(( $1 % 256 ))"
}

# returns the ip part of an CIDR
#
# cidr_ip "172.16.0.10/22"
# => 172.16.0.10
cidr_ip() {
  IFS=/ read -r ip _ <<EOF
$1
EOF
  echo $ip
}

# returns the prefix part of an CIDR
#
# cidr_prefix "172.16.0.10/22"
# => 22
cidr_prefix() {
  IFS=/ read -r _ prefix <<EOF
$1
EOF
  echo $prefix
}

Get_NetworkIP() {
	# $1 = IP Address/CIDR	
	local IP="$(cidr_ip "$GUESTNETWORK")"
	local PREFIX="$(cidr_prefix "$GUESTNETWORK")"

	i1=`echo $IP | cut -d . -f 1`
	i2=`echo $IP | cut -d . -f 2`
	i3=`echo $IP | cut -d . -f 3`
	i4=`echo $IP | cut -d . -f 4`
	
	mask=$(( ((1<<32)-1) & (((1<<32)-1) << (32 - $PREFIX)) ))
	echo $(( $i1 & ($mask>>24) )).$(( $i2 & ($mask>>16) )).$(( $i3 & ($mask>>8) )).$(( $i4 & $mask ))
}

convert_netmask() { # convert cidr to netmask
    value=$(( 0xffffffff ^ ((1 << (32 - $1)) - 1) ))
    echo "$(( (value >> 24) & 0xff )).$(( (value >> 16) & 0xff )).$(( (value >> 8) & 0xff )).$(( value & 0xff ))"
}

IP_Local(){
	if echo "$1" | grep -qE '(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.168\.)'; then
		return 0
	elif [ "$1" = "127.0.0.1" ]; then
		return 0
	else
		return 1
	fi
}

IP_Router(){
	if [ "$1" = "$(nvram get lan_ipaddr)" ] || [ "$1" = "127.0.0.1" ]; then
		return 0
	elif [ "$1" = "$(eval echo "$GUESTLANIP" | cut -f1-3 -d".").$(nvram get lan_ipaddr | cut -f4 -d".")" ]; then
		return 0
	else
		return 1
	fi
}

Client_Isolate() {

	ISOBEFORE="$(nvram get "${GUESTIF}_ap_isolate")"
	if [ "$CLIENTISOLATE" = "false" ] && [ $ISOBEFORE = "0" ];then
		return 0
	fi
	if [ "$CLIENTISOLATE" = "true" ] && [ $ISOBEFORE = "1" ];then
		return 0
	fi	

	Print_Output true "Client Isolation Setting has changed, setting NVRAM and restarting wireless interface" "$WARN"
	
	if [ "CLIENTISOLATE" = "true" ]; then
		nvram set "${GUESTIF}_ap_isolate"="1"
	else
		nvram set "${GUESTIF}_ap_isolate"="0"
	fi
	
	nvram commit
	WIRELESSRESTART="true"
	service restart_wireless
	
	return 1
}


Configure_NVRAM() {

	local BR0IFS="$(nvram get br0_ifnames)"
	local LANIFS="$(nvram get lan_ifnames)"

	Print_Output true "Setting NVRAM network variables......"

	if [ "$(nvram get lan1_ifnames)" = "$LANPORTS"" ""$GUESTIF" ] && [ "$(nvram get "${GUESTBR}"_ifnames)" = "$GUESTIF"" ""$LANPORTS" ]; then
		return
	else
	
		for IFN in "$LANPORTS"; do
			LANIFS="$(echo ${LANIFS} | sed s/"$IFN"//)"
		done
	
		LANIFS="$(echo ${LANIFS} | sed s/"$GUESTIF"//)"
	
		for IFN in "$LANPORTS"; do
			BR0IFS="$(echo ${BR0IFS} | sed s/"$IFN"//)"
		done

		BR0IFS="$(echo ${BR0IFS} | sed s/"$GUESTIF"//)"

		nvram set lan_ifnames="$LANIFS"
		nvram set br0_ifnames="$BR0IFS"
		nvram set "${GUESTBR}"_ifnames="$GUESTIF"" ""$LANPORTS"
		nvram set "${GUESTBR}"_ifname="$GUESTBR"
		
		nvram set lan1_ifnames="$LANPORTS"" ""$GUESTIF"
		nvram set lan1_ifname="$GUESTBR"
		nvram set lan1_ipaddr="$GUESTLANIP"
		nvram set lan1_netmask="$GUESTLANMASK"
	
		killall eapd
		eapd &
		sleep 5
	fi
}

Iface_BounceClients(){

	Print_Output true "Bouncing wireless clients from guest network interface"

	wl -i "$GUESTIF" radio off >/dev/null 2>&1
	sleep 10
	wl -i "$GUESTIF" radio on >/dev/null 2>&1

	ARPDUMP="$(arp -an)"
	IFACE_MACS="$(wl -i "${GUESTIF}" assoclist)"
	if [ "$IFACE_MACS" != "" ]; then
		IFS=$'\n'
		for GUEST_MAC in $IFACE_MACS; do
			GUEST_MACADDR="${GUEST_MAC#* }"
			GUEST_ARPINFO="$(arp -an | grep -i "$GUEST_MACADDR")"
			for ARP_ENTRY in $GUEST_ARPINFO; do
				GUEST_IPADDR="$(echo "$GUEST_ARPINFO" | awk '{print $2}' | sed -e 's/(//g;s/)//g')"
				arp -d "$GUEST_IPADDR"
			done
		done
		unset IFS
	fi
	ip -s -s neigh flush all >/dev/null 2>&1
	killall -q networkmap
	sleep 5
	if [ -z "$(pidof networkmap)" ]; then
		networkmap >/dev/null 2>&1 &
	fi
}

Execute_UserScripts(){
	FILES="$USER_SCRIPT_DIR/*.sh"
	for f in $FILES; do
		if [ -f "$f" ]; then
			Print_Output true "Executing user script: $f"
			sh "$f"
		fi
	done
}

Configure_bridge() {
	# if $1=force, then don't check, just do..... Errors be dammed!!
	
	Print_Output true "Function Configure_bridge called...."

	# Check to see if guest bridge is up and functional
	
	Set_Lan_Access
	Client_Isolate
	
	if ! [ "$1" = "force" ];then
		if [ -f /sys/class/net/${GUESTBR}/operstate ]; then
			Print_Output true "Bridge $GUESTBR appears to be already setup... returning" "$PASS"
			return 1
		fi
	else
	
		if [ "$1" = "force" ];then
			Print_Output true "Configure_bridge called with force option ..... forcing reconfiguration of bridge $GUESTBR" "$WARN"
		fi
	
		local mask="$(cidr_prefix $GUESTNETWORK)"
		
		Print_Output true "New bridge $GUESTBR does not appear to be active, setting up bridges...." "$WARN"
		
		brctl addbr "$GUESTBR"
		brctl setfd "$GUESTBR" 2
		brctl stp "$GUESTBR" on

		brctl delif br0 "$GUESTIF"
		brctl delif br0 "$LANPORTS"

		brctl addif "$GUESTBR" "$GUESTIF"
		brctl addif "$GUESTBR" "$LANPORTS"

		ifconfig "$GUESTBR" "$GUESTLANIP" netmask $(convert_netmask $mask)
		ifconfig "$GUESTBR" allmulti up

		Configure_NVRAM
		
		return 0
	fi

}

Firewall_Rules() {

	Print_Output true "Setting up firewall rules"

	# Setup Iptables - Delete things first

	iptables -t filter -D INPUT -j GuestInput > /dev/null 2>&1
	iptables -t filter -D FORWARD -j GuestForward > /dev/null 2>&1

	iptables -t filter -F GuestInput > /dev/null 2>&1
	iptables -t filter -F GuestForward > /dev/null 2>&1
	iptables -t filter -F GuestReject > /dev/null 2>&1
	iptables -t filter -X GuestInput > /dev/null 2>&1
	iptables -t filter -X GuestForward > /dev/null 2>&1
	iptables -t filter -X GuestReject > /dev/null 2>&1

	# Iptables - Add Guest Network Rules

	iptables -t filter -N GuestInput
	iptables -t filter -N GuestReject
	iptables -t filter -N GuestForward
	iptables -t filter -N DNSRules

	iptables -t filter -I INPUT -j GuestInput
	iptables -t filter -I GuestReject -j REJECT

	# Begin INPUT Rules

	iptables -t filter -I GuestInput -i "$GUESTBR" -j GuestReject
	iptables -t filter -I GuestInput -i "$GUESTBR" -p icmp -j ACCEPT
	iptables -t filter -I GuestInput -i "$GUESTBR" -p udp -m multiport --dports 67,68,123,853 -j ACCEPT
	iptables -t filter -I GuestInput -i "$GUESTBR" -p udp -m udp --dport 53 -j ACCEPT
	iptables -t filter -I GuestInput -i "$GUESTBR" -p tcp -m tcp --dport 53 -j ACCEPT
	
	if [ "$TWOWAY" = "true" ] || [ "$ONEWAY" = "true" ]; then
		iptables -t filter -I GuestInput -d 224.0.0.0/4 -i "$GUESTBR" -j ACCEPT
	fi
	
	if [ "$ENABLED_WINS" -eq 1 ] && [ "$ENABLED_SAMBA" -eq 1 ]; then
		iptables -t filter -I GuestInput -i "$GUESTBR" -p udp -m multiport --dports 137,138 -j ACCEPT
	fi

	# Begin forward Rules
	
	#iptables -t filter -I FORWARD ! -i "$GUESTBR" -o eth5 -j logdrop

	iptables -t filter -I GuestForward -i "$GUESTBR" -j ACCEPT

	if [ "$TWOWAY" = "false" ]; then
		iptables -t filter -I GuestForward ! -i "$IFACE_WAN" -o "$GUESTBR" -j GuestReject
		iptables -t filter -I GuestForward -i "$GUESTBR" ! -o "$IFACE_WAN" -j GuestReject
	fi

	if [ "$ONEWAY" = "true" ]; then
		iptables -t filter -I GuestForward ! -i "$IFACE_WAN" -o "$GUESTBR" -j ACCEPT
		iptables -t filter -I GuestForward -i "$GUESTBR" ! -o "$IFACE_WAN" -m state --state RELATED,ESTABLISHED -j ACCEPT
	fi
	
	if [ "$TWOWAY" = "false" ] && [ "$ONEWAY" = "true" ]; then 
		iptables -t filter -D GuestForward ! -i "$IFACE_WAN" -o "$GUESTBR" -j GuestReject > /dev/null 2>&1
	fi
	
	if [ "$CLIENTISOLATE" = "true" ]; then
		iptables -t filter -I GuestForward -i "$GUESTBR" -o "$GUESTBR" -j GuestReject
	fi
	
	if [ "$BLOCKINTERNET" = "true" ]; then
		iptables -t filter -I GuestForward -i "$GUESTBR" -o "$IFACE_WAN" -j GuestReject
		iptables -t filter -I GuestForward -i "$IFACE_WAN" -o "$GUESTBR" -j DROP
	fi
	
	if [ "$ENABLED_NTPD" -eq 1 ]; then
		iptables -t filter -I GuestForward -i "$GUESTBR" -p tcp --dport 123 -j REJECT
		iptables -t filter -I GuestForward -i "$GUESTBR" -p udp --dport 123 -j REJECT
	fi
	
	iptables -t filter -I FORWARD -j GuestForward

}

NAT_Rules() {

	Print_Output true "Setting up NAT Rules"

	# Delete firewall rules dealing with guest network
	iptables -t nat -D PREROUTING -i "$GUESTBR" -p tcp -m tcp --dport 123 -j DNAT --to-destination "$LAN_IP" > /dev/null 2>&1
	iptables -t nat -D PREROUTING -i "$GUESTBR" -p udp -m udp --dport 123 -j DNAT --to-destination "$LAN_IP" > /dev/null 2>&1
	iptables -t nat -D POSTROUTING -s "$LANSUBNET" -d "$LANSUBNET" -o "$GUESTBR" -j MASQUERADE > /dev/null 2>&1

	# Add firewall rules dealing with guest netwrok

	if [ "$ENABLED_NTPD" -eq 1 ]; then
		iptables -t nat -I PREROUTING -i "$GUESTBR" -p tcp -m tcp --dport 123 -j DNAT --to-destination "$LAN_IP"
		iptables -t nat -I PREROUTING -i "$GUESTBR" -p udp -m udp --dport 123 -j DNAT --to-destination "$LAN_IP"
	fi

	iptables -t nat -I POSTROUTING -s "$LANSUBNET" -d "$LANSUBNET" -o "$GUESTBR" -j MASQUERADE

}

DNS_Rules() {
	ACTIONS=""
	IFACE="$2"
	
	case $1 in
		create)
			ACTIONS="-D -I"
		;;
		delete)
			ACTIONS="-D"
		;;
	esac
	
	for ACTION in $ACTIONS; do
		if IP_Local "$DNS1" || IP_Local "$DNS2"; then
			RULES=$(iptables -nvL "$INPT" --line-number | grep "$IFACE" | grep "pt:53" | awk '{print $1}' | sort -nr)
			for RULENO in $RULES; do
				iptables -D GuestInput "$RULENO"
			done
			
			RULES=$(iptables -nvL "$FWRD" --line-number | grep "$IFACE" | grep "pt:53" | awk '{print $1}' | sort -nr)
			for RULENO in $RULES; do
				iptables -D GuestForward "$RULENO"
			done
			
			if IP_Router "$DNS1" "$GUESTBR" || IP_Router "$$DNS2" "$GUESTBR"; then
				RULES=$(iptables -nvL "$INPT" --line-number | grep "$IFACE" | grep "multiport dports 80,443" | awk '{print $1}' | sort -nr)
				for RULENO in $RULES; do
					iptables -D GuestInput "$RULENO"
				done
				
				for PROTO in tcp udp; do
					iptables "$ACTION" GuestInput -i "$GUESTBR" -p "$PROTO" --dport 53 -j ACCEPT
				done
			fi
			if [ "$$DNS1" != "$DNS2" ]; then
				if IP_Local "$(eval echo "$DNS1")" && ! IP_Router "$(eval echo "$DNS1")" "$GUESTBR"; then
					for PROTO in tcp udp; do
						iptables "$ACTION" GuestForward -i "$GUESTBR" -d "$DNS1" -p "$PROTO" --dport 53 -j ACCEPT
						iptables "$ACTION" GuestForward -o "$GUESTBR" -s "$DNS1" -p "$PROTO" --sport 53 -j ACCEPT
					done
				fi
				if IP_Local "$DNS2" && ! IP_Router "$DNS2" "$GUESTBR"; then
					for PROTO in tcp udp; do
						iptables "$ACTION" GuestForward -i "$GUESTBR" -d "$DNS2" -p "$PROTO" --dport 53 -j ACCEPT
						iptables "$ACTION" GuestForward -o "$GUESTBR" -s "$DNS2" -p "$PROTO" --sport 53 -j ACCEPT
					done
				fi
			else
				if ! IP_Router "$DNS1" "$GUESTBR"; then
					for PROTO in tcp udp; do
						iptables "$ACTION" GuestForward -i "$GUESTBR" -d "$DNS1" -p "$PROTO" --dport 53 -j ACCEPT
						iptables "$ACTION" GuestForward -o "$GUESTBR" -s "$DNS1" -p "$PROTO" --sport 53 -j ACCEPT
					done
				fi
			fi
		else
			RULES=$(iptables -nvL GuestInput --line-number | grep "$GUESTBR" | grep "pt:53" | awk '{print $1}' | sort -nr)
			for RULENO in $RULES; do
				iptables -D GuestInput "$RULENO"
			done
			
			RULES=$(iptables -nvL GuestForward --line-number | grep "$GUESTBR" | grep "pt:53" | awk '{print $1}' | sort -nr)
			for RULENO in $RULES; do
				iptables -D GuestForward "$RULENO"
			done
		fi
		
	done	

}

Clean_EBT() {

	Print_Output true "Clearing any ebtable rules...."

	# ebtable rules 
	# In our default config, these rules should not exist, but delete them just in case
	ebtables -t broute -D BROUTING -p IPv4 -i "$GUESTIF" --ip-dst "$LAN_IP"/24 --ip-proto tcp -j DROP > /dev/null 2>&1
	ebtables -t broute -D BROUTING -p IPv4 -i "$GUESTIF" --ip-dst "$LAN_IP" --ip-proto icmp -j ACCEPT > /dev/null 2>&1
	ebtables -t broute -D BROUTING -p IPv4 -i "$GUESTIF" --ip-dst "$LAN_IP"/24 --ip-proto icmp -j DROP > /dev/null 2>&1

	ebtables -t broute -D BROUTING -p ipv4 -i "$GUESTIF" -j DROP > /dev/null 2>&1	
	ebtables -t broute -D BROUTING -p ipv6 -i "$GUESTIF" -j DROP > /dev/null 2>&1
	ebtables -t broute -D BROUTING -p arp -i "$GUESTIF" -j DROP > /dev/null 2>&1
}

Set_Lan_Access() {

	Print_Output true "Checking to LAN access nvram variable....."

	if [ "$(nvram get "${GUESTIF}_lanaccess")" != "on" ]; then
		Print_Output true "LAN access nvram varibale is not set correctly. Setting and restarting wireless interface" "$WARN"
		nvram set "$GUESTIF"_lanaccess=on
		nvram commit
		WIRELESSRESTART="true"
		service restart_wireless >/dev/null 2>&1
		return 0
	else	
		return 1
	fi
}



############# Start of main script  ##################



GUESTLANIP="$(cidr_ip "$GUESTNETWORK")"
LANSUBNET="$(Get_NetworkIP)"/"$(cidr_prefix "$GUESTNETWORK")"
WIRELESSRESTART="false"

case "$1" in
	firewall)
		Print_Output true "Script called with firewall option.... Setting up firewall and nat rules"
		Check_Lock
		if ! [ -f /sys/class/net/${GUESTBR}/operstate ]; then
			Configure_bridge
		fi
		Clean_EBT
		Firewall_Rules
		NAT_Rules
		;;
	nat)
		Print_Output true "Script called with nat option..... Setting up nat rules"
		if ! [ -f /sys/class/net/${GUESTBR}/operstate ]; then
			Check_Lock
			Configure_bridge
			Firewall_Rules
		fi
		Clean_EBT
		NAT_Rules
		;;
	check)
		Print_Output true "Script called with check option .... Checking to see if iptables rules and bridge still in place"
		Check_Lock
		if ! iptables -nL | grep -q "GuestInput" || [ ! Configure_bridge ]; then
			Print_Output true "Either the iptables rules or the new bridge is not present... reapplying network changes" "$WARN"
			Clean_EBT
			Firewall_Rules
			NAT_Rules
		else
			Print_Output true "Iptable rules and $GUESTBR appear to be in place... exiting" "$PASS"
			Clear_Lock
			exit 0
		fi
		;;
	isolate)
		Print_Output true "Script called with option isolate.... Checking client isolation"
		Check_Lock
		if Client_Isolate; then
			Clear_Lock
			exit 0
		fi
		;;
	bounce_clients)
		Print_Output true "Script called with option bounce_clients.... Bouncing all clients from the $GUESTIF interface"
		Check_Lock
		Iface_BounceClients
		exit 0
		;;
	start)
		Print_Output true "Script called with option start.... Setting up new bridge $GUESTBR for interface $GUESTIF"
		Check_Lock
		Configure_bridge force
		Clean_EBT
		Firewall_Rules
		NAT_Rules
		;;
	*)
		echo
		echo "usage: guest-net.sh {start|firewall|nat|check|isolate|bounce_clients}"
		echo
		exit 0
		;;
esac

if [ "$WIRELESSRESTART" = "false" ]; then
	Print_Output true "Bouncing clients on $GUESTIF before exiting"
	Iface_BounceClients
fi

Clear_Lock

