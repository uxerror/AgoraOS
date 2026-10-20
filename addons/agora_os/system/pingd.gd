extends AgoraProgram
## pingd: the server of the Ping! instant messaging network. People get a
## Ping! number when they register, log in with it, keep their contact list
## on the server, see their contacts come and go, and send each other
## messages; messages for someone who is offline wait until they log in.
## The protocol is described in [AgoraPing].
##
## /etc/pingd.conf: "name NAME" (shown in the greeting), "port N" (5190),
## "first_uin N", "register yes|no" (may anyone create an account?).
## Accounts live in /var/lib/pingd/accounts (uin:password hash:nick:
## contacts), waiting messages in /var/lib/pingd/offline/UIN. Logins and
## registrations are logged to daemon.

const CONF := "/etc/pingd.conf"
const ACCOUNTS := "/var/lib/pingd/accounts"
const OFFLINE := "/var/lib/pingd/offline"
## A client that says nothing for this long is gone (clients send NOP).
const IDLE_TIMEOUT := 600.0

var p: AgoraProcess
var _root := AgoraCred.root()
var _conf := {}
## uin -> {uin, hash, nick, contacts: PackedStringArray}
var _accounts := {}
## uin -> {conn, status, client}
var _online := {}
## Chat rooms: "#name" -> PackedStringArray of uins.
var _rooms := {}
var _listener: AgoraTcp.Listener


func summary() -> String:
	return "the Ping! messaging server"


func usage() -> String:
	return "usage: pingd [-f CONFIG]"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "f")
	_conf = _read_conf(a.value("f", CONF))
	_load_accounts()
	_listener = p.machine.net.tcp.listen(p, int(_conf.port))
	if _listener == null:
		_log("cannot listen on port %d: %s" % [_conf.port, AgoraErrno.describe(p.machine.net.tcp.last_error)])
		return p.fail("port %d: %s" % [_conf.port, AgoraErrno.describe(p.machine.net.tcp.last_error)], 1)
	_log("%s server %s started on port %d, %d accounts" % [AgoraPing.VERSION, _conf.name, _conf.port, _accounts.size()])
	while p.is_running():
		var conn: AgoraTcp.Conn = await _listener.accept(p.is_dead)
		if conn == null:
			break
		_session(conn)
	_listener.close()
	for uin: String in _online.keys():
		_send(_online[uin].conn, ["KICKED", "Server shutting down"], true)
		_online[uin].conn.close()
	return 0


func _read_conf(path: String) -> Dictionary:
	var c := {"name": p.machine.hostname, "port": AgoraPing.PORT, "first_uin": 100001, "register": true}
	for line in p.read_text(path).split("\n", false):
		line = line.get_slice("#", 0).strip_edges()
		var key := line.get_slice(" ", 0)
		var value := line.substr(key.length()).strip_edges()
		match key:
			"name": c.name = value
			"port": c.port = value.to_int()
			"first_uin": c.first_uin = value.to_int()
			"register": c.register = value in ["yes", "on", "true", "1"]
	return c


func _log(message: String) -> void:
	p.machine.log_event("daemon", "pingd[%d]" % p.pid, message)


# --- accounts ------------------------------------------------------------------

func _load_accounts() -> void:
	_accounts.clear()
	for line in p.machine.vfs.read_text(_root, ACCOUNTS).split("\n", false):
		var f := line.split(":")
		if f.size() < 3 or line.begins_with("#"):
			continue
		_accounts[f[0]] = {"uin": f[0], "hash": f[1], "nick": f[2],
			"contacts": f[3].split(",", false) if f.size() > 3 else PackedStringArray()}


func _save_accounts() -> void:
	var lines: PackedStringArray = []
	var uins := _accounts.keys()
	uins.sort_custom(func(a: String, b: String) -> bool: return a.to_int() < b.to_int())
	for uin: String in uins:
		var acc: Dictionary = _accounts[uin]
		lines.append("%s:%s:%s:%s" % [uin, acc.hash, acc.nick, ",".join(acc.contacts)])
	var vfs := p.machine.vfs
	vfs.make_dirs(_root, AgoraPath.dirname(ACCOUNTS))
	vfs.write_text(_root, ACCOUNTS + ".new", "\n".join(lines) + "\n", "/", false, AgoraStat.MODE_PRIVATE_FILE)
	vfs.rename(_root, ACCOUNTS + ".new", ACCOUNTS)


func _next_uin() -> String:
	var n: int = _conf.first_uin
	for uin: String in _accounts:
		n = maxi(n, uin.to_int() + 1)
	return str(n)


## What others see of [param uin]: its status, or offline.
func _status_of(uin: String) -> String:
	return AgoraPing.seen_as(str(_online[uin].status)) if _online.has(uin) else "offline"


static func _clean_nick(nick: String) -> String:
	return nick.replace(":", "").replace("\n", " ").strip_edges().left(AgoraPing.MAX_NICK)


# --- sessions ------------------------------------------------------------------

func _send(conn: AgoraTcp.Conn, words: Array, trailing: bool = false) -> void:
	if conn.is_open() and not conn.write_closed:
		conn.output.write(AgoraPing.line(words, trailing))


## Tells everyone who has [param uin] on their list how it looks now.
func _announce(uin: String) -> void:
	var status := _status_of(uin)
	for other: String in _online:
		if other != uin and (_accounts[other].contacts as PackedStringArray).has(uin):
			_send(_online[other].conn, ["PRESENCE", uin, status])


func _session(conn: AgoraTcp.Conn) -> void:
	var client := AgoraInet.to_str(conn.remote_addr)
	var me := ""
	var deadline := [Time.get_ticks_msec() + int(IDLE_TIMEOUT * 1000)]
	var stop := func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline[0]
	_send(conn, ["HELLO", AgoraPing.VERSION, _conf.name])
	while p.is_running():
		var raw: Variant = await conn.input.read_line(stop)
		if raw == null:
			break
		deadline[0] = Time.get_ticks_msec() + int(IDLE_TIMEOUT * 1000)
		var msg := AgoraPing.parse(str(raw))
		var args: PackedStringArray = msg.args
		if msg.cmd == "BYE":
			_send(conn, ["BYE"])
			break
		if msg.cmd == "NOP":
			_send(conn, ["NOP"])
			continue
		if me.is_empty():
			match msg.cmd:
				"REGISTER":
					if not _conf.register:
						_send(conn, ["ERROR", "403", "Registration is closed"], true)
					elif args.size() < 2 or args[0].is_empty() or _clean_nick(args[1]).is_empty():
						_send(conn, ["ERROR", "400", "Usage: REGISTER password :nick"], true)
					else:
						var uin := _next_uin()
						_accounts[uin] = {"uin": uin, "hash": AgoraUsers.hash_password(args[0]), "nick": _clean_nick(args[1]), "contacts": PackedStringArray()}
						_save_accounts()
						_log("new account %s (%s) from %s" % [uin, _accounts[uin].nick, client])
						_send(conn, ["REGISTERED", uin])
				"LOGIN":
					var uin := args[0] if args.size() > 0 else ""
					if args.size() < 2 or not _accounts.has(uin) or not _check(uin, args[1]):
						_log("failed login for %s from %s" % [uin, client])
						_send(conn, ["ERROR", "401", "Wrong number or password"], true)
						continue
					var status := args[2] if args.size() > 2 and AgoraPing.is_status(args[2]) and args[2] != "offline" else "online"
					if _online.has(uin):
						var old: AgoraTcp.Conn = _online[uin].conn
						_send(old, ["KICKED", "You logged in from another place"], true)
						old.close()
					me = uin
					_online[uin] = {"conn": conn, "status": status, "client": client}
					_log("login %s (%s) from %s" % [uin, _accounts[uin].nick, client])
					_send(conn, ["WELCOME", uin, status, _accounts[uin].nick], true)
					for c: String in _accounts[uin].contacts:
						if _accounts.has(c):
							_send(conn, ["CONTACT", c, _status_of(c), _accounts[c].nick], true)
					_deliver_offline(conn, uin)
					_send(conn, ["READY"])
					_announce(uin)
				_:
					_send(conn, ["ERROR", "403", "Log in first"], true)
			continue
		_command(conn, me, msg.cmd, args)
	if not me.is_empty() and _online.has(me) and _online[me].conn == conn:
		for room: String in _rooms.keys():
			_part(me, room)
		_online.erase(me)
		_log("logout %s from %s" % [me, client])
		_announce(me)
	conn.close()


func _check(uin: String, password: String) -> bool:
	var hash: String = _accounts[uin].hash
	var salt := hash.get_slice("$", 2)
	return AgoraUsers.hash_password(password, salt) == hash


func _command(conn: AgoraTcp.Conn, me: String, cmd: String, args: PackedStringArray) -> void:
	var acc: Dictionary = _accounts[me]
	match cmd:
		"STATUS":
			if args.is_empty() or not AgoraPing.is_status(args[0]) or args[0] == "offline":
				_send(conn, ["ERROR", "400", "Unknown status"], true)
				return
			_online[me].status = args[0]
			_send(conn, ["STATUS", args[0]])
			_announce(me)
		"ADD":
			var uin := args[0] if not args.is_empty() else ""
			if not _accounts.has(uin) or uin == me:
				_send(conn, ["ERROR", "404", uin, "No such user"], true)
				return
			if not (acc.contacts as PackedStringArray).has(uin):
				acc.contacts.append(uin)
				_save_accounts()
			_send(conn, ["CONTACT", uin, _status_of(uin), _accounts[uin].nick], true)
		"DEL":
			var uin := args[0] if not args.is_empty() else ""
			var list: PackedStringArray = acc.contacts
			var k := list.find(uin)
			if k >= 0:
				list.remove_at(k)
				acc.contacts = list
				_save_accounts()
			_send(conn, ["REMOVED", uin])
		"MSG":
			if args.size() < 2:
				_send(conn, ["ERROR", "400", "Usage: MSG uin :text"], true)
				return
			var to := args[0]
			if not _accounts.has(to):
				_send(conn, ["ERROR", "404", to, "No such user"], true)
				return
			var text := args[1].left(AgoraPing.MAX_TEXT)
			var now := str(int(p.machine.clock.now()))
			if _online.has(to):
				_send(_online[to].conn, ["MSG", me, now, text], true)
				_send(conn, ["SENT", to])
			else:
				var vfs := p.machine.vfs
				vfs.make_dirs(_root, OFFLINE)
				vfs.write_text(_root, "%s/%s" % [OFFLINE, to], "%s %s %s\n" % [me, now, AgoraPing.escape(text)], "/", true)
				_send(conn, ["STORED", to])
		"INFO":
			var uin := args[0] if not args.is_empty() else ""
			if not _accounts.has(uin):
				_send(conn, ["ERROR", "404", uin, "No such user"], true)
				return
			_send(conn, ["INFO", uin, _status_of(uin), _accounts[uin].nick], true)
		"SEARCH":
			var what := (args[0] if not args.is_empty() else "").to_lower().strip_edges()
			var found := 0
			for uin: String in _accounts:
				if found >= 50:
					break
				if what.is_empty() or uin == what or str(_accounts[uin].nick).to_lower().contains(what):
					_send(conn, ["FOUND", uin, _status_of(uin), _accounts[uin].nick], true)
					found += 1
			_send(conn, ["END"])
		"NICK":
			var nick := _clean_nick(args[0] if not args.is_empty() else "")
			if nick.is_empty():
				_send(conn, ["ERROR", "400", "Empty nick"], true)
				return
			acc.nick = nick
			_save_accounts()
			_send(conn, ["NICK", me, nick], true)
		"FILE":
			if args.size() < 4 or not args[2].is_valid_int():
				_send(conn, ["ERROR", "400", "Usage: FILE uin id size :name"], true)
			elif not _online.has(args[0]):
				_send(conn, ["ERROR", "410", args[0], "Not online"], true)
			elif args[2].to_int() > AgoraPing.MAX_FILE:
				_send(conn, ["ERROR", "413", args[0], "File too big"], true)
			else:
				_send(_online[args[0]].conn, ["FILE", me, args[1], args[2], AgoraPath.basename(args[3])], true)
				_send(conn, ["OFFERED", args[0], args[1]])
		"ACCEPT", "DECLINE", "DATA", "DONE":
			# Passed on to the other end of the transfer.
			if args.size() < 2 or not _online.has(args[0]):
				_send(conn, ["ERROR", "410", args[0] if not args.is_empty() else "", "Not online"], true)
				return
			var out: String = {"ACCEPT": "ACCEPTED", "DECLINE": "DECLINED", "DATA": "DATA", "DONE": "DONE"}[cmd]
			if cmd == "DATA":
				_send(_online[args[0]].conn, [out, me, args[1], args[2] if args.size() > 2 else ""], true)
			else:
				_send(_online[args[0]].conn, [out, me, args[1]])
		"JOIN":
			var room := args[0].to_lower() if not args.is_empty() else ""
			if not AgoraPing.is_room(room):
				_send(conn, ["ERROR", "400", "Rooms are named #name"], true)
				return
			var members: PackedStringArray = _rooms.get(room, PackedStringArray())
			if not members.has(me):
				members.append(me)
				_rooms[room] = members
				for uin in members:
					_send(_online[uin].conn, ["JOINED", room, me, acc.nick], true)
			for uin in members:
				_send(conn, ["MEMBER", room, uin, _accounts[uin].nick], true)
			_send(conn, ["END"])
		"PART":
			var room := args[0].to_lower() if not args.is_empty() else ""
			_part(me, room)
		"SAY":
			var room := args[0].to_lower() if not args.is_empty() else ""
			var members: PackedStringArray = _rooms.get(room, PackedStringArray())
			if args.size() < 2 or not members.has(me):
				_send(conn, ["ERROR", "403", "Join the room first"], true)
				return
			var now := str(int(p.machine.clock.now()))
			for uin in members:
				_send(_online[uin].conn, ["SAID", room, me, now, args[1].left(AgoraPing.MAX_TEXT)], true)
		"ROOMS":
			var names := _rooms.keys()
			names.sort()
			for room: String in names:
				_send(conn, ["ROOM", room, str((_rooms[room] as PackedStringArray).size())])
			_send(conn, ["END"])
		"LOGIN", "REGISTER":
			_send(conn, ["ERROR", "409", "Already logged in"], true)
		_:
			_send(conn, ["ERROR", "400", "Unknown command"], true)


## [param uin] leaves [param room]; the room goes with its last one.
func _part(uin: String, room: String) -> void:
	var members: PackedStringArray = _rooms.get(room, PackedStringArray())
	var k := members.find(uin)
	if k < 0:
		return
	for other in members:
		if _online.has(other):
			_send(_online[other].conn, ["PARTED", room, uin])
	members.remove_at(k)
	if members.is_empty():
		_rooms.erase(room)
	else:
		_rooms[room] = members


func _deliver_offline(conn: AgoraTcp.Conn, uin: String) -> void:
	var path := "%s/%s" % [OFFLINE, uin]
	var vfs := p.machine.vfs
	var text := vfs.read_text(_root, path)
	for line in text.split("\n", false):
		var from := line.get_slice(" ", 0)
		var time := line.get_slice(" ", 1)
		var body := line.substr(from.length() + time.length() + 2)
		_send(conn, ["OFFLINE", from, time, AgoraPing.unescape(body)], true)
	if not text.is_empty():
		vfs.unlink(_root, path)
