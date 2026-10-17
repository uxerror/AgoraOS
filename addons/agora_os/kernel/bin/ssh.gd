extends AgoraProgram
## OpenSSH-style client. Connects over TCP (so routes, firewalls and NAT
## matter), asks for the password, then connects this terminal to a login
## shell on the remote machine, or runs a command there.

const BANNER := "SSH-2.0-OpenSSH_4.3p2 Debian-9"

var _status := -1
var _done := false


func summary() -> String:
	return "log into a remote machine"


func usage() -> String:
	return "usage: ssh [-p port] [-l login_name] [user@]hostname [command]"


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	var port := 22
	var user := p.user_name()
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
	if command.is_empty():
		conn.output.write("SHELL\n")
		p.signal_handler = func(sig: int) -> bool:
			if sig == AgoraProcess.SIGINT:
				AgoraSshChannel.request(conn, {"signal": sig})
				return true
			return false
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
	_done = true
	conn.close()
	if p.tty:
		p.tty.echo = true
	if command.is_empty():
		p.errln("Connection to %s closed." % host)
	if _status < 0 and conn.error != AgoraErrno.OK:
		p.errln("Connection to %s closed by remote host." % host if conn.error == AgoraErrno.ECONNRESET else "Write failed: %s" % AgoraErrno.describe(conn.error))
	return _status if _status >= 0 else 255


## Lines typed here (or a command's stdin) go to the remote side; Ctrl+D
## sends end-of-file. For a command, the end of stdin ends its input.
func _keyboard(p: AgoraProcess, conn: AgoraTcp.Conn, command: bool) -> void:
	var stop := func() -> bool: return _done or p.is_dead()
	while not _done and not p.is_dead():
		var line: Variant = await p.stdin.read_line(stop)
		if _done or p.is_dead():
			return
		if line == null:
			AgoraSshChannel.request(conn, {"eof": true})
			if command or p.stdin.is_eof():
				return
			continue
		AgoraSshChannel.data(conn, str(line) + "\n")
