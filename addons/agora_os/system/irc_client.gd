class_name AgoraIrcClient
extends RefCounted
## A connection to an IRC server for client programs: [method open]
## connects and registers, every line after arrives through
## [signal received]; PINGs are answered here.

signal received(msg: Dictionary)
signal disconnected(reason: String)

const TIMEOUT := 30.0

var p: AgoraProcess
var conn: AgoraTcp.Conn
var nick := ""
## The server's name, from its welcome.
var server := ""
var _closing := false


func _init(proc: AgoraProcess) -> void:
	p = proc


func is_connected_to_server() -> bool:
	return conn != null and conn.is_open()


## Connects and registers as [param want]. Returns "" or what went wrong.
## A taken nick gets "_" added, as clients did.
func open(host: String, port: int, want: String, user: String, real: String) -> String:
	var r: Dictionary = await AgoraResolver.resolve(p, host)
	if r.has("error"):
		return "%s: %s" % [host, AgoraResolver.message(r.error)]
	var opened: Dictionary = await p.machine.net.tcp.open_connection(p, r.addr, port)
	if opened.has("error"):
		return "%s: %s" % [host, AgoraErrno.describe(opened.error)]
	conn = opened.conn
	_closing = false
	nick = want
	send("NICK " + nick)
	send("USER %s 0 * :%s" % [user, real])
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	while true:
		var raw: Variant = await conn.input.read_line(func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline)
		if raw == null:
			conn.close()
			conn = null
			return "%s: no welcome from the server" % host
		var m := AgoraIrc.parse(str(raw))
		match m.cmd:
			"001":
				server = m.prefix
				nick = m.params[0]
				received.emit(m)
				break
			"433":
				nick = nick.left(8) + "_"
				send("NICK " + nick)
			"PING":
				send("PONG :" + (m.params[0] if not m.params.is_empty() else ""))
			"ERROR":
				conn.close()
				conn = null
				return "%s: %s" % [host, m.params[0] if not m.params.is_empty() else "closed"]
			_:
				received.emit(m)
	_reader()
	return ""


func _reader() -> void:
	var c := conn
	while c == conn and p.is_running():
		var raw: Variant = await c.input.read_line(p.is_dead)
		if raw == null:
			break
		var m := AgoraIrc.parse(str(raw))
		if m.cmd == "PING":
			send("PONG :" + (m.params[0] if not m.params.is_empty() else ""))
			continue
		if m.cmd == "NICK" and m.nick == nick and not m.params.is_empty():
			nick = m.params[0]
		received.emit(m)
	if c == conn:
		conn = null
		c.close()
		disconnected.emit("" if _closing else "Connection to %s lost" % server)


func send(line: String) -> void:
	if is_connected_to_server() and not conn.write_closed:
		conn.output.write(line + "\r\n")


func close(reason: String = "Leaving") -> void:
	if conn == null:
		return
	_closing = true
	send("QUIT :" + reason)
	conn.close()
