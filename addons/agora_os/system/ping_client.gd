class_name AgoraPingClient
extends RefCounted
## A connection to a Ping! server for client programs. [method open]
## connects, [method request] sends a command and waits for its answer,
## everything else the server says arrives through [signal received].

## A line from the server that wasn't the answer to a request.
signal received(cmd: String, args: PackedStringArray)
## The connection is gone; [param reason] says why.
signal disconnected(reason: String)

const TIMEOUT := 15.0
const KEEPALIVE := 60.0

var p: AgoraProcess
var conn: AgoraTcp.Conn
var server_name := ""
var host := ""
var _want: PackedStringArray = []
var _reply: Variant = null
var _collect: PackedStringArray = []
var _collected: Array = []
var _closing := false


func _init(proc: AgoraProcess) -> void:
	p = proc


func is_connected_to_server() -> bool:
	return conn != null and conn.is_open()


## Connects to [param server] and reads its greeting. Returns "" or what
## went wrong.
func open(server: String, port: int = AgoraPing.PORT) -> String:
	host = server
	var r: Dictionary = await AgoraResolver.resolve(p, server)
	if r.has("error"):
		return "%s: %s" % [server, AgoraResolver.message(r.error)]
	var opened: Dictionary = await p.machine.net.tcp.open_connection(p, r.addr, port)
	if opened.has("error"):
		return "%s: %s" % [server, AgoraErrno.describe(opened.error)]
	conn = opened.conn
	_closing = false
	var hello: Variant = await _read()
	if hello == null or hello.cmd != "HELLO":
		conn.close()
		conn = null
		return "%s: not a Ping! server" % server
	server_name = hello.args[1] if hello.args.size() > 1 else server
	_reader()
	_keepalive()
	return ""


func _read() -> Variant:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	var raw: Variant = await conn.input.read_line(func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline)
	return AgoraPing.parse(str(raw)) if raw != null else null


func _reader() -> void:
	var c := conn
	while c == conn and p.is_running():
		var raw: Variant = await c.input.read_line(p.is_dead)
		if raw == null:
			break
		var msg := AgoraPing.parse(str(raw))
		if not _want.is_empty() and _collect.has(msg.cmd):
			_collected.append(msg)
			continue
		if not _want.is_empty() and (_want.has(msg.cmd) or msg.cmd == "ERROR"):
			_want = PackedStringArray()
			_reply = msg
			continue
		received.emit(msg.cmd, msg.args)
	if c == conn:
		conn = null
		c.close()
		disconnected.emit("" if _closing else "Connection to %s lost" % host)


func _keepalive() -> void:
	var c := conn
	while c == conn and c != null and c.is_open() and p.is_running():
		await p.sleep(KEEPALIVE)
		if c == conn and c.is_open():
			send(["NOP"])


## Sends a command without waiting.
func send(words: Array, trailing: bool = false) -> void:
	if is_connected_to_server():
		conn.output.write(AgoraPing.line(words, trailing))


## Sends a command and waits for one of the [param answers] (or ERROR):
## {cmd, args}, or {cmd: "ERROR", args: ["0", reason]} if nothing came.
## Lines whose command is in [param collect] are gathered on the way, in
## "lines" of the result.
func request(words: Array, trailing: bool, answers: PackedStringArray, collect: PackedStringArray = []) -> Dictionary:
	if not is_connected_to_server():
		return {"cmd": "ERROR", "args": PackedStringArray(["0", "Not connected"])}
	while not _want.is_empty():
		await p.sleep(0.05) # one request at a time
	_want = answers
	_reply = null
	_collect = collect
	_collected = []
	send(words, trailing)
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	while _reply == null and is_connected_to_server() and Time.get_ticks_msec() < deadline and p.is_running():
		await p.sleep(0.02)
	_want = PackedStringArray()
	_collect = PackedStringArray()
	if _reply == null:
		return {"cmd": "ERROR", "args": PackedStringArray(["0", "No answer from the server"]), "lines": []}
	var r: Dictionary = _reply
	r.lines = _collected
	_reply = null
	return r


## Says goodbye and closes the connection.
func close() -> void:
	if conn == null:
		return
	_closing = true
	send(["BYE"])
	conn.close()
