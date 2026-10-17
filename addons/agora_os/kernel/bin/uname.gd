extends AgoraProgram


func summary() -> String:
	return "print system information"


func usage() -> String:
	return "usage: uname [-asnrm]"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var parts: PackedStringArray = []
	var all := a.has("a")
	if all or a.has("s") or a.flags.is_empty():
		parts.append(AgoraMachine.KERNEL_NAME)
	if all or a.has("n"):
		parts.append(p.machine.hostname)
	if all or a.has("r"):
		parts.append(AgoraMachine.KERNEL_VERSION)
	if all or a.has("m"):
		parts.append("agx86")
	p.outln(" ".join(parts))
	return 0
