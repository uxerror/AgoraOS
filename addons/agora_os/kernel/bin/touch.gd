extends AgoraProgram


func summary() -> String:
	return "create empty files or update timestamps"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if a.operands.is_empty():
		return p.fail("missing file operand", 2)
	var status := 0
	for f in a.operands:
		if p.exists(f):
			if p.touch_time(f) != AgoraErrno.OK:
				status = p.fail("cannot touch '%s': %s" % [f, AgoraErrno.describe(p.errno)])
		elif p.write_text(f, "") != AgoraErrno.OK:
			status = p.fail("cannot touch '%s': %s" % [f, AgoraErrno.describe(p.errno)])
	return status
