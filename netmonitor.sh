#!/bin/bash

set -e
cd /opt/netmonitor

router="nod-gw1.su.se"
switches="./switches.conf"
vlans="./vlans.conf"
logfolder="/var/log/netmonitor"
map="$logfolder/connection.map"
log="$logfolder/mappings.log"
secret=$(cat ./secret.conf)

ip_mac_mib=iso.3.6.1.2.1.3.1.1.2
mac_id_mib=iso.3.6.1.2.1.17.4.3.1.2
id_port_mib=iso.3.6.1.2.1.17.1.4.1.2 
port_name_mib=iso.3.6.1.2.1.31.1.1.1.1
port_comment_mib=iso.3.6.1.2.1.31.1.1.1.18

stamp() {
    date '+%F %T'
}

walk() {
    local secret="$1" && shift
    local host="$1" && shift
    local mib="$1" && shift

    snmpwalk -v1 -r0 -c "$secret" -OQ "$host" "$mib" 2>/dev/null \
	| sed -e "s/$mib\.//" -e 's/"//g' -e 's/ //g'
}

swalk() {
    local host="$1" && shift
    local mib="$1" && shift
    local vlan="$1" && shift

    walk "${secret}@${vlan}" "$host" "$mib"
}

sget() {
    local host="$1" && shift
    local mib="$1" && shift
    local vlan="$1" && shift

    swalk "$host" "$mib" "$vlan" | cut -d= -f2
}

declare -A mac_ip_mappings
starttime=$(stamp)

for line in $(walk "$secret" "$router" "$ip_mac_mib")
do
    ip=$(echo "$line" | cut -d= -f1 | cut -d. -f3-)
    mac=$(echo "$line" | cut -d= -f2 | sed -r 's/(..)/&:/g;s/:$//')
    mac_ip_mappings["$mac"]="$ip"
done

if [ -e "$map" ]; then
    mv "$map" "$map.old"
else
    touch "$map.old"
fi
touch "$map"

while read switch garbage
do
    if [ "${switch:0:1}" = "#" ]; then
	continue
    fi

    if ! ping -c3 -w3 "$switch" >/dev/null 2>&1; then
	if ! [ -e "$logfolder/$switch.down" ]; then 
	    touch "$logfolder/$switch.down"
	    echo "$(stamp) - $switch is down"
	fi
	continue
    elif [ -e "$logfolder/$switch.down" ]; then
	rm "$logfolder/$switch.down"
	echo "$(stamp) - $switch is back up"
    fi

    shortswitch=$(echo "$switch" | cut -d. -f1)
    while read vlan garbage
    do
	if [ "${vlan:0:1}" = "#" ]; then
	    continue
	fi
	
	for line in $(swalk "$switch" "$mac_id_mib" "$vlan")
	do
	    mac=$(printf '%02X:%02X:%02X:%02X:%02X:%02X\n' \
		$(echo "$line" | cut -d= -f1 | tr '.' ' '))
	    portid=$(echo "$line" | cut -d= -f2)
	    portnum=$(sget "$switch" "$id_port_mib.$portid" "$vlan")
	    portname=$(sget "$switch" "$port_name_mib.$portnum" "$vlan")
	    portcomment=$(sget "$switch" "$port_comment_mib.$portnum" "$vlan")

	    if ! [ "${portname:0:2}" = "Gi" ]; then
		continue
	    fi
	    
	    {
		echo -n "$(stamp) $shortswitch $portname $portcomment vlan$vlan: "
		echo "${mac_ip_mappings["$mac"]} $mac"
	    } >> "$map"
	done
    done < $vlans
done < $switches
endtime=$(stamp)

cut -d' ' -f3- "$map" | sed "s/^ *//" | sort -k3 > "$map.tmp"
cut -d' ' -f3- "$map.old" | sed "s/^ *//" | sort -k3 > "$map.old.tmp"

{
    echo "$starttime Scan started"
    diff -N "$map.old.tmp" "$map.tmp" \
	| grep "^[<>]" \
	| sed -e "s/</Down:/" -e "s/>/Up:/" \
	| ts "$starttime"

    echo "$endtime Scan ended"
} >> "$log"

rm "$map.tmp" "$map.old.tmp"
