extends AgoraProgram


func summary() -> String:
	return "print the current directory"


func main(p: AgoraProcess) -> int:
	p.outln(p.cwd)
	return 0
