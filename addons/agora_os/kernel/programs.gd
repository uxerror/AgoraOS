class_name AgoraPrograms
extends RefCounted
## Registry of native programs. A binary on disk names one of these entries.
## The list is explicit (no folder scanning) so it works in exported builds.
## The game can add its own programs with [method register].

const SETUID: PackedStringArray = ["crontab", "passwd", "su", "sudo"]

## Where each program is installed, if not /bin/<name>.
const PATHS := {
	"systemd": "/lib/systemd/systemd",
	"udhcpd": "/usr/sbin/udhcpd",
	"traceroute": "/usr/bin/traceroute",
	"dumpleases": "/usr/bin/dumpleases",
	"sysvinit": "/lib/sysvinit/init",
}
## Programs that belong in /sbin (system administration and daemons).
const SBIN: PackedStringArray = [
	"agora-install", "arp", "bridge", "brctl", "crond", "iptables", "iptables-restore", "iptables-save", "getty", "halt", "ifconfig", "ifdown", "ifup", "mkfs", "poweroff",
	"reboot", "route", "runlevel", "sysctl", "udhcpc", "service", "shutdown", "sshd", "start-stop-daemon",
	"syslogd", "telinit", "useradd",
]

const _BUILTIN := {
	"arp": preload("bin/arp.gd"),
	"bridge": preload("bin/bridge.gd"),
	"brctl": preload("bin/brctl.gd"),
	"basename": preload("bin/basename.gd"),
	"cat": preload("bin/cat.gd"),
	"chmod": preload("bin/chmod.gd"),
	"chown": preload("bin/chown.gd"),
	"clear": preload("bin/clear.gd"),
	"cp": preload("bin/cp.gd"),
	"cut": preload("bin/cut.gd"),
	"date": preload("bin/date.gd"),
	"dirname": preload("bin/dirname.gd"),
	"echo": preload("bin/echo.gd"),
	"eject": preload("bin/eject.gd"),
	"env": preload("bin/env.gd"),
	"false": preload("bin/false.gd"),
	"find": preload("bin/find.gd"),
	"free": preload("bin/free.gd"),
	"getty": preload("bin/getty.gd"),
	"grep": preload("bin/grep.gd"),
	"head": preload("bin/head.gd"),
	"help": preload("bin/help.gd"),
	"hostname": preload("bin/hostname.gd"),
	"id": preload("bin/id.gd"),
	"ifconfig": preload("bin/ifconfig.gd"),
	"ip": preload("bin/ip.gd"),
	"iptables": preload("bin/iptables.gd"),
	"iptables-restore": preload("bin/iptables.gd"),
	"iptables-save": preload("bin/iptables.gd"),
	"kill": preload("bin/kill.gd"),
	"ln": preload("bin/ln.gd"),
	"login": preload("bin/login.gd"),
	"ls": preload("bin/ls.gd"),
	"lsblk": preload("bin/lsblk.gd"),
	"mkdir": preload("bin/mkdir.gd"),
	"mkfs": preload("bin/mkfs.gd"),
	"mount": preload("bin/mount.gd"),
	"mv": preload("bin/mv.gd"),
	"nc": preload("bin/nc.gd"),
	"netstat": preload("bin/netstat.gd"),
	"passwd": preload("bin/passwd.gd"),
	"ping": preload("bin/ping.gd"),
	"ps": preload("bin/ps.gd"),
	"pwd": preload("bin/pwd.gd"),
	"readlink": preload("bin/readlink.gd"),
	"rm": preload("bin/rm.gd"),
	"route": preload("bin/route.gd"),
	"rmdir": preload("bin/rmdir.gd"),
	"seq": preload("bin/seq.gd"),
	"sh": preload("bin/sh.gd"),
	"sleep": preload("bin/sleep.gd"),
	"sort": preload("bin/sort.gd"),
	"ssh": preload("bin/ssh.gd"),
	"stat": preload("bin/stat.gd"),
	"sysctl": preload("bin/sysctl.gd"),
	"su": preload("bin/su.gd"),
	"sudo": preload("bin/sudo.gd"),
	"tail": preload("bin/tail.gd"),
	"tee": preload("bin/tee.gd"),
	"test": preload("bin/test.gd"),
	"[": preload("bin/test.gd"),
	"touch": preload("bin/touch.gd"),
	"traceroute": preload("bin/traceroute.gd"),
	"tr": preload("bin/tr.gd"),
	"true": preload("bin/true.gd"),
	"umount": preload("bin/umount.gd"),
	"uname": preload("bin/uname.gd"),
	"uniq": preload("bin/uniq.gd"),
	"uptime": preload("bin/uptime.gd"),
	"useradd": preload("bin/useradd.gd"),
	"wc": preload("bin/wc.gd"),
	"which": preload("bin/which.gd"),
	"whoami": preload("bin/whoami.gd"),
	"yes": preload("bin/yes.gd"),
	# graphical programs
	"desktop": preload("../gui/apps/desktop.gd"),
	"edit": preload("../gui/apps/edit.gd"),
	"files": preload("../gui/apps/files.gd"),
	"greeter": preload("../gui/apps/greeter.gd"),
	"open": preload("../gui/apps/open.gd"),
	"panel": preload("../gui/apps/panel.gd"),
	"terminal": preload("../gui/apps/terminal.gd"),
	"view": preload("../gui/apps/view.gd"),
	"wm": preload("../gui/apps/wm.gd"),
	# init systems, daemons and their tools
	"crond": preload("../system/crond.gd"),
	"crontab": preload("../system/crontab.gd"),
	"dmesg": preload("../system/dmesg.gd"),
	"dumpleases": preload("../system/dumpleases.gd"),
	"udhcpc": preload("../system/udhcpc.gd"),
	"udhcpd": preload("../system/udhcpd.gd"),
	"halt": preload("../system/reboot.gd"),
	"ifdown": preload("../system/ifupdown.gd"),
	"ifup": preload("../system/ifupdown.gd"),
	"journalctl": preload("../system/journalctl.gd"),
	"logger": preload("../system/logger.gd"),
	"poweroff": preload("../system/reboot.gd"),
	"reboot": preload("../system/reboot.gd"),
	"runlevel": preload("../system/runlevel.gd"),
	"service": preload("../system/service.gd"),
	"shutdown": preload("../system/reboot.gd"),
	"sshd": preload("../system/sshd.gd"),
	"start-stop-daemon": preload("../system/start_stop_daemon.gd"),
	"busybox": preload("../system/busybox.gd"),
	"apkg": preload("../system/apkg.gd"),
	"agora-install": preload("../system/agora_install.gd"),
	"syslogd": preload("../system/syslogd.gd"),
	"systemctl": preload("../system/systemctl.gd"),
	"systemd": preload("../system/systemd.gd"),
	"sysvinit": preload("../system/sysvinit.gd"),
	"telinit": preload("../system/sysvinit.gd"),
}

static var _extra := {}
static var _extra_paths := {}


static func lookup(name: String) -> Script:
	if _extra.has(name):
		return _extra[name]
	return _BUILTIN.get(name)


## Adds a program, installed at [param path] (default /bin/<name>). Put it on
## a machine with [method AgoraInstaller.install_program].
static func register(name: String, script: Script, path: String = "") -> void:
	_extra[name] = script
	if not path.is_empty():
		_extra_paths[name] = path


## Absolute install path of a program.
static func path_for(name: String) -> String:
	if _extra_paths.has(name):
		return _extra_paths[name]
	if PATHS.has(name):
		return PATHS[name]
	return ("/sbin/" if SBIN.has(name) else "/bin/") + name


static func names() -> PackedStringArray:
	var out := PackedStringArray(_BUILTIN.keys())
	for k: String in _extra:
		if not out.has(k):
			out.append(k)
	out.sort()
	return out
