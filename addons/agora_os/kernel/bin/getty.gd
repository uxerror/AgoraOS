extends AgoraProgram
## Shows a login prompt on a terminal (tty1 on the monitor, ttyS0 on the
## serial port) and starts login for whoever types a name.
## -n -l PROGRAM runs PROGRAM right away instead (the install CD uses it).

var p: AgoraProcess


func summary() -> String:
	return "open a terminal and ask for a login name"


func usage() -> String:
	return "usage: getty [-n -l PROGRAM] TTY"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "l")
	if a.operands.is_empty():
		return p.fail(usage(), 1)
	var tty := p.machine.get_tty(a.operands[0])
	if tty == null:
		return p.fail("/dev/%s: No such device" % a.operands[0].trim_prefix("/dev/"), 1)
	while p.is_running():
		var argv: PackedStringArray
		if a.has("n") and a.has("l"):
			argv = PackedStringArray([a.value("l")])
		else:
			tty.output.write("\n" + _issue(tty) + "\n%s login: " % p.machine.hostname)
			var name: Variant = await tty.input.read_line(p.is_dead)
			if name == null or not p.is_running():
				if p.is_running():
					await p.sleep(0.2)
				continue
			if (name as String).strip_edges().is_empty():
				continue
			argv = PackedStringArray(["/bin/login", (name as String).strip_edges()])
		var child := p.machine.spawn(argv, {
			"stdin": tty.input, "stdout": tty.output, "stderr": tty.output, "tty": tty,
			"env": {"PATH": AgoraMachine.DEFAULT_PATH, "TERM": "agora"}, "parent": p,
		})
		if child == null:
			return p.fail("%s: %s" % [argv[0], AgoraErrno.describe(p.machine.errno)], 1)
		tty.foreground.assign([child])
		await child.wait()
		tty.output.write("\u001b[2J\u001b[H")
	return 0


func _issue(tty: AgoraTty) -> String:
	return p.read_text("/etc/issue").strip_edges().replace("\\n", p.machine.hostname).replace("\\l", tty.name)
