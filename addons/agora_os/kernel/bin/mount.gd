extends AgoraProgram


func summary() -> String:
	return "list mounted file systems"


func main(p: AgoraProcess) -> int:
	for line in lines_of(p.read_text("/proc/mounts")):
		var f := line.split(" ")
		p.outln("%s on %s type %s (%s)" % [f[0], f[1], f[0], f[2]])
	return 0
