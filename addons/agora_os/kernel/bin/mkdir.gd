extends AgoraProgram


func summary() -> String:
	return "make directories"


func usage() -> String:
	return "usage: mkdir [-p] [-m mode] dir...\n  -p  create parents as needed, no error if it exists\n  -m  set permissions (octal)"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "m")
	if not a.error.is_empty() or a.operands.is_empty():
		return p.fail(a.error if not a.error.is_empty() else "missing operand", 2)
	var mode := AgoraStat.MODE_DIR
	if a.has("m"):
		mode = AgoraStat.parse_octal(a.value("m"))
		if mode < 0:
			return p.fail("invalid mode '%s'" % a.value("m"))
	var status := 0
	for d in a.operands:
		var e := p.make_dirs(d, mode) if a.has("p") else p.mkdir(d, mode)
		if e != AgoraErrno.OK:
			status = p.fail("cannot create directory '%s': %s" % [d, AgoraErrno.describe(e)])
		elif a.has("m"):
			p.chmod(d, mode)
	return status
