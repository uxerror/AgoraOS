extends AgoraProgram


func summary() -> String:
	return "print the kernel ring buffer"


func main(p: AgoraProcess) -> int:
	var text := p.read_text("/proc/kmsg")
	if p.errno != AgoraErrno.OK:
		return p.fail_path("/proc/kmsg")
	p.out(text)
	return 0
