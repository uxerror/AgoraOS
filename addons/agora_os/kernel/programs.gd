class_name AgoraPrograms
extends RefCounted
## Registry of native programs. A binary in /bin names one of these entries.
## The list is explicit (no folder scanning) so it works in exported builds.
## The game can add its own programs with [method register].

const SETUID: PackedStringArray = ["passwd", "su", "sudo"]

const _BUILTIN := {
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
	"env": preload("bin/env.gd"),
	"false": preload("bin/false.gd"),
	"find": preload("bin/find.gd"),
	"grep": preload("bin/grep.gd"),
	"head": preload("bin/head.gd"),
	"help": preload("bin/help.gd"),
	"hostname": preload("bin/hostname.gd"),
	"id": preload("bin/id.gd"),
	"ifconfig": preload("bin/ifconfig.gd"),
	"kill": preload("bin/kill.gd"),
	"ln": preload("bin/ln.gd"),
	"ls": preload("bin/ls.gd"),
	"mkdir": preload("bin/mkdir.gd"),
	"mount": preload("bin/mount.gd"),
	"mv": preload("bin/mv.gd"),
	"passwd": preload("bin/passwd.gd"),
	"ping": preload("bin/ping.gd"),
	"ps": preload("bin/ps.gd"),
	"pwd": preload("bin/pwd.gd"),
	"rm": preload("bin/rm.gd"),
	"rmdir": preload("bin/rmdir.gd"),
	"seq": preload("bin/seq.gd"),
	"sh": preload("bin/sh.gd"),
	"sleep": preload("bin/sleep.gd"),
	"sort": preload("bin/sort.gd"),
	"ssh": preload("bin/ssh.gd"),
	"stat": preload("bin/stat.gd"),
	"su": preload("bin/su.gd"),
	"sudo": preload("bin/sudo.gd"),
	"tail": preload("bin/tail.gd"),
	"tee": preload("bin/tee.gd"),
	"test": preload("bin/test.gd"),
	"[": preload("bin/test.gd"),
	"touch": preload("bin/touch.gd"),
	"tr": preload("bin/tr.gd"),
	"true": preload("bin/true.gd"),
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
}

static var _extra := {}


static func lookup(name: String) -> Script:
	if _extra.has(name):
		return _extra[name]
	return _BUILTIN.get(name)


## Adds a program. Install it on a machine with [method AgoraInstaller.install_program].
static func register(name: String, script: Script) -> void:
	_extra[name] = script


static func names() -> PackedStringArray:
	var out := PackedStringArray(_BUILTIN.keys())
	for k: String in _extra:
		if not out.has(k):
			out.append(k)
	out.sort()
	return out
