extends AgoraProgram
## Installed setuid root. Members of the "sudo" group may run commands as
## root after entering their own password.


func summary() -> String:
	return "run a command as root"


func usage() -> String:
	return "usage: sudo command [args...]"


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		return p.fail(usage(), 1)
	var users := p.machine.users
	var caller := users.name_of(p.cred.ruid)
	var command := " ".join(p.argv.slice(1))
	if p.cred.ruid != 0:
		var sudo_group := users.find_group("sudo")
		if sudo_group.is_empty() or not users.group_ids_for(caller).has(sudo_group.gid):
			p.machine.log_event("auth.log", "sudo", "%s : user NOT in sudoers ; COMMAND=%s" % [caller, command])
			return p.fail("%s is not in the sudoers file. This incident will be reported." % caller)
		var password: Variant = await read_secret(p, "[sudo] password for %s: " % caller)
		if password == null or not users.check_password(caller, password):
			p.machine.log_event("auth.log", "sudo", "%s : authentication failure ; COMMAND=%s" % [caller, command])
			return p.fail("incorrect password")
	p.machine.log_event("auth.log", "sudo", "%s : COMMAND=%s" % [caller, command])
	var env := p.env.duplicate()
	env.merge({"USER": "root", "LOGNAME": "root", "SUDO_USER": caller}, true)
	var child := p.spawn(p.argv.slice(1), {"cred": AgoraCred.root(), "env": env})
	if child == null:
		return p.fail("%s: command not found" % p.argv[1], 127)
	if p.tty:
		p.tty.foreground.assign([child])
	return await child.wait()
