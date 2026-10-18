extends AgoraProgram
## in.telnetd (netkit-telnet 0.17): the TELNET server, started by inetd
## with the connection on its standard input and output. It negotiates
## options, asks for the terminal type, opens a pseudo-terminal, shows
## /etc/issue.net and runs "login -h <client>" on it. Everything, the
## password included, crosses the network as plain text.
##
## The client edits lines itself. While the terminal echo is off (a
## password prompt) the server says WILL ECHO, so the client stops echoing;
## WONT ECHO hands echo back, as BSD telnetd's line mode kludge does.

const T := preload("res://addons/agora_os/system/telnet_proto.gd")

var p: AgoraProcess
var _pty: AgoraTty
var _parser := AgoraTelnet.Parser.new()
var _server_echo := false
var _done := false


func summary() -> String:
	return "telnet protocol server"


func usage() -> String:
	return "usage: in.telnetd [-h] [-L login program] (started by inetd)"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "L")
	var login: String = a.value("L") if a.has("L") else "/bin/login"
	var client := AgoraInet.to_str(p.socket.remote_addr) if p.socket else "localhost"
	var tag := "telnetd[%d]" % p.pid
	# What the client can do: netkit asks for these four first.
	_send(T.command(T.DO, T.TTYPE) + T.command(T.DO, T.TSPEED) + T.command(T.DO, T.XDISPLOC) + T.command(T.DO, T.NEW_ENVIRON))
	var term := await _terminal_type()
	if _done:
		return 0
	_send(T.command(T.WILL, T.SGA) + T.command(T.DO, T.NAWS))
	_pty = AgoraTty.new(p.machine.alloc_pty())
	var issue := p.read_text("/etc/issue.net").strip_edges()
	if not issue.is_empty():
		_send(_crlf(issue.replace("%h", p.machine.hostname) + "\n"))
	var pty_ref := weakref(_pty)
	var screen := func(text: String) -> void: _send(_crlf(T.escape(text)))
	var modes := func() -> void:
		var t := pty_ref.get_ref() as AgoraTty
		if t:
			_set_echo(not t.echo)
	_pty.printed.connect(screen)
	_pty.mode_changed.connect(modes)
	var argv := PackedStringArray([login, "-h", client, "-p"])
	var child := p.machine.spawn(argv, {
		"stdin": _pty.input, "stdout": _pty.output, "stderr": _pty.output, "tty": _pty,
		"env": {"PATH": AgoraMachine.DEFAULT_PATH, "TERM": term.to_lower() if not term.is_empty() else "network"},
		"parent": p, "new_session": true,
	})
	if child == null:
		p.machine.log_event("daemon", tag, "%s: %s" % [login, AgoraErrno.describe(p.machine.errno)])
		_pty.printed.disconnect(screen)
		_pty.mode_changed.disconnect(modes)
		return 1
	_pty.foreground.assign([child])
	_relay(child)
	await child.wait()
	_done = true
	_pty.printed.disconnect(screen)
	_pty.mode_changed.disconnect(modes)
	return 0


func _send(text: String) -> void:
	if not _done:
		p.stdout.write(text)


## The terminal's newlines as the network virtual terminal wants them.
static func _crlf(text: String) -> String:
	return text.replace("\r\n", "\n").replace("\n", "\r\n")


## Waits for the answers to the first questions and, if the client will
## say it, its terminal type.
func _terminal_type() -> String:
	var asked := false
	var deadline := Time.get_ticks_msec() + 2000
	var term := ""
	var answers := 0
	while answers < 4 or (asked and term.is_empty()):
		if Time.get_ticks_msec() > deadline:
			break
		var chunk: Variant = await p.stdin.read_some(func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline)
		if chunk == null:
			if p.stdin.is_eof() or p.is_dead():
				_done = true
				return ""
			break
		_parser.feed(chunk) # anything typed this early is dropped
		for c: Array in _parser.take():
			if c.size() == 2 and c[0] in [T.WILL, T.WONT]:
				answers += 1
				if c[0] == T.WILL and c[1] == T.TTYPE:
					asked = true
					_send(T.subneg(T.TTYPE, PackedByteArray([T.SEND])))
				elif c[0] == T.WILL:
					_send(T.command(T.DONT, c[1])) # nothing else is wanted from it
			elif c.size() == 3 and c[0] == T.SB and c[1] == T.TTYPE and not c[2].is_empty() and c[2][0] == T.IS:
				term = (c[2] as PackedByteArray).slice(1).get_string_from_ascii()
	return term


func _set_echo(on: bool) -> void:
	if on == _server_echo:
		return
	_server_echo = on
	_send(T.command(T.WILL if on else T.WONT, T.ECHO))


## What the client sends: typed text for the terminal, and commands.
func _relay(child: AgoraProcess) -> void:
	var stop := func() -> bool: return _done or p.is_dead()
	while not stop.call():
		var chunk: Variant = await p.stdin.read_some(stop)
		if chunk == null:
			if not _done:
				_pty.hang_up() # the connection is gone
			return
		var data := _parser.feed(chunk)
		for c: Array in _parser.take():
			_command(c)
		if not data.is_empty():
			# CR LF and CR NUL are the network's newline.
			_pty.input.write(data.replace("\r\n", "\n").replace("\r" + AgoraWire.raw_byte(0), "\n").replace("\r", "\n"))


func _command(c: Array) -> void:
	match c[0]:
		T.INTERRUPT:
			_pty.interrupt()
		T.AYT:
			_send("\r\n[Yes]\r\n")
		T.DO:
			if c[1] not in [T.ECHO, T.SGA]:
				_send(T.command(T.WONT, c[1]))
		T.WILL:
			if c[1] != T.NAWS:
				_send(T.command(T.DONT, c[1]))
