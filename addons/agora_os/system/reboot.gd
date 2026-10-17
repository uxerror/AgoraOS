extends AgoraProgram
## reboot, halt, poweroff and shutdown in one program (by argv[0]). They ask
## whichever init is running, through /dev/initctl.


func summary() -> String:
	return "reboot or stop the system"


func usage() -> String:
	return "usage: reboot | halt | poweroff | shutdown [-r|-h|-H|-P] [now]"


func main(p: AgoraProcess) -> int:
	var name := AgoraPath.basename(p.argv[0])
	var verb := name
	if name == "shutdown":
		var a := AgoraArgs.parse(p.argv)
		verb = "reboot" if a.has("r") else "halt" if a.has("H") else "poweroff"
		var when := a.operands[0] if not a.operands.is_empty() else "now"
		if when not in ["now", "+0", "0"]:
			return p.fail("only immediate shutdown ('now') is supported")
	if not p.cred.is_root():
		return p.fail("must be superuser.")
	var reply: String = await AgoraInitCtl.send(p, verb)
	if AgoraInitCtl.is_error(reply):
		return p.fail(AgoraInitCtl.message(reply))
	if name == "shutdown":
		p.outln("\nBroadcast message from %s:\nThe system is going down for %s NOW!" % [p.user_name(), "reboot" if verb == "reboot" else "power off" if verb == "poweroff" else "halt"])
	return 0
