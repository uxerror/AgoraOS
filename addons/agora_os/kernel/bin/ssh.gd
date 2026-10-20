extends AgoraProgram
## OpenSSH-style client. Connects over TCP (so routes, firewalls and NAT
## matter), asks for the password, then connects this terminal to a login
## shell on the remote machine, or runs a command there.
##
## A shell gets a pseudo-terminal on the remote side of this terminal's
## type and size; a command gets one with -t (-tt even when stdin is not a
## terminal), and -T asks for none. When the remote terminal goes raw (a
## full-screen program), this one does too and every key goes over as it
## is typed; a new window size follows.

const BANNER := "SSH-2.0-OpenSSH_4.3p2 Debian-9"

var _status := -1
var _done := false
## The remote terminal's mode, mirrored on this one.
var _raw := false
var _send_size := Callable()


func summary() -> String:
	return "log into a remote machine"


func usage() -> String:
	return "usage: ssh [-tT] [-p port] [-l login_name] [user@]hostname [command]"


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	var port := 22
	var user := p.user_name()
	var want_tty := 0 # -t counts up, -T is -1
	# Options may come before or after the host name, not in the command.
	var rest: PackedStringArray = []
	var i := 0
	while i < args.size():
		var a := args[i]
		var in_command := rest.size() > 1
		if not in_command and a in ["-p", "-l", "-o"]:
			if i + 1 >= args.size():
				return p.fail(usage(), 255)
			if a == "-p":
				port = int(args[i + 1])
			elif a == "-l":
				user = args[i + 1]
			i += 2
			continue
		if not in_command and a.begins_with("-") and a.length() > 1:
			for flag in a.substr(1):
				if flag == "t":
					want_tty = maxi(want_tty, 0) + 1
				elif flag == "T":
					want_tty = -1
			i += 1 # other options are accepted and ignored
			continue
		rest.append(a)
		i += 1
	if rest.is_empty():
		p.errln(usage())
		return 255
	var host := rest[0]
	if host.contains("@"):
		user = host.get_slice("@", 0)
		host = host.get_slice("@", 1)
	var command := " ".join(rest.slice(1))
	var found: Dictionary = await AgoraResolver.resolve(p, host)
	var addr: int = found.get("addr", -1)
	if addr < 0:
		return p.fail("Could not resolve hostname %s: %s" % [host, AgoraResolver.message(found.error)], 255)
	var r: Dictionary = await p.machine.net.tcp.open_connection(p, addr, port)
	if r.has("error"):
		return p.fail("connect to host %s port %d: %s" % [host, port, AgoraErrno.describe(r.error)], 255)
	var conn: AgoraTcp.Conn = r.conn
	conn.pid = p.pid
	conn.nodelay = true # TCP_NODELAY, as OpenSSH does
	var alive := func() -> bool: return p.is_dead() or not conn.is_open()
	var banner: Variant = await conn.input.read_line(alive)
	if banner == null or not str(banner).begins_with("SSH-"):
		conn.close()
		return p.fail("ssh_exchange_identification: Connection closed by remote host", 255)
	conn.output.write(BANNER + "\n")
	var ok := false
	for attempt in 3:
		var password: Variant = await read_secret(p, "%s@%s's password: " % [user, host])
		if password == null or p.is_dead():
			conn.close()
			return 255
		conn.output.write("AUTH %s %s\n" % [user, Marshalls.utf8_to_base64(str(password))])
		var reply: Variant = await conn.input.read_line(alive)
		if reply == "AUTH-OK":
			ok = true
			break
		if reply == null:
			conn.close()
			return p.fail("Connection closed by %s" % AgoraInet.to_str(addr), 255)
		if attempt < 2:
			p.errln("Permission denied, please try again.")
	if not ok:
		conn.close()
		p.errln("%s@%s: Permission denied (publickey,password)." % [user, host])
		return 255
	var pty := (command.is_empty() and want_tty >= 0) or want_tty > 0
	if pty and p.tty == null and want_tty < 2:
		p.errln("Pseudo-terminal will not be allocated because stdin is not a terminal.")
		pty = false
	if pty:
		var cols := p.tty.cols if p.tty else 80
		var rows := p.tty.rows if p.tty else 24
		conn.output.write("PTY %s %d %d\n" % [str(p.env.get("TERM", "vt100")), cols, rows])
		if p.tty:
			_send_size = func() -> void:
				if not _done:
					AgoraSshChannel.request(conn, {"window-change": [p.tty.cols, p.tty.rows]})
			p.tty.resized.connect(_send_size)
	if pty:
		# Ctrl+C belongs to the remote terminal.
		p.signal_handler = func(sig: int) -> bool:
			if sig == AgoraProcess.SIGINT:
				AgoraSshChannel.request(conn, {"signal": sig})
				return true
			return false
	if command.is_empty():
		conn.output.write("SHELL\n")
	else:
		conn.output.write("EXEC %s\n" % Marshalls.utf8_to_base64(command))
	_keyboard(p, conn, not command.is_empty())
	# Whatever the remote side sends, until it closes the connection.
	while not p.is_dead():
		var msg: Array = await AgoraSshChannel.receive(conn, p.is_dead)
		if msg.is_empty():
			break
		match msg[0]:
			"D":
				p.out(msg[1])
			"E":
				p.err(msg[1])
			"C":
				var req: Dictionary = msg[1]
				if req.has("exit-status"):
					_status = int(req["exit-status"])
				if req.has("echo") and p.tty:
					p.tty.echo = req.echo
				if req.has("raw") and p.tty and bool(req.raw) != _raw:
					_raw = bool(req.raw)
					p.tty.raw = _raw
					p.stdin.changed.emit() # the keyboard reader changes its pace
	_done = true
	conn.close()
	if p.tty:
		p.tty.echo = true
		p.tty.raw = false
		if _send_size.is_valid() and p.tty.resized.is_connected(_send_size):
			p.tty.resized.disconnect(_send_size)
	if pty:
		p.errln("Connection to %s closed." % host)
	if _status < 0 and conn.error != AgoraErrno.OK:
		p.errln("Connection to %s closed by remote host." % host if conn.error == AgoraErrno.ECONNRESET else "Write failed: %s" % AgoraErrno.describe(conn.error))
	return _status if _status >= 0 else 255


## Lines typed here (or a command's stdin) go to the remote side; Ctrl+D
## sends end-of-file. For a command, the end of stdin ends its input. While
## the remote terminal is raw, keys go over one by one.
func _keyboard(p: AgoraProcess, conn: AgoraTcp.Conn, command: bool) -> void:
	while not _done and not p.is_dead():
		var raw := _raw
		var stop := func() -> bool: return _done or p.is_dead() or _raw != raw
		if raw:
			var keys: Variant = await p.stdin.read_some(stop)
			if _done or p.is_dead():
				return
			if keys != null:
				AgoraSshChannel.data(conn, str(keys))
			elif p.stdin.is_eof():
				AgoraSshChannel.request(conn, {"eof": true})
				return
			continue
		var line: Variant = await p.stdin.read_line(stop)
		if _done or p.is_dead():
			return
		if _raw != raw:
			continue
		if line == null:
			AgoraSshChannel.request(conn, {"eof": true})
			if command or p.stdin.is_eof():
				return
			continue
		AgoraSshChannel.data(conn, str(line) + "\n")
