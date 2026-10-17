extends AgoraProgram


func summary() -> String:
	return "show or set the host name"


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		p.outln(p.machine.hostname)
		return 0
	if not p.cred.is_root():
		return p.fail("you must be root to change the host name")
	p.write_text("/etc/hostname", p.argv[1] + "\n")
	return 0
