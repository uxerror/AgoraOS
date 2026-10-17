extends AgoraProgram
## SSH server. Listens on port 22 while it runs; ssh clients on other
## machines are refused unless it does. Settings: /etc/ssh/sshd_config.


func summary() -> String:
	return "OpenSSH-style server daemon"


func usage() -> String:
	return "usage: sshd [-D]\n  -D  don't detach (always the case here)"


func main(p: AgoraProcess) -> int:
	var port := int(_config(p, "Port", "22"))
	var e := p.machine.listen(port, p, "sshd")
	if e != AgoraErrno.OK:
		var msg := "Bind to port %d on 0.0.0.0 failed: %s." % [port, AgoraErrno.describe(e)]
		p.machine.log_event("auth", "sshd[%d]" % p.pid, msg)
		return p.fail(msg, 255)
	var msg := "Server listening on 0.0.0.0 port %d." % port
	p.machine.log_event("auth", "sshd[%d]" % p.pid, msg)
	p.outln(msg)
	while p.is_running():
		await p.sleep(3600.0)
	return 0


## Value of [param key] in /etc/ssh/sshd_config ("Key value" lines).
static func _config(p: AgoraProcess, key: String, default: String) -> String:
	for line in p.read_text("/etc/ssh/sshd_config").split("\n", false):
		var words := line.strip_edges().split(" ", false)
		if words.size() >= 2 and words[0] == key:
			return words[1]
	return default
