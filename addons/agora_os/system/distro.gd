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
	"sshd": ["OpenSSH server daemon", "/sbin/sshd", "-D", 30, "openssh", ["ssh", "sshd"]],
}

const GROUPS := "root:x:0:\nadm:x:4:\nsudo:x:27:\nusers:x:100:\n"

const PROFILE := """# /etc/profile: read by every login shell.
export PATH=/bin:/usr/bin
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
echo "Hostname: $(cat /etc/hostname)"
echo "Cleaning /tmp"
rm -rf /tmp/*
exit 0
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
	"multi-user.target": "[Unit]\nDescription=Multi-User System\nRequires=basic.target\nAfter=basic.target\n",
	"graphical.target": "[Unit]\nDescription=Graphical Interface\nRequires=multi-user.target\nAfter=multi-user.target\nWants=display-manager.service\n",
}

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



## Packages per profile, in install order (dependencies are added anyway).
const PROFILES := {
	"desktop": ["agora-kernel", "base-files", "sh", "coreutils", "util-linux", "shadow", "iproute",
		"sysklogd", "cron", "openssh", "sysvinit", "systemd", "agora-desktop", "apkg"],
	"server": ["agora-kernel", "base-files", "sh", "coreutils", "util-linux", "shadow", "iproute",
		"sysklogd", "cron", "openssh", "sysvinit", "systemd", "apkg"],
	"router": ["agora-kernel", "base-files", "busybox", "router-base", "openssh", "apkg"],
	"live": ["agora-kernel", "base-files", "sh", "coreutils", "util-linux", "shadow", "iproute",
		"sysvinit", "live-config", "agora-installer", "apkg"],
}

const PROFILE_INFO := {
	"desktop": "graphical desktop with servers and tools",
	"server": "the same without graphics",
	"router": "minimal busybox system for network devices",
}

const COREUTILS: PackedStringArray = [
	"[", "basename", "cat", "chmod", "chown", "clear", "cp", "cut", "date", "dirname", "echo",
	"env", "false", "find", "grep", "head", "help", "hostname", "id", "kill", "ln", "ls", "mkdir",
	"mv", "ps", "pwd", "readlink", "rm", "rmdir", "seq", "sleep", "sort", "stat", "tail", "tee",
	"test", "touch", "tr", "true", "uname", "uniq", "uptime", "wc", "which", "whoami", "yes",
]

## Applets compiled into busybox, and the program implementing each.
const BUSYBOX_APPLETS := {
	"sh": "sh", "ash": "sh", "cat": "cat", "chmod": "chmod", "chown": "chown", "clear": "clear",
	"cp": "cp", "cut": "cut", "date": "date", "dmesg": "dmesg", "echo": "echo", "env": "env",
	"false": "false", "find": "find", "free": "free", "getty": "getty", "grep": "grep",
	"halt": "halt", "head": "head", "hostname": "hostname", "id": "id", "ifconfig": "ifconfig",
	"init": "sysvinit", "ip": "ip", "kill": "kill", "ln": "ln", "logger": "logger", "login": "login",
	"ls": "ls", "mkdir": "mkdir", "mount": "mount", "mv": "mv", "passwd": "passwd", "ping": "ping",
	"poweroff": "poweroff", "ps": "ps", "pwd": "pwd", "readlink": "readlink", "reboot": "reboot",
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

const APKG_REPOS := """# /etc/apkg/repositories: where apkg looks for packages (.pkg files).
# Mount the install CD there: mount /dev/sr0 /media/cdrom
/media/cdrom/repo
"""

static var _catalog := {}


## Every package by name.
static func catalog() -> Dictionary:
	if _catalog.is_empty():
		_catalog = _build_catalog()
	return _catalog


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
	c["agora-kernel"] = _pkg("agora-kernel", "Agora kernel image", {
		"dirs": {"/boot": AgoraStat.MODE_DIR},
		"files": {"/boot/vmlinuz-" + VERSION: ["Agora kernel %s\n" % VERSION, AgoraStat.MODE_FILE]},
		"links": {"/boot/vmlinuz": "vmlinuz-" + VERSION},
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
		"programs": ["dmesg", "eject", "free", "getty", "halt", "login", "logger", "lsblk", "mkfs",
			"mount", "poweroff", "reboot", "shutdown", "umount"],
	})
	c["shadow"] = _pkg("shadow", "user accounts: su, sudo, passwd, useradd", {"programs": ["passwd", "su", "sudo", "useradd"]})
	c["iproute"] = _pkg("iproute", "network configuration: ip, ifconfig, ping", {"programs": ["ifconfig", "ip", "ping"]})
	for name: String in SERVICES:
		var svc: Array = SERVICES[name]
		var pkg_name: String = svc[4]
		var spec := _pkg(pkg_name, (svc[0] as String).to_lower(), {"programs": svc[5].duplicate()})
		spec.files["/lib/systemd/system/%s.service" % name] = [_unit_text(name, svc), AgoraStat.MODE_FILE]
		spec.files["/etc/init.d/" + name] = [_init_script(name, svc), AgoraStat.MODE_EXEC]
		spec.links.merge(_service_links(name, svc[3]))
		c[pkg_name] = spec
	c["sysklogd"].files["/etc/syslog.conf"] = [SYSLOG_CONF, AgoraStat.MODE_FILE]
	c["cron"].files["/etc/crontab"] = [CRONTAB, AgoraStat.MODE_FILE]
	c["cron"].dirs["/var/spool/cron/crontabs"] = AgoraStat.MODE_PRIVATE_DIR
	c["openssh"].files["/etc/ssh/sshd_config"] = [SSHD_CONFIG, AgoraStat.MODE_FILE]
	c["openssh"].dirs["/etc/ssh"] = AgoraStat.MODE_DIR
	var units := {}
	for target: String in TARGETS:
		units["/lib/systemd/system/" + target] = [TARGETS[target], AgoraStat.MODE_FILE]
	units["/lib/systemd/system/getty-tty1.service"] = [GETTY_UNIT % ["tty1", "tty1", "tty1"], AgoraStat.MODE_FILE]
	units["/lib/systemd/system/serial-getty-ttyS0.service"] = [GETTY_UNIT % ["ttyS0", "ttyS0", "ttyS0"], AgoraStat.MODE_FILE]
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
		"programs": ["runlevel", "service", "start-stop-daemon", "sysvinit", "telinit"],
		"dirs": _rc_dirs(),
		"files": {
			"/etc/inittab": [INITTAB, AgoraStat.MODE_FILE],
			"/etc/init.d/rc": [RC, AgoraStat.MODE_EXEC],
			"/etc/init.d/rcS": [RCS, AgoraStat.MODE_EXEC],
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
	})
	var router_links := {}
	for name in ["syslogd", "sshd"]:
		router_links["/etc/rc3.d/S%02d%s" % [SERVICES[name][3], name]] = "../init.d/" + name
	c["router-base"] = _pkg("router-base", "router firmware configuration", {
		"depends": ["busybox"],
		"dirs": {"/etc/init.d": AgoraStat.MODE_DIR, "/etc/rc3.d": AgoraStat.MODE_DIR},
		"files": {
			"/etc/inittab": [ROUTER_INITTAB, AgoraStat.MODE_FILE],
			"/etc/init.d/rc": [RC, AgoraStat.MODE_EXEC],
			"/etc/init.d/rcS": [RCS, AgoraStat.MODE_EXEC],
			"/etc/init.d/syslogd": [_init_script("syslogd", SERVICES.syslogd), AgoraStat.MODE_EXEC],
			"/etc/syslog.conf": [SYSLOG_CONF, AgoraStat.MODE_FILE],
			"/etc/banner": [ROUTER_BANNER % VERSION, AgoraStat.MODE_FILE],
		},
		"links": router_links,
	})
	c["apkg"] = _pkg("apkg", "the package manager", {
		"programs": ["apkg"],
		"dirs": {"/etc/apkg": AgoraStat.MODE_DIR, "/var/lib/apkg/info": AgoraStat.MODE_DIR, "/media/cdrom": AgoraStat.MODE_DIR},
		"files": {"/etc/apkg/repositories": [APKG_REPOS, AgoraStat.MODE_FILE]},
	})
	c["live-config"] = _pkg("live-config", "configuration of the install CD", {
		"depends": ["sysvinit"],
		"files": {"/etc/inittab": [LIVE_INITTAB, AgoraStat.MODE_FILE]},
	})
	c["agora-installer"] = _pkg("agora-installer", "the system installer", {"programs": ["agora-install"]})
	return c


static func _rc_dirs() -> Dictionary:
	var dirs := {"/etc/init.d": AgoraStat.MODE_DIR}
	for level in 7:
		dirs["/etc/rc%d.d" % level] = AgoraStat.MODE_DIR
	return dirs


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
	var after := "After=syslogd.service\n" if name != "syslogd" else ""
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


