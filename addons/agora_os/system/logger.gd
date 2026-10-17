extends AgoraProgram


func summary() -> String:
	return "write a message to the system log"


func usage() -> String:
	return "usage: logger [-t tag] [-p facility.level] [message...]\nWithout a message, logs each line of stdin."


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "tp")
	if not a.error.is_empty():
		return p.fail(a.error, 1)
	var tag := a.value("t", p.user_name())
	var facility := a.value("p", "user.notice").get_slice(".", 0)
	if not a.operands.is_empty():
		p.machine.log_event(facility, tag, " ".join(a.operands))
		return 0
	while true:
		var line: Variant = await p.read_line()
		if line == null:
			break
		p.machine.log_event(facility, tag, line)
	return 0
