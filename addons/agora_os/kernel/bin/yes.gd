extends AgoraProgram


func summary() -> String:
	return "print a string forever"


func main(p: AgoraProcess) -> int:
	var text := " ".join(p.argv.slice(1)) if p.argv.size() > 1 else "y"
	while p.outln(text):
		await p.tick()
	return 0
