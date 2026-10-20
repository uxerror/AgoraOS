extends AgoraProgram
## tty (coreutils): the name of the terminal on standard input, or "not a
## tty" (exit status 1). -s says nothing and only sets the status.


func summary() -> String:
	return "print the file name of the terminal connected to standard input"


func usage() -> String:
	return "usage: tty [-s]"


func main(p: AgoraProcess) -> int:
	var silent := p.argv.has("-s") or p.argv.has("--silent") or p.argv.has("--quiet")
	var on_tty := p.tty != null and p.stdin == p.tty.input
	if not silent:
		p.outln(("/dev/" + p.tty.name) if on_tty else "not a tty")
	return 0 if on_tty else 1
