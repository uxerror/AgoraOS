class_name AgoraInstaller
extends RefCounted
## Installs AgoraOS onto a disk: formats it, installs the packages of a
## profile (see [AgoraDistro]) and writes the initial configuration
## (host name, accounts, init). Used by the agora-install program on the
## install CD, and by [method AgoraMachine.create] for ready-made machines.


## Formats [param disk] and installs the system on it.
## [param opts]:
## - profile: "desktop" (default), "server", "router" or "live"
## - users: Array of {name, password, groups: Array, gecos}
## - root_password: String ("" = no password)
## - motd: String shown at login
## - init: "systemd" (default) or "sysvinit" for desktop and server
## - packages: extra package names
static func install_disk(disk: AgoraDisk, hostname: String, opts: Dictionary = {}, clock: AgoraClock = null) -> void:
	disk.format()
	var vfs := target_vfs(disk, clock)
	install_target(vfs, hostname, opts)


## A VFS over a disk's file system alone, for installing onto it.
static func target_vfs(disk: AgoraDisk, clock: AgoraClock = null) -> AgoraVfs:
	var c := clock if clock else AgoraClock.new()
	var vfs := AgoraVfs.new(c.now_int)
	vfs.mount("/", disk.fs)
	return vfs


## Installs and configures on [param vfs]. [param fetch] returns a package
## dictionary by name (default: the built-in catalog; the installer reads
## .pkg files from the CD instead).
static func install_target(vfs: AgoraVfs, hostname: String, opts: Dictionary = {}, fetch: Callable = Callable()) -> void:
	for pkg in plan(opts, fetch):
		AgoraPackages.install(vfs, pkg)
	configure(vfs, hostname, opts)


## Packages to install for [param opts], dependencies first.
static func plan(opts: Dictionary, fetch: Callable = Callable()) -> Array[Dictionary]:
	var profile: String = opts.get("profile", "desktop")
	var names := PackedStringArray(AgoraDistro.PROFILES[profile])
	names.append_array(opts.get("packages", []))
	return AgoraPackages.resolve(names, fetch if fetch.is_valid() else AgoraDistro.package)


## Writes the machine's own configuration: host name, accounts, logs, init.
static func configure(vfs: AgoraVfs, hostname: String, opts: Dictionary) -> void:
	var root := AgoraCred.root()
	var profile: String = opts.get("profile", "desktop")
	vfs.write_text(root, "/etc/hostname", hostname + "\n")
	vfs.write_text(root, "/etc/passwd", "root:x:0:0:root:/root:/bin/sh\n")
	vfs.write_text(root, "/etc/group", AgoraDistro.GROUPS)
	vfs.write_text(root, "/etc/shadow", "", "/", false, AgoraStat.MODE_PRIVATE_FILE)
	vfs.chmod(root, "/etc/shadow", AgoraStat.MODE_PRIVATE_FILE)
	var users := AgoraUsers.new(vfs)
	users.set_password("root", opts.get("root_password", ""))
	var banner := vfs.read_text(root, "/etc/banner")
	vfs.write_text(root, "/etc/motd", opts.get("motd", banner if not banner.is_empty() else "Welcome to %s.\n" % hostname))
	vfs.write_text(root, "/etc/issue", "AgoraOS %s \\n \\l\n" % AgoraDistro.VERSION)
	vfs.write_text(root, "/etc/os-release", 'NAME="AgoraOS"\nVERSION="%s"\nID=agora\nVARIANT_ID=%s\n' % [AgoraDistro.VERSION, profile])
	for log_file in ["auth.log", "syslog"]:
		var path: String = "/var/log/" + log_file
		vfs.write_text(root, path, "", "/", false, 416) # 0o640
		vfs.chown(root, path, 0, 4) # group adm may read logs
	if vfs.exists(root, "/lib/systemd/system"):
		var target := "graphical.target" if vfs.exists(root, "/bin/greeter") else "multi-user.target"
		vfs.unlink(root, "/etc/systemd/system/default.target")
		vfs.symlink(root, "/lib/systemd/system/" + target, "/etc/systemd/system/default.target")
	if profile in ["desktop", "server"]:
		set_init(vfs, opts.get("init", "systemd"))
	elif not vfs.exists(root, "/sbin/init"):
		set_init(vfs, "sysvinit")
	for u: Dictionary in opts.get("users", []):
		users.add_user(u.name, u.get("password", ""), {"groups": u.get("groups", []), "gecos": u.get("gecos", "")})
	configure_network(vfs, hostname, opts.get("network", {}), opts.get("nameservers", []), "192.168.1.1" if profile == "router" else "127.0.1.1")


## Writes /etc/hosts and, for the interfaces in [param network], the
## ifupdown configuration. Each entry is {method: "dhcp", "static" or
## "manual", address, netmask, gateway}. Without entries only lo is set up
## (a router keeps the configuration its firmware package brought).
static func configure_network(vfs: AgoraVfs, hostname: String, network: Dictionary, nameservers: Array, own_address: String = "127.0.1.1") -> void:
	var root := AgoraCred.root()
	vfs.write_text(root, "/etc/hosts", "127.0.0.1\tlocalhost\n%s\t%s\n" % [own_address, hostname])
	if not nameservers.is_empty():
		var text := ""
		for ns: String in nameservers:
			text += "nameserver %s\n" % ns
		vfs.write_text(root, "/etc/resolv.conf", text)
	if not vfs.is_dir(root, "/etc/network"):
		return
	if network.is_empty() and vfs.exists(root, "/etc/network/interfaces"):
		return
	var text := AgoraDistro.INTERFACES_HEAD
	var first := true
	for dev: String in network:
		var cfg: Dictionary = network[dev]
		var method: String = cfg.get("method", "dhcp")
		text += "\n# The %s network interface\nauto %s\niface %s inet %s\n" % ["primary" if first else "secondary", dev, dev, method]
		first = false
		if method == "static":
			for key in ["address", "netmask", "gateway"]:
				if cfg.has(key):
					text += "\t%s %s\n" % [key, cfg[key]]
	vfs.write_text(root, "/etc/network/interfaces", text)


## Points /sbin/init at an init implementation: "systemd" or "sysvinit".
## Takes effect at the next boot.
static func set_init(vfs: AgoraVfs, which: String) -> void:
	var root := AgoraCred.root()
	vfs.unlink(root, AgoraMachine.INIT_PATH)
	vfs.symlink(root, AgoraPrograms.path_for(which), AgoraMachine.INIT_PATH)


## Brings a running machine up to date with this version of the OS: every
## package of its profile is installed, adding only files that are missing,
## so local edits (the player's, or an intruder's) survive. Machines saved
## before packages existed count as desktops.
static func upgrade(m: AgoraMachine) -> void:
	upgrade_vfs(m.vfs)


## [method upgrade] for a disk that isn't running, e.g. before power-on.
static func upgrade_vfs(vfs: AgoraVfs) -> void:
	var root := AgoraCred.root()
	if not vfs.exists(root, "/etc/os-release"):
		return
	var profile := "desktop"
	for line in vfs.read_text(root, "/etc/os-release").split("\n", false):
		if line.begins_with("VARIANT_ID="):
			profile = line.substr(11)
	if not AgoraDistro.PROFILES.has(profile):
		return
	var names := PackedStringArray(AgoraDistro.PROFILES[profile])
	for n: String in AgoraPackages.installed(vfs):
		if not names.has(n):
			names.append(n)
	for pkg in AgoraPackages.resolve(names, AgoraDistro.package):
		AgoraPackages.install(vfs, pkg, true)
	if not vfs.read_text(root, "/etc/os-release").contains("VARIANT_ID="):
		vfs.write_text(root, "/etc/os-release", "VARIANT_ID=%s\n" % profile, "/", true)
	if vfs.stat(root, AgoraMachine.INIT_PATH, "/", false) == null:
		set_init(vfs, "systemd")
	if vfs.stat(root, "/etc/systemd/system/default.target", "/", false) == null and vfs.exists(root, "/lib/systemd/system"):
		vfs.symlink(root, "/lib/systemd/system/graphical.target", "/etc/systemd/system/default.target")
