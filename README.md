===========
Qemu Script
===========

'v3'
'2018-05-12'

Makes using qemu easier.
Single BASH script to manage VMs.
Commands: up, down, info, reset, ctrl-alt-del, etc

Features Supported:

* NO ADDITIONAL BINARY FILES OR LIBRARIES
** Doesn't need libvirt, just base qemu
* Integrated nftables firewall
* Optionally masquerade VMs to outside network
* Multiple configurations for same underlying disk image
* Headless operation on a server (vnc option)
* Integrated with 'pass' password manager
** Allow sending local saved password to VM as if typed
* Various special key strokes
* Power down and reset (acpi) VMs

Intended future features:
* Better user isolation using restricted ssh shells for VM server

qs: /usr/bin/qs
Main BASH script file

qs.conf: /etc/qs/qs.conf
universal configuration file

qs.conf: /home/$USER/.qs/qs.conf
per user configuration file

sudoers.qs.conf: /etc/sudoers.d/qs
SUDO permissions for qemu group
Users using this should be part of qemu group
Needed to dynamically configure networking and VFIO forwarding

nftables.conf: /etc/nftables.conf
NFTables firewall

/var/log/firewall.log
Firewall blacklist and NAT log

/etc/network/if-up.d/if-qs
/etc/network/if-post-down.d/if-qs
add/remove IP to my_ip set in nftables firewall

COMMAND EXAMPLES:
qs up example
qs down 1
qs info
qs reset 1
qs ctrl-alt-del 1

1 would be the IDX reported by info
reset and down send ACPI commands to VM (require acpid for linux)
ctrl-alt-del send keystroke ctrl-alt-del to VM IDX 1

Intended for use on Debian system and only tested on Debian
Use elsewhere at your own risk!

VM subnet set to 10.0.0.0/24 (look inside qs and nftables.conf)
Bridge set to 10.0.0.1 (br0)

'' USE CASE 1) Make a new Debian VM ''

* Create configuration file

mkdir -p ~/.qs
cat > ~/.qs/deb.conf << END_TEXT
VM deb
	image ${HOME}/deb.qcow2
	internet 10.0.0.2
	mem 2
	cpu 1
END_TEXT

* Create new qcow2 disk

qemu-img create -f qcow2 ${HOME}/deb.qcow2 2G

* Install

Download ISO for example ${HOME}/debian.iso

sudo qs up deb bootonce ${HOME}/debian.iso

Follow standard Debian installation

* Use it!

sudo qs up deb
sudo qs info

