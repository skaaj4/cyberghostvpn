#!/usr/bin/env bash

enable_dns_port() {
	echo "Allowing PORT 53 - IN/OUT"
	sudo ufw allow out 53 #Allow port 53 on all interface for initial VPN connection
	sudo ufw allow in 53
}

disable_dns_port() {
	echo "Blocking PORT 53 - IN/OUT"
	sudo ufw delete allow out 53 #Remove Local DNS Port to prevent leaks
	sudo ufw delete allow in 53
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(<"${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# Loads various settings that are used elsewhere in the script
# This should be called before any other functions
docker_setup_env() {
	file_env 'ACC'
	file_env 'PASS'
}

docker_setup_env
sudo ufw enable #Start Firewall

FILE=/usr/local/cyberghost/uninstall.sh
if [ ! -f "$FILE" ]; then
	echo "CyberGhost CLI not installed. Installing..."
	bash /install.sh
	echo "Installed"
fi

FIREWALL_FILE=/.FIREWALL.cg
if [ ! -f "$FIREWALL_FILE" ]; then
	echo "Initiating Firewall First Time Setup..."

	sysctl -w net.ipv6.conf.all.disable_ipv6=1 #Disable IPV6
	sysctl -w net.ipv6.conf.default.disable_ipv6=1
	sysctl -w net.ipv6.conf.lo.disable_ipv6=1
	sysctl -w net.ipv6.conf.eth0.disable_ipv6=1
	sysctl -w net.ipv4.ip_forward=1

	sudo ufw disable #Stop Firewall
	export CYBERGHOST_API_IP=$(getent ahostsv4 v2-api.cyberghostvpn.com | grep STREAM | head -n 1 | cut -d ' ' -f 1)
	sudo ufw default deny outgoing #Deny All traffic by default on all interfaces
	sudo ufw default deny incoming
	sudo ufw allow out on cyberghost from any to any #Allow All over cyberghost interface
	sudo ufw allow in on cyberghost from any to any
	sudo ufw allow in 1337 #Allow port 1337 for CyberGhost Communication
	sudo ufw allow out 1337
	sudo ufw allow out from any to "$CYBERGHOST_API_IP" #Allow v2-api.cyberghostvpn.com [104.20.0.14] IP for connection
	sudo ufw allow in from "$CYBERGHOST_API_IP" to any

	#Allow all ports in WHITELISTPORTS ENV [Seperate by ',']
	if [ -n "${WHITELISTPORTS}" ]; then
		echo "Setting Whitelisted Ports..."
		IFS=',' read -a array <<<"$WHITELISTPORTS"
		for i in "${array[@]}"; do
			echo "Whitelisting Port:" "$i"
			sudo ufw allow "$i"
		done
	fi

	sudo ufw enable #Start Firewall
	echo "Firewall Setup Complete"
	echo 'FIREWALL ACTIVE WHEN FILE EXISTS' >.FIREWALL.cg
fi

#Login to account if config not exist
config_ini=/home/root/.cyberghost/config.ini
if [ ! -f "$config_ini" ]; then
	echo "Logging into CyberGhost..."
	enable_dns_port
	expect /auth.sh
	disable_dns_port
fi

if [ -n "${NETWORK}" ]; then
	echo "Adding network route..."
	export LOCAL_GATEWAY=$(ip r | awk '/^def/{print $3}') # Get local Gateway
	ip route add $NETWORK via $LOCAL_GATEWAY dev eth0     #Enable access to local lan
	echo "$NETWORK" "routed to " "$LOCAL_GATEWAY" " on eth0"
fi

FILE_RUN=/home/root/.cyberghost/run.sh
if [ ! -f "$FILE_RUN" ]; then
	cp /run.sh /home/root/.cyberghost/run.sh
fi

#WIREGUARD START AND WATCH
enable_dns_port
bash /home/root/.cyberghost/run.sh #Start the CyberGhost run script
disable_dns_port
while true; do #Watch if Connection is lost then reconnect
	sleep 30
	if [[ $(sudo cyberghostvpn --status | grep 'No VPN connections found.' | wc -l) = "1" ]]; then
		echo 'VPN Connection Lost - Attempting to reconnect....'

		enable_dns_port

		bash /home/root/.cyberghost/run.sh #Start the CyberGhost run script

		disable_dns_port
	fi
done
