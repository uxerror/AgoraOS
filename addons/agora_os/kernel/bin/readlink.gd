extends AgoraProgram


func summary() -> String:
	return "print where a symbolic link points"


func usage() -> String:
	return "usage: readlink [-f] path...\n  -f  print the full resolved path"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var status := 0
	for path in a.operands:
		var out := p.realpath(path) if a.has("f") else p.read_link(path)
		if p.errno != AgoraErrno.OK:
			status = 1
			continue
		p.outln(out)
	return status
