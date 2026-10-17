extends AgoraProgram
## Asks for the password of a user on a terminal and starts their shell.


func summary() -> String:
	return "begin a session on a terminal"


func main(p: AgoraProcess) -> int:
	if not p.cred.is_root():
		return p.fail("must be run by root (getty)", 1)
	if p.tty == null or p.argv.size() < 2:
		return p.fail("usage: login USER (on a terminal)", 1)
	var user := p.argv[1]
	var users := p.machine.users
	var password: Variant = await read_secret(p, "Password: ")
	if password == null:
		return 1
	if users.find(user).is_empty() or users.is_locked(user) or not users.check_password(user, password):
		p.machine.log_event("auth", "login[%d]" % p.pid, "FAILED LOGIN FOR %s on %s" % [user, p.tty.name])
		await p.sleep(2.0)
		p.outln("\nLogin incorrect")
		return 1
	p.machine.log_event("auth", "login[%d]" % p.pid, "session opened for user %s on %s" % [user, p.tty.name])
	var shell := p.machine.login(user, p.tty, p)
	if shell == null:
		return p.fail("cannot start a shell for %s" % user, 1)
	await shell.wait()
	p.machine.log_event("auth", "login[%d]" % p.pid, "session closed for user %s" % user)
	return 0
