extends AgoraProgram
## popa3d (1.0.2): a small POP3 server, started by inetd with the
## connection on its standard input and output. Users log in with USER and
## PASS (their system password, sent as plain text) and get their mailbox,
## /var/mail/USER: STAT, LIST, UIDL, RETR, TOP, DELE, RSET, NOOP, LAST,
## QUIT. Messages marked with DELE go away at QUIT; mail that arrives
## meanwhile stays. Logins and failed attempts are logged to daemon.

const SPOOL := "/var/mail"
const IDLE_TIMEOUT := 600.0
const MAX_FAILS := 3

var p: AgoraProcess
var _user := ""
var _cred: AgoraCred
var _box := ""
var _original := ""
var _msgs: Array = [] # AgoraMbox messages, plus "deleted" and "text"
var _last := 0


func summary() -> String:
	return "Post Office Protocol (POP3) server"


func usage() -> String:
	return "usage: popa3d (started by inetd)"


func main(proc: AgoraProcess) -> int:
	p = proc
	var deadline := [Time.get_ticks_msec() + int(IDLE_TIMEOUT * 1000)]
	var stop := func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline[0]
	var fails := 0
	var pending_user := ""
	_ok()
	while p.is_running():
		var raw: Variant = await p.stdin.read_line(stop)
		if raw == null:
			break # no QUIT: nothing is deleted
		deadline[0] = Time.get_ticks_msec() + int(IDLE_TIMEOUT * 1000)
		var line := str(raw).trim_suffix("\r")
		var verb := line.get_slice(" ", 0).to_upper()
		var args := line.substr(verb.length()).strip_edges().split(" ", false)
		if verb == "QUIT":
			if not _user.is_empty() and not _commit():
				_err()
			else:
				_ok()
			break
		if _user.is_empty():
			match verb:
				"USER":
					pending_user = args[0] if not args.is_empty() else ""
					if pending_user.is_empty():
						_err()
					else:
						_ok()
				"PASS":
					var password := line.substr(5) if line.length() > 5 else ""
					if pending_user.is_empty() or not await _login(pending_user, password):
						fails += 1
						# Failures are answered slowly, so guessing takes time.
						await p.sleep(1.0)
						_err()
						if fails >= MAX_FAILS:
							break
					else:
						_ok()
					pending_user = ""
				"NOOP":
					_ok()
				_:
					_err()
			continue
		_command(verb, args)
	return 0


func _send(text: String) -> void:
	p.out(text + "\r\n")


func _ok(text: String = "") -> void:
	_send("+OK" + (" " + text if not text.is_empty() else ""))


func _err() -> void:
	_send("-ERR")


func _log(message: String) -> void:
	p.machine.log_event("daemon", "popa3d[%d]" % p.pid, message)


func _login(user: String, password: String) -> bool:
	var users := p.machine.users
	if users.find(user).is_empty() or users.is_locked(user) or not users.check_password(user, password):
		_log("Authentication failed for %s" % (user if not users.find(user).is_empty() else "UNKNOWN USER"))
		return false
	_user = user
	_cred = users.cred_for(user)
	_box = "%s/%s" % [SPOOL, user]
	_original = p.machine.vfs.read_text(_cred, _box)
	_msgs = AgoraMbox.parse(_original)
	for m: Dictionary in _msgs:
		m.deleted = false
		m.text = AgoraMbox.message_text(m)
		m.octets = _octets(m.text)
	_log("Authentication passed for %s" % user)
	return true


## The size of a message as POP3 counts it: lines end in CR LF.
static func _octets(text: String) -> int:
	return text.to_utf8_buffer().size() + text.count("\n")


func _message(arg: PackedStringArray) -> Dictionary:
	if arg.is_empty() or not arg[0].is_valid_int():
		return {}
	var n := arg[0].to_int()
	if n < 1 or n > _msgs.size() or _msgs[n - 1].deleted:
		return {}
	return _msgs[n - 1]


func _command(verb: String, args: PackedStringArray) -> void:
	match verb:
		"STAT":
			var count := 0
			var size := 0
			for m: Dictionary in _msgs:
				if not m.deleted:
					count += 1
					size += int(m.octets)
			_ok("%d %d" % [count, size])
		"LIST", "UIDL":
			if not args.is_empty():
				var m := _message(args)
				if m.is_empty():
					_err()
				else:
					_ok("%s %s" % [args[0], _list_value(verb, m)])
				return
			_ok()
			for k in _msgs.size():
				if not _msgs[k].deleted:
					_send("%d %s" % [k + 1, _list_value(verb, _msgs[k])])
			_send(".")
		"RETR", "TOP":
			var m := _message(args)
			if m.is_empty() or (verb == "TOP" and (args.size() < 2 or not args[1].is_valid_int())):
				_err()
				return
			var text: String = m.text
			if verb == "TOP":
				var parsed := AgoraMbox.parse_message(text)
				var body_lines := str(parsed.body).split("\n")
				text = "".join(parsed.headers) + "\n" + "\n".join(body_lines.slice(0, args[1].to_int()))
			else:
				_last = maxi(_last, args[0].to_int())
			_ok()
			var out := ""
			for l in text.trim_suffix("\n").split("\n"):
				out += ("." + l if l.begins_with(".") else l) + "\r\n"
			p.out(out + ".\r\n")
		"DELE":
			var m := _message(args)
			if m.is_empty():
				_err()
			else:
				m.deleted = true
				_ok()
		"RSET":
			for m: Dictionary in _msgs:
				m.deleted = false
			_ok()
		"NOOP":
			_ok()
		"LAST":
			_ok(str(_last))
		_:
			_err()


func _list_value(verb: String, m: Dictionary) -> String:
	return str(m.octets) if verb == "LIST" else str(m.text).md5_text()


## Takes the deleted messages out of the mailbox, keeping what arrived
## since it was read. Returns false if the mailbox can't be written.
func _commit() -> bool:
	if not _msgs.any(func(m: Dictionary) -> bool: return m.deleted):
		return true
	var vfs := p.machine.vfs
	var now := vfs.read_text(_cred, _box)
	var arrived := now.substr(_original.length()) if now.begins_with(_original) else ""
	var keep := ""
	for m: Dictionary in _msgs:
		if not m.deleted:
			keep += AgoraMbox.to_text(m)
	return vfs.write_text(_cred, _box, keep + arrived) == AgoraErrno.OK
