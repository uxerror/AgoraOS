extends AgoraProgram


func summary() -> String:
	return "copy stdin to stdout and files"


func usage() -> String:
	return "usage: tee [-a] [file...]"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var status := 0
	for f in a.operands:
		if p.write_text(f, "", a.has("a")) != AgoraErrno.OK:
			status = p.fail_path(f)
	while true:
		var line: Variant = await p.read_line()
		if line == null:
			break
		p.outln(line)
		for f in a.operands:
			p.write_text(f, line + "\n", true)
	return status
