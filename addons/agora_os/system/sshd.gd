extends AgoraProgram
## SSH server (OpenSSH-style). Listens on TCP port 22 (Port in
## /etc/ssh/sshd_config), checks passwords itself, logs to auth.log, and
## runs the user's login shell on a pseudo-terminal whose screen and
## keyboard travel over the connection. "ssh host command" runs the
## command without a terminal.
##
## After the version banners the client sends "AUTH user password"
## (password base64-encoded), may ask for a pseudo-terminal ("PTY term
## cols rows", as pty-req), then "SHELL" or "EXEC command". A shell or a
## command with a terminal runs on a pty of that size; its modes (echo,
## raw), the window size, signals and the exit status go over the
## connection's control channel (see [AgoraSshChannel]).

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
	var term := {}
	if request != null and str(request).begins_with("PTY "):
		var w := str(request).split(" ", false)
		term = {"term": w[1] if w.size() > 1 else "vt100", "cols": int(w[2]) if w.size() > 2 else 80, "rows": int(w[3]) if w.size() > 3 else 24}
		request = await conn.input.read_line(abort)
	if request == null:
		conn.close()
		return
	_log("pam_unix(sshd:session): session opened for user %s by (uid=0)" % user)
	var code := 255
	var command := Marshalls.base64_to_utf8(str(request).substr(5)) if str(request).begins_with("EXEC ") else ""
	if term.is_empty():
		code = await _exec(conn, user, command)
	else:
		code = await _shell(conn, user, term, command)
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


## A command, or with an empty [param command] the shell, without a
## terminal: its output and stdin are plain streams.
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
	var argv := PackedStringArray([u.shell, "-c", command]) if not command.is_empty() else PackedStringArray([u.shell])
	var child := p.machine.spawn(argv, {
		"cred": cred, "env": _env(conn, user),
		"cwd": u.home if p.machine.vfs.is_dir(cred, u.home) else "/",
		"stdin": stdin, "stdout": stdout, "stderr": stderr, "parent": p, "new_session": true,
	})
	if child == null:
		stdout.changed.disconnect(out_cb)
		stderr.changed.disconnect(err_cb)
		return 127
	_client_input(conn, child, func(text: String) -> void: stdin.write(text), func() -> void: stdin.release_writer(), Callable(), null)
	var code := await child.wait()
	stdout.changed.disconnect(out_cb)
	stderr.changed.disconnect(err_cb)
	AgoraSshChannel.data(conn, stdout.read_available())
	AgoraSshChannel.data(conn, stderr.read_available(), true)
	return code


## The login shell, or [param command], on a pseudo-terminal of the size
## and type in [param term] ({term, cols, rows}).
func _shell(conn: AgoraTcp.Conn, user: String, term: Dictionary, command: String = "") -> int:
	var pty := AgoraTty.new(p.machine.alloc_pty())
	pty.cols = maxi(1, int(term.cols))
	pty.rows = maxi(1, int(term.rows))
	var screen := func(text: String) -> void: AgoraSshChannel.data(conn, text)
	var pty_ref := weakref(pty) # the handler lives in pty; it must not hold it
	var modes := func() -> void:
		var t := pty_ref.get_ref() as AgoraTty
		if t:
			AgoraSshChannel.request(conn, {"echo": t.echo, "raw": t.raw})
	pty.printed.connect(screen)
	pty.mode_changed.connect(modes)
	var env := _env(conn, user)
	var shell: AgoraProcess
	if command.is_empty():
		shell = p.machine.login(user, pty, p)
		if shell:
			for key: String in ["SSH_CLIENT", "SSH_CONNECTION"]:
				shell.env[key] = env[key]
	else:
		var u := p.machine.users.find(user)
		var cred := p.machine.users.cred_for(user)
		shell = p.machine.spawn(PackedStringArray([u.shell, "-c", command]), {
			"cred": cred, "env": env, "cwd": u.home if p.machine.vfs.is_dir(cred, u.home) else "/",
			"stdin": pty.input, "stdout": pty.output, "stderr": pty.output, "tty": pty,
			"parent": p, "new_session": true, "start": false,
		})
		if shell:
			pty.foreground.assign([shell])
			shell.start()
	if shell == null:
		pty.printed.disconnect(screen)
		pty.mode_changed.disconnect(modes)
		return 255
	shell.env["TERM"] = str(term.term)
	_client_input(conn, shell, func(text: String) -> void: pty.input.write(text), func() -> void: pty.send_eof(),
		func() -> void: pty.interrupt(), pty)
	var code := await shell.wait()
	pty.printed.disconnect(screen)
	pty.mode_changed.disconnect(modes)
	return code


## Messages from the client: typed text, Ctrl+C, Ctrl+D. A lost
## connection hangs up the session.
func _client_input(conn: AgoraTcp.Conn, proc: AgoraProcess, write: Callable, eof: Callable, interrupt: Callable, pty: AgoraTty) -> void:
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
				elif req.has("window-change") and pty and (req["window-change"] as Array).size() == 2:
					pty.cols = maxi(1, int(req["window-change"][0]))
					pty.rows = maxi(1, int(req["window-change"][1]))
				elif int(req.get("signal", 0)) == AgoraProcess.SIGINT:
					if interrupt.is_valid():
						interrupt.call()
					else:
						proc.send_signal(AgoraProcess.SIGINT)
