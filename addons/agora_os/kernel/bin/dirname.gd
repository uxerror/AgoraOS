extends AgoraProgram


func summary() -> String:
	return "strip the last component from a path"


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		return p.fail("missing operand", 2)
	p.outln(AgoraPath.dirname(p.argv[1]))
	return 0
