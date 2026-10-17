extends AgoraProgram


func summary() -> String:
	return "clear the terminal screen"


func main(p: AgoraProcess) -> int:
	# ANSI "erase screen" + "cursor home". Terminal front ends interpret it.
	p.out("\u001b[2J\u001b[H")
	return 0
