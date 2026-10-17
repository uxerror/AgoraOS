class_name AgoraInstaller
extends RefCounted
## Lays down the base system on a fresh machine: the directory tree,
## configuration files in /etc, accounts and the binaries in /bin.

const DIRS := {
	"/bin": AgoraStat.MODE_DIR,
	"/dev": AgoraStat.MODE_DIR,
	"/etc": AgoraStat.MODE_DIR,
	"/etc/skel": AgoraStat.MODE_DIR,
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

## Files every system has. [method upgrade] adds any that are missing, so
## older saved machines pick up new parts of the OS without losing data.
## Values are [content, mode].
const SYSTEM_FILES := {
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
}


## [param opts]:
## - users: Array of {name, password, groups: Array, gecos}
## - root_password: String ("" = no password)
## - motd: String shown at login
## - programs: PackedStringArray of program names (default: all registered)
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
		if not m.vfs.exists(root, "/bin/" + name):
			install_program(m, name)


static func _write_system_files(m: AgoraMachine, only_missing: bool) -> void:
	var root := AgoraCred.root()
	for path: String in SYSTEM_FILES:
		if only_missing and m.vfs.exists(root, path):
			continue
		m.vfs.make_dirs(root, AgoraPath.dirname(path))
		m.vfs.write_text(root, path, SYSTEM_FILES[path][0], "/", false, SYSTEM_FILES[path][1])
		m.vfs.chmod(root, path, SYSTEM_FILES[path][1])


## Writes the binary for a registered program into /bin.
static func install_program(m: AgoraMachine, name: String, dir: String = "/bin") -> void:
	var root := AgoraCred.root()
	var path := AgoraPath.join(dir, name)
	var body := "%s%s\n# %s native executable. Not human readable.\n" % [AgoraMachine.EXEC_MAGIC, name, AgoraMachine.KERNEL_NAME]
	var mode := AgoraStat.MODE_EXEC
	if AgoraPrograms.SETUID.has(name):
		mode |= AgoraStat.S_ISUID
	m.vfs.write_text(root, path, body, "/", false, mode)
	m.vfs.chmod(root, path, mode)
