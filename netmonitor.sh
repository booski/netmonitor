#!/bin/bash

set -e

router="nod-gw1.su.se"
switches="./switches.conf"
vlans="./vlans.conf"
logfolder="/var/log/netmonitor"
map="$logfolder/connection.map"
log="$logfolder/mappings.log"

ip_mac_mib=iso.3.6.1.2.1.3.1.1.2
mac_id_mib=iso.3.6.1.2.1.17.4.3.1.2
id_port_mib=iso.3.6.1.2.1.17.1.4.1.2 
port_name_mib=iso.3.6.1.2.1.31.1.1.1.1
port_comment_mib=iso.3.6.1.2.1.31.1.1.1.18

stamp() {
    date --rfc-3339=seconds
}

walk() {
    local secret="$1"
    local host="$2"
    local mib="$3"

    snmpwalk -v 1 -c "$secret" -OQ "$host" "$mib" | sed -e "s/$mib\.//" -e "s/ //g" -e 's/"//g'
}

swalk() {
    local secret="$1"
    local host="$2"
    local mib="$3"
    local vlan="$4"

    walk "$secret"@"$vlan" "$host" "$mib"
}

sget() {
    local secret="$1"
    local host="$2"
    local mib="$3"
    local vlan="$4"

    swalk "$secret" "$host" "$mib" "$vlan" | cut -d= -f2
}

cd /opt/netmonitor
secret=$(cat ./secret.conf)

declare -A mac_ip_mappings
starttime=$(stamp)

for line in $(walk dsv "$router" "$ip_mac_mib" \
    | cut -d. -f13- \
    | sed -r -e 's/ *$//' -e 's/ /:/g')
do
    ip=$(echo "$line" | cut -d= -f1)
    mac=$(echo "$line" | cut -d= -f2)
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
	    echo "$(stamp) - $name"
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
	
	for line in $(swalk dsv-test "$switch" "$mac_id_mib" "$vlan")
	do
	    mac=$(printf '%02X:%02X:%02X:%02X:%02X:%02X\n' $(echo "$line" | cut -d= -f1 | tr '.' ' '))
	    portid=$(echo "$line" | cut -d= -f2)
	    portnum=$(sget dsv-test "$switch" "$id_port_mib.$portid" "$vlan")
	    portname=$(sget dsv-test "$switch" "$port_name_mib.$portnum" "$vlan")
	    portcomment=$(sget dsv-test "$switch" "$port_comment_mib.$portnum" "$vlan")
	    
	    echo "$(stamp) $shortswitch $portname $portcomment: ${mac_ip_mappings["$mac"]} $mac" >> "$map"
	done
    done < $vlans
done < $switches
endtime=$(stamp)

sort "$map" -o "$map"

cut -d@ -f2 "$map" | sed "s/^ *//" > "$map.tmp"
cut -d@ -f2 "$map.old" | sed "s/^ *//" > "$map.old.tmp"

{
    echo "$starttime Scan started"
    diff -N "$map.old.tmp" "$map.tmp" \
	| grep "^[<>]" \
	| sed -e "s/</Down:/" -e "s/>/Up:/" \
	| ts "$starttime"

    echo "$endtime Scan ended"
} >> "$log"

rm "$map.tmp" "$map.old.tmp"
