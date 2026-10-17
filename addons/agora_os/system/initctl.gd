class_name AgoraInitCtl
extends RefCounted
## Client side of the init control channel, /dev/initctl.
##
## Whatever runs as pid 1 creates that device (mode 0600, so only root can
## use it). A request is one line written to it; the reply is read back.
## Every init understands "poweroff", "reboot" and "halt". sysvinit also
## takes "runlevel N"; systemd also takes "start UNIT", "stop UNIT", etc.

const DEVICE := "/dev/initctl"


## Sends [param command] and returns the reply ("ok", "error: ...").
static func send(p: AgoraProcess, command: String) -> String:
	if p.stat(DEVICE) == null:
		return "error: %s: init does not accept requests" % DEVICE
	if p.write_text(DEVICE, command + "\n") != AgoraErrno.OK:
		return "error: " + ("Access denied" if p.errno == AgoraErrno.EACCES else AgoraErrno.describe(p.errno))
	return p.read_text(DEVICE).strip_edges()


static func is_error(reply: String) -> bool:
	return reply.begins_with("error")


static func message(reply: String) -> String:
	return reply.trim_prefix("error:").strip_edges()
