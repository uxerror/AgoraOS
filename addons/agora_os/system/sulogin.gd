extends AgoraProgram
## Single-user login: asks for root's password on the console and starts a
## root shell for maintenance. Init runs it in single-user mode (runlevel S,
## systemd's rescue.target). Control-D boots on normally instead.


func summary() -> String:
	return "single-user login on the console"


func main(p: AgoraProcess) -> int:
	if not p.cred.is_root():
		return p.fail("only root can run sulogin", 1)
	var tty := p.machine.console_tty()
	if tty == null:
		return p.fail("cannot open console", 1)
	while p.is_running():
		tty.output.write("Give root password for maintenance\n(or type Control-D to continue): ")
		tty.echo = false
		var answer: Variant = await tty.input.read_line(p.is_dead)
		tty.echo = true
		tty.output.write("\n")
		if answer == null:
			return 0
		if not p.machine.users.check_password("root", str(answer).trim_suffix("\n")):
			tty.output.write("Login incorrect.\n")
			continue
		var root: Dictionary = p.machine.users.find("root")
		var shell: String = root.get("shell", "/bin/sh")
		var child := p.machine.spawn(PackedStringArray([shell]), {
			"stdin": tty.input, "stdout": tty.output, "stderr": tty.output, "tty": tty, "parent": p,
			"cwd": "/", "env": {"PATH": AgoraMachine.DEFAULT_PATH, "HOME": root.get("home", "/root"),
				"USER": "root", "LOGNAME": "root", "SHELL": shell, "TERM": "agora"},
			"start": false,
		})
		if child == null:
			return p.fail("%s: %s" % [shell, AgoraErrno.describe(p.machine.errno)], 1)
		child.argv[0] = "-" + AgoraPath.basename(shell)
		tty.foreground.assign([child])
		child.start()
		await child.wait()
		return 0
	return 0
