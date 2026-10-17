extends AgoraProgram
## The text-mode installer of the install CD. getty starts it on every
## console. It asks a few questions, formats the chosen disk, installs the
## packages of a profile from /repo, configures the system, ejects the CD
## and reboots into the new system.

var p: AgoraProcess


func summary() -> String:
	return "install AgoraOS to a disk"


func main(proc: AgoraProcess) -> int:
	p = proc
	if not p.cred.is_root():
		return p.fail("must be run as root", 1)
	var hw := p.machine.hardware
	p.out("\u001b[2J\u001b[H")
	p.outln("=== AgoraOS %s installer ===\n" % AgoraDistro.VERSION)
	var targets: Array[AgoraDisk] = []
	for d in hw.disks:
		if not d.removable and not d.read_only:
			targets.append(d)
	if targets.is_empty():
		p.outln("No disk to install to was found. Press Enter to retry.")
		await p.read_line()
		return 1

	p.outln("Disks:")
	for i in targets.size():
		var d := targets[i]
		p.outln("  %d) /dev/%-9s %-20s %6s  %s" % [i + 1, hw.device_name(d), d.model, d.size_text(), "has a file system" if d.is_formatted() else "empty"])
	var disk: AgoraDisk = targets[await _choose("Install to which disk", targets.size())]

	var profiles := PackedStringArray(AgoraDistro.PROFILE_INFO.keys())
	p.outln("\nProfiles:")
	for i in profiles.size():
		p.outln("  %d) %-8s %s" % [i + 1, profiles[i], AgoraDistro.PROFILE_INFO[profiles[i]]])
	var default_profile := profiles.find("router") + 1 if hw.template == "router" else 1
	var profile := profiles[await _choose("Profile", profiles.size(), default_profile)]

	var hostname := await _ask("\nHost name", "router" if profile == "router" else "agora")
	var root_password := await _new_password("root")
	var opts := {"profile": profile, "root_password": root_password, "users": []}
	if profile != "router":
		var user := await _ask("Create a user account (empty to skip)", "")
		if not user.is_empty():
			opts.users.append({"name": user, "password": await _new_password(user), "groups": ["sudo"]})
		opts["init"] = await _ask("Init system (systemd or sysvinit)", "systemd")
		if opts.init not in ["systemd", "sysvinit"]:
			opts.init = "systemd"

	var device := "/dev/" + hw.device_name(disk)
	p.outln("\nAbout to erase %s and install the %s profile as '%s'." % [device, profile, hostname])
	if (await _ask("Continue? (y/n)", "n")).to_lower() != "y":
		p.outln("Cancelled.")
		return 1

	if await p.run(PackedStringArray(["mkfs", device])) != 0:
		return p.fail("formatting failed", 1)
	var vfs := AgoraInstaller.target_vfs(disk, p.machine.clock)
	var fetch := func(name: String) -> Dictionary: return AgoraPackages.from_json(p.read_text("/repo/%s.pkg" % name))
	for pkg in AgoraInstaller.plan(opts, fetch):
		p.outln("  installing %-16s %s" % [pkg.name, pkg.version])
		AgoraPackages.install(vfs, pkg)
		await p.tick()
	p.outln("  configuring the system")
	AgoraInstaller.configure(vfs, hostname, opts)
	p.outln("\nInstallation complete.")
	if p.machine.root_disk.removable:
		p.outln("Ejecting the installation media.")
		hw.eject(p.machine.root_disk)
	var answer := (await _ask("Reboot now? (y/n)", "y")).to_lower()
	await p.run(PackedStringArray(["reboot" if answer != "n" else "poweroff"]))
	return 0


func _ask(question: String, default: String) -> String:
	p.out("%s [%s]: " % [question, default] if not default.is_empty() else "%s: " % question)
	var line: Variant = await p.read_line()
	if line == null:
		return default
	var text := (line as String).strip_edges()
	return text if not text.is_empty() else default


## Returns a 0-based index.
func _choose(question: String, count: int, default: int = 1) -> int:
	while true:
		var answer := await _ask(question, str(default))
		if answer.is_valid_int() and int(answer) >= 1 and int(answer) <= count:
			return int(answer) - 1
		p.outln("Please enter a number from 1 to %d." % count)
	return 0


func _new_password(user: String) -> String:
	while true:
		var first: Variant = await read_secret(p, "Password for %s: " % user)
		if first == null:
			return "" # the console went away
		var second: Variant = await read_secret(p, "Again: ")
		if first == second:
			if (first as String).is_empty():
				p.outln("(no password set)")
			return first if first != null else ""
		p.outln("Passwords don't match, try again.")
	return ""
