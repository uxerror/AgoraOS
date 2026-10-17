extends AgoraProgram
## SSH server (OpenSSH-style). Listens on TCP port 22 (Port in
## /etc/ssh/sshd_config), checks passwords itself, logs to auth.log, and
## runs the user's login shell on a pseudo-terminal whose screen and
## keyboard travel over the connection. "ssh host command" runs the
## command without a terminal.
##
## After the version banners the client sends "AUTH user password"
## (password base64-encoded), then "SHELL" or "EXEC command". Terminal
## modes, signals and the exit status go over the connection's control
## channel.

const BANNER := "SSH-2.0-OpenSSH_4.3p2 Debian-9"

var p: AgoraProcess


func summary() -> String:
	return "OpenSSH-style server daemon"


func usage() -> String:
	return "usage: sshd [-D]\n  -D  don't detach (always the case here)"


func main(proc: AgoraProcess) -> int:
	p = proc
	var port := int(_config(p, "Port", "22"))
	var listener := p.machine.net.tcp.listen(p, port)
	if listener == null:
		var err := p.machine.net.tcp.last_error
		_log("error: Bind to port %d on 0.0.0.0 failed: %s." % [port, AgoraErrno.describe(err)])
		_log("fatal: Cannot bind any address.")
		p.errln("error: Bind to port %d on 0.0.0.0 failed: %s." % [port, AgoraErrno.describe(err)])
		return p.fail("fatal: Cannot bind any address.", 255)
	var msg := "Server listening on 0.0.0.0 port %d." % port
	_log(msg)
	p.outln(msg)
	while p.is_running():
		var conn: AgoraTcp.Conn = await listener.accept(p.is_dead)
		if conn:
			_session(conn)
	listener.close()
	return 0


func _log(message: String) -> void:
	p.machine.log_event("auth", "sshd[%d]" % p.pid, message)


## Value of [param key] in /etc/ssh/sshd_config ("Key value" lines).
static func _config(proc: AgoraProcess, key: String, default: String) -> String:
	for line in proc.read_text("/etc/ssh/sshd_config").split("\n", false):
		var words := line.strip_edges().split(" ", false)
		if words.size() >= 2 and words[0] == key:
			return words[1]
	return default


func _session(conn: AgoraTcp.Conn) -> void:
	var from := "%s port %d" % [AgoraInet.to_str(conn.remote_addr), conn.remote_port]
	var abort := func() -> bool: return p.is_dead() or not conn.is_open()
	conn.output.write(BANNER + "\n")
	var hello: Variant = await conn.input.read_line(abort)
	if hello == null or not str(hello).begins_with("SSH-"):
		_log("Did not receive identification string from %s" % AgoraInet.to_str(conn.remote_addr))
		conn.close()
		return
	var users := p.machine.users
	var root_allowed := _config(p, "PermitRootLogin", "yes") != "no"
	var max_tries := int(_config(p, "MaxAuthTries", "6"))
	var tries := 0
	var user := ""
	while true:
		var line: Variant = await conn.input.read_line(abort)
		if line == null:
			_log("Connection closed by %s [preauth]" % AgoraInet.to_str(conn.remote_addr))
			conn.close()
			return
		var words := str(line).split(" ")
		if words.size() < 3 or words[0] != "AUTH":
			continue
		user = words[1]
		var password := Marshalls.base64_to_utf8(words[2])
		var known := not users.find(user).is_empty()
		var allowed: bool = root_allowed or users.find(user).get("uid", -1) != 0
		if known and allowed and not users.is_locked(user) and users.check_password(user, password):
			_log("Accepted password for %s from %s ssh2" % [user, from])
			conn.output.write("AUTH-OK\n")
			break
		_log(("Failed password for %s from %s ssh2" if known else "Failed password for invalid user %s from %s ssh2") % [user, from])
		tries += 1
		if tries >= max_tries:
			_log("Disconnecting: Too many authentication failures for %s [preauth]" % user)
			conn.close()
			return
		conn.output.write("AUTH-FAIL\n")
	var request: Variant = await conn.input.read_line(abort)
	if request == null:
		conn.close()
		return
	_log("pam_unix(sshd:session): session opened for user %s by (uid=0)" % user)
	var code := 255
	if str(request).begins_with("EXEC "):
		code = await _exec(conn, user, Marshalls.base64_to_utf8(str(request).substr(5)))
	else:
		code = await _shell(conn, user)
	_log("pam_unix(sshd:session): session closed for user %s" % user)
	conn.send_control({"exit-status": code})
	conn.close()


func _env(conn: AgoraTcp.Conn, user: String) -> Dictionary:
	var u := p.machine.users.find(user)
	var remote := "%s %d" % [AgoraInet.to_str(conn.remote_addr), conn.remote_port]
	return {
		"HOME": u.home, "USER": user, "LOGNAME": user, "SHELL": u.shell, "PATH": AgoraMachine.DEFAULT_PATH,
		"SSH_CLIENT": "%s %d" % [remote, conn.local_port],
		"SSH_CONNECTION": "%s %s %d" % [remote, AgoraInet.to_str(conn.local_addr), conn.local_port],
	}


func _exec(conn: AgoraTcp.Conn, user: String, command: String) -> int:
	var u := p.machine.users.find(user)
	var child := p.machine.spawn(PackedStringArray([u.shell, "-c", command]), {
		"cred": p.machine.users.cred_for(user), "env": _env(conn, user),
		"cwd": u.home if p.machine.vfs.is_dir(p.machine.users.cred_for(user), u.home) else "/",
		"stdin": conn.input, "stdout": conn.output, "stderr": conn.output, "parent": p, "new_session": true,
	})
	if child == null:
		return 127
	return await child.wait()


func _shell(conn: AgoraTcp.Conn, user: String) -> int:
	var pty := AgoraTty.new(p.machine.alloc_pty())
	var screen := func(text: String) -> void:
		if conn.is_open():
			conn.output.write(text)
	var modes := func() -> void: conn.send_control({"echo": pty.echo})
	pty.printed.connect(screen)
	pty.mode_changed.connect(modes)
	conn.control.connect(func(msg: Dictionary) -> void:
		if msg.get("signal") == AgoraProcess.SIGINT:
			pty.interrupt()
		elif msg.get("eof", false):
			pty.send_eof())
	var shell := p.machine.login(user, pty, p)
	if shell == null:
		return 255
	for key: String in ["SSH_CLIENT", "SSH_CONNECTION"]:
		shell.env[key] = _env(conn, user)[key]
	_keyboard(conn, pty, shell)
	var code := await shell.wait()
	pty.printed.disconnect(screen)
	pty.mode_changed.disconnect(modes)
	return code


## Typed lines from the client go to the terminal; a lost connection hangs
## it up.
func _keyboard(conn: AgoraTcp.Conn, pty: AgoraTty, shell: AgoraProcess) -> void:
	while shell.is_running():
		var line: Variant = await conn.input.read_line(func() -> bool: return shell.is_dead())
		if line == null:
			if shell.is_running():
				pty.hang_up()
			return
		pty.type_line(line)
