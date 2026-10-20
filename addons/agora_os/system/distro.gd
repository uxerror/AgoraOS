class_name AgoraDistro
extends RefCounted
## The AgoraOS distribution: every package with its files, and the profiles
## (sets of packages) for different devices. The same kernel and tools, put
## together differently: a desktop, a server, a router, a live install CD.
##
## A package is a dictionary: {name, version, description, depends: [],
## dirs: {path: mode}, files: {path: [content, mode]}, programs: [names],
## links: {link: target}}. [AgoraPackages] installs them; apkg reads them
## from .pkg files in a repository.

const VERSION := "0.1.0"

## Directory layout every system has (owned by base-files).
const DIRS := {
	"/bin": AgoraStat.MODE_DIR,
	"/dev": AgoraStat.MODE_DIR,
	"/etc": AgoraStat.MODE_DIR,
	"/etc/skel": AgoraStat.MODE_DIR,
	"/home": AgoraStat.MODE_DIR,
	"/media": AgoraStat.MODE_DIR,
	"/mnt": AgoraStat.MODE_DIR,
	"/proc": AgoraStat.MODE_DIR,
	"/root": AgoraStat.MODE_PRIVATE_DIR,
	"/run": AgoraStat.MODE_DIR,
	"/sbin": AgoraStat.MODE_DIR,
	"/sys": AgoraStat.MODE_DIR,
	"/tmp": AgoraStat.MODE_TMP,
	"/usr": AgoraStat.MODE_DIR,
	"/usr/bin": AgoraStat.MODE_DIR,
	"/usr/share": AgoraStat.MODE_DIR,
	"/var": AgoraStat.MODE_DIR,
	"/var/log": AgoraStat.MODE_DIR,
}

## Services shipped with the system: name -> [description, daemon, args,
## start order, package, programs]. Each gets a systemd unit and a SysV
## init script.
const SERVICES := {
	"syslogd": ["System Logging Service", "/sbin/syslogd", "-n", 10, "sysklogd", ["logger", "syslogd"]],
	"crond": ["Regular background program processing daemon", "/sbin/crond", "-n", 20, "cron", ["crond", "crontab"]],
	"sshd": ["OpenSSH server daemon", "/sbin/sshd", "-D", 30, "openssh", ["scp", "ssh", "sshd"]],
	"udhcpd": ["Very small DHCP server", "/usr/sbin/udhcpd", "-f", 25, "udhcpd", ["dumpleases", "udhcpd"]],
	"dnsmasq": ["dnsmasq - A lightweight DHCP and caching DNS server", "/usr/sbin/dnsmasq", "-k", 24, "dnsmasq", ["dnsmasq"]],
	"inetd": ["Internet superserver", "/usr/sbin/inetd", "-i", 20, "openbsd-inetd", ["inetd"]],
	"apache2": ["Apache web server", "/usr/sbin/apache2", "-k start", 91, "apache2", ["apache2"]],
	"exim4": ["exim Mail Transport Agent", "/usr/sbin/exim4", "-bd -q30m", 20, "exim4", ["exim4", "update-exim4.conf"]],
	"pingd": ["Ping! messaging server", "/usr/sbin/pingd", "", 92, "pingd", ["pingd"]],
	"ircd-hybrid": ["IRCD-Hybrid server", "/usr/sbin/ircd", "", 93, "ircd-hybrid", ["ircd"]],
	"ircbot": ["IRC channel bots", "/usr/sbin/ircbot", "", 94, "ircbot", ["ircbot"]],
	"ferretd": ["Ferret web crawler", "/usr/sbin/ferretd", "", 95, "ferret", ["ferretd", "ferret-search", "ferret-addurl"]],
}

## The parts of ircd-hybrid's configuration that ircd reads.
const IRCD_CONF := """/* /etc/ircd-hybrid/ircd.conf: IRCD-Hybrid configuration. */

serverinfo {
	name = "irc.localdomain";
	description = "ircd-hybrid server";
	network_name = "LocalNet";
	network_desc = "This is My Network";
	hub = no;
};

admin {
	name = "IRC Admin";
	description = "Main Server Administrator";
	email = "<root@localhost>";
};

listen {
	port = 6667;
};

auth {
	user = "*@*";
	class = "users";
};
"""

const GROUPS := "root:x:0:\nadm:x:4:\ndialout:x:20:\nsudo:x:27:\nusers:x:100:\n"

const PROFILE := """# /etc/profile: read by every login shell.
if [ "$(whoami)" = root ]; then
	export PATH=/usr/sbin:/usr/bin:/sbin:/bin
else
	export PATH=/bin:/usr/bin
fi
export PS1='\\u@\\h:\\w\\$ '
alias ll='ls -l'
alias la='ls -la'
"""

const XINITRC := """#!/bin/sh
# Default graphical session, started by the login screen.
# Copy it to ~/.xinitrc to customize your own session.
# The session ends when the last command (the window manager) exits.
desktop &
panel &
terminal &
wm
"""

const THEME_AGORA := """# AgoraOS default window theme.
title_height = 24
border = 4
font_size = 14
title_bg = #1f3a5f
title_bg_inactive = #3a3d42
title_fg = #f0f0f0
title_fg_inactive = #a0a4aa
border_color = #0f1d30
border_color_inactive = #26282c
button_fg = #f0f0f0
panel_bg = #0f1d30
panel_fg = #e0e4ea
"""

const THEME_CLASSIC := """# Grey bevel-free look of early 2000s desktops.
title_height = 20
border = 3
font_size = 13
title_bg = #0a246a
title_bg_inactive = #808080
title_fg = #ffffff
title_fg_inactive = #d4d0c8
border_color = #d4d0c8
border_color_inactive = #d4d0c8
button_fg = #ffffff
close_hover = #b22222
panel_bg = #d4d0c8
panel_fg = #000000
"""

const MIME_TYPES := """# MIME type and the file extensions that map to it.
text/plain txt text log conf cfg ini md sh profile list theme
text/html html htm
image/png png
image/jpeg jpg jpeg
image/webp webp
"""

const README := """Welcome to AgoraOS.

This is a Unix-like system, and almost everything in it is a plain file:

  /etc/passwd, /etc/group   user accounts (passwords in /etc/shadow)
  /var/log/auth.log         logins, su and sudo, failed attempts
  ~/.sh_history             commands you typed
  ~/.xinitrc                your graphical session (start from /etc/X11/xinitrc)
  ~/.config/wm.conf         window theme, e.g. theme=classic
  /usr/share/applications   entries of the application menu

Open a terminal and try:  help,  ls -la /,  ps -e,  id,  sudo -h
Files you put in ~/Desktop show up as icons here.
"""

const TERMINAL_ENTRY := "[Desktop Entry]\nName=Terminal\nComment=Command line shell\nExec=terminal\n"
const FILES_ENTRY := "[Desktop Entry]\nName=Files\nComment=Browse folders\nExec=files %f\nMimeType=inode/directory;\n"
const PARLEY_ENTRY := "[Desktop Entry]\nName=Parley IRC\nComment=Chat on IRC channels\nExec=parley\n"
const PINGMSG_ENTRY := "[Desktop Entry]\nName=Ping! Messenger\nComment=Chat with your friends on the Ping! network\nExec=pingmsg\n"
const KESTREL_ENTRY := "[Desktop Entry]\nName=Kestrel Navigator\nComment=Browse the World Wide Web\nExec=kestrel %f\nMimeType=text/html;\n"
const KESTREL_BOOKMARKS := """<!DOCTYPE NETSCAPE-Bookmark-file-1>
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>

<DL><p>
    <DT><A HREF="http://www.lanlink.net/">LanLink Internet</A>
    <DT><A HREF="http://www.ferret.org/">Ferret Search</A>
    <DT><A HREF="http://www.pingmsg.com/">Ping! Messenger</A>
    <DT><A HREF="http://www.byteslash.org/">ByteSlash</A>
    <DT><A HREF="http://www.penguinpit.org/">PenguinPit</A>
    <DT><A HREF="http://www.staticnoise.org/">Static Noise</A>
    <DT><A HREF="http://www.demozone.net/">DemoZone</A>
</DL><p>
"""
const PIGEON_ENTRY := "[Desktop Entry]\nName=Pigeon Mail\nComment=Read and write e-mail\nExec=pigeon\n"
const EDIT_ENTRY := "[Desktop Entry]\nName=Text Editor\nComment=Edit text files\nExec=edit %f\nMimeType=text/plain;text/*;\n"
const VIEW_ENTRY := "[Desktop Entry]\nName=Image Viewer\nExec=view %f\nMimeType=image/png;image/jpeg;image/webp;\nNoDisplay=true\n"

const SKEL_PROFILE := "# ~/.profile: personal settings for login shells.\n"

const INITTAB := """# /etc/inittab: configuration of the SysV init (see /lib/sysvinit/init).
# id:runlevels:action:process
id:5:initdefault:
si::sysinit:/etc/init.d/rcS
l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6
# What to do in single-user mode.
~~:S:wait:/sbin/sulogin
# Graphical login on runlevel 5, if the machine has a screen (/dev/fb0).
x:5:respawn:/bin/sh -c "if [ -e /dev/fb0 ] && [ -x /bin/greeter ]; then DISPLAY=:0 greeter; else sleep 1000000; fi"
# Text logins on the monitor and the serial port.
1:2345:respawn:/sbin/getty tty1
S0:2345:respawn:/sbin/getty ttyS0
"""

const RC := """#!/bin/sh
# /etc/init.d/rc: switch services to runlevel $1.
# Stops the K* scripts and starts the S* scripts of /etc/rc$1.d, in order.
level=$1
for script in /etc/rc$level.d/K*; do
	[ -x "$script" ] && "$script" stop
done
for script in /etc/rc$level.d/S*; do
	[ -x "$script" ] && "$script" start
done
exit 0
"""

const RCS := """#!/bin/sh
# /etc/init.d/rcS: one-time system initialization at boot.
# Runs the S* scripts of /etc/rcS.d in order (checkroot, networking, ...).
echo "Hostname: $(cat /etc/hostname)"
for script in /etc/rcS.d/S*; do
	[ -x "$script" ] && "$script" start
done
echo "Cleaning /tmp"
rm -rf /tmp/*
exit 0
"""

## postinst and postrm of kernel packages: the boot menu follows the
## kernels in /boot.
const KERNEL_HOOK := """#!/bin/sh
if [ -x /usr/sbin/update-grub ] && [ -e /boot/grub/menu.lst ]; then
	case "$1" in
		configure|remove) update-grub -y ;;
	esac
fi
exit 0
"""

const HWCLOCK_INIT := """#!/bin/sh
# /etc/init.d/hwclock.sh: the kernel takes the time from the hardware
# clock at boot; at shutdown the system time goes back into it.
case "$1" in
	stop)
		hwclock --systohc
		echo "Saving the system clock."
		;;
esac
exit 0
"""

const CHECKROOT := """#!/bin/sh
# /etc/init.d/checkroot.sh: the kernel mounts the root file system
# read-only when its command line says "ro"; make it writable.
case "$1" in
	start)
		for opt in $(cat /proc/cmdline); do
			if [ "$opt" = ro ]; then
				echo "Remounting root filesystem read-write..."
				mount -n -o remount,rw /
			fi
		done
		;;
esac
exit 0
"""

const NETWORKING_INIT := """#!/bin/sh
# /etc/init.d/networking: raise or take down the network interfaces
# configured in /etc/network/interfaces.
case "$1" in
	start)
		echo -n "Configuring network interfaces..."
		ifup -a
		echo "done."
		;;
	stop)
		echo -n "Deconfiguring network interfaces..."
		ifdown -a --exclude=lo
		echo "done."
		;;
	restart|force-reload)
		echo -n "Reconfiguring network interfaces..."
		ifdown -a --exclude=lo
		ifup -a
		echo "done."
		;;
	*)
		echo "Usage: /etc/init.d/networking {start|stop|restart|force-reload}"
		exit 1
		;;
esac
exit 0
"""

const NETWORKING_UNIT := """[Unit]
Description=Raise network interfaces
Wants=network.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ifup -a
ExecStop=/sbin/ifdown -a --exclude=lo
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"""

const INTERFACES_HEAD := """# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

# The loopback network interface
auto lo
iface lo inet loopback
"""

const ROUTER_INTERFACES := """# /etc/network/interfaces: the router's ports.
# eth0 is the WAN port, eth1-eth4 are the LAN ports.

auto lo
iface lo inet loopback

# LAN: the four LAN ports are bridged into one network.
auto br-lan
iface br-lan inet static
	bridge_ports eth1 eth2 eth3 eth4
	bridge_stp off
	address 192.168.1.1
	netmask 255.255.255.0

# WAN: ask the provider for an address, in the background.
auto eth0
iface eth0 inet manual
	up udhcpc -b -i eth0 -p /var/run/udhcpc.eth0.pid &
	down kill $(cat /var/run/udhcpc.eth0.pid)
"""

const UDHCPC_SCRIPT := """#!/bin/sh
# udhcpc script edited by Tim Riker <Tim@Rikers.org>

[ -z "$1" ] && echo "Error: should be called from udhcpc" && exit 1

RESOLV_CONF="/etc/resolv.conf"
[ -n "$broadcast" ] && BROADCAST="broadcast $broadcast"
[ -n "$subnet" ] && NETMASK="netmask $subnet"

case "$1" in
	deconfig)
		/sbin/ifconfig $interface 0.0.0.0
		;;

	renew|bound)
		/sbin/ifconfig $interface $ip $BROADCAST $NETMASK

		if [ -n "$router" ] ; then
			echo "deleting routers"
			while route del default gw 0.0.0.0 dev $interface 2>/dev/null ; do
				:
			done

			for i in $router ; do
				route add default gw $i dev $interface
			done
		fi

		echo -n > $RESOLV_CONF
		[ -n "$domain" ] && echo search $domain >> $RESOLV_CONF
		for i in $dns ; do
			echo adding dns $i
			echo nameserver $i >> $RESOLV_CONF
		done
		;;
esac

exit 0
"""

const UDHCPD_CONF := """# Sample udhcpd configuration file (/etc/udhcpd.conf)

# The start and end of the IP lease block
start		192.168.0.20
end		192.168.0.254

# The interface that udhcpd will use
interface	eth0

# How long an offered address is reserved (seconds)
#offer_time	60

# How often to write the lease file (seconds, 0 to never)
#auto_time	7200

#lease_file	/var/lib/misc/udhcpd.leases
#pidfile	/var/run/udhcpd.pid

opt	dns	192.168.0.1
option	subnet	255.255.255.0
opt	router	192.168.0.1
option	domain	local
option	lease	864000		# 10 days of seconds
"""

const ROUTER_UDHCPD_CONF := """# /etc/udhcpd.conf: addresses for the LAN.
start		192.168.1.100
end		192.168.1.199
interface	br-lan
max_leases	100
auto_time	30
lease_file	/var/lib/misc/udhcpd.leases
pidfile		/var/run/udhcpd.pid

opt	router	192.168.1.1
opt	dns	192.168.1.1
option	subnet	255.255.255.0
option	domain	lan
option	lease	86400
"""

const ROUTER_FIREWALL := """#!/bin/sh
# /etc/init.d/firewall: the router's packet filter and NAT.
# The LAN (br-lan) may go anywhere; from the WAN (eth0) only replies come in.
WAN=eth0
LAN=br-lan

case "$1" in
	start)
		echo "Starting firewall"
		iptables -P INPUT ACCEPT
		iptables -P FORWARD DROP
		iptables -A INPUT -i $WAN -m state --state RELATED,ESTABLISHED -j ACCEPT
		iptables -A INPUT -i $WAN -j DROP
		iptables -A FORWARD -i $LAN -o $WAN -j ACCEPT
		iptables -A FORWARD -i $WAN -o $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT
		iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE
		echo 1 > /proc/sys/net/ipv4/ip_forward
		;;
	stop)
		echo "Stopping firewall"
		echo 0 > /proc/sys/net/ipv4/ip_forward
		iptables -F
		iptables -t nat -F
		iptables -P FORWARD ACCEPT
		;;
	restart)
		$0 stop
		$0 start
		;;
	*)
		echo "Usage: $0 {start|stop|restart}"
		exit 1
		;;
esac
exit 0
"""

const DNSMASQ_CONF := """# Configuration file for dnsmasq.
#
# Format is one option per line, legal options are the same
# as the long options legal on the command line. See
# "/usr/sbin/dnsmasq --help" or "man 8 dnsmasq" for details.

# Never forward plain names (without a dot or domain part)
#domain-needed
# Never forward addresses in the non-routed address spaces.
#bogus-priv

# Don't read /etc/resolv.conf; get upstream servers only from server= lines.
#no-resolv
# Add other name servers here, with domain specs if they are for
# non-public domains.
#server=/localnet/192.168.0.1

# Add local-only domains here, queries in these domains are answered
# from /etc/hosts only.
#local=/localnet/

# Add domains which you want to force to an IP address here.
#address=/double-click.net/127.0.0.1

# Listen only on this interface.
#interface=eth0

# Add the domain to simple names in /etc/hosts.
#expand-hosts
#domain=thekelleys.org.uk

# Set the cachesize here.
#cache-size=150

# For debugging purposes, log each DNS query as it passes through dnsmasq.
#log-queries

# Include all files in a directory which end in .conf
conf-dir=/etc/dnsmasq.d/,*.conf
"""

const ROUTER_DNSMASQ := """# /etc/dnsmasq.d/lan.conf: DNS for the LAN.
# Names from /etc/hosts answer as name.lan; everything else goes to the
# provider's servers, which udhcpc writes into /etc/resolv.conf.
domain-needed
bogus-priv
local=/lan/
domain=lan
expand-hosts
interface=br-lan
cache-size=150
#log-queries
"""

const SYSLOG_CONF := """# /etc/syslog.conf: which messages go to which file.
# selector[;selector]      file        (facility.level; level "none" excludes)
auth,authpriv.*            /var/log/auth.log
cron.*                     /var/log/cron.log
kern.*                     /var/log/kern.log
*.*;auth,authpriv.none     /var/log/syslog
"""

const CRONTAB := """# /etc/crontab: system-wide cron table.
# m  h  dom mon dow user  command
17 *    * * *   root  echo "hourly maintenance" > /dev/null
"""

const SSHD_CONFIG := """# /etc/ssh/sshd_config: SSH server settings.
Port 22
PermitRootLogin yes
PasswordAuthentication yes
"""

const TARGETS := {
	"basic.target": "[Unit]\nDescription=Basic System\n",
	"network.target": "[Unit]\nDescription=Network\n",
	"multi-user.target": "[Unit]\nDescription=Multi-User System\nRequires=basic.target\nAfter=basic.target\n",
	"graphical.target": "[Unit]\nDescription=Graphical Interface\nRequires=multi-user.target\nAfter=multi-user.target\nWants=display-manager.service\n",
	"rescue.target": "[Unit]\nDescription=Rescue Mode\nRequires=rescue.service\nAfter=rescue.service\n",
	"emergency.target": "[Unit]\nDescription=Emergency Mode\nRequires=emergency.service\nAfter=emergency.service\n",
}

const RESCUE_UNIT := """[Unit]
Description=%s

[Service]
ExecStart=/bin/sh -c "/sbin/sulogin; /bin/systemctl default"
"""

const GETTY_UNIT := """[Unit]
Description=Login prompt on %s
ConditionPathExists=/dev/%s

[Service]
ExecStart=/sbin/getty %s
Restart=always
RestartSec=1
"""

const DISPLAY_MANAGER_UNIT := """[Unit]
Description=Graphical Login Screen
ConditionPathExists=/dev/fb0
After=multi-user.target

[Service]
ExecStart=/bin/greeter
Environment=DISPLAY=:0
Restart=always
RestartSec=1
"""



## /etc/services from netbase: well-known ports by name.
const ETC_SERVICES := """# Network services, Internet style
#
# Note that it is presently the policy of IANA to assign a single well-known
# port number for both TCP and UDP; hence, officially ports have two entries
# even if the protocol doesn't support UDP operations.

tcpmux		1/tcp				# TCP port service multiplexer
echo		7/tcp
echo		7/udp
discard		9/tcp		sink null
discard		9/udp		sink null
systat		11/tcp		users
daytime		13/tcp
daytime		13/udp
netstat		15/tcp
qotd		17/tcp		quote
chargen		19/tcp		ttytst source
chargen		19/udp		ttytst source
ftp-data	20/tcp
ftp		21/tcp
fsp		21/udp		fspd
ssh		22/tcp				# SSH Remote Login Protocol
ssh		22/udp
telnet		23/tcp
smtp		25/tcp		mail
time		37/tcp		timserver
time		37/udp		timserver
whois		43/tcp		nicname
domain		53/tcp				# Domain Name Server
domain		53/udp
bootps		67/udp
bootpc		68/udp
tftp		69/udp
gopher		70/tcp				# Internet Gopher
finger		79/tcp
www		80/tcp		http		# WorldWideWeb HTTP
kerberos	88/tcp		kerberos5 krb5	# Kerberos v5
pop3		110/tcp		pop-3		# POP version 3
sunrpc		111/tcp		portmapper	# RPC 4.0 portmapper
sunrpc		111/udp		portmapper
auth		113/tcp		authentication tap ident
nntp		119/tcp		readnews untp	# USENET News Transfer Protocol
ntp		123/udp				# Network Time Protocol
netbios-ns	137/udp				# NETBIOS Name Service
netbios-dgm	138/udp				# NETBIOS Datagram Service
netbios-ssn	139/tcp				# NETBIOS session service
imap2		143/tcp		imap		# Interim Mail Access P 2 and 4
snmp		161/udp				# Simple Net Mgmt Protocol
irc		194/tcp				# Internet Relay Chat
https		443/tcp				# http protocol over TLS/SSL
microsoft-ds	445/tcp				# Microsoft Naked CIFS
exec		512/tcp
biff		512/udp		comsat
login		513/tcp
who		513/udp		whod
shell		514/tcp		cmd		# no passwords used
syslog		514/udp
printer		515/tcp		spooler		# line printer spooler
talk		517/udp
ntalk		518/udp
route		520/udp		router routed	# RIP
uucp		540/tcp		uucpd		# uucp daemon
submission	587/tcp				# Submission [RFC4409]
imaps		993/tcp				# IMAP over SSL
pop3s		995/tcp				# POP-3 over SSL
socks		1080/tcp			# socks proxy server
mysql		3306/tcp
pingnet		5190/tcp			# Ping! instant messaging
postgresql	5432/tcp	postgres	# PostgreSQL Database
x11		6000/tcp	x11-0		# X Window System
ircd		6667/tcp			# Internet Relay Chat
http-alt	8080/tcp	webcache	# WWW caching service
"""

const INETD_CONF := """# /etc/inetd.conf:  see inetd(8) for further informations.
#
# Internet superserver configuration database
#
#
# Lines starting with "#:LABEL:" or "#<off>#" should not
# be changed unless you know what you are doing!
#
# If you want to disable an entry so it isn't touched during
# package updates just comment it out with a single '#' character.
#
# Packages should modify this file by using update-inetd(8)
#
# <service_name> <sock_type> <proto> <flags> <user> <server_path> <args>
#
#:INTERNAL: Internal services
#discard		stream	tcp	nowait	root	internal
#daytime		stream	tcp	nowait	root	internal
#time		stream	tcp	nowait	root	internal

#:STANDARD: These are standard services.

#:BSD: Shell, login, exec and talk are BSD protocols.

#:MAIL: Mail, news and uucp services.

#:INFO: Info services

#:BOOT: TFTP service is provided primarily for booting.  Most sites
#       run this only on machines acting as "boot servers."

#:RPC: RPC based services

#:HAM-RADIO: amateur-radio services

#:OTHER: Other services
"""

const HOSTS_ALLOW := """# /etc/hosts.allow: list of hosts that are allowed to access the system.
#                  See the manual pages hosts_access(5) and hosts_options(5).
#
# Example:    ALL: LOCAL @some_netgroup
#             ALL: .foobar.edu EXCEPT terminalserver.foobar.edu
#
# If you're going to protect the portmapper use the name "portmap" for the
# daemon name. Remember that you can only use the keyword "ALL" and IP
# addresses (NOT host or domain names) for the portmapper, as well as for
# rpc.mountd (the NFS mount daemon). See portmap(8) and rpc.mountd(8)
# for further information.
#
"""

const HOSTS_DENY := """# /etc/hosts.deny: list of hosts that are _not_ allowed to access the system.
#                  See the manual pages hosts_access(5) and hosts_options(5).
#
# Example:    ALL: some.host.name, .some.domain
#             ALL EXCEPT in.fingerd: other.host.name, .other.domain
#
# If you're going to protect the portmapper use the name "portmap" for the
# daemon name. Remember that you can only use the keyword "ALL" and IP
# addresses (NOT host or domain names) for the portmapper, as well as for
# rpc.mountd (the NFS mount daemon). See portmap(8) and rpc.mountd(8)
# for further information.
#
# The PARANOID wildcard checks that the remote host name matches its address.
#
# You may wish to enable this to ensure any programs that don't
# validate looked up hostnames still leave understandable logs. In past
# versions of Debian this has been the default.
# ALL: PARANOID
"""

const APACHE2_CONF := """# This is the main Apache server configuration file.  It contains the
# configuration directives that give the server its instructions.
# See http://httpd.apache.org/docs/2.2/ for detailed information about
# the directives.

ServerRoot "/etc/apache2"
Timeout 300
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 15

User www-data
Group www-data

AccessFileName .htaccess
DefaultType text/plain
HostnameLookups Off

# ErrorLog: The location of the error log file.
ErrorLog /var/log/apache2/error.log
LogLevel warn

DirectoryIndex index.html index.cgi index.pl index.php index.xhtml
IndexIgnore .??* *~ *# HEADER* README* RCS CVS *,v *,t

LogFormat "%h %l %u %t \\"%r\\" %>s %b \\"%{Referer}i\\" \\"%{User-Agent}i\\"" combined
LogFormat "%h %l %u %t \\"%r\\" %>s %b" common

ServerTokens Full
ServerSignature On

# Include module configuration, the virtual host configurations and the
# ports to listen on.
Include /etc/apache2/mods-enabled/
Include /etc/apache2/ports.conf
Include /etc/apache2/conf.d/
Include /etc/apache2/sites-enabled/
"""

const APACHE2_USERDIR := """<IfModule mod_userdir.c>
        UserDir public_html
        UserDir disabled root

        <Directory /home/*/public_html>
                AllowOverride FileInfo AuthConfig Limit
                Options MultiViews Indexes SymLinksIfOwnerMatch IncludesNoExec
        </Directory>
</IfModule>
"""

const APACHE2_SITE := """NameVirtualHost *
<VirtualHost *>
	ServerAdmin webmaster@localhost

	DocumentRoot /var/www/
	<Directory />
		Options FollowSymLinks
		AllowOverride None
	</Directory>
	<Directory /var/www/>
		Options Indexes FollowSymLinks MultiViews
		AllowOverride None
		Order allow,deny
		allow from all
	</Directory>

	ScriptAlias /cgi-bin/ /usr/lib/cgi-bin/
	<Directory "/usr/lib/cgi-bin">
		AllowOverride None
		Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
		Order allow,deny
		Allow from all
	</Directory>

	ErrorLog /var/log/apache2/error.log
	LogLevel warn
	CustomLog /var/log/apache2/access.log combined
	ServerSignature On
</VirtualHost>
"""

## Debian's exim4-config, set up for local delivery only.
const EXIM4_CONF := """# /etc/exim4/update-exim4.conf.conf
#
# Edit this file and /etc/mailname by hand and execute update-exim4.conf
# yourself or use 'dpkg-reconfigure exim4-config'
#
# This is a Debian specific file

dc_eximconfig_configtype='local'
dc_other_hostnames=''
dc_local_interfaces='127.0.0.1 ; ::1'
dc_readhost=''
dc_relay_domains=''
dc_minimaldns='false'
dc_relay_nets=''
dc_smarthost=''
CFILEMODE='644'
dc_use_split_config='false'
dc_hide_mailname=''
dc_mailname_in_oh='true'
dc_localdelivery='mail_spool'
"""

const ETC_ALIASES := """# /etc/aliases
mailer-daemon: postmaster
postmaster: root
nobody: root
hostmaster: root
usenet: root
news: root
webmaster: root
www: root
ftp: root
abuse: root
noc: root
security: root
"""

## bsd-mailx's system-wide settings.
const MAIL_RC := """set ask askcc append dot save crt
ignore Received Message-Id Resent-Message-Id Status Mail-From Return-Path Via Delivered-To
"""

## /etc/ftpusers: accounts that may not log in by FTP.
const FTPUSERS := """# /etc/ftpusers: list of users disallowed FTP access. See ftpusers(5).

root
daemon
bin
sys
sync
games
man
lp
mail
news
uucp
nobody
"""

## Packages per profile, in install order (dependencies are added anyway).
const PROFILES := {
	"desktop": ["agora-kernel", "base-files", "sh", "coreutils", "util-linux", "shadow", "iproute", "net-tools", "iputils-ping", "ifupdown", "udhcpc",
		"procps", "traceroute", "tcpdump", "ethtool", "iptables", "netcat", "dnsutils", "netbase", "telnet", "ftp", "wget", "lynx", "sysklogd", "cron", "openssh", "exim4", "bsd-mailx", "sysvinit", "systemd", "agora-desktop", "kestrel", "pigeon", "pingmsg", "parley", "apkg", "grub", "sox"],
	"server": ["agora-kernel", "base-files", "sh", "coreutils", "util-linux", "shadow", "iproute", "net-tools", "iputils-ping", "ifupdown", "udhcpc",
		"procps", "traceroute", "tcpdump", "ethtool", "iptables", "netcat", "dnsutils", "netbase", "telnet", "ftp", "wget", "lynx", "openbsd-inetd", "sysklogd", "cron", "openssh", "exim4", "bsd-mailx", "sysvinit", "systemd", "apkg", "grub"],
	"router": ["agora-kernel", "base-files", "busybox", "bridge-utils", "iptables", "router-base", "dnsmasq", "openssh", "apkg"],
	"live": ["agora-kernel", "base-files", "sh", "coreutils", "util-linux", "shadow", "iproute", "net-tools", "iputils-ping",
		"sysvinit", "live-config", "agora-installer", "apkg"],
}

const PROFILE_INFO := {
	"desktop": "graphical desktop with servers and tools",
	"server": "the same without graphics",
	"router": "minimal busybox system for network devices",
}

const COREUTILS: PackedStringArray = [
	"[", "basename", "cat", "chmod", "chown", "clear", "cp", "cut", "date", "dirname", "echo",
	"env", "false", "find", "getent", "grep", "head", "help", "hostname", "id", "kill", "ln", "ls", "mkdir",
	"mv", "printf", "ps", "pwd", "readlink", "rm", "rmdir", "seq", "sleep", "sort", "stat", "tail", "tee",
	"test", "touch", "tr", "true", "tty", "uname", "uniq", "uptime", "wc", "which", "whoami", "yes",
]

## Applets compiled into busybox, and the program implementing each.
const BUSYBOX_APPLETS := {
	"sh": "sh", "ash": "sh", "cat": "cat", "chmod": "chmod", "chown": "chown", "clear": "clear",
	"cp": "cp", "cut": "cut", "date": "date", "dmesg": "dmesg", "echo": "echo", "env": "env",
	"false": "false", "find": "find", "free": "free", "getty": "getty", "grep": "grep",
	"halt": "halt", "head": "head", "hostname": "hostname", "id": "id", "ifconfig": "ifconfig",
	"init": "sysvinit", "ip": "ip", "kill": "kill", "ln": "ln", "logger": "logger", "login": "login",
	"ls": "ls", "mkdir": "mkdir", "mount": "mount", "mv": "mv", "passwd": "passwd", "ping": "ping",
	"poweroff": "poweroff", "ps": "ps", "pwd": "pwd", "readlink": "readlink", "reboot": "reboot", "route": "route", "ifup": "ifup", "ifdown": "ifdown",
	"udhcpc": "udhcpc", "udhcpd": "udhcpd", "dumpleases": "dumpleases", "sysctl": "sysctl",
	"traceroute": "traceroute", "nc": "nc", "netstat": "netstat", "nslookup": "nslookup",
	"rm": "rm", "rmdir": "rmdir", "sleep": "sleep", "sort": "sort", "start-stop-daemon": "start-stop-daemon",
	"su": "su", "syslogd": "syslogd", "tail": "tail", "tee": "tee", "telinit": "telinit", "test": "test",
	"[": "test", "touch": "touch", "tr": "tr", "true": "true", "umount": "umount", "uname": "uname",
	"uniq": "uniq", "uptime": "uptime", "wc": "wc", "which": "which", "whoami": "whoami",
	"crond": "crond", "crontab": "crontab",
}

const ROUTER_INITTAB := """# /etc/inittab: busybox init on the router.
id:3:initdefault:
si::sysinit:/etc/init.d/rcS
rc:3:wait:/etc/init.d/rc 3
S0:3:respawn:/sbin/getty ttyS0
"""

const ROUTER_BANNER := """
  _______  ___  ___
 |   _   ||   ||   |  Agora Networks WR-54
 |  |_|  ||   ||   |  AgoraOS %s (router)
 |       ||___||___|  ---------------------------
 |_______|            busybox based firmware

"""

const LIVE_INITTAB := """# /etc/inittab of the install CD: the installer runs on every console.
id:3:initdefault:
si::sysinit:/etc/init.d/rcS
1:3:respawn:/sbin/getty -n -l /sbin/agora-install tty1
S0:3:respawn:/sbin/getty -n -l /sbin/agora-install ttyS0
"""

const APKG_SOURCES := """# /etc/apkg/sources.list: the archives apkg installs from.
# After changing this file, run "apkg update".
#
#   apkg URI SUITE COMPONENT...
#
# The install CD (mount /dev/sr0 /media/cdrom first):
#apkg file:/media/cdrom stable main
#
# The AgoraOS archive on the net:
apkg http://ftp.agoraos.org/agora stable main
"""

static var _catalog := {}


## Every package by name.
static func catalog() -> Dictionary:
	if _catalog.is_empty():
		_catalog = _build_catalog()
	return _catalog


## Every package of the distribution, in name order (for archives).
static func all_packages() -> Array:
	var names := catalog().keys()
	names.sort()
	var out: Array = []
	for n: String in names:
		out.append(package(n))
	return out


static func package(name: String) -> Dictionary:
	var spec: Dictionary = catalog().get(name, {})
	return spec.duplicate(true)


static func _pkg(name: String, description: String, extra: Dictionary) -> Dictionary:
	var p := {"name": name, "version": VERSION, "description": description, "depends": [],
		"dirs": {}, "files": {}, "programs": [], "links": {}}
	p.merge(extra, true)
	return p


static func _build_catalog() -> Dictionary:
	var c := {}
	c["fetchmail"] = _pkg("fetchmail", "SSL enabled POP3, APOP, IMAP mail gatherer/forwarder", {
		"programs": ["fetchmail"], "depends": ["mail-transport-agent"],
	})
	c["sox"] = _pkg("sox", "Swiss army knife of sound processing: play", {"programs": ["play"]})
	c["minicom"] = _pkg("minicom", "friendly menu driven serial communication program", {
		"programs": ["minicom"],
		"dirs": {"/etc/minicom": AgoraStat.MODE_DIR},
		"files": {"/etc/minicom/minirc.dfl": ["# Machine-generated file - use \"minicom -s\" to change parameters.\npu port             /dev/ttyS0\npu baudrate         9600\npu bits             8\npu parity           N\npu stopbits         1\n", AgoraStat.MODE_FILE]},
	})
	c["grub"] = _pkg("grub", "GRand Unified Bootloader (Legacy version)", {
		"programs": ["grub-install", "grub-md5-crypt", "update-grub"],
		"dirs": {"/usr/lib/grub": AgoraStat.MODE_DIR, AgoraGrub.STAGE_DIR: AgoraStat.MODE_DIR},
		"files": AgoraGrub.package_files(),
	})
	c["agora-kernel"] = _pkg("agora-kernel", "Agora kernel image", {
		"dirs": {"/boot": AgoraStat.MODE_DIR},
		"files": {"/boot/vmlinuz-" + VERSION: ["Agora kernel %s\n" % VERSION, AgoraStat.MODE_FILE]},
		"links": {"/boot/vmlinuz": "vmlinuz-" + VERSION},
		"scripts": {"postinst": KERNEL_HOOK, "postrm": KERNEL_HOOK},
	})
	c["base-files"] = _pkg("base-files", "directory layout and basic configuration", {
		"dirs": DIRS,
		"files": {
			"/etc/profile": [PROFILE, AgoraStat.MODE_FILE],
			"/etc/skel/.profile": [SKEL_PROFILE, AgoraStat.MODE_FILE],
			"/etc/mime.types": [MIME_TYPES, AgoraStat.MODE_FILE],
		},
		"links": {"/var/run": "/run"},
	})
	c["sh"] = _pkg("sh", "the command interpreter", {"programs": ["sh"]})
	c["coreutils"] = _pkg("coreutils", "basic file, text and shell utilities", {"programs": COREUTILS, "depends": ["sh"]})
	c["util-linux"] = _pkg("util-linux", "system utilities: mount, disks, consoles, power", {
		"programs": ["dmesg", "eject", "free", "getty", "halt", "hwclock", "login", "logger", "lsblk", "mkfs",
			"mount", "poweroff", "reboot", "shutdown", "umount"],
	})
	c["shadow"] = _pkg("shadow", "user accounts: su, sudo, passwd, useradd", {"programs": ["passwd", "su", "sudo", "useradd"]})
	c["iproute"] = _pkg("iproute", "networking and traffic control tools: ip, bridge", {"programs": ["bridge", "ip"]})
	c["bridge-utils"] = _pkg("bridge-utils", "utilities for configuring Ethernet bridges: brctl", {"programs": ["brctl"]})
	c["net-tools"] = _pkg("net-tools", "the NET-3 networking toolkit: ifconfig, route, arp, netstat", {"programs": ["arp", "ifconfig", "netstat", "route"]})
	c["netcat"] = _pkg("netcat", "TCP/IP swiss army knife", {"programs": ["nc"]})
	c["ifupdown"] = _pkg("ifupdown", "high level tools to configure network interfaces", {
		"depends": ["iproute"],
		"programs": ["ifdown", "ifup"],
		"dirs": {"/etc/network": AgoraStat.MODE_DIR, "/etc/rcS.d": AgoraStat.MODE_DIR},
		"files": {
			"/etc/init.d/networking": [NETWORKING_INIT, AgoraStat.MODE_EXEC],
			"/lib/systemd/system/networking.service": [NETWORKING_UNIT, AgoraStat.MODE_FILE],
		},
		"links": _networking_links(),
	})
	c["udhcpc"] = _pkg("udhcpc", "very small DHCP client", {
		"programs": ["udhcpc"],
		"dirs": {"/usr/share/udhcpc": AgoraStat.MODE_DIR},
		"files": {"/usr/share/udhcpc/default.script": [UDHCPC_SCRIPT, AgoraStat.MODE_EXEC]},
	})
	c["iptables"] = _pkg("iptables", "administration tools for packet filtering and NAT", {"programs": ["iptables", "iptables-restore", "iptables-save"]})
	c["procps"] = _pkg("procps", "/proc file system utilities: sysctl", {"programs": ["sysctl"]})
	c["traceroute"] = _pkg("traceroute", "traces the route taken by packets over an IPv4 network", {"programs": ["traceroute"]})
	c["tcpdump"] = _pkg("tcpdump", "command-line network traffic analyzer", {"programs": ["tcpdump"]})
	c["ethtool"] = _pkg("ethtool", "display or change Ethernet device settings", {"programs": ["ethtool"]})
	c["iputils-ping"] = _pkg("iputils-ping", "tools to test the reachability of network hosts", {"programs": ["ping"]})
	for name: String in SERVICES:
		var svc: Array = SERVICES[name]
		var pkg_name: String = svc[4]
		var spec := _pkg(pkg_name, (svc[0] as String).to_lower(), {"programs": svc[5].duplicate()})
		spec.files["/lib/systemd/system/%s.service" % name] = [_unit_text(name, svc), AgoraStat.MODE_FILE]
		spec.files["/etc/init.d/" + name] = [_init_script(name, svc), AgoraStat.MODE_EXEC]
		spec.links.merge(_service_links(name, svc[3]))
		c[pkg_name] = spec
	c["sysklogd"].files["/etc/syslog.conf"] = [SYSLOG_CONF, AgoraStat.MODE_FILE]
	c["udhcpd"].files["/etc/udhcpd.conf"] = [UDHCPD_CONF, AgoraStat.MODE_FILE]
	c["dnsmasq"].files["/etc/dnsmasq.conf"] = [DNSMASQ_CONF, AgoraStat.MODE_FILE]
	c["dnsmasq"].dirs["/etc/dnsmasq.d"] = AgoraStat.MODE_DIR
	c["dnsutils"] = _pkg("dnsutils", "clients provided with BIND: dig, host, nslookup", {"programs": ["dig", "host", "nslookup"]})
	c["udhcpd"].dirs["/var/lib/misc"] = AgoraStat.MODE_DIR
	c["cron"].files["/etc/crontab"] = [CRONTAB, AgoraStat.MODE_FILE]
	c["cron"].dirs["/var/spool/cron/crontabs"] = AgoraStat.MODE_PRIVATE_DIR
	c["openssh"].files["/etc/ssh/sshd_config"] = [SSHD_CONFIG, AgoraStat.MODE_FILE]
	c["openssh"].dirs["/etc/ssh"] = AgoraStat.MODE_DIR
	c["openbsd-inetd"].files["/etc/inetd.conf"] = [INETD_CONF, AgoraStat.MODE_FILE]
	c["openbsd-inetd"].depends = ["tcpd", "netbase"]
	c["tcpd"] = _pkg("tcpd", "Wietse Venema's TCP wrapper utilities", {
		"programs": ["tcpd"],
		"files": {"/etc/hosts.allow": [HOSTS_ALLOW, AgoraStat.MODE_FILE], "/etc/hosts.deny": [HOSTS_DENY, AgoraStat.MODE_FILE]},
	})
	c["netbase"] = _pkg("netbase", "Basic TCP/IP networking system", {"files": {"/etc/services": [ETC_SERVICES, AgoraStat.MODE_FILE]}})
	c["telnet"] = _pkg("telnet", "The telnet client", {"programs": ["telnet"], "depends": ["netbase"]})
	c["ftp"] = _pkg("ftp", "The FTP client", {"programs": ["ftp"], "depends": ["netbase"]})
	c["wget"] = _pkg("wget", "retrieves files from the web", {"programs": ["wget"]})
	c["lynx"] = _pkg("lynx", "Text-mode WWW Browser", {"programs": ["lynx"]})
	c["ferret"].description = "the Ferret search engine: crawler and search CGI"
	c["ferret"].depends = ["apache2"]
	c["ferret"].dirs.merge({"/etc/ferret": AgoraStat.MODE_DIR, "/var/lib/ferret": AgoraStat.MODE_DIR})
	c["ferret"].files.merge({
		"/etc/ferret/ferret.conf": ["# /etc/ferret/ferret.conf: where the crawler starts and how often.\n#seed http://www.example.org/\ninterval 1800\nmax_pages 300\n", AgoraStat.MODE_FILE],
		"/var/lib/ferret/submitted": ["", 438], # 0o666: the addurl CGI (www-data) appends
	})
	c["apache2"].depends = ["netbase"]
	c["apache2"].users = [{"name": "www-data", "uid": 33, "home": "/var/www", "shell": "/bin/sh", "gecos": "www-data"}]
	c["apache2"].dirs.merge({
		"/etc/apache2": AgoraStat.MODE_DIR, "/etc/apache2/conf.d": AgoraStat.MODE_DIR, "/etc/apache2/mods-enabled": AgoraStat.MODE_DIR,
		"/etc/apache2/sites-available": AgoraStat.MODE_DIR, "/etc/apache2/sites-enabled": AgoraStat.MODE_DIR,
		"/var/www": AgoraStat.MODE_DIR, "/usr/lib/cgi-bin": AgoraStat.MODE_DIR,
		"/var/log/apache2": 488, # 0o750
	})
	c["apache2"].files.merge({
		"/etc/apache2/apache2.conf": [APACHE2_CONF, AgoraStat.MODE_FILE],
		"/etc/apache2/ports.conf": ["Listen 80\n", AgoraStat.MODE_FILE],
		"/etc/apache2/mods-enabled/userdir.conf": [APACHE2_USERDIR, AgoraStat.MODE_FILE],
		"/etc/apache2/sites-available/default": [APACHE2_SITE, AgoraStat.MODE_FILE],
		"/var/www/index.html": ["<html><body><h1>It works!</h1></body></html>\n", AgoraStat.MODE_FILE],
	})
	c["apache2"].links["/etc/apache2/sites-enabled/000-default"] = "/etc/apache2/sites-available/default"
	c["exim4"].description = "Exim (v4) mail transport agent"
	c["exim4"].depends = ["netbase"]
	c["exim4"].provides = ["mail-transport-agent"]
	c["exim4"].users = [
		{"name": "mail", "uid": 8, "home": "/var/mail", "shell": "/bin/sh", "gecos": "mail"},
		{"name": "Debian-exim", "uid": 101, "home": "/var/spool/exim4", "shell": "/bin/false", "gecos": ""},
	]
	c["exim4"].dirs.merge({
		"/etc/exim4": AgoraStat.MODE_DIR, "/var/spool/exim4": 488, "/var/spool/exim4/input": 488, # 0o750
		"/var/log/exim4": 488, "/var/mail": 1533, # 0o2775
	})
	c["exim4"].files.merge({
		"/etc/exim4/update-exim4.conf.conf": [EXIM4_CONF, AgoraStat.MODE_FILE],
		"/etc/aliases": [ETC_ALIASES, AgoraStat.MODE_FILE],
	})
	c["exim4"].links.merge({
		"/usr/sbin/sendmail": "exim4", "/usr/sbin/exim": "exim4", "/usr/lib/sendmail": "../sbin/exim4",
		"/usr/bin/mailq": "../sbin/exim4", "/usr/bin/runq": "../sbin/exim4", "/usr/bin/newaliases": "../sbin/exim4",
	})
	c["pingd"].description = "server of the Ping! instant messaging network"
	c["pingd"].depends = ["netbase"]
	c["pingd"].dirs.merge({"/var/lib/pingd": AgoraStat.MODE_PRIVATE_DIR, "/var/lib/pingd/offline": AgoraStat.MODE_PRIVATE_DIR})
	c["pingd"].files["/etc/pingd.conf"] = ["# /etc/pingd.conf: the Ping! server.\nname login.pingmsg.com\nport 5190\nfirst_uin 100001\nregister yes\n", AgoraStat.MODE_FILE]
	c["ircd-hybrid"].description = "high-performance secure IRC server"
	c["ircd-hybrid"].depends = ["netbase"]
	c["ircd-hybrid"].dirs["/etc/ircd-hybrid"] = AgoraStat.MODE_DIR
	c["ircd-hybrid"].files.merge({
		"/etc/ircd-hybrid/ircd.conf": [IRCD_CONF, AgoraStat.MODE_FILE],
		"/etc/ircd-hybrid/ircd.motd": ["Welcome to this IRC server.\nPlease be nice.\n", AgoraStat.MODE_FILE],
	})
	c["ircbot"].description = "bots that keep IRC channels company"
	c["ircbot"].depends = ["netbase"]
	c["ircbot"].dirs["/etc/ircbot"] = AgoraStat.MODE_DIR
	c["parley"] = _pkg("parley", "Parley, the graphical IRC client", {
		"programs": ["parley"], "depends": ["agora-desktop"],
		"files": {
			"/etc/parley.conf": ["# /etc/parley.conf: defaults for Parley.\nserver=irc.lanlink.net\nport=6667\n", AgoraStat.MODE_FILE],
			"/usr/share/applications/parley.desktop": [PARLEY_ENTRY, AgoraStat.MODE_FILE],
		},
	})
	c["kestrel"] = _pkg("kestrel", "Kestrel Navigator, the graphical web browser", {
		"programs": ["kestrel"], "depends": ["agora-desktop"],
		"dirs": {"/etc/kestrel": AgoraStat.MODE_DIR},
		"files": {
			"/etc/kestrel/kestrel.conf": ["# /etc/kestrel/kestrel.conf\nhomepage=http://www.lanlink.net/\n", AgoraStat.MODE_FILE],
			"/etc/kestrel/bookmarks.html": [KESTREL_BOOKMARKS, AgoraStat.MODE_FILE],
			"/usr/share/applications/kestrel.desktop": [KESTREL_ENTRY, AgoraStat.MODE_FILE],
		},
	})
	c["pigeon"] = _pkg("pigeon", "Pigeon Mail, the graphical mail program", {
		"programs": ["pigeon"], "depends": ["agora-desktop"],
		"files": {"/usr/share/applications/pigeon.desktop": [PIGEON_ENTRY, AgoraStat.MODE_FILE]},
	})
	c["pingmsg"] = _pkg("pingmsg", "Ping! Messenger, the instant messaging client", {
		"programs": ["pingmsg"], "depends": ["agora-desktop"],
		"files": {
			"/etc/pingmsg.conf": ["# /etc/pingmsg.conf: where Ping! Messenger connects.\nserver=login.pingmsg.com\nport=5190\n", AgoraStat.MODE_FILE],
			"/usr/share/applications/pingmsg.desktop": [PINGMSG_ENTRY, AgoraStat.MODE_FILE],
			# Its sounds: a two-note "ping" for a message, a rising one for a friend coming online.
			"/usr/share/sounds/pingmsg/message.wav": [Marshalls.raw_to_base64(AgoraWav.chime([[1568.0, 0.09], [2093.0, 0.16]])), AgoraStat.MODE_FILE, "base64"],
			"/usr/share/sounds/pingmsg/online.wav": [Marshalls.raw_to_base64(AgoraWav.chime([[659.0, 0.08], [784.0, 0.08], [988.0, 0.14]])), AgoraStat.MODE_FILE, "base64"],
		},
	})
	c["bsd-mailx"] = _pkg("bsd-mailx", "simple mail user agent", {
		"programs": ["mail"], "depends": ["exim4 | mail-transport-agent"], "provides": ["mailx", "mail-reader"],
		"files": {"/etc/mail.rc": [MAIL_RC, AgoraStat.MODE_FILE]},
		"links": {"/usr/bin/mailx": "mail", "/usr/bin/bsd-mailx": "mail"},
	})
	c["ftpd"] = _pkg("ftpd", "File Transfer Protocol (FTP) server", {
		"programs": ["in.ftpd"], "depends": ["openbsd-inetd"],
		"files": {"/etc/ftpusers": [FTPUSERS, AgoraStat.MODE_FILE]},
		"inetd": ["ftp\tstream\ttcp\tnowait\troot\t/usr/sbin/tcpd\t/usr/sbin/in.ftpd"],
	})
	c["popa3d"] = _pkg("popa3d", "Tiny POP3 daemon, designed with security as the primary goal", {
		"programs": ["popa3d"], "depends": ["openbsd-inetd"],
		"inetd": ["pop3\tstream\ttcp\tnowait\troot\t/usr/sbin/tcpd\t/usr/sbin/popa3d"],
	})
	c["telnetd"] = _pkg("telnetd", "The telnet server", {
		"programs": ["in.telnetd"], "depends": ["openbsd-inetd"],
		"files": {"/etc/issue.net": ["AgoraOS %s\n" % VERSION, AgoraStat.MODE_FILE]},
		"inetd": ["telnet\tstream\ttcp\tnowait\troot\t/usr/sbin/tcpd\t/usr/sbin/in.telnetd"],
	})
	var units := {}
	for target: String in TARGETS:
		units["/lib/systemd/system/" + target] = [TARGETS[target], AgoraStat.MODE_FILE]
	units["/lib/systemd/system/getty-tty1.service"] = [GETTY_UNIT % ["tty1", "tty1", "tty1"], AgoraStat.MODE_FILE]
	units["/lib/systemd/system/serial-getty-ttyS0.service"] = [GETTY_UNIT % ["ttyS0", "ttyS0", "ttyS0"], AgoraStat.MODE_FILE]
	units["/lib/systemd/system/rescue.service"] = [RESCUE_UNIT % "Rescue Shell", AgoraStat.MODE_FILE]
	units["/lib/systemd/system/emergency.service"] = [RESCUE_UNIT % "Emergency Shell", AgoraStat.MODE_FILE]
	c["systemd"] = _pkg("systemd", "system and service manager", {
		"programs": ["journalctl", "systemctl", "systemd"],
		"dirs": {"/etc/systemd/system": AgoraStat.MODE_DIR, "/lib/systemd/system": AgoraStat.MODE_DIR, "/var/log/journal": AgoraStat.MODE_DIR},
		"files": units,
		"links": {
			"/etc/systemd/system/multi-user.target.wants/getty-tty1.service": "/lib/systemd/system/getty-tty1.service",
			"/etc/systemd/system/multi-user.target.wants/serial-getty-ttyS0.service": "/lib/systemd/system/serial-getty-ttyS0.service",
		},
	})
	c["sysvinit"] = _pkg("sysvinit", "SysV init and runlevel scripts", {
		"programs": ["runlevel", "service", "start-stop-daemon", "sulogin", "sysvinit", "telinit"],
		"dirs": _rc_dirs(),
		"files": {
			"/etc/inittab": [INITTAB, AgoraStat.MODE_FILE],
			"/etc/init.d/rc": [RC, AgoraStat.MODE_EXEC],
			"/etc/init.d/rcS": [RCS, AgoraStat.MODE_EXEC],
			"/etc/init.d/checkroot.sh": [CHECKROOT, AgoraStat.MODE_EXEC],
			"/etc/init.d/hwclock.sh": [HWCLOCK_INIT, AgoraStat.MODE_EXEC],
		},
		"links": {
			"/etc/rcS.d/S10checkroot.sh": "../init.d/checkroot.sh",
			"/etc/rc0.d/K25hwclock.sh": "../init.d/hwclock.sh",
			"/etc/rc6.d/K25hwclock.sh": "../init.d/hwclock.sh",
		},
	})
	c["agora-desktop"] = _pkg("agora-desktop", "graphical desktop: login screen, window manager, apps", {
		"depends": ["coreutils"],
		"programs": ["desktop", "edit", "files", "greeter", "open", "panel", "terminal", "view", "wm"],
		"files": {
			"/etc/X11/xinitrc": [XINITRC, AgoraStat.MODE_EXEC],
			"/etc/greeter.conf": ["# autologin=<user>\n", AgoraStat.MODE_FILE],
			"/etc/wm.conf": ["theme=agora\n", AgoraStat.MODE_FILE],
			"/etc/desktop.conf": ["background=#1d2b38\n", AgoraStat.MODE_FILE],
			"/usr/share/themes/agora/wm.theme": [THEME_AGORA, AgoraStat.MODE_FILE],
			"/usr/share/themes/classic/wm.theme": [THEME_CLASSIC, AgoraStat.MODE_FILE],
			"/usr/share/applications/terminal.desktop": [TERMINAL_ENTRY, AgoraStat.MODE_FILE],
			"/usr/share/applications/files.desktop": [FILES_ENTRY, AgoraStat.MODE_FILE],
			"/usr/share/applications/edit.desktop": [EDIT_ENTRY, AgoraStat.MODE_FILE],
			"/usr/share/applications/view.desktop": [VIEW_ENTRY, AgoraStat.MODE_FILE],
			"/lib/systemd/system/display-manager.service": [DISPLAY_MANAGER_UNIT, AgoraStat.MODE_FILE],
			"/etc/skel/Desktop/README.txt": [README, AgoraStat.MODE_FILE],
		},
		"links": {"/etc/systemd/system/graphical.target.wants/display-manager.service": "/lib/systemd/system/display-manager.service"},
	})
	var applet_links := {}
	for applet: String in BUSYBOX_APPLETS:
		var path := "/sbin/init" if applet == "init" else AgoraPrograms.path_for(applet)
		applet_links[path] = "/bin/busybox"
	c["busybox"] = _pkg("busybox", "tiny versions of many common UNIX utilities in one binary", {
		"programs": ["busybox"], "links": applet_links,
		"dirs": {"/usr/share/udhcpc": AgoraStat.MODE_DIR},
		"files": {"/usr/share/udhcpc/default.script": [UDHCPC_SCRIPT, AgoraStat.MODE_EXEC]},
	})
	var router_links := {}
	for name in ["syslogd", "udhcpd", "sshd"]:
		router_links["/etc/rc3.d/S%02d%s" % [SERVICES[name][3], name]] = "../init.d/" + name
	router_links["/etc/rcS.d/S40networking"] = "../init.d/networking"
	router_links["/etc/rc3.d/S05firewall"] = "../init.d/firewall"
	c["router-base"] = _pkg("router-base", "router firmware configuration", {
		"depends": ["busybox"],
		"dirs": {"/etc/init.d": AgoraStat.MODE_DIR, "/etc/rc3.d": AgoraStat.MODE_DIR, "/etc/rcS.d": AgoraStat.MODE_DIR, "/etc/network": AgoraStat.MODE_DIR, "/var/lib/misc": AgoraStat.MODE_DIR},
		"files": {
			"/etc/network/interfaces": [ROUTER_INTERFACES, AgoraStat.MODE_FILE],
			"/etc/init.d/networking": [NETWORKING_INIT, AgoraStat.MODE_EXEC],
			"/etc/init.d/firewall": [ROUTER_FIREWALL, AgoraStat.MODE_EXEC],
			"/etc/dnsmasq.d/lan.conf": [ROUTER_DNSMASQ, AgoraStat.MODE_FILE],
			"/etc/inittab": [ROUTER_INITTAB, AgoraStat.MODE_FILE],
			"/etc/init.d/rc": [RC, AgoraStat.MODE_EXEC],
			"/etc/init.d/rcS": [RCS, AgoraStat.MODE_EXEC],
			"/etc/init.d/syslogd": [_init_script("syslogd", SERVICES.syslogd), AgoraStat.MODE_EXEC],
			"/etc/init.d/udhcpd": [_init_script("udhcpd", SERVICES.udhcpd), AgoraStat.MODE_EXEC],
			"/etc/udhcpd.conf": [ROUTER_UDHCPD_CONF, AgoraStat.MODE_FILE],
			"/etc/syslog.conf": [SYSLOG_CONF, AgoraStat.MODE_FILE],
			"/etc/banner": [ROUTER_BANNER % VERSION, AgoraStat.MODE_FILE],
		},
		"links": router_links,
	})
	c["apkg"] = _pkg("apkg", "the package manager", {
		"programs": ["apkg", "apkg-build", "apkg-scanpackages"],
		"dirs": {"/etc/apkg": AgoraStat.MODE_DIR, "/var/lib/apkg/info": AgoraStat.MODE_DIR, "/var/lib/apkg/lists": AgoraStat.MODE_DIR,
			"/var/cache/apkg/archives": AgoraStat.MODE_DIR, "/media/cdrom": AgoraStat.MODE_DIR},
		"files": {"/etc/apkg/sources.list": [APKG_SOURCES, AgoraStat.MODE_FILE]},
	})
	c["live-config"] = _pkg("live-config", "configuration of the install CD", {
		"depends": ["sysvinit"],
		"files": {"/etc/inittab": [LIVE_INITTAB, AgoraStat.MODE_FILE]},
	})
	c["agora-installer"] = _pkg("agora-installer", "the system installer", {"programs": ["agora-install"]})
	return c


static func _rc_dirs() -> Dictionary:
	var dirs := {"/etc/init.d": AgoraStat.MODE_DIR, "/etc/rcS.d": AgoraStat.MODE_DIR}
	for level in 7:
		dirs["/etc/rc%d.d" % level] = AgoraStat.MODE_DIR
	return dirs


## Networking comes up early at boot (rcS) and goes down last.
static func _networking_links() -> Dictionary:
	return {
		"/etc/systemd/system/multi-user.target.wants/networking.service": "/lib/systemd/system/networking.service",
		"/etc/rcS.d/S40networking": "../init.d/networking",
		"/etc/rc0.d/K95networking": "../init.d/networking",
		"/etc/rc6.d/K95networking": "../init.d/networking",
	}


## systemd "wants" link and SysV rc links for a service.
static func _service_links(name: String, order: int) -> Dictionary:
	var links := {"/etc/systemd/system/multi-user.target.wants/%s.service" % name: "/lib/systemd/system/%s.service" % name}
	for level in ["2", "3", "4", "5"]:
		links["/etc/rc%s.d/S%02d%s" % [level, order, name]] = "../init.d/" + name
	for level in ["0", "1", "6"]:
		if level == "1" and name == "syslogd":
			continue
		links["/etc/rc%s.d/K%02d%s" % [level, 100 - order, name]] = "../init.d/" + name
	return links


static func _unit_text(name: String, svc: Array) -> String:
	var after := "After=syslogd.service%s\n" % (" network.target" if name == "sshd" else "") if name != "syslogd" else ""
	return "[Unit]\nDescription=%s\n%s\n[Service]\nExecStart=%s %s\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target\n" % [svc[0], after, svc[1], svc[2]]


static func _init_script(name: String, svc: Array) -> String:
	return """#!/bin/sh
# /etc/init.d/{name}: start and stop the {desc}.
NAME={name}
DAEMON={daemon}
ARGS="{args}"
PIDFILE=/run/$NAME.pid

case "$1" in
	start)
		echo "Starting $NAME"
		start-stop-daemon --start --oknodo --pidfile $PIDFILE --exec $DAEMON -- $ARGS
		;;
	stop)
		echo "Stopping $NAME"
		start-stop-daemon --stop --oknodo --pidfile $PIDFILE
		;;
	restart)
		$0 stop
		$0 start
		;;
	status)
		if [ -f $PIDFILE ] && [ -d /proc/$(cat $PIDFILE) ]; then
			echo "$NAME is running"
		else
			echo "$NAME is not running"
			exit 3
		fi
		;;
	*)
		echo "Usage: $0 {start|stop|restart|status}"
		exit 1
		;;
esac
exit 0
""".format({"name": name, "desc": (svc[0] as String).to_lower(), "daemon": svc[1], "args": svc[2]})


