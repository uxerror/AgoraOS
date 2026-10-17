class_name AgoraInstaller
extends RefCounted
## Lays down the base system on a fresh machine: the directory tree,
## configuration files in /etc, accounts and the binaries in /bin.

const DIRS := {
	"/bin": AgoraStat.MODE_DIR,
	"/dev": AgoraStat.MODE_DIR,
	"/etc": AgoraStat.MODE_DIR,
	"/etc/init.d": AgoraStat.MODE_DIR,
	"/etc/rc0.d": AgoraStat.MODE_DIR,
	"/etc/rc1.d": AgoraStat.MODE_DIR,
	"/etc/rc2.d": AgoraStat.MODE_DIR,
	"/etc/rc3.d": AgoraStat.MODE_DIR,
	"/etc/rc4.d": AgoraStat.MODE_DIR,
	"/etc/rc5.d": AgoraStat.MODE_DIR,
	"/etc/rc6.d": AgoraStat.MODE_DIR,
	"/etc/skel": AgoraStat.MODE_DIR,
	"/etc/ssh": AgoraStat.MODE_DIR,
	"/etc/systemd/system": AgoraStat.MODE_DIR,
	"/lib/systemd/system": AgoraStat.MODE_DIR,
	"/lib/sysvinit": AgoraStat.MODE_DIR,
	"/run": AgoraStat.MODE_DIR,
	"/sbin": AgoraStat.MODE_DIR,
	"/home": AgoraStat.MODE_DIR,
	"/mnt": AgoraStat.MODE_DIR,
	"/proc": AgoraStat.MODE_DIR,
	"/root": AgoraStat.MODE_PRIVATE_DIR,
	"/tmp": AgoraStat.MODE_TMP,
	"/usr": AgoraStat.MODE_DIR,
	"/usr/bin": AgoraStat.MODE_DIR,
	"/usr/share": AgoraStat.MODE_DIR,
	"/var": AgoraStat.MODE_DIR,
	"/var/log": AgoraStat.MODE_DIR,
	"/var/log/journal": AgoraStat.MODE_DIR,
	"/var/spool/cron/crontabs": AgoraStat.MODE_PRIVATE_DIR,
}

## Services shipped with the system: name -> [description, daemon, args,
## start order]. Each gets a systemd unit and a SysV init script.
const SERVICES := {
	"syslogd": ["System Logging Service", "/sbin/syslogd", "-n", 10],
	"crond": ["Regular background program processing daemon", "/sbin/crond", "-n", 20],
	"sshd": ["OpenSSH server daemon", "/sbin/sshd", "-D", 30],
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
x:5:respawn:/bin/sh -c "if [ -e /dev/fb0 ]; then DISPLAY=:0 greeter; else sleep 1000000; fi"
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


## Files every system has, as path -> [content, mode]. [method upgrade]
## adds any that are missing, so older saved machines pick up new parts of
## the OS without losing data.
static func system_files() -> Dictionary:
	var files := {
		"/etc/profile": [PROFILE, AgoraStat.MODE_FILE],
		"/etc/skel/.profile": [SKEL_PROFILE, AgoraStat.MODE_FILE],
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
		"/etc/mime.types": [MIME_TYPES, AgoraStat.MODE_FILE],
		"/etc/skel/Desktop/README.txt": [README, AgoraStat.MODE_FILE],
		"/etc/inittab": [INITTAB, AgoraStat.MODE_FILE],
		"/etc/init.d/rc": [RC, AgoraStat.MODE_EXEC],
		"/etc/init.d/rcS": [RCS, AgoraStat.MODE_EXEC],
		"/etc/syslog.conf": [SYSLOG_CONF, AgoraStat.MODE_FILE],
		"/etc/crontab": [CRONTAB, AgoraStat.MODE_FILE],
		"/etc/ssh/sshd_config": [SSHD_CONFIG, AgoraStat.MODE_FILE],
		"/lib/systemd/system/display-manager.service": [DISPLAY_MANAGER_UNIT, AgoraStat.MODE_FILE],
	}
	for target: String in TARGETS:
		files["/lib/systemd/system/" + target] = [TARGETS[target], AgoraStat.MODE_FILE]
	for name: String in SERVICES:
		var svc: Array = SERVICES[name]
		files["/lib/systemd/system/%s.service" % name] = [_unit_text(name, svc), AgoraStat.MODE_FILE]
		files["/etc/init.d/" + name] = [_init_script(name, svc), AgoraStat.MODE_EXEC]
	return files


## Symlinks every system has, as link -> target.
static func system_links() -> Dictionary:
	var links := {
		"/var/run": "/run",
		"/etc/systemd/system/default.target": "/lib/systemd/system/graphical.target",
		"/etc/systemd/system/graphical.target.wants/display-manager.service": "/lib/systemd/system/display-manager.service",
	}
	for name: String in SERVICES:
		var order: int = SERVICES[name][3]
		links["/etc/systemd/system/multi-user.target.wants/%s.service" % name] = "/lib/systemd/system/%s.service" % name
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


## [param opts]:
## - users: Array of {name, password, groups: Array, gecos}
## - root_password: String ("" = no password)
## - motd: String shown at login
## - programs: PackedStringArray of program names (default: all registered)
## - init: "systemd" (default) or "sysvinit": what /sbin/init points to
static func install(m: AgoraMachine, hostname: String, opts: Dictionary = {}) -> void:
	var root := AgoraCred.root()
	var vfs := m.vfs
	for path: String in DIRS:
		vfs.make_dirs(root, path)
		vfs.chmod(root, path, DIRS[path])
	vfs.write_text(root, "/etc/hostname", hostname + "\n")
	vfs.write_text(root, "/etc/passwd", "root:x:0:0:root:/root:/bin/sh\n")
	vfs.write_text(root, "/etc/group", GROUPS)
	vfs.write_text(root, "/etc/shadow", "", "/", false, AgoraStat.MODE_PRIVATE_FILE)
	vfs.chmod(root, "/etc/shadow", AgoraStat.MODE_PRIVATE_FILE)
	m.users.set_password("root", opts.get("root_password", ""))
	_write_system_files(m, false)
	vfs.write_text(root, "/etc/motd", opts.get("motd", "Welcome to %s.\n" % hostname))
	vfs.write_text(root, "/etc/issue", "%s %s \\n \\l\n" % [AgoraMachine.KERNEL_NAME, AgoraMachine.KERNEL_VERSION])
	vfs.write_text(root, "/etc/os-release", 'NAME="AgoraOS"\nVERSION="%s"\nID=agora\n' % AgoraMachine.KERNEL_VERSION)
	for log_file in ["auth.log", "syslog"]:
		var path: String = "/var/log/" + log_file
		vfs.write_text(root, path, "", "/", false, 416) # 0o640
		vfs.chown(root, path, 0, 4) # group adm may read logs
	var programs: PackedStringArray = opts.get("programs", AgoraPrograms.names())
	for name in programs:
		install_program(m, name)
	_make_links(m)
	set_init(m, opts.get("init", "systemd"))
	for u: Dictionary in opts.get("users", []):
		m.users.add_user(u.name, u.get("password", ""), {
			"groups": u.get("groups", []), "gecos": u.get("gecos", ""),
		})


## Brings an existing machine up to date with this version of the OS: adds
## missing system files and directories and missing binaries. Never
## overwrites anything, so the player's (or an intruder's) edits survive.
static func upgrade(m: AgoraMachine) -> void:
	var root := AgoraCred.root()
	for path: String in DIRS:
		if not m.vfs.exists(root, path):
			m.vfs.make_dirs(root, path)
			m.vfs.chmod(root, path, DIRS[path])
	_write_system_files(m, true)
	for name in AgoraPrograms.names():
		if not m.vfs.exists(root, AgoraPrograms.path_for(name)):
			install_program(m, name)
	_make_links(m)
	if m.vfs.stat(root, AgoraMachine.INIT_PATH, "/", false) == null:
		set_init(m, "systemd")


## Points /sbin/init at an init implementation: "systemd" or "sysvinit".
## Takes effect at the next boot. Anything else on disk can be linked by hand.
static func set_init(m: AgoraMachine, which: String) -> void:
	var root := AgoraCred.root()
	m.vfs.unlink(root, AgoraMachine.INIT_PATH)
	m.vfs.symlink(root, AgoraPrograms.path_for(which), AgoraMachine.INIT_PATH)


static func _make_links(m: AgoraMachine) -> void:
	var root := AgoraCred.root()
	var links := system_links()
	for link: String in links:
		if m.vfs.stat(root, link, "/", false) != null:
			continue
		m.vfs.make_dirs(root, AgoraPath.dirname(link))
		m.vfs.symlink(root, links[link], link)


static func _write_system_files(m: AgoraMachine, only_missing: bool) -> void:
	var root := AgoraCred.root()
	var files := system_files()
	for path: String in files:
		if only_missing and m.vfs.stat(root, path, "/", false) != null:
			continue
		m.vfs.make_dirs(root, AgoraPath.dirname(path))
		m.vfs.write_text(root, path, files[path][0], "/", false, files[path][1])
		m.vfs.chmod(root, path, files[path][1])


## Writes the binary of a registered program to its place (see
## [method AgoraPrograms.path_for]).
static func install_program(m: AgoraMachine, name: String) -> void:
	var root := AgoraCred.root()
	var path := AgoraPrograms.path_for(name)
	m.vfs.make_dirs(root, AgoraPath.dirname(path))
	var body := "%s%s\n# %s native executable. Not human readable.\n" % [AgoraMachine.EXEC_MAGIC, name, AgoraMachine.KERNEL_NAME]
	var mode := AgoraStat.MODE_EXEC
	if AgoraPrograms.SETUID.has(name):
		mode |= AgoraStat.S_ISUID
	m.vfs.write_text(root, path, body, "/", false, mode)
	m.vfs.chmod(root, path, mode)
