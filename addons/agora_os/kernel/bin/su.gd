extends AgoraProgram
## Installed setuid root. Checks the target user's password unless the
## caller (the real uid) is already root.


func summary() -> String:
	return "run a shell as another user"


func usage() -> String:
	return "usage: su [-] [user]\nDefaults to root. '-' starts a login shell in the user's home."


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	var login := false
	if not args.is_empty() and args[0] in ["-", "-l", "--login"]:
		login = true
		args.remove_at(0)
	var target := args[0] if not args.is_empty() else "root"
	var users := p.machine.users
	var u := users.find(target)
	if u.is_empty():
		return p.fail("user %s does not exist" % target)
	var caller := users.name_of(p.cred.ruid)
	if p.cred.ruid != 0:
		var password: Variant = await read_secret(p, "Password: ")
		if password == null or not users.check_password(target, password):
			await p.sleep(1.0)
			p.machine.log_event("auth.log", "su[%d]" % p.pid, "FAILED su for %s by %s" % [target, caller])
			return p.fail("Authentication failure")
	p.machine.log_event("auth.log", "su[%d]" % p.pid, "Successful su for %s by %s" % [target, caller])
	var env := p.env.duplicate()
	env.merge({"HOME": u.home, "USER": u.name, "LOGNAME": u.name, "SHELL": u.shell}, true)
	var cwd := p.cwd
	var argv := PackedStringArray([u.shell])
	if login:
		env = {"HOME": u.home, "USER": u.name, "LOGNAME": u.name, "SHELL": u.shell,
			"PATH": AgoraMachine.DEFAULT_PATH, "TERM": p.getenv("TERM", "agora")}
		cwd = u.home
		argv.append("-l")
	var shell := p.spawn(argv, {"cred": users.cred_for(target), "env": env, "cwd": cwd})
	if shell == null:
		return p.fail("cannot run %s: %s" % [u.shell, AgoraErrno.describe(p.errno)])
	if p.tty:
		p.tty.foreground.assign([shell])
	return await shell.wait()
