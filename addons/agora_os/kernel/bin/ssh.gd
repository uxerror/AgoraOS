extends AgoraProgram
## Logs into another machine on the network. The remote shell runs on the
## remote machine (its files, users, processes) but talks to this terminal.


func summary() -> String:
	return "log into a remote machine"


func usage() -> String:
	return "usage: ssh [user@]host"


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		return p.fail(usage(), 255)
	if p.tty == null:
		return p.fail("a terminal is required", 255)
	var dest := p.argv[1]
	var user := p.user_name()
	var host := dest
	if dest.contains("@"):
		user = dest.get_slice("@", 0)
		host = dest.get_slice("@", 1)
	var net := p.machine.network
	var remote := net.get_machine(host) if net else null
	if remote == null:
		return p.fail("Could not resolve hostname %s: Name or service not known" % host, 255)
	await p.sleep(net.latency_ms(p.machine, remote) / 1000.0)
	var tag := "sshd"
	var from := p.machine.ip
	var users := remote.users
	for attempt in 3:
		var password: Variant = await read_secret(p, "%s@%s's password: " % [user, host])
		if password == null or p.is_dead():
			return 255
		if not users.find(user).is_empty() and not users.is_locked(user) and users.check_password(user, password):
			remote.log_event("auth.log", tag, "Accepted password for %s from %s" % [user, from])
			var shell := remote.login(user, p.tty)
			if shell == null:
				return p.fail("remote shell failed to start", 255)
			var code := await shell.wait()
			p.outln("Connection to %s closed." % host)
			return code
		remote.log_event("auth.log", tag, "Failed password for %s from %s" % [user, from])
		await p.sleep(1.0)
		p.errln("Permission denied, please try again.")
	return p.fail("%s@%s: Permission denied (password)." % [user, host], 255)
