extends AgoraProgram
## Installed setuid root, so it can write /etc/shadow.


func summary() -> String:
	return "change a user's password"


func usage() -> String:
	return "usage: passwd [user]"


func main(p: AgoraProcess) -> int:
	var users := p.machine.users
	var caller := users.name_of(p.cred.ruid)
	var target := p.argv[1] if p.argv.size() > 1 else caller
	if users.find(target).is_empty():
		return p.fail("user '%s' does not exist" % target)
	if p.cred.ruid != 0:
		if target != caller:
			return p.fail("You may not view or modify password information for %s." % target)
		var old: Variant = await read_secret(p, "Current password: ")
		if old == null or not users.check_password(caller, old):
			p.machine.log_event("auth.log", "passwd", "authentication failure for %s" % caller)
			return p.fail("Authentication token manipulation error")
	var first: Variant = await read_secret(p, "New password: ")
	var second: Variant = await read_secret(p, "Retype new password: ")
	if first == null or first != second:
		return p.fail("Sorry, passwords do not match.")
	users.set_password(target, first)
	p.machine.log_event("auth.log", "passwd", "password changed for %s" % target)
	p.outln("passwd: password updated successfully")
	return 0
