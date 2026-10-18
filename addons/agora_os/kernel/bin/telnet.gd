extends AgoraProgram
## telnet (netkit-telnet 0.17): a TELNET client, and the classic way to
## talk to any TCP service by hand ("telnet host 25"). It answers the
## server's option negotiation (terminal type, window size, echo) and never
## starts one itself, so other services see only what is typed.
##
## Lines are edited here and sent with CR LF. When the server takes over
## echoing (WILL ECHO, as for a password), typing is not shown. Ctrl+C
## sends Interrupt Process; end of input closes the connection.

const T := preload("res://addons/agora_os/system/telnet_proto.gd")

var p: AgoraProcess
var _conn: AgoraTcp.Conn
var _parser := AgoraTelnet.Parser.new()
var _done := false


func summary() -> String:
	return "user interface to the TELNET protocol"


func usage() -> String:
	return "usage: telnet [-l user] [host-name [port]]"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "le")
	if a.operands.is_empty() or a.operands.size() > 2:
		p.errln(usage())
		return 1
	var host := a.operands[0]
	var service := a.operands[1] if a.operands.size() > 1 else "telnet"
	var port := _port(service)
	if port <= 0:
		return p.fail("could not resolve %s/%s: Servname not supported for ai_socktype" % [host, service], 1)
	var found: Dictionary = await AgoraResolver.resolve(p, host)
	var addr: int = found.get("addr", -1)
	if addr < 0:
		return p.fail("could not resolve %s/%s: %s" % [host, service, AgoraResolver.message(found.error)], 1)
	p.outln("Trying %s..." % AgoraInet.to_str(addr))
	var r: Dictionary = await p.machine.net.tcp.open_connection(p, addr, port)
	if r.has("error"):
		return p.fail("Unable to connect to remote host: %s" % AgoraErrno.describe(r.error), 1)
	_conn = r.conn
	_conn.pid = p.pid
	_conn.nodelay = true
	p.outln("Connected to %s." % host)
	p.outln("Escape character is '^]'.")
	p.signal_handler = func(sig: int) -> bool:
		if sig == AgoraProcess.SIGINT and not _done:
			_conn.output.write(T.control(T.INTERRUPT))
			return true
		return false
	_keyboard()
	while not p.is_dead():
		var chunk: Variant = await _conn.input.read_some(p.is_dead)
		if chunk == null:
			break
		var data := _parser.feed(chunk)
		for c: Array in _parser.take():
			_command(c)
		if not data.is_empty():
			p.out(_from_network(data))
	_done = true
	_conn.close()
	if p.tty:
		p.tty.echo = true
	if p.is_dead():
		return 1
	p.errln("Connection closed by foreign host.")
	return 1


## A service name from /etc/services, or a number.
func _port(service: String) -> int:
	if service.is_valid_int():
		return service.to_int()
	for line in p.read_text("/etc/services").split("\n", false):
		var w := line.get_slice("#", 0).replace("\t", " ").split(" ", false)
		if w.size() >= 2 and w[1].ends_with("/tcp") and (w[0] == service or w.slice(2).has(service)):
			return w[1].get_slice("/", 0).to_int()
	return 23 if service == "telnet" else 0


## Network newlines (CR LF, CR NUL) as the terminal's; raw bytes are shown
## as the characters they are in Latin-1.
static func _from_network(data: String) -> String:
	var text := data.replace("\r\n", "\n").replace("\r" + AgoraWire.raw_byte(0), "\n")
	var out := ""
	for k in text.length():
		var c := text.unicode_at(k)
		var b := AgoraWire.byte_of(c)
		if c == 0x0D or b == 0:
			continue
		out += char(b) if b >= 0x80 else text.substr(k, 1)
	return out


func _command(c: Array) -> void:
	match c[0]:
		T.DO:
			match c[1]:
				T.TTYPE:
					_send(T.command(T.WILL, T.TTYPE))
				T.NAWS:
					_send(T.command(T.WILL, T.NAWS))
					_send(T.subneg(T.NAWS, PackedByteArray([0, 80, 0, 24])))
				_:
					_send(T.command(T.WONT, c[1]))
		T.DONT:
			_send(T.command(T.WONT, c[1]))
		T.WILL:
			match c[1]:
				T.ECHO:
					_send(T.command(T.DO, T.ECHO))
					if p.tty:
						p.tty.echo = false # the server echoes now
				T.SGA:
					_send(T.command(T.DO, T.SGA))
				_:
					_send(T.command(T.DONT, c[1]))
		T.WONT:
			if c[1] == T.ECHO:
				_send(T.command(T.DONT, T.ECHO))
				if p.tty:
					p.tty.echo = true
		T.SB:
			if c[1] == T.TTYPE and not (c[2] as PackedByteArray).is_empty() and c[2][0] == T.SEND:
				var term := str(p.env.get("TERM", "network")).to_upper()
				var payload := PackedByteArray([T.IS])
				payload.append_array(term.to_ascii_buffer())
				_send(T.subneg(T.TTYPE, payload))


func _send(text: String) -> void:
	if not _done:
		_conn.output.write(text)


## Typed lines go to the server with CR LF; the end of input closes the
## sending side and waits for the server to finish.
func _keyboard() -> void:
	var stop := func() -> bool: return _done or p.is_dead()
	while not stop.call():
		var line: Variant = await p.stdin.read_line(stop)
		if stop.call():
			return
		if line == null:
			if p.stdin.is_eof() or p.tty == null:
				_conn.shutdown_write()
				return
			continue
		_send(T.escape(str(line)) + "\r\n")
