extends AgoraProgram


func summary() -> String:
	return "locate a command in PATH"


func main(p: AgoraProcess) -> int:
	var status := 0
	for name in p.argv.slice(1):
		var found := p.machine.find_executable(name, p.getenv("PATH", AgoraMachine.DEFAULT_PATH), p.cred, p.cwd)
		if found.is_empty():
			status = 1
		else:
			p.outln(found)
	return status
