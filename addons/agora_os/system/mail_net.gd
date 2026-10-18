class_name AgoraMailNet
extends RefCounted
## Mail over the network for client programs: fetching a mailbox by POP3
## (RFC 1939) and sending a message by SMTP (RFC 821), the way mail
## programs of the time did it, plain text and all.

const TIMEOUT := 30.0


static func _connect(p: AgoraProcess, server: String, port: int) -> Dictionary:
	var r: Dictionary = await AgoraResolver.resolve(p, server)
	if r.has("error"):
		return {"error": "The host '%s' could not be found. (%s)" % [server, AgoraResolver.message(r.error)]}
	var opened: Dictionary = await p.machine.net.tcp.open_connection(p, r.addr, port)
	if opened.has("error"):
		return {"error": "Could not connect to the server %s, port %d. (%s)" % [server, port, AgoraErrno.describe(opened.error)]}
	return {"conn": opened.conn}


static func _line(p: AgoraProcess, conn: AgoraTcp.Conn) -> Variant:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	var raw: Variant = await conn.input.read_line(func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline)
	return str(raw).trim_suffix("\r") if raw != null else null


# --- POP3 ----------------------------------------------------------------------

## Fetches the mailbox of [param user]. [param seen] lists the UIDLs of
## messages fetched before (with [param keep], messages stay on the server
## and those are skipped); without [param keep] each fetched message is
## deleted there. Returns {messages: [{text, uidl}], uidls (all on the
## server)} or {error}.
static func pop3_fetch(p: AgoraProcess, server: String, port: int, user: String, password: String,
		keep: bool = false, seen: PackedStringArray = []) -> Dictionary:
	var c := await _connect(p, server, port)
	if c.has("error"):
		return c
	var conn: AgoraTcp.Conn = c.conn
	var result := await _pop3_session(p, conn, server, user, password, keep, seen)
	conn.close()
	return result


static func _pop3_session(p: AgoraProcess, conn: AgoraTcp.Conn, server: String, user: String, password: String,
		keep: bool, seen: PackedStringArray) -> Dictionary:
	var greeting: Variant = await _line(p, conn)
	if greeting == null or not str(greeting).begins_with("+OK"):
		return {"error": "The server didn't greet like a POP3 server: %s" % [greeting]}
	var answer := func(cmd: String) -> String:
		conn.output.write(cmd + "\r\n")
		var l: Variant = await _line(p, conn)
		return str(l) if l != null else "-ERR connection closed"
	if not str(await answer.call("USER " + user)).begins_with("+OK") or not str(await answer.call("PASS " + password)).begins_with("+OK"):
		await answer.call("QUIT")
		return {"error": "Your user name or password was rejected by the server %s." % server, "auth": true}
	# Which messages are there.
	var uidls := {}
	var numbers: Array[int] = []
	if str(await answer.call("UIDL")).begins_with("+OK"):
		while true:
			var l: Variant = await _line(p, conn)
			if l == null or l == ".":
				break
			numbers.append(str(l).get_slice(" ", 0).to_int())
			uidls[numbers[-1]] = str(l).get_slice(" ", 1)
	else:
		var stat: String = await answer.call("STAT")
		for n in range(1, stat.get_slice(" ", 1).to_int() + 1):
			numbers.append(n)
	var out: Array = []
	for n in numbers:
		var uidl: String = uidls.get(n, "")
		if keep and not uidl.is_empty() and seen.has(uidl):
			continue
		if not str(await answer.call("RETR %d" % n)).begins_with("+OK"):
			continue
		var lines: PackedStringArray = []
		while true:
			var l: Variant = await _line(p, conn)
			if l == null:
				return {"error": "The connection to the server was lost while reading message %d." % n}
			if l == ".":
				break
			lines.append(str(l).substr(1) if str(l).begins_with("..") else str(l))
		out.append({"text": "\n".join(lines) + "\n", "uidl": uidl})
		if not keep:
			await answer.call("DELE %d" % n)
	await answer.call("QUIT")
	return {"messages": out, "uidls": PackedStringArray(uidls.values())}


# --- SMTP ----------------------------------------------------------------------

## Sends [param text] (headers and body) from [param sender] to
## [param rcpts] through the SMTP server. Returns {} or {error}; a
## recipient the server refuses is an error too.
static func smtp_send(p: AgoraProcess, server: String, port: int, sender: String, rcpts: PackedStringArray, text: String) -> Dictionary:
	var c := await _connect(p, server, port)
	if c.has("error"):
		return c
	var conn: AgoraTcp.Conn = c.conn
	var result := await _smtp_session(p, conn, sender, rcpts, text)
	conn.close()
	return result


## One reply, all its lines: [code, text].
static func _reply(p: AgoraProcess, conn: AgoraTcp.Conn) -> Array:
	var lines: PackedStringArray = []
	while true:
		var l: Variant = await _line(p, conn)
		if l == null:
			return [0, "\n".join(lines)]
		lines.append(str(l))
		if str(l).length() < 4 or str(l)[3] != "-":
			return [str(l).left(3).to_int(), "\n".join(lines)]
	return [0, ""]


static func _smtp_session(p: AgoraProcess, conn: AgoraTcp.Conn, sender: String, rcpts: PackedStringArray, text: String) -> Dictionary:
	var r := await _reply(p, conn)
	if r[0] != 220:
		return {"error": "The server didn't greet like an SMTP server: %s" % r[1]}
	var say := func(cmd: String) -> Array:
		conn.output.write(cmd + "\r\n")
		return await _reply(p, conn)
	r = await say.call("HELO " + p.machine.hostname)
	if r[0] != 250:
		return {"error": "The server refused HELO: %s" % r[1]}
	r = await say.call("MAIL FROM:<%s>" % sender)
	if r[0] != 250:
		await say.call("QUIT")
		return {"error": "The server refused the sender %s: %s" % [sender, r[1]]}
	for rcpt in rcpts:
		r = await say.call("RCPT TO:<%s>" % rcpt)
		if r[0] != 250 and r[0] != 251:
			await say.call("QUIT")
			return {"error": "The server refused the recipient %s: %s" % [rcpt, r[1]], "rcpt": rcpt}
	r = await say.call("DATA")
	if r[0] != 354:
		await say.call("QUIT")
		return {"error": "The server refused the message: %s" % r[1]}
	var data := ""
	for l in text.trim_suffix("\n").split("\n"):
		data += ("." + l if l.begins_with(".") else l) + "\r\n"
	conn.output.write(data + ".\r\n")
	r = await _reply(p, conn)
	await say.call("QUIT")
	if r[0] != 250:
		return {"error": "The server did not accept the message: %s" % r[1]}
	return {}
