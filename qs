#!/bin/bash
#
#  Qemu Script v3.0
#  2018/05/12 https://github.com/hack-char
#
#  Copyright 2018, char
#
#    This file is part of Qemu Script.
#
#    Qemu Script is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    Qemu Script is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with Qemu Script.  If not, see <http://www.gnu.org/licenses/>.
#
####################################################

function qs_help() {
	echo 'QS v3.0 - Qemu Script'
	echo
	echo ' sudo qs [COMMAND] [VM INDEX] [ARGS]'
	echo
	echo "Configuration files by default are in $HOME/.qs and /etc/qs"
	echo "Requires running as root for networking and PCI forwarding"
	echo "Default is users require group qemu"
	echo
	echo '*** Examples ***'
	echo
	echo 'up VM-NAME'
	echo 'down IDX '
	echo 'reset IDX '
	echo 'ctrl-alt-del IDX '
	echo 'info '
	echo
	exit 0
}

LOGNAME=/usr/bin/logname

# defaults SET BRIDGE per your environment
DEFAULT_QS_CONFIG=/etc/qs
DEFAULT_USER_QS_CONFIG=/home/`${LOGNAME}`/.qs
# these need to be the same in nftables.conf
DEFAULT_QS_BRIDGE=br0
DEFAULT_QS_BRIDGE_IP=10.88.105.0/24

##### Shouldn't have to edit anything below this #########

# all dependencies besides QEMU
# 'pass' is optional and supported
IP=/bin/ip
SED=/bin/sed
PS=/bin/ps
CUT=/usr/bin/cut
SORT=/usr/bin/sort
HEAD=/usr/bin/head
TR=/usr/bin/tr
PRINTF=/usr/bin/printf
NFT=/usr/sbin/nft
LS=/bin/ls
WC=/usr/bin/wc
LSMOD=/bin/lsmod
UNIQ=/usr/bin/uniq
TAC=/usr/bin/tac
GREP=/bin/grep
RMMOD=/sbin/rmmod
MODPROBE=/sbin/modprobe
QS_QEMU_CMD=/usr/bin/qemu-system-x86_64

if [ $EUID != 0 ]; then
	echo This script must be run SUDO ROOT...
	exit 1
fi

QS_CONFIG=${QS_CONFIG:-$DEFAULT_QS_CONFIG}
QS_USER_CONFIG=${QS_USER_CONFIG:-$DEFAULT_USER_QS_CONFIG}
QS_BRIDGE=${QS_BRIDGE:-$DEFAULT_QS_BRIDGE}
QS_BRIDGE_IP=${QS_BRIDGE_IP:-$DEFAULT_QS_BRIDGE_IP}

QS_QEMU_OPTS='-localtime -usb -enable-kvm -monitor none -balloon virtio -numa node,nodeid=0 -numa node,nodeid=1'
# by default we are enabling pulse audio
# it seems to work well when using multiple VMs
QS_QEMU_ENV='QEMU_AUDIO_DRV=pa'
QS_DEFAULT_CORES=1
QS_DEFAULT_MEM=1
QS_CURRENT_VM=''

# general configuration stored in arrays with VM name as index
declare -A image
declare -A raw
declare -A auto
declare -A cpu
declare -A wifi
declare -A usb
declare -A cores
declare -A mem
declare -A memslots
declare -A maxmem
declare -A bootonce
declare -A headless
declare -A vnc
declare -A internet
declare -A disk
declare -A index
declare -A before
declare -A after
declare -A vfio
declare -A mutevm
declare -A param
declare -A ether
declare -A pci_driver
declare -A pci_id
declare -A pci_module
declare igroup
declare ifile

# VM we are bringing up
up_vm=""

# various helper functions ####################################################

# helper function to print error
function qs_require_vm() {
	if [[ x$QS_CURRENT_VM == x ]]; then
		echo QS_CONFIG ERROR! Must specify vm name before $@
		exit -1
	fi
}

function remove_mod() {
	if [ `$GREP -q $1 /proc/modules; echo $?` == 0 ]; then
		$RMMOD $1
	fi
}

# parse each line of a configuration file
function parseLine() {
	cmd=`echo ${1} | $TR A-Z a-z`
	shift
	case $cmd in
		vm)
			QS_CURRENT_VM=$@ ;;
		image)
			qs_require_vm image name
			image["$QS_CURRENT_VM"]=$1 ;;
		raw)
			qs_require_vm raw disk files
			raw["$QS_CURRENT_VM"]=1 ;;
		auto)
			qs_require_vm auto
			auto["$QS_CURRENT_VM"]=1 ;;
		cpu)
			qs_require_vm cpu
			cpu["$QS_CURRENT_VM"]=$@ ;;
		wifi)
			qs_require_vm wifi
			wifi["$QS_CURRENT_VM"]=$@ ;;
		param)
			qs_require_vm param
			param["$QS_CURRENT_VM"]=$@ ;;
		ether)
			qs_require_vm ether
			ether["$QS_CURRENT_VM"]=$@ ;;
		usb)
			qs_require_vm usb
			usb["$QS_CURRENT_VM"]=$@ ;;
		cores)
			qs_require_vm cores
			cores["$QS_CURRENT_VM"]=$@ ;;
		mem)
			qs_require_vm mem
			mem["$QS_CURRENT_VM"]=$@ ;;
		memslots)
			qs_require_vm memslots
			memslots["$QS_CURRENT_VM"]=$@ ;;
		maxmem)
			qs_require_vm maxmem
			maxmem["$QS_CURRENT_VM"]=$@ ;;
		bootonce)
			qs_require_vm bootonce
			bootonce["$QS_CURRENT_VM"]=$@ ;;
		disk)
			qs_require_vm disk
			if [ x$2 == xraw ]; then
				disk["$QS_CURRENT_VM"]+=" ${1},format=raw"
			else
				disk["$QS_CURRENT_VM"]+=" $@" 
			fi ;;
		internet)
			qs_require_vm internet
			internet["$QS_CURRENT_VM"]=$@ ;;
		headless)
			qs_require_vm headless
			headless["$QS_CURRENT_VM"]=$@ ;;
		mute)
			qs_require_vm mute
			mutevm["$QS_CURRENT_VM"]=1 ;;
		vnc)
			qs_require_vm vnc
			vnc["$QS_CURRENT_VM"]=$@ ;;
		index)
			qs_require_vm index
			index["$QS_CURRENT_VM"]=$@ ;;
		vfio)
			qs_require_vm vfio
			vfio["$QS_CURRENT_VM"]+=" $@" ;;
	esac

}

# parse all the configuration files
function parseConf() {
	for CONF_DIR in $QS_USER_CONFIG $QS_CONFIG; do
		if [ -d $CONF_DIR ]; then
			for CONF_FILE in `$LS $CONF_DIR`; do
				if [ -r ${CONF_DIR}/${CONF_FILE} ]; then
					exec 4<${CONF_DIR}/${CONF_FILE}
					while read -u 4 conf_line; do
						parseLine $conf_line
					done
					exec 4>&-
				fi
			done
		fi
	done

	QS_CURRENT_VM=$up_vm
	while [ $# -gt 0 ]; do
		parseLine $1 $2
		shift 2
	done
}


# get next tapX value
function get_next_tap() {
	LAST_TAP=`$IP tuntap show mode tap | $SED '{s/tap\|\://g}' | $CUT -f1 -d' ' | $SORT -nr | $HEAD -n1`
	if [ x$LAST_TAP == x ]; then
		echo 0
	else
		echo $(($LAST_TAP+1))
	fi
}

# verify bridge is up, if not then bring it up
function verify_bridge() {
	$IP link show type bridge ${QS_BRIDGE} &> /dev/null
	if [ $? -eq 1 ] ; then
		$IP link add  ${QS_BRIDGE} type bridge
		$IP addr add dev ${QS_BRIDGE} ${QS_BRIDGE_IP}
		$IP link set dev ${QS_BRIDGE} up
		$NFT add element inet filter my_ip \{ $QS_BRIDGE_IP \}
		if [ `$NFT list set inet filter blacklist4_ip | grep -q $QS_BRIDGE_IP; echo $?` == 0 ]; then
			$NFT delete element inet filter blacklist4_ip \{ $QS_BRIDGE_IP \}
		fi
		/bin/echo 1 > /sys/class/net/br0/bridge/stp_state
	fi
}

# remove tapX if not assinged to running QEMU process
function rm_unused_taps() {
	infos=(`$PS -wwflC qemu-system-x86_64 | $SED -nr '{s/.* -name ([^ ]+) .*ifname=(tap[0-9]+).*/\2/p}'`)
	taps=`$IP tuntap list | grep ": tap" | $CUT -f1 -d':'`
	for j in $taps; do
		is_running=0
		for i in ${infos[*]}; do
			if [ x$j = x$i ]; then
				is_running=1
			fi
		done
		if [[ $is_running -eq 0 ]]; then
			$IP tuntap del dev $j mode tap
		fi
	done
}

function driver_dep() {
	modules=`${LSMOD} | $GREP -E "^$@" | ${SED} -e '{s|\([a-zA-Z_]\+\)[ ]\+[0-9]\+[ ]\+[0-9]\+[ ]\+\([a-zA-Z_,0-9]\+\)|\1 \2|}'`
	ret=""
	for m in `echo $modules | ${SED} -e '{s|[, ]|\n|g}' | ${SORT} - | ${UNIQ}`; do
		ret="${ret} "`echo $m | $GREP -vE "[0-9]+"`
	done
	echo $ret
}

function get_vfio() {

	LAST_SLASH="${SED} -e {s|.*/\([0-9.:a-f]\+\)$|\1|}"
	LAST_SLASHA="${SED} -e {s|.*/\([0-9._a-zA-Z-]\+\)$|\1|}"

	target=`${LS} -d /sys/bus/pci/devices/*${1}*`

	if [[ `echo $target | ${WC} -w` != 1 ]]; then
		echo Error! Select exactly one device not: ${1}
		exit 1
	fi

	cur_igroup=`${LS} -l ${target}/iommu_group | ${LAST_SLASH}`
	igroup="$igroup $cur_igroup"
	targets=""
	targets=`${LS} -l /sys/kernel/iommu_groups/${cur_igroup}/devices/ | tail -n +2 | ${LAST_SLASH}`
	target_modules=""

	ifile="$ifile /dev/vfio/${cur_igroup}"

	for t in ${targets}; do

		devid=`lspci -n -s $t | cut -f3 -d' ' | $SED '{s/:/ /g}'`
		pci_id["${t}"]=$devid

		if [ -d /sys/bus/pci/devices/${t}/driver ]; then
			driver=`${LS} -l /sys/bus/pci/devices/${t}/driver | $LAST_SLASHA`
			pci_driver["${t}"]=$driver
			cnt=0
			new_cnt=1
			mods=$driver
			while [[ $new_cnt != $cnt ]]; do
				cnt=$new_cnt
				new_mods=""
				for n in $mods; do
					for m in `driver_dep $n`; do
						new_mods="$m $new_mods"
					done
				done
				mods=" $mods "
				for m in $new_mods; do
					if [[ $mods != *" $m "* ]]; then
						mods=" $m $mods"
					fi
				done
				new_cnt=`echo $mods | wc -w`
			done
			pci_module["${t}"]=$mods
		fi

	done

}

function vfio_before() {
	for p_id in ${!pci_driver[@]}; do
		if [ -f /sys/bus/pci/devices/${p_id}/driver/unbind ]; then
			echo "$p_id" > /sys/bus/pci/devices/${p_id}/driver/unbind
		fi
		for m in ${pci_module[$p_id]}; do
			remove_mod $m
		done
	done

	$MODPROBE vfio
	$MODPROBE vfio-pci
	$MODPROBE vfio_iommu_type1

	for p_id in ${!pci_id[@]}; do
		echo "${pci_id[$p_id]}" > /sys/bus/pci/drivers/vfio-pci/new_id
	done

	for i in $ifile ; do
		if [ -c ${i} ]; then
			chown root:qemu ${i}
			chmod 660 ${i}
		else
			echo ERROR! IOMMU group file $i not found!
		fi
	done

}

function vfio_after() {

	for i in ${!pci_id[@]}; do
		echo "$i" > /sys/bus/pci/drivers/vfio-pci/unbind
		echo "${pci_id[$i]}" > /sys/bus/pci/drivers/vfio-pci/remove_id
	done

	remove_mod vfio_iommu_type1
	remove_mod vfio-pci
	remove_mod vfio

	for i in ${!pci_module[@]}; do
		for m in ${pci_module[$i]}; do
			modprobe $m
		done
	done

	for d in ${!pci_driver[@]}; do
		$MODPROBE ${pci_driver[$d]}
		echo "${d}" > /sys/bus/pci/drivers/${pci_driver[$d]}/bind >& /dev/null
	done

}


# run after QEMU completes - remove tap and IP from firewall
# args: NEW_MAC
function qs_after() {
	vfio_after

	if [ x${internet[$up_vm]} != x ]; then
		if [ `$NFT list set ip nat vm_ip | grep -q ${internet[$up_vm]}; echo $?` == 0 ]; then
			$NFT delete element ip nat vm_ip { ${internet[$up_vm]} }
		fi
	fi

	if [ `$NFT list set inet filter vm_addr | grep -q $1 ; echo $?` == 0 ]; then
		$NFT delete element inet filter vm_addr { $1 }
	fi

}


# print out status of available and running VMs ##############################################

function qs_info() {
	parseConf
	declare -a infos
	infos=(`$PS -wwC qemu-system-x86_64 -o %cpu,rss,args | $SED -nr '{s/[ ]*([0-9.]+)[ ]+([0-9.]+).* -name ([^ ]+) .*ifname=tap([0-9]+).*/\3 \4 \1 \2/p}'`)
	idx=0
	echo -e "IDX\tCPU\tMEM(kB)\t\tVM"
	while [[ ${#infos[*]} -gt $idx ]]; do
		tap_val=-1
		for i in ${!image[@]}; do
			if [[ $i == ${infos[$idx]} ]]; then
				tap_val=${infos[$(($idx+1))]}
				echo -e "${tap_val}\t${infos[$(($idx+2))]}\t${infos[$(($idx+3))]}\t\t$i"
				unset image[$i]
			fi
		done
		if [[ x$tap_val == x-1 ]]; then
			tap_val=${infos[$(($idx+1))]}
			echo -e "${tap_val}\t${infos[$(($idx+2))]}\t${infos[$(($idx+3))]}\t\t${infos[$idx]} - UNKNOWN"
		fi
		idx=$(($idx+4))
	done
	for i in ${!image[@]}; do
		echo -e "\t\t\t\t$i"
	done
	rm_unused_taps
}


# bring up NFT if not running
function verify_firewall() {
	if [ $UID -eq 0 ]; then
		if [ x`$NFT list table inet filter > /dev/null; echo $?`==1 ]; then
			if [ ! -x /etc/nftables.conf ]; then
				echo Error! No /etc/nftables.conf and firewall will not work correctly!
			else
				/etc/nftables.conf &
			fi
		fi
		for addr in `$IP addr | $SED -nr '{s/inet\s([0-9\.]+)\/[0-9]+ .*/\1/p}'`; do
			if [ x$addr != x127.0.0.1 ]; then
				$NFT add element inet filter my_ip \{ $addr \}
				if [ `$NFT list set inet filter blacklist4_ip | grep -q $addr ; echo $?` == 0 ]; then
					$NFT delete element inet filter blacklist4_ip \{ $addr \}
				fi
			fi
		done
	fi
}


#############################################################################################
# MAIN FUNCTION brings up the VM
# args: VM
#  if VM==auto then any vm set to 'auto xxx' will be brought up
function qs_up() {
	rm_unused_taps
	verify_firewall
	up_vm=$2
	shift 2
	if [ x$up_vm == xauto ]; then
		parseConf
	else
		parseConf $@
	fi
	for i in ${!image[@]}; do
		if [ ! -r ${image[$i]} ]; then
			if [[ x$up_vm == x$i ]]; then
				echo QS ERROR! VM $i can not read image file ${image[$i]}
			fi
			continue
		fi
		if [[ x$up_vm == x$i || ( x$up_vm == xauto && x${auto[$i]} != x ) ]] ; then
			verify_bridge
			NEW_TAP=`get_next_tap`
			$IP tuntap add mode tap dev tap${NEW_TAP}
			$IP link set tap${NEW_TAP} master ${QS_BRIDGE}
			$IP link set tap${NEW_TAP} up
			MEM=${mem[$i]:-$QS_DEFAULT_MEM}G
			CORES=${cores[$i]:-$QS_DEFAULT_CORES}
			DISKS=""
			VGA="-vga std"

			# std
			if [ x${maxmem[$i]} != x -a x${memslots[$i]} != x ]; then
				MEM="${MEM},slots=${memslots[$i]},maxmem=${maxmem[$i]}G"
			fi
			if [ x${headless[$i]} != x ]; then
				VGA="-vga none"
			fi
			SND="-soundhw pcspk"
			DISKFORMAT=""
			if [ x${raw[$i]} == x1 ]; then
				DISKFORMAT=",format=raw"
			fi
			if [ x${mutevm[$i]} == x ]; then
				SND="-soundhw hda"
			fi
			for j in ${disk[$i]} ; do
				DISKS+=" -drive file=${j} "
			done
			VFIO=""
			for j in ${vfio[$i]} ; do
				VFIO+=" -device vfio-pci,host=${j}"
			done
			BOOT="-boot a"
			if [ x${bootonce[$i]} != x ]; then
				BOOT="-boot once=d -cdrom ${bootonce[$i]}"
			fi
			VNC=""
			VNCPASS=""
			if [ x${vnc[$i]} != x ]; then
				VNC="-nographic -vnc :${NEW_TAP},password"
				VNCPASS="${vnc[$i]}"
			fi
			CPU=""
			if [ x${cpu[$i]} != x ]; then
				CPU="-cpu ${cpu[$i]}"
			fi
			ADDL_PARAMS=""
			for j in ${param[$i]} ; do
				ADDL_PARAMS+=" ${j} "
			done
			tap_hex=`$PRINTF "%02x" ${NEW_TAP}`
			if [ x${ether[$i]} != x ]; then
				NEW_MAC=${ether[$i]}
			else
				NEW_MAC=12:34:56:78:90:${tap_hex}
			fi
			ETHERNET="-device e1000,netdev=net0,mac=${NEW_MAC} -netdev tap,id=net0,ifname=tap${NEW_TAP},script=no,downscript=no"
			QMP="-qmp tcp:127.0.0.1:$((4000+${NEW_TAP})),server,nowait"
			IMG=""
			for j in ${image[$i]}; do
				IMG+="-drive file=${j}${DISKFORMAT}"
			done
			NAME="-name $i"
			QS_RUN="${QS_QEMU_CMD} ${QS_QEMU_OPTS} $VGA $VNC -m $MEM -smp $CORES $SND $NAME $BOOT $IMG $DISKS $ETHERNET $CPU $VFIO $QMP $ADDL_PARAMS"

			for v_arg in ${vfio[$i]} ; do
				get_vfio $v_arg
			done
			if [ x"${vfio[$i]}" != x ]; then
				vfio_before
			fi

			$NFT add element inet filter vm_addr { $NEW_MAC }
			if [ x${internet[$i]} != x ]; then
				$NFT add element ip nat vm_ip { ${internet[$i]} }
			fi

			if [ x${mutevm[$i]} != x ]; then
				QS_QEMU_ENV='QEMU_AUDIO_DRV=none'
			fi

			$( cat /dev/null | sudo -u `$LOGNAME` ${QS_QEMU_ENV} ${QS_RUN} ; qs_after $NEW_MAC) &> /dev/null &

			if [ x${VNCPASS} != x ]; then
				( sleep 1; qs_vnc $NEW_TAP $VNCPASS ) &
			fi

		fi
	done
}

###########################################################
# various functions sending QMP commands to the VM follow

# bring down VM by index
# send QMP command to TCP port to ACPI power off VM
# args: IDX
function qs_down() {
	parseConf
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	echo -e '{"execute": "system_powerdown"}\r\n'  >&4
	read -u 4 resp
	if [ $resp != {"return": {}} ]; then
		echo Error bringing $2 down "$resp"
	fi

	exec 2>&5 5>&-

	tap_hex=`$PRINTF "%02x" ${2}`
	NEW_MAC=12:34:56:78:90:${tap_hex}

	if [ x${internet[$2]} != x ]; then
		if [ `$NFT list set inet filter vm_addr | grep -q $NEW_MAC ; echo $?` == 0 ]; then
			$NFT delete element inet filter vm_addr { $NEW_MAC } &
		fi
	fi

	rm_unused_taps

}

# issue ACPI reset to VM by IDX
# send QMP command to TCP port
# args: IDX
function qs_reset() {
	parseConf
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	echo -e '{"execute": "system_reset"}\r\n'  >&4
	read -u 4 resp
	if [ $resp != {"return": {}} ]; then
		echo Error reseting $2 - "$resp"
	fi

	exec 2<&5

}

# issue cntrl - alt - delete to VM by IDX
# sends QMP command to TCP port
# args: IDX
function qs_ctrl_alt_del() {
	parseConf
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	CMD_SEND='{"execute": "send-key", "arguments":{"keys":[ {"type":"qcode", "data":"ctrl"}, {"type":"qcode", "data":"alt"}, {"type":"qcode", "data":"delete"} ]}}'
	echo -e $CMD_SEND  >&4
	GOOD_RESP=`echo -e '{"return": {}}\r\n'`
	if [ "$resp" != "$GOOD_RESP" ] ; then
		echo Error 
	fi
	exec 2<&5
}


# issue alt - ... to VM by IDX
# sends QMP command to TCP port
# args: IDX
function qs_alt_f2() {
	parseConf
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	CMD_SEND='{"execute": "send-key", "arguments":{"keys":[ {"type":"qcode", "data":"ctrl"}, {"type":"qcode", "data":"alt"}, {"type":"qcode", "data":"f2"} ]}}'
	echo -e $CMD_SEND  >&4
	GOOD_RESP=`echo -e '{"return": {}}\r\n'`
	if [ "$resp" != "$GOOD_RESP" ] ; then
		echo Error 
	fi
	exec 2<&5
}

# issue alt - ... to VM by IDX
# sends QMP command to TCP port
# args: IDX
function qs_alt_f1() {
	parseConf
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	CMD_SEND='{"execute": "send-key", "arguments":{"keys":[ {"type":"qcode", "data":"ctrl"}, {"type":"qcode", "data":"alt"}, {"type":"qcode", "data":"f1"} ]}}'
	echo -e $CMD_SEND  >&4
	GOOD_RESP=`echo -e '{"return": {}}\r\n'`
	if [ "$resp" != "$GOOD_RESP" ] ; then
		echo Error 
	fi
	exec 2<&5
}


function qs_type() {
	parseConf
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	for c in `echo $3 | $SED 's/./ &/g;s/^ //'`; do

		r=''
		#echo c is $c

		case "$c" in
			 \`) r='grave_accent' ;; 
			'~') r='shift grave_accent' ;; 
			'1') r='1' ;;
			'!') r='shift 1';;
			'2') r='2' ;;
			'@') r='shift 2';;
			'3') r='3' ;;
			'#') r='shift 3';;
			'4') r='4' ;;
			'$') r='shift 4';;
			'5') r='5' ;;
			'%') r='shift 5';;
			'6') r='6' ;;
			'^') r='shift 6';;
			'7') r='7' ;;
			'&') r='shift 7';;
			'8') r='8' ;;
			'*') r='shift 8';;
			'9') r='9' ;;
			'(') r='shift 9';;
			'0') r='0' ;;
			')') r='shift 0';;
			'=') r='equal' ;;
			'+') r='shift equal';;
			'-') r='minus' ;;
			'_') r='shift minus';;
			'q') r='q' ;;
			'Q') r='shift q' ;;
			'w') r='w' ;;
			'W') r='shift w' ;;
			'e') r='e' ;;
			'E') r='shift e' ;;
			'r') r='r' ;;
			'R') r='shift r' ;;
			't') r='t' ;;
			'T') r='shift t' ;;
			'y') r='y' ;;
			'Y') r='shift y' ;;
			'u') r='u' ;;
			'U') r='shift u' ;;
			'i') r='i' ;;
			'I') r='shift i' ;;
			'o') r='o' ;;
			'O') r='shift o' ;;
			'p') r='p' ;;
			'P') r='shift p' ;;
			'[') r='bracket_left' ;;
			'{') r='shift bracket_left' ;;
			']') r='bracket_right' ;;
			'}') r='shift bracket_right' ;;
			'\') r='backslash' ;;
			'|') r='shift backslash' ;;
			'a') r='a' ;;
			'A') r='shift a' ;;
			's') r='s' ;;
			'S') r='shift s' ;;
			'd') r='d' ;;
			'D') r='shift d' ;;
			'f') r='f' ;;
			'F') r='shift f' ;;
			'g') r='g' ;;
			'G') r='shift g' ;;
			'h') r='h' ;;
			'H') r='shift h' ;;
			'j') r='j' ;;
			'J') r='shift j' ;;
			'k') r='k' ;;
			'K') r='shift k' ;;
			'l') r='l' ;;
			'L') r='shift l' ;;
			';') r='semicolon' ;;
			':') r='shift semicolon' ;;
			 \') r='apostrophe' ;;
			 \") r='shift apostrophe' ;;
			'z') r='z' ;;
			'Z') r='shift z' ;;
			'x') r='x' ;;
			'X') r='shift x' ;;
			'c') r='c' ;;
			'C') r='shift c' ;;
			'v') r='v' ;;
			'V') r='shift v' ;;
			'b') r='b' ;;
			'B') r='shift b' ;;
			'n') r='n' ;;
			'N') r='shift n' ;;
			'm') r='m' ;;
			'M') r='shift m' ;;
			',') r='comma' ;;
			'<') r='shift comma' ;;
			'.') r='dot' ;;
			'>') r='shift dot' ;;
			'/') r='slash' ;;
			'?') r='shift slash' ;;
		esac

		CMD_SEND="{\"execute\": \"send-key\", \"arguments\":{\"keys\":[ "
		ADDL=""
		for i in $r; do
			CMD_SEND+="$ADDL {\"type\":\"qcode\", \"data\":\"$i\"}" 
			ADDL=","
		done

		CMD_SEND+=" ]}}"
		echo -e $CMD_SEND  >&4
		GOOD_RESP=`echo -e '{"return": {}}\r\n'`
		if [ "$resp" != "$GOOD_RESP" ] ; then
			echo Error
		fi
	done
	exec 2<&5
}

function qs_pass() {
	PASS=/usr/bin/pass

	if [ ! -x $PASS ]; then
		echo Pass not found!
		exit 1
	fi

	p=`sudo -u $( ${LOGNAME} ) $PASS $3`
	if [ x$p != x ]; then
		qs_type type $2 $p
	fi
	unset p
}

# issue alt - ... to VM by IDX
# sends QMP command to TCP port
# args: IDX
function qs_alt_f7() {
	parseConf
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	CMD_SEND='{"execute": "send-key", "arguments":{"keys":[ {"type":"qcode", "data":"ctrl"}, {"type":"qcode", "data":"alt"}, {"type":"qcode", "data":"f7"} ]}}'
	echo -e $CMD_SEND  >&4
	GOOD_RESP=`echo -e '{"return": {}}\r\n'`
	if [ "$resp" != "$GOOD_RESP" ] ; then
		echo Error
	fi
	exec 2<&5
}


# sets VNC password auth per 'vnc PASSWORD' from config file
# sends QMP command to TCP port
# args: IDX PASSWORD
function qs_vnc() {
	parseConf
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$1))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	CMD_SEND="{\"execute\": \"set_password\", \"arguments\":{\"password\": \"$2\", \"protocol\": \"vnc\"}}"
	echo -e $CMD_SEND  >&4
	read -u 4 resp
	GOOD_RESP=`echo -e '{"return": {}}\r\n'`
	if [ "$resp" != "$GOOD_RESP" ] ; then
		echo Error
	fi
	exec 2>&5 5>&-
	exec 4>&-
}

# sends QMP command to TCP port
# not really ready for prime time but good for debuging code
# args: IDX COMMAND
function qs_cmd() {
	parseConf
	echo $2 $3
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	echo $NETSTR
	exec 4<>$NETSTR
	echo open resp is $resp	
	read -u 4 resp
	echo $resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	echo  $resp 
	CMD_SEND="{\"execute\": \"$3\""
	shift 3
	declare -a cmdarg
	cmdarg=($@)
	do_bracket=0
	for ((i=0; i<$#; i=i+2)) ; do	
		if [[ $i -ne 0 ]]; then
			CMD_SEND="${CMD_SEND}, "
		else
			CMD_SEND="${CMD_SEND}, \"arguments\":{"
			do_bracket=1
		fi
		CMD_SEND="${CMD_SEND}\"${cmdarg[$i]}\": ${cmdarg[$(($i+1))]}"
	done
	if [ $do_bracket ]; then
		CMD_SEND="${CMD_SEND}}}\r\n"
	else
		CMD_SEND="${CMD_SEND}}\r\n"
	fi
	echo $CMD_SEND
	echo -e $CMD_SEND  >&4
	read -u 4 resp
	echo $resp
	if [ "X$resp" != X'{"return": {}}' ]; then
		echo Error 
	fi
	exec 2<&5

}

# add hot-plug memory
# <VM> <SLOT> <MEM>
#  2    3      4
function qs_addmem() {
	parseConf
	GOOD_RESP=`echo -e '{"return": {}}\r\n'`
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	CMD_SEND="{\"execute\": \"object-add\", \"arguments\":{\"qom-type\": \"memory-backend-ram\", \"id\": \"mem${3}\", \"props\": { \"size\": ${4} } }}"
	echo $CMD_SEND
	echo -e $CMD_SEND  >&4
	read -u 4 resp	
	echo $resp
	if [ "$resp" != "$GOOD_RESP" ] ; then
		echo Error on object add: $resp
	fi
	CMD_SEND="{\"execute\": \"device_add\", \"arguments\":{\"driver\": \"pc-dimm\", \"id\": \"dimm${3}\", \"memdev\": \"mem${3}\" }}"
	echo $CMD_SEND
	echo -e $CMD_SEND  >&4
	read -u 4 resp
	echo $resp
	if [ "$resp" != "$GOOD_RESP" ] ; then
		echo Error on device add: $resp
	fi
	exec 2<&5
}

# add hot-plug memory
# <VM> <SLOT> <MEM>
#  2    3      4
function qs_delmem() {
	parseConf
	GOOD_RESP=`echo -e '{"return": {}}\r\n'`
	NETSTR="/dev/tcp/127.0.0.1/$((4000+$2))"
	exec 5>&2 2> /dev/null
	exec 4<>$NETSTR
	read -u 4 resp
	echo -e '{"execute": "qmp_capabilities"}\r\n'  >&4
	read -u 4 resp
	CMD_SEND="{\"execute\": \"device_del\", \"arguments\":{\"id\": \"dimm${3}\" }}"
	echo $CMD_SEND
	echo -e $CMD_SEND  >&4
	read -u 4 resp	
	echo $resp
	if [ "$resp" != "$GOOD_RESP" ] ; then
		echo Error on device del: $resp
	fi
	sleep 2
	CMD_SEND="{\"execute\": \"object-del\", \"arguments\":{\"id\": \"mem${3}\" }}"
	echo $CMD_SEND
	echo -e $CMD_SEND  >&4
	read -u 4 resp
	echo $resp
	if [ "$resp" != "$GOOD_RESP" ] ; then
		echo Error on object del: $resp
	fi
	exec 2<&5
}

# show help if no args, or do whatever is commanded 

if [ ${#} -eq 0 ]; then
	qs_help
fi

case $1 in
	up)
		qs_up $@ ;;
	down)  
		if [ x$2 == xall ]; then
			next_tap=`get_next_tap`
			for ((i=0; i<$next_tap; i=i+1)); do
				qs_down down $i
			done
		else
			qs_down $@ 
		fi ;;
	reset)
		qs_reset $@ ;;
	info)
		qs_info ;;
	cmd)
		qs_cmd $@ ;;
	ctrl-alt-del)
		qs_ctrl_alt_del $@ ;;
	alt-f1)
		qs_alt_f1 $@ ;;
	alt-f2)
		qs_alt_f2 $@ ;;
	alt-f7)
		qs_alt_f7 $@ ;;
	auto)
		qs_up up auto ;;
	type)
		qs_type $@ ;;
	pass)
		qs_pass $@ ;;
	addmem)
		qs_addmem $@ ;;
	delmem)
		qs_delmem $@ ;;
	*)
		qs_help ;;
esac
