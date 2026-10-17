extends AgoraProgram


func summary() -> String:
	return "remove empty directories"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if a.operands.is_empty():
		return p.fail("missing operand", 2)
	var status := 0
	for d in a.operands:
		if p.rmdir(d) != AgoraErrno.OK:
			status = p.fail("failed to remove '%s': %s" % [d, AgoraErrno.describe(p.errno)])
	return status
