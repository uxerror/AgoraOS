extends AgoraProgram


func summary() -> String:
	return "print the previous and current runlevel"


func main(p: AgoraProcess) -> int:
	var text := p.read_text("/run/runlevel").strip_edges()
	if text.is_empty():
		p.outln("unknown")
		return 1
	p.outln(text)
	return 0
