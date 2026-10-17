extends AgoraProgram


func summary() -> String:
	return "print the effective user name"


func main(p: AgoraProcess) -> int:
	p.outln(p.user_name())
	return 0
