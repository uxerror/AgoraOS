extends AgoraProgram
## fetchmail 6.3.6: fetches mail from POP3 mailboxes and hands each message
## to the local mail system by SMTP (localhost:25), as Debian Etch's did.
##
## ~/.fetchmailrc (no more than 0700) has the mailboxes:
## [codeblock]
## set daemon 300
## poll mail.lanlink.net protocol pop3 user "alice" password "secret" keep
## [/codeblock]
## Messages are deleted on the server once delivered, unless "keep"; kept
## ones are remembered by their UIDL in ~/.fetchids and not fetched again
## (unless "fetchall"). -c only counts, -v shows the dialogue, -d N polls
## every N seconds in the background, -q stops that daemon.

const VERSION := "6.3.6"
## Exit statuses, as fetchmail(1) lists them.
const PS_SUCCESS := 0
const PS_NOMAIL := 1
const PS_SOCKET := 2
const PS_AUTHFAIL := 3
const PS_SYNTAX := 5
const PS_SMTP := 10
const PS_EXCLUDE := 13
## Words that only make the rc file read like English.
const NOISE: PackedStringArray = ["and", "with", "has", "wants", "options", "here", "there", "is"]

var p: AgoraProcess
var _verbose := false
var _silent := false
var _syslog := false


func summary() -> String:
	return "fetch mail from a POP, IMAP, ETRN, or ODMR-capable server"


func usage() -> String:
	return "usage:  fetchmail [options] [server ...]\n  Options are as follows:\n  -?, --help        display this option help\n  -V, --version     display version info\n  -c, --check       check for messages without fetching\n  -s, --silent      work silently\n  -v, --verbose     work noisily (diagnostic output)\n  -d, --daemon      run as a daemon once per n seconds\n  -q, --quit        kill daemon process\n  -f, --fetchmailrc specify alternate run control file\n  -k, --keep        save new messages after retrieval\n  -K, --nokeep      delete new messages after retrieval\n  -a, --all         retrieve old and new messages\n  -u, --username    specify users's login on server\n  -p, --protocol    specify retrieval protocol"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "dfup", PackedStringArray(["daemon", "fetchmailrc", "username", "protocol"]))
	if not a.error.is_empty():
		return p.fail("fetchmail: " + a.error, PS_SYNTAX)
	if a.has("?") or a.has("help"):
		p.outln(usage())
		return 0
	if a.has("V") or a.has("version"):
		p.outln("This is fetchmail release %s+NTLM+SDPS+SSL+NLS" % VERSION)
		return 0
	_verbose = a.has("v") or a.has("verbose")
	_silent = a.has("s") or a.has("silent")
	var pidfile := p.home() + "/.fetchmail.pid"
	if a.has("q") or a.has("quit"):
		return _quit(pidfile)
	var rcfile: String = a.value("f", a.value("fetchmailrc", p.home() + "/.fetchmailrc"))
	var rc := {"daemon": 0, "polls": []}
	if p.exists(rcfile):
		var st := p.stat(rcfile)
		if st.mode & 63 != 0: # 0o077
			p.errln("File %s must have no more than -rwx------ (0700) permissions." % rcfile)
			return PS_SYNTAX
		rc = _parse_rc(p.read_text(rcfile))
		if rc.has("error"):
			p.errln("fetchmail: %s" % rc.error)
			return PS_SYNTAX
	var polls: Array = rc.polls
	if not a.operands.is_empty():
		# Servers on the command line: those polls only, or new ones.
		var picked: Array = []
		for server in a.operands:
			var found: Dictionary = {}
			for q: Dictionary in polls:
				if q.host == server:
					found = q
			picked.append(found if not found.is_empty() else {"host": server, "proto": "pop3", "port": 110, "user": p.user_name(), "pass": "", "keep": false, "fetchall": false})
		polls = picked
	for q: Dictionary in polls:
		if a.has("k") or a.has("keep"):
			q.keep = true
		if a.has("K") or a.has("nokeep"):
			q.keep = false
		if a.has("a") or a.has("all"):
			q.fetchall = true
		if a.has("u") or a.has("username"):
			q.user = a.value("u", a.value("username"))
	if polls.is_empty():
		p.errln("fetchmail: no mailservers have been specified.")
		return PS_SYNTAX
	for q: Dictionary in polls:
		if q.proto != "pop3":
			p.errln("fetchmail: %s: protocol %s is not supported here" % [q.host, q.proto.to_upper()])
			return PS_SYNTAX
	var interval := int(a.value("d", a.value("daemon", str(rc.daemon))))
	var running := _running(pidfile)
	if running > 0:
		if interval > 0:
			p.errln("fetchmail: can't start another daemon: one is running at %d." % running)
			return PS_EXCLUDE
		p.machine.kill(running, AgoraProcess.SIGUSR1, p.cred)
		p.errln("fetchmail: background fetchmail at %d awakened." % running)
		return PS_SUCCESS
	if a.has("c") or a.has("check"):
		var status := PS_NOMAIL
		for q: Dictionary in polls:
			status = _better(status, await _check(q))
		return status
	if interval > 0:
		return await _daemon(polls, interval, pidfile)
	var status := PS_NOMAIL
	for q: Dictionary in polls:
		status = _better(status, await _poll(q))
	return status


## The most telling of two statuses: success beats no mail beats errors.
static func _better(a: int, b: int) -> int:
	if a == PS_SUCCESS or b == PS_SUCCESS:
		return PS_SUCCESS
	if a == PS_NOMAIL:
		return b
	return a


# --- the run control file ------------------------------------------------------

## Words of the rc file: quoted strings stay whole, comments go.
static func _words(text: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for line in text.split("\n"):
		var i := 0
		while i < line.length():
			var c := line[i]
			if c == "#":
				break
			if c == " " or c == "\t" or c == "," or c == ";" or c == ":":
				i += 1
				continue
			if c == "\"" or c == "'":
				var end := line.find(c, i + 1)
				if end < 0:
					end = line.length()
				out.append(line.substr(i + 1, end - i - 1))
				i = end + 1
				continue
			var start := i
			while i < line.length() and not line[i] in [" ", "\t", ",", ";"]:
				i += 1
			out.append(line.substr(start, i - start))
	return out


static func _parse_rc(text: String) -> Dictionary:
	var rc := {"daemon": 0, "polls": []}
	var words := _words(text)
	var q: Dictionary = {}
	var k := 0
	while k < words.size():
		var w := words[k]
		var next := words[k + 1] if k + 1 < words.size() else ""
		k += 1
		if w in NOISE:
			continue
		match w:
			"set":
				if next == "daemon" and k + 1 < words.size():
					rc.daemon = int(words[k + 1])
				k += 2
			"poll", "server", "skip":
				q = {"host": next, "proto": "pop3", "port": 110, "user": "", "pass": "", "keep": false, "fetchall": false}
				(rc.polls as Array).append(q)
				k += 1
			"proto", "protocol", "port", "service", "user", "username", "pass", "password":
				if q.is_empty():
					return {"error": "syntax error: %s outside a poll statement" % w}
				match w:
					"proto", "protocol": q.proto = next.to_lower()
					"port", "service": q.port = int(next)
					"user", "username": q.user = next
					"pass", "password": q.pass = next
				k += 1
			"keep":
				q.keep = true
			"nokeep":
				q.keep = false
			"no":
				if next == "keep":
					q.keep = false
				k += 1
			"fetchall":
				q.fetchall = true
			"timeout", "interval", "smtphost", "mda", "folder":
				k += 1
	return rc


# --- a POP3 session ------------------------------------------------------------

func _log(text: String) -> void:
	if _syslog:
		p.machine.log_event("mail", "fetchmail[%d]" % p.pid, text)
	elif not _silent:
		p.outln(text)


func _err(text: String) -> void:
	if _syslog:
		p.machine.log_event("mail", "fetchmail[%d]" % p.pid, text.trim_prefix("fetchmail: "))
	else:
		p.errln(text)


## Opens the session and logs in: {conn, addr} or {status}.
func _login(q: Dictionary) -> Dictionary:
	var r: Dictionary = await AgoraResolver.resolve(p, q.host)
	if r.has("error"):
		_err("fetchmail: %s: host is unknown." % q.host)
		_err("fetchmail: Query status=2 (SOCKET)")
		return {"status": PS_SOCKET}
	var opened: Dictionary = await p.machine.net.tcp.open_connection(p, r.addr, q.port)
	if opened.has("error"):
		_err("fetchmail: connection to %s:%s [%s/%d] failed: %s." % [q.host, "pop3" if q.port == 110 else str(q.port), AgoraInet.to_str(r.addr), q.port, AgoraErrno.describe(opened.error)])
		_err("fetchmail: Query status=2 (SOCKET)")
		return {"status": PS_SOCKET}
	var conn: AgoraTcp.Conn = opened.conn
	var greeting: Variant = await _read(conn)
	if greeting == null or not str(greeting).begins_with("+OK"):
		conn.close()
		_err("fetchmail: %s: no POP3 greeting" % q.host)
		_err("fetchmail: Query status=2 (SOCKET)")
		return {"status": PS_SOCKET}
	var user: String = q.user if not str(q.user).is_empty() else p.user_name()
	if not str(await _say(conn, "USER " + user)).begins_with("+OK") or not str(await _say(conn, "PASS " + str(q.pass), "PASS *")).begins_with("+OK"):
		await _say(conn, "QUIT")
		conn.close()
		_err("fetchmail: Authorization failure on %s@%s" % [user, q.host])
		_err("fetchmail: Query status=3 (AUTHFAIL)")
		return {"status": PS_AUTHFAIL}
	return {"conn": conn, "addr": AgoraInet.to_str(r.addr), "user": user}


func _read(conn: AgoraTcp.Conn) -> Variant:
	var line: Variant = await AgoraMailNet._line(p, conn)
	if _verbose and line != null:
		p.outln("fetchmail: POP3< " + str(line))
	return line


## Sends a command and returns the first line of the answer. [param shown]
## is what -v prints instead (the password).
func _say(conn: AgoraTcp.Conn, cmd: String, shown: String = "") -> String:
	if _verbose:
		p.outln("fetchmail: POP3> " + (shown if not shown.is_empty() else cmd))
	conn.output.write(cmd + "\r\n")
	var l: Variant = await _read(conn)
	return str(l) if l != null else "-ERR connection closed"


## The mailbox: [{n, size, uidl}].
func _list(conn: AgoraTcp.Conn) -> Array:
	var out: Array = []
	var sizes := {}
	if str(await _say(conn, "LIST")).begins_with("+OK"):
		while true:
			var l: Variant = await _read(conn)
			if l == null or l == ".":
				break
			sizes[str(l).get_slice(" ", 0).to_int()] = str(l).get_slice(" ", 1).to_int()
	var uidls := {}
	if str(await _say(conn, "UIDL")).begins_with("+OK"):
		while true:
			var l: Variant = await _read(conn)
			if l == null or l == ".":
				break
			uidls[str(l).get_slice(" ", 0).to_int()] = str(l).get_slice(" ", 1)
	var numbers := sizes.keys()
	numbers.sort()
	for n: int in numbers:
		out.append({"n": n, "size": sizes[n], "uidl": uidls.get(n, "")})
	return out


func _seen_file() -> String:
	return p.home() + "/.fetchids"


## UIDLs fetched and kept before, for [param user]@[param host].
func _seen(user: String, host: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for line in p.read_text(_seen_file()).split("\n", false):
		var w := line.split(" ", false)
		if w.size() == 2 and w[0] == "%s@%s" % [user, host]:
			out.append(w[1])
	return out


func _remember(user: String, host: String, uidls: PackedStringArray) -> void:
	var keep: PackedStringArray = []
	for line in p.read_text(_seen_file()).split("\n", false):
		if not line.begins_with("%s@%s " % [user, host]):
			keep.append(line)
	for u in uidls:
		keep.append("%s@%s %s" % [user, host, u])
	p.write_text(_seen_file(), "\n".join(keep) + ("\n" if not keep.is_empty() else ""), false, AgoraStat.MODE_PRIVATE_FILE)


## -c: how many messages there are, fetching nothing.
func _check(q: Dictionary) -> int:
	var s := await _login(q)
	if s.has("status"):
		return s.status
	var conn: AgoraTcp.Conn = s.conn
	var box := await _list(conn)
	await _say(conn, "QUIT")
	conn.close()
	var seen := _seen(s.user, q.host)
	var old := box.filter(func(m: Dictionary) -> bool: return seen.has(m.uidl)).size()
	if box.is_empty() or (old == box.size() and not q.fetchall):
		_log("fetchmail: No mail for %s at %s" % [s.user, q.host])
		return PS_NOMAIL
	_log("%d messages (%d seen) for %s at %s." % [box.size(), old, s.user, q.host])
	return PS_SUCCESS


## Fetches one mailbox and delivers what is new.
func _poll(q: Dictionary) -> int:
	var s := await _login(q)
	if s.has("status"):
		return s.status
	var conn: AgoraTcp.Conn = s.conn
	var user: String = s.user
	var box := await _list(conn)
	var seen := _seen(user, q.host)
	var fresh := box.filter(func(m: Dictionary) -> bool: return q.fetchall or not seen.has(m.uidl))
	if fresh.is_empty():
		await _say(conn, "QUIT")
		conn.close()
		_log("fetchmail: No mail for %s at %s" % [user, q.host])
		return PS_NOMAIL
	var octets := 0
	for m: Dictionary in box:
		octets += int(m.size)
	var old := box.size() - fresh.size()
	_log("%d %s%s for %s at %s (%d octets)." % [box.size(), "message" if box.size() == 1 else "messages", " (%d seen)" % old if old > 0 else "", user, q.host, octets])
	var kept: PackedStringArray = seen.duplicate() if q.keep else PackedStringArray()
	var status := PS_SUCCESS
	for m: Dictionary in fresh:
		if not str(await _say(conn, "RETR %d" % m.n)).begins_with("+OK"):
			continue
		var lines: PackedStringArray = []
		while true:
			var l: Variant = await AgoraMailNet._line(p, conn)
			if l == null or l == ".":
				break
			lines.append(str(l).substr(1) if str(l).begins_with("..") else str(l))
		var text := "\n".join(lines) + "\n"
		var delivered := await _deliver(text, q.host, s.addr, user)
		var line := "reading message %s@%s:%d of %d (%d octets)" % [user, q.host, m.n, box.size(), m.size]
		if not delivered:
			_log(line + " not flushed")
			_err("fetchmail: SMTP connect to localhost failed")
			status = PS_SMTP
			break
		if q.keep:
			if not kept.has(m.uidl):
				kept.append(m.uidl)
			_log(line + " not flushed")
		else:
			await _say(conn, "DELE %d" % m.n)
			_log(line + " flushed")
	await _say(conn, "QUIT")
	conn.close()
	if q.keep:
		_remember(user, q.host, kept)
	if status == PS_SMTP:
		_err("fetchmail: Query status=10 (SMTP)")
	return status


## Hands a message to the local mail system, as fetchmail does: by SMTP to
## localhost, with a Received: line on top.
func _deliver(text: String, host: String, addr: String, user: String) -> bool:
	var from := ""
	for line in text.split("\n"):
		if line.is_empty():
			break
		if line.to_lower().begins_with("return-path:") or (from.is_empty() and line.to_lower().begins_with("from:")):
			from = line.substr(line.find(":") + 1).strip_edges()
	if from.contains("<"):
		from = from.substr(from.find("<") + 1).get_slice(">", 0)
	var received := "Received: from %s [%s]\n\tby %s with POP3 (fetchmail-%s)\n\tfor <%s@localhost> (single-drop); %s\n" % [
		host, addr, p.machine.hostname, VERSION, p.user_name(), p.machine.clock.format_rfc822()]
	var r: Dictionary = await AgoraMailNet.smtp_send(p, "127.0.0.1", 25, from, PackedStringArray([p.user_name() + "@localhost"]), received + text)
	if r.has("error") and _verbose:
		p.outln("fetchmail: " + str(r.error))
	return not r.has("error")


# --- the daemon ----------------------------------------------------------------

func _running(pidfile: String) -> int:
	if not p.exists(pidfile):
		return 0
	var pid := p.read_text(pidfile).get_slice("\n", 0).strip_edges().to_int()
	var other := p.machine.get_process(pid)
	return pid if other and other.is_running() and other.name == "fetchmail" else 0


func _quit(pidfile: String) -> int:
	var pid := _running(pidfile)
	if pid == 0:
		p.errln("fetchmail: no other fetchmail is running")
		return PS_EXCLUDE
	p.machine.kill(pid, AgoraProcess.SIGTERM, p.cred)
	p.unlink(pidfile)
	p.errln("fetchmail: background fetchmail at %d killed." % pid)
	return PS_SUCCESS


## Polls every [param interval] seconds of game time in the background,
## logging to syslog; SIGUSR1 wakes it up at once.
func _daemon(polls: Array, interval: int, pidfile: String) -> int:
	p.errln("fetchmail: starting fetchmail %s daemon " % VERSION)
	p.write_text(pidfile, "%d\n%d\n" % [p.pid, interval], false, AgoraStat.MODE_PRIVATE_FILE)
	p.daemonize()
	_syslog = true
	var woken := [false]
	p.signal_handler = func(sig: int) -> bool:
		if sig == AgoraProcess.SIGUSR1:
			woken[0] = true
			return true
		return false
	p.machine.log_event("mail", "fetchmail[%d]" % p.pid, "starting fetchmail %s daemon " % VERSION)
	while p.is_running():
		for q: Dictionary in polls:
			await _poll(q)
		var until := p.machine.clock.now() + interval
		woken[0] = false
		while p.is_running() and not woken[0] and p.machine.clock.now() < until:
			await p.sleep(clampf((until - p.machine.clock.now()) / maxf(p.machine.clock.speed, 0.001), 0.05, 1.0))
	p.signal_handler = Callable()
	return PS_SUCCESS
