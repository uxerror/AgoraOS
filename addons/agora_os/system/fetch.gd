class_name AgoraFetch
extends RefCounted
## Fetches a file by URL for programs that download (apkg): file: from the
## disk, http: through [AgoraHttp], ftp: as an anonymous FTP user in
## passive mode. Returns {bytes} or {error} with the text apt printed for
## the problem.

const TIMEOUT := 60.0


static func fetch(p: AgoraProcess, url: String, agent: String = "AgoraOS") -> Dictionary:
	if url.begins_with("file:"):
		var path := url.substr(5)
		while path.begins_with("//"):
			path = path.substr(1)
		if path.begins_with("localhost/"):
			path = path.substr(9)
		var bytes := p.read_bytes(path)
		if p.errno != AgoraErrno.OK:
			return {"error": "File not found" if p.errno == AgoraErrno.ENOENT else AgoraErrno.describe(p.errno)}
		return {"bytes": bytes}
	var u := AgoraHttp.parse_url(url)
	if u.is_empty():
		return {"error": "Malformed URL"}
	if u.scheme == "http":
		var r: Dictionary = await AgoraHttp.fetch(p, url, {"agent": agent, "timeout": TIMEOUT})
		if r.has("error"):
			return {"error": _http_error(r, u)}
		if int(r.code) != 200:
			return {"error": "%d %s" % [r.code, r.get("reason", "")]}
		return {"bytes": AgoraWire.encode(str(r.body))}
	if u.scheme == "ftp":
		return await _ftp(p, u)
	return {"error": "Unsupported URL scheme '%s'" % u.scheme}


static func _http_error(r: Dictionary, u: Dictionary) -> String:
	match str(r.get("stage", "")):
		"resolve":
			return "Could not resolve '%s'" % u.host
		"connect":
			var code: int = r.get("code_errno", 0)
			return "Could not connect to %s:%d. - connect (%d %s)" % [u.host, u.port, code, r.error]
	return str(r.error)


static func _connect(p: AgoraProcess, host: String, port: int) -> Dictionary:
	var addr := AgoraInet.parse(host)
	if addr < 0:
		var found: Dictionary = await AgoraResolver.resolve(p, host)
		if found.has("error"):
			return {"error": "Could not resolve '%s'" % host}
		addr = found.addr
	var c: Dictionary = await p.machine.net.tcp.open_connection(p, addr, port)
	if c.has("error"):
		return {"error": "Could not connect to %s:%d. - connect (%d %s)" % [host, port, c.error, AgoraErrno.describe(c.error)]}
	return {"conn": c.conn}


static func _reply(p: AgoraProcess, conn: AgoraTcp.Conn) -> Array:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	while true:
		var raw: Variant = await conn.input.read_line(func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline)
		if raw == null:
			return [0, "Server closed the connection"]
		var line := str(raw).trim_suffix("\r")
		if line.length() >= 4 and line[3] == " " and line.left(3).is_valid_int():
			return [line.left(3).to_int(), line]
	return [0, ""]


static func _ftp(p: AgoraProcess, u: Dictionary) -> Dictionary:
	var c := await _connect(p, u.host, u.port)
	if c.has("error"):
		return c
	var ctrl: AgoraTcp.Conn = c.conn
	var result := await _ftp_session(p, ctrl, u)
	ctrl.close()
	return result


static func _ftp_session(p: AgoraProcess, ctrl: AgoraTcp.Conn, u: Dictionary) -> Dictionary:
	var say := func(cmd: String) -> Array:
		ctrl.output.write(cmd + "\r\n")
		return await _reply(p, ctrl)
	var r := await _reply(p, ctrl)
	if r[0] != 220:
		return {"error": "Server sent: %s" % r[1]}
	r = await say.call("USER anonymous")
	if r[0] == 331:
		r = await say.call("PASS apkg@%s" % p.machine.hostname)
	if r[0] != 230:
		return {"error": "Login failed: %s" % r[1]}
	await say.call("TYPE I")
	r = await say.call("PASV")
	if r[0] != 227:
		return {"error": "Unable to determine the peer name"}
	var n := str(r[1]).get_slice("(", 1).get_slice(")", 0).split(",")
	if n.size() != 6:
		return {"error": "Unable to determine the peer name"}
	var opened: Dictionary = await p.machine.net.tcp.open_connection(p, AgoraInet.parse(".".join(n.slice(0, 4))), n[4].to_int() * 256 + n[5].to_int())
	if opened.has("error"):
		return {"error": "Could not connect data socket, connection timed out"}
	var data: AgoraTcp.Conn = opened.conn
	r = await say.call("RETR " + str(u.path))
	if r[0] != 150 and r[0] != 125:
		data.close()
		await say.call("QUIT")
		return {"error": str(r[1]).substr(4)}
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	var body := await data.input.read_all(func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline)
	data.close()
	r = await _reply(p, ctrl)
	await say.call("QUIT")
	if r[0] != 226:
		return {"error": "Transfer failed: %s" % r[1]}
	return {"bytes": AgoraWire.encode(body)}
