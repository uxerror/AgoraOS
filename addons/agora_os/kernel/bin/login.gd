extends AgoraProgram
## Asks for the password of a user on a terminal and starts their shell.
## getty passes the name it read; without one (telnetd), login asks for it
## and gives three tries. -h HOST names the remote host for the logs; -p
## keeps the environment (accepted, nothing to keep here).

const TRIES := 3


func summary() -> String:
	return "begin a session on a terminal"


func usage() -> String:
	return "usage: login [-p] [-h host] [username]"


func main(p: AgoraProcess) -> int:
	if not p.cred.is_root():
		return p.fail("must be run by root (getty)", 1)
	var a := AgoraArgs.parse(p.argv, "h")
	if p.tty == null:
		return p.fail(usage() + " (on a terminal)", 1)
	var remote: String = a.value("h") if a.has("h") else ""
	var users := p.machine.users
	var tag := "login[%d]" % p.pid
	var tries := 1 if not a.operands.is_empty() else TRIES
	for attempt in tries:
		var user := ""
		if not a.operands.is_empty():
			user = a.operands[0]
		else:
			p.tty.output.write("%s login: " % p.machine.hostname)
			var name: Variant = await p.read_line()
			if name == null:
				return 1
			user = (name as String).strip_edges()
			if user.is_empty():
				continue
		var password: Variant = await read_secret(p, "Password: ")
		if password == null:
			return 1
		if users.find(user).is_empty() or users.is_locked(user) or not users.check_password(user, password):
			if remote.is_empty():
				p.machine.log_event("auth", tag, "FAILED LOGIN FOR %s on %s" % [user, p.tty.name])
			else:
				p.machine.log_event("auth", tag, "FAILED LOGIN %d FROM %s FOR %s, Authentication failure" % [attempt + 1, remote, user])
			await p.sleep(2.0)
			p.outln("\nLogin incorrect")
			continue
		var where := p.tty.name + (" from " + remote if not remote.is_empty() else "")
		p.machine.log_event("auth", tag, "session opened for user %s on %s" % [user, where])
		var shell := p.machine.login(user, p.tty, p)
		if shell == null:
			return p.fail("cannot start a shell for %s" % user, 1)
		if not remote.is_empty():
			shell.env["REMOTEHOST"] = remote
		await shell.wait()
		p.machine.log_event("auth", tag, "session closed for user %s" % user)
		return 0
	return 1
