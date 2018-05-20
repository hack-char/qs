#!/bin/bash

if [[ $EUID != 0 ]]; then
	echo Error! You need to be root to copy these root owned files to their install directories!
	exit 1
fi

if [ ! -f /etc/debian_version ]; then
	echo ERROR! This is only verified to work on Debian!
	echo You\'ll have to manually comment out this check if you insist on trying qs
	exit 1
fi

DEPENDS="/bin/ip /bin/sed /bin/ps /usr/bin/cut /usr/bin/sort /usr/bin/head /usr/bin/tr /usr/bin/printf /usr/sbin/nft
 /bin/ls /usr/bin/logname /usr/bin/wc /bin/lsmod /usr/bin/uniq /usr/bin/tac /bin/grep /sbin/rmmod /sbin/modprobe /usr/bin/qemu-system-x86_64"

for d in $DEPENDS; do
	if [ ! -x $d ]; then
		echo ERROR! Can not find $d 
		echo This must be installed before installing qs
		exit 1
	fi
done

function verify_install() {
	if [[ ! -f $1 || ! -d $2 ]]; then
		echo ERROR! Need to install $3 and have $1 available
		exit 1
	else
		if [ -f $2 ]; then
			cp ${2} ${2}.bak
		fi
		cp $1 $2
	fi
}

verify_install logrotate.firewall.conf /etc/logrotate.d LogRotate
verify_install if-qs /etc/network/if-up.d ifup
ln -fs /etc/network/if-up.d/if-qs /etc/network/if-post-down.d/if-qs
verify_install nftables.conf /etc NFTables
verify_install qs.service /etc/systemd/system SystemD
verify_install rsyslog.firewall.conf /etc/rsyslog.d rSyslogD
verify_install sudoers_qs /etc/sudoers.d sudo
verify_install qs /usr/bin QS
touch /var/log/firewall.log
if [[ `grep -q qemu /etc/group; echo $?` == 1 ]]; then
	groupadd qemu
fi
systemctl restart rsyslog
systemctl enable nftables
systemctl enable qs

