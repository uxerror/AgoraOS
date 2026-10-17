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
			conn.nodelay = true # OpenSSH sets TCP_NODELAY on sessions
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
	AgoraSshChannel.request(conn, {"exit-status": code})
	conn.close()


func _env(conn: AgoraTcp.Conn, user: String) -> Dictionary:
	var u := p.machine.users.find(user)
	var remote := "%s %d" % [AgoraInet.to_str(conn.remote_addr), conn.remote_port]
	return {
		"HOME": u.home, "USER": user, "LOGNAME": user, "SHELL": u.shell, "PATH": AgoraMachine.DEFAULT_PATH,
		"SSH_CLIENT": "%s %d" % [remote, conn.local_port],
		"SSH_CONNECTION": "%s %s %d" % [remote, AgoraInet.to_str(conn.local_addr), conn.local_port],
	}


## Output of a stream, framed for the channel as it arrives.
func _forward(stream: AgoraStream, conn: AgoraTcp.Conn, stderr: bool) -> Callable:
	var send := func() -> void: AgoraSshChannel.data(conn, stream.read_available(), stderr)
	stream.changed.connect(send)
	return send


func _exec(conn: AgoraTcp.Conn, user: String, command: String) -> int:
	var u := p.machine.users.find(user)
	var cred := p.machine.users.cred_for(user)
	var stdin := AgoraStream.new()
	stdin.add_writer()
	var stdout := AgoraStream.new()
	stdout.add_reader()
	var stderr := AgoraStream.new()
	stderr.add_reader()
	var out_cb := _forward(stdout, conn, false)
	var err_cb := _forward(stderr, conn, true)
	var child := p.machine.spawn(PackedStringArray([u.shell, "-c", command]), {
		"cred": cred, "env": _env(conn, user),
		"cwd": u.home if p.machine.vfs.is_dir(cred, u.home) else "/",
		"stdin": stdin, "stdout": stdout, "stderr": stderr, "parent": p, "new_session": true,
	})
	if child == null:
		stdout.changed.disconnect(out_cb)
		stderr.changed.disconnect(err_cb)
		return 127
	_client_input(conn, child, func(text: String) -> void: stdin.write(text), func() -> void: stdin.release_writer(), Callable())
	var code := await child.wait()
	stdout.changed.disconnect(out_cb)
	stderr.changed.disconnect(err_cb)
	AgoraSshChannel.data(conn, stdout.read_available())
	AgoraSshChannel.data(conn, stderr.read_available(), true)
	return code


func _shell(conn: AgoraTcp.Conn, user: String) -> int:
	var pty := AgoraTty.new(p.machine.alloc_pty())
	var screen := func(text: String) -> void: AgoraSshChannel.data(conn, text)
	var pty_ref := weakref(pty) # the handler lives in pty; it must not hold it
	var modes := func() -> void:
		var t := pty_ref.get_ref() as AgoraTty
		if t:
			AgoraSshChannel.request(conn, {"echo": t.echo})
	pty.printed.connect(screen)
	pty.mode_changed.connect(modes)
	var shell := p.machine.login(user, pty, p)
	if shell == null:
		return 255
	for key: String in ["SSH_CLIENT", "SSH_CONNECTION"]:
		shell.env[key] = _env(conn, user)[key]
	_client_input(conn, shell, func(text: String) -> void: pty.input.write(text), func() -> void: pty.send_eof(),
		func() -> void: pty.interrupt())
	var code := await shell.wait()
	pty.printed.disconnect(screen)
	pty.mode_changed.disconnect(modes)
	return code


## Messages from the client: typed text, Ctrl+C, Ctrl+D. A lost
## connection hangs up the session.
func _client_input(conn: AgoraTcp.Conn, proc: AgoraProcess, write: Callable, eof: Callable, interrupt: Callable) -> void:
	while proc.is_running():
		var msg: Array = await AgoraSshChannel.receive(conn, func() -> bool: return proc.is_dead())
		if msg.is_empty():
			if proc.is_running():
				if interrupt.is_valid() and proc.tty:
					proc.tty.hang_up()
				else:
					eof.call()
			return
		match msg[0]:
			"D":
				write.call(msg[1])
			"C":
				var req: Dictionary = msg[1]
				if req.get("eof", false):
					eof.call()
				elif int(req.get("signal", 0)) == AgoraProcess.SIGINT:
					if interrupt.is_valid():
						interrupt.call()
					else:
						proc.send_signal(AgoraProcess.SIGINT)
