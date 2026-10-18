extends AgoraProgram
## exim4 (Exim 4.63 as Debian configures it): the mail transfer agent.
##
##   exim4 -bd -q30m      the daemon: SMTP on port 25, and a queue run
##                         every 30 minutes
##   sendmail [-t] [-i|-oi] [-f FROM] [-F NAME] [ADDR...]
##                         take a message on standard input and deliver it
##   mailq, exim4 -bp      list the queue;  exim4 -q, runq  run it once
##   exim4 -M ID           deliver one message now;  -Mrm ID  remove it
##   exim4 -bt ADDR        show where an address would go
##
## Settings come from /etc/exim4/update-exim4.conf.conf, as Debian's
## debconf writes it: dc_eximconfig_configtype ("internet": deliver to
## other hosts by their MX; "smarthost": send everything remote to
## dc_smarthost; "local": local delivery only), dc_other_hostnames (more
## local domains, ":" between), dc_relay_nets (networks that may send mail
## to other domains through us) and dc_local_interfaces ("127.0.0.1" keeps
## the daemon to this host).
##
## Messages wait in /var/spool/exim4/input (an -H file with the envelope
## and headers, a -D file with the body). Routers, in Debian's order:
## dnslookup (or smarthost, or nonlocal) for other domains, system_aliases
## (/etc/aliases), userforward (~/.forward), local_user (/var/mail/USER in
## mbox format) and mail4root (/var/mail/mail). A message that can't be
## delivered comes back to its sender; one that can't be delivered yet
## stays queued and is retried. Everything is logged to
## /var/log/exim4/mainlog, refused SMTP commands also to rejectlog.

const VERSION := "4.63"
const CONF := "/etc/exim4/update-exim4.conf.conf"
const SPOOL := "/var/spool/exim4/input"
const MAINLOG := "/var/log/exim4/mainlog"
const REJECTLOG := "/var/log/exim4/rejectlog"
const ALIASES := "/etc/aliases"
const EXIM_USER := "Debian-exim"
## Give up on a deferred message after this many seconds of game time.
const RETRY_LIMIT := 4 * 86400
## Mail with more Received: lines than this is looping.
const MAX_RECEIVED := 30
const SMTP_TIMEOUT := 300.0
const REPLY_TIMEOUT := 60.0
const BASE62 := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
const DAYS: PackedStringArray = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS: PackedStringArray = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
## Flags of header lines in the -H file, as Exim writes them.
const HEADER_FLAGS := {"bcc": "B", "cc": "C", "from": "F", "message-id": "I", "received": "P", "reply-to": "R", "sender": "S", "to": "T"}

## Messages some process is delivering right now, per machine.
static var _busy := {}

var p: AgoraProcess
var _root := AgoraCred.root()
var _conf := {}
var _listeners: Array[AgoraTcp.Listener] = []


func summary() -> String:
	return "a mail transfer agent"


func usage() -> String:
	return "usage: exim4 [-bd] [-bp] [-q[TIME]] [-M ID] [-Mrm ID] [-bt ADDR] [-t] [-i] [-f ADDRESS] [ADDRESS...]"


func main(proc: AgoraProcess) -> int:
	p = proc
	_conf = load_conf(p)
	var name := AgoraPath.basename(p.argv[0])
	var args := p.argv.slice(1)
	match name:
		"mailq":
			args = PackedStringArray(["-bp"])
		"runq":
			args = PackedStringArray(["-q"])
		"newaliases", "update-exim4.conf":
			return 0 # the aliases file and the settings are read as they are
	if args.has("-bp"):
		return _list_queue()
	if args.has("-bV"):
		p.outln("Exim version %s #1 built 18-Jan-2007 12:00:00" % VERSION)
		p.outln("Copyright (c) University of Cambridge 2006")
		return 0
	if args.has("-bd"):
		return await _daemon(args)
	if args.has("-bt"):
		return await _test_addresses(args.slice(args.find("-bt") + 1))
	if args.has("-Mc"):
		# Exim starts itself this way to deliver a message it just took.
		p.daemonize()
		await deliver(args[args.find("-Mc") + 1])
		return 0
	for flag in ["-M", "-Mrm"]:
		if args.has(flag):
			return await _manage(flag, args.slice(args.find(flag) + 1))
	for a in args:
		if a.begins_with("-q"):
			if not _is_admin():
				p.errln("exim: permission denied")
				return 1
			await run_queue()
			return 0
	return await _submit(args)


# --- configuration -------------------------------------------------------------

static func load_conf(proc: AgoraProcess) -> Dictionary:
	var c := {
		"type": "local", "other_hostnames": PackedStringArray(), "relay_nets": PackedStringArray(),
		"local_interfaces": "127.0.0.1", "smarthost": "",
	}
	for line in proc.read_text(CONF).split("\n", false):
		line = line.strip_edges()
		if line.begins_with("#") or not line.contains("="):
			continue
		var key := line.get_slice("=", 0).strip_edges()
		var value := line.substr(line.find("=") + 1).strip_edges().trim_prefix("'").trim_suffix("'")
		match key:
			"dc_eximconfig_configtype":
				c.type = value
			"dc_other_hostnames":
				c.other_hostnames = value.replace(";", ":").split(":", false)
			"dc_relay_nets":
				c.relay_nets = value.replace(";", ":").split(":", false)
			"dc_local_interfaces":
				c.local_interfaces = value
			"dc_smarthost":
				c.smarthost = value.get_slice("::", 0).strip_edges()
	var mailname := proc.read_text("/etc/mailname").strip_edges()
	c.mailname = mailname if not mailname.is_empty() else proc.machine.hostname
	return c


## Domains whose mail is delivered here.
func _local_domains() -> PackedStringArray:
	var out := PackedStringArray([p.machine.hostname.to_lower(), "localhost", str(_conf.mailname).to_lower()])
	for d: String in _conf.other_hostnames:
		out.append(d.strip_edges().to_lower())
	return out


func _is_local_domain(domain: String) -> bool:
	return _local_domains().has(domain.to_lower())


## The address Exim makes of a bare local part.
func _qualify(addr: String) -> String:
	return addr if addr.contains("@") or addr.is_empty() else "%s@%s" % [addr, _conf.mailname]


## How the log names an SMTP client: "H=name (helo) [ip]".
static func client_desc(name: String, helo: String, ip: String) -> String:
	var shown := name
	if not helo.is_empty() and helo.to_lower() != name.to_lower():
		shown = ("%s (%s)" % [name, helo]).strip_edges()
	return ("H=%s [%s]" % [shown, ip]).replace("= [", "=[")


## root, Debian-exim and the members of its group may manage the queue.
func _is_admin() -> bool:
	if p.cred.ruid == 0:
		return true
	var exim := p.machine.users.find(EXIM_USER)
	if exim.is_empty():
		return false
	var me := p.machine.users.name_of(p.cred.ruid)
	return p.cred.ruid == int(exim.uid) or p.machine.users.group_ids_for(me).has(int(exim.gid))


# --- logs and times ------------------------------------------------------------

func _log(line: String, reject: bool = false) -> void:
	for path in [MAINLOG] + ([REJECTLOG] if reject else []):
		_append_log(path, "%s %s\n" % [_log_time(), line])


func _append_log(path: String, line: String) -> void:
	var vfs := p.machine.vfs
	if not vfs.exists(_root, path):
		vfs.make_dirs(_root, AgoraPath.dirname(path))
		vfs.write_text(_root, path, "", "/", false, 416) # 0o640
		var exim := p.machine.users.find(EXIM_USER)
		vfs.chown(_root, path, int(exim.get("uid", 0)), 4) # Debian-exim:adm
	vfs.write_text(_root, path, line, "/", true)


func _log_time() -> String:
	var d := p.machine.clock.local_datetime()
	return "%04d-%02d-%02d %02d:%02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]


## "Sat, 18 Oct 2003 21:30:05 +0000", as in Date: and Received: lines.
func _rfc822_date(unix: float = -1.0) -> String:
	var clock := p.machine.clock
	var d := clock.local_datetime(unix)
	var tz := clock.tz_offset_minutes
	return "%s, %02d %s %d %02d:%02d:%02d %s%02d%02d" % [DAYS[d.weekday], d.day, MONTHS[d.month - 1], d.year, d.hour, d.minute, d.second,
		"-" if tz < 0 else "+", absi(tz) / 60, absi(tz) % 60]


## "Sat Oct 18 21:30:05 2003", as in the From line of an mbox.
func _ctime(unix: float = -1.0) -> String:
	var d := p.machine.clock.local_datetime(unix)
	return "%s %s %2d %02d:%02d:%02d %d" % [DAYS[d.weekday], MONTHS[d.month - 1], d.day, d.hour, d.minute, d.second, d.year]


static func _base62(n: int, width: int) -> String:
	var out := ""
	for k in width:
		out = BASE62[n % 62] + out
		n /= 62
	return out


## A new message id: the time, the process and a fraction of a second.
func _new_id() -> String:
	var t := p.machine.clock.now()
	var frac := int(fmod(t, 1.0) * 1000000.0) / 500
	while true:
		var id := "%s-%s-%s" % [_base62(int(t), 6), _base62(p.pid, 6), _base62(frac % 3844, 2)]
		if not p.machine.vfs.exists(_root, "%s/%s-H" % [SPOOL, id]):
			return id
		frac += 1
	return ""


# --- messages ------------------------------------------------------------------

## A message: {id, sender, recipients, delivered, headers (Array of
## "Name: value\n" lines, continuations included), body, time, ident,
## protocol, host, helo, frozen}.
static func new_message() -> Dictionary:
	return {"id": "", "sender": "", "recipients": PackedStringArray(), "delivered": PackedStringArray(),
		"headers": [], "body": "", "time": 0.0, "ident": "", "protocol": "local", "host": "", "helo": "", "frozen": false}


## Splits a message into its header lines and body. Text that doesn't
## start with a header is all body.
static func parse_text(text: String) -> Dictionary:
	text = text.replace("\r\n", "\n")
	var headers: Array = []
	var lines := text.split("\n")
	var k := 0
	while k < lines.size():
		var line := lines[k]
		if line.is_empty():
			k += 1
			break
		if (line.begins_with(" ") or line.begins_with("\t")) and not headers.is_empty():
			headers[-1] = str(headers[-1]) + line + "\n"
		elif _is_header_line(line):
			headers.append(line + "\n")
		else:
			break
		k += 1
	var body := "\n".join(lines.slice(k))
	return {"headers": headers, "body": body}


static func _is_header_line(line: String) -> bool:
	var colon := line.find(":")
	if colon <= 0:
		return false
	var name := line.substr(0, colon)
	return not name.contains(" ") and not name.contains("\t")


## The value of the first [param name] header, unfolded ("" if none).
static func header(headers: Array, name: String) -> String:
	for h: String in headers:
		if h.get_slice(":", 0).to_lower() == name.to_lower():
			return h.substr(h.find(":") + 1).replace("\n\t", " ").replace("\n ", " ").strip_edges()
	return ""


static func has_header(headers: Array, name: String) -> bool:
	for h: String in headers:
		if h.get_slice(":", 0).to_lower() == name.to_lower():
			return true
	return false


## The addresses in a header value: "Bob <bob@x>, carol@y" -> [bob@x, carol@y].
static func addresses(value: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var parts: PackedStringArray = []
	var cur := ""
	var quoted := false
	var depth := 0
	for c in value:
		if c == "\"":
			quoted = not quoted
		elif not quoted and c == "(":
			depth += 1
		elif not quoted and c == ")":
			depth = maxi(0, depth - 1)
		elif not quoted and depth == 0 and c == ",":
			parts.append(cur)
			cur = ""
			continue
		if depth == 0 and c != ")":
			cur += c
	parts.append(cur)
	for part in parts:
		part = part.strip_edges()
		if part.contains("<") and part.contains(">"):
			part = part.substr(part.find("<") + 1, part.find(">") - part.find("<") - 1)
		elif part.contains(":") and not part.contains("@"):
			continue # a group name ("undisclosed-recipients:;")
		part = part.trim_suffix(";").strip_edges()
		if not part.is_empty() and not part.contains(" "):
			out.append(part)
	return out


func message_text(msg: Dictionary) -> String:
	return "".join(msg.headers) + "\n" + str(msg.body)


static func text_size(text: String) -> int:
	return text.to_utf8_buffer().size()


func _spool_path(id: String, part: String) -> String:
	return "%s/%s-%s" % [SPOOL, id, part]


## Writes the -D and -H files of [param msg].
func write_spool(msg: Dictionary) -> void:
	var vfs := p.machine.vfs
	vfs.make_dirs(_root, SPOOL)
	var id: String = msg.id
	if not vfs.exists(_root, _spool_path(id, "D")):
		vfs.write_text(_root, _spool_path(id, "D"), "%s-D\n%s" % [id, msg.body], "/", false, 416) # 0o640
	var users := p.machine.users
	var ident: String = msg.ident if not str(msg.ident).is_empty() else EXIM_USER
	var u := users.find(ident)
	var lines: PackedStringArray = [
		"%s-H" % id,
		"%s %d %d" % [ident, int(u.get("uid", 0)), int(u.get("gid", 0))],
		"<%s>" % msg.sender,
		"%d 0" % int(msg.time),
		"-ident %s" % ident,
		"-received_protocol %s" % msg.protocol,
		"-body_linecount %d" % str(msg.body).count("\n"),
	]
	if not str(msg.host).is_empty():
		lines.append("-host_address %s" % msg.host)
	if not str(msg.helo).is_empty():
		lines.append("-helo_name %s" % msg.helo)
	if msg.frozen:
		lines.append("-frozen %d" % int(p.machine.clock.now()))
	# The addresses already delivered (Exim keeps them as a tree).
	if (msg.delivered as PackedStringArray).is_empty():
		lines.append("XX")
	else:
		for a: String in msg.delivered:
			lines.append("NN " + a)
	lines.append(str((msg.recipients as PackedStringArray).size()))
	for a: String in msg.recipients:
		lines.append(a)
	lines.append("")
	var text := "\n".join(lines) + "\n"
	for h: String in msg.headers:
		var flag: String = HEADER_FLAGS.get(h.get_slice(":", 0).to_lower(), " ")
		text += "%03d%s %s" % [h.length(), flag, h]
	vfs.write_text(_root, _spool_path(id, "H") + ".new", text, "/", false, 416)
	vfs.rename(_root, _spool_path(id, "H") + ".new", _spool_path(id, "H"))


## Reads a queued message, or {} if there is none with that id.
func load_message(id: String) -> Dictionary:
	var vfs := p.machine.vfs
	var htext := vfs.read_text(_root, _spool_path(id, "H"))
	var dtext := vfs.read_text(_root, _spool_path(id, "D"))
	if htext.is_empty() or not dtext.begins_with(id + "-D\n"):
		return {}
	var msg := new_message()
	msg.id = id
	msg.body = dtext.substr(id.length() + 3)
	var lines := htext.split("\n")
	msg.ident = lines[1].get_slice(" ", 0)
	msg.sender = lines[2].trim_prefix("<").trim_suffix(">")
	msg.time = float(lines[3].get_slice(" ", 0).to_int())
	var k := 4
	while k < lines.size() and lines[k].begins_with("-"):
		var key := lines[k].get_slice(" ", 0)
		var value := lines[k].substr(key.length() + 1)
		match key:
			"-received_protocol": msg.protocol = value
			"-host_address": msg.host = value
			"-helo_name": msg.helo = value
			"-frozen": msg.frozen = true
		k += 1
	var delivered: PackedStringArray = []
	while k < lines.size() and not lines[k].is_valid_int():
		if lines[k].length() > 3 and lines[k][2] == " ":
			delivered.append(lines[k].substr(3))
		k += 1
	msg.delivered = delivered
	var count := lines[k].to_int() if k < lines.size() else 0
	msg.recipients = lines.slice(k + 1, k + 1 + count)
	# Headers follow the blank line: NNNf Name: value, NNN characters long.
	var start := htext.find("\n\n")
	var pos := start + 2 if start >= 0 else htext.length()
	var headers: Array = []
	while pos + 5 <= htext.length():
		var n := htext.substr(pos, 3).to_int()
		var flag := htext[pos + 3]
		var h := htext.substr(pos + 5, n)
		if flag != "*":
			headers.append(h)
		pos += 5 + n
	msg.headers = headers
	return msg


func queued_ids() -> PackedStringArray:
	var out: PackedStringArray = []
	for n in p.machine.vfs.list_dir(_root, SPOOL):
		if n.ends_with("-H"):
			out.append(n.trim_suffix("-H"))
	out.sort()
	return out


func _remove(id: String) -> void:
	p.machine.vfs.unlink(_root, _spool_path(id, "H"))
	p.machine.vfs.unlink(_root, _spool_path(id, "D"))


# --- receiving -----------------------------------------------------------------

## Queues a new message and logs its arrival. [param via] describes where it
## came from for the Received: line and the log: {user} for local mail,
## {ip, port, name, helo, protocol} for SMTP.
func accept(msg: Dictionary, via: Dictionary) -> String:
	var id := _new_id()
	msg.id = id
	msg.time = p.machine.clock.now()
	var host := p.machine.hostname
	var headers: Array = msg.headers
	var rcpts: PackedStringArray = msg.recipients
	var had_id := header(headers, "Message-Id")
	var for_part := "\n\tfor %s" % rcpts[0] if rcpts.size() == 1 else ""
	var envelope := "\n\t(envelope-from <%s>)" % msg.sender if not str(msg.sender).is_empty() else ""
	var received: String
	if via.has("ip"):
		var ip: String = via.ip
		var helo: String = via.get("helo", "")
		var name: String = via.get("name", "")
		var from: String
		if name.is_empty():
			from = "[%s]%s" % [ip, " (helo=%s)" % helo if not helo.is_empty() else ""]
		elif helo.is_empty() or helo.to_lower() == name.to_lower():
			from = "%s ([%s])" % [name, ip]
		else:
			from = "%s ([%s] helo=%s)" % [name, ip, helo]
		received = "Received: from %s\n\tby %s with %s (Exim %s)%s\n\tid %s%s; %s\n" % [from, host, via.protocol, VERSION, envelope, id, for_part, _rfc822_date()]
		msg.protocol = via.protocol
		msg.host = "%s.%d" % [ip, int(via.get("port", 0))]
		msg.helo = helo
	else:
		received = "Received: from %s by %s with local (Exim %s)%s\n\tid %s%s; %s\n" % [via.user, host, VERSION, envelope, id, for_part, _rfc822_date()]
		msg.ident = via.user
	headers.insert(0, received)
	# What the message lacks, Exim adds at the end of the header.
	if not has_header(headers, "Message-Id"):
		headers.append("Message-Id: <E%s@%s>\n" % [id, host])
	if via.has("user") and not has_header(headers, "From"):
		var u := p.machine.users.find(str(via.user))
		var gecos := str(u.get("gecos", "")).get_slice(",", 0)
		headers.append("From: %s\n" % ("%s <%s>" % [gecos, msg.sender] if not gecos.is_empty() else msg.sender))
	if not has_header(headers, "Date"):
		headers.append("Date: %s\n" % _rfc822_date())
	write_spool(msg)
	var size := text_size(message_text(msg))
	var line := "%s <= %s" % [id, msg.sender if not str(msg.sender).is_empty() else "<>"]
	if via.has("ip"):
		line += " %s P=%s" % [client_desc(via.get("name", ""), via.get("helo", ""), via.ip), via.protocol]
	else:
		if via.has("bounce_of"):
			line += " R=" + str(via.bounce_of)
		line += " U=%s P=local" % via.user
	line += " S=%d" % size
	if not had_id.is_empty():
		line += " id=" + had_id.trim_prefix("<").trim_suffix(">")
	_log(line)
	return id


## sendmail: the message on standard input, recipients from the arguments
## (or with -t from its To:, Cc: and Bcc: lines).
func _submit(args: PackedStringArray) -> int:
	var from_header := false
	var dot_ends := true
	var sender := ""
	var full_name := ""
	var rcpts: PackedStringArray = []
	var k := 0
	while k < args.size():
		var a := args[k]
		k += 1
		match a:
			"-t":
				from_header = true
			"-i", "-oi":
				dot_ends = false
			"-f", "-r":
				if k < args.size():
					sender = args[k]
					k += 1
			"-F":
				if k < args.size():
					full_name = args[k]
					k += 1
			"--":
				rcpts.append_array(args.slice(k))
				k = args.size()
			_:
				if a.begins_with("-f") and a.length() > 2:
					sender = a.substr(2)
				elif a.begins_with("-o") or a.begins_with("-b") or a.begins_with("-od") or a.begins_with("-v"):
					pass # -oem, -bm, -odi and friends change nothing here
				elif a.begins_with("-"):
					p.errln("exim: unknown option %s\n%s" % [a, usage()])
					return 1
				else:
					rcpts.append(a)
	# The text, up to end of input (or a line with a single dot).
	var lines: PackedStringArray = []
	while true:
		var line: Variant = await p.stdin.read_line(p.is_dead)
		if line == null:
			break
		var text := str(line).trim_suffix("\r")
		if dot_ends and text == ".":
			break
		lines.append(text)
	var parsed := parse_text("\n".join(lines) + ("\n" if not lines.is_empty() else ""))
	var msg := new_message()
	msg.headers = parsed.headers
	msg.body = parsed.body
	var me := p.machine.users.name_of(p.cred.ruid)
	var trusted := p.cred.ruid == 0 or me == EXIM_USER
	# Untrusted callers may only ask for an empty sender.
	if sender == "<>":
		msg.sender = ""
	elif trusted and not sender.is_empty():
		msg.sender = _qualify(sender.trim_prefix("<").trim_suffix(">"))
	else:
		msg.sender = _qualify(me)
	if not full_name.is_empty() and not has_header(msg.headers, "From"):
		msg.headers.append("From: %s <%s>\n" % [full_name, msg.sender])
	if from_header:
		for name in ["To", "Cc", "Bcc"]:
			for h: String in msg.headers:
				if h.get_slice(":", 0).to_lower() == name.to_lower():
					rcpts.append_array(addresses(h.substr(h.find(":") + 1).replace("\n", " ")))
		msg.headers = msg.headers.filter(func(h: String) -> bool: return h.get_slice(":", 0).to_lower() != "bcc")
	var clean: PackedStringArray = []
	for r in rcpts:
		for a in addresses(r):
			a = _qualify(a)
			if not clean.has(a):
				clean.append(a)
	if clean.is_empty():
		p.errln("exim: no recipients" if not from_header else "exim: no recipients found in headers")
		return 1
	msg.recipients = clean
	var id := accept(msg, {"user": me})
	# Delivery goes on in the background, as Exim forks for it.
	var child := p.spawn(PackedStringArray([AgoraPrograms.path_for("exim4"), "-Mc", id]),
		{"stdin": AgoraStream.empty(), "stdout": AgoraStream.discard(), "stderr": AgoraStream.discard(), "tty": null})
	if child == null:
		await deliver(id)
	return 0


# --- routing -------------------------------------------------------------------

## Where [param addr] goes: a list of {addr, orig, kind, router, ...}
## where kind is "local" (with user and mailbox), "remote" (with domain,
## transport and maybe hosts) or "fail" (with error).
func route(addr: String, orig: String = "", depth: int = 0) -> Array:
	if orig.is_empty():
		orig = addr
	var local_part := addr.get_slice("@", 0) if addr.contains("@") else addr
	var domain := addr.substr(addr.rfind("@") + 1).to_lower() if addr.contains("@") else str(_conf.mailname)
	if depth > 10:
		return [{"addr": addr, "orig": orig, "kind": "fail", "error": "alias or forward loop"}]
	if not _is_local_domain(domain):
		match str(_conf.type):
			"internet":
				return [{"addr": addr, "orig": orig, "kind": "remote", "domain": domain, "router": "dnslookup", "transport": "remote_smtp"}]
			"smarthost", "satellite":
				return [{"addr": addr, "orig": orig, "kind": "remote", "domain": domain, "router": "smarthost",
					"transport": "remote_smtp_smarthost", "hosts": str(_conf.smarthost)}]
		return [{"addr": addr, "orig": orig, "kind": "fail", "router": "nonlocal", "error": "Mailing to remote domains not supported"}]
	var lp := local_part.to_lower()
	# system_aliases
	var targets := _alias(lp)
	if not targets.is_empty():
		return _route_all(targets, orig, depth)
	var u := p.machine.users.find(lp)
	# userforward
	if not u.is_empty() and lp != "root":
		var forward := _forward(u)
		if not forward.is_empty():
			var out: Array = []
			var kept: PackedStringArray = []
			for t in forward:
				if t.begins_with("\\"):
					var name := t.substr(1).get_slice("@", 0)
					var target := p.machine.users.find(name)
					if not target.is_empty():
						out.append(_local_user(target, orig))
						continue
					t = name
				kept.append(t)
			out.append_array(_route_all(kept, orig, depth))
			return out
		return [_local_user(u, orig)]
	if lp == "root":
		var mail_user := p.machine.users.find("mail")
		return [{"addr": "root@" + domain, "orig": orig, "kind": "local", "router": "mail4root", "transport": "address_file",
			"user": "mail" if not mail_user.is_empty() else "root", "mailbox": "/var/mail/mail", "shown": "/var/mail/mail"}]
	return [{"addr": addr, "orig": orig, "kind": "fail", "error": "Unrouteable address"}]


func _route_all(targets: PackedStringArray, orig: String, depth: int) -> Array:
	var out: Array = []
	for t in targets:
		out.append_array(route(_qualify(t), orig, depth + 1))
	return out


func _local_user(u: Dictionary, orig: String) -> Dictionary:
	return {"addr": str(u.name), "orig": orig, "kind": "local", "router": "local_user", "transport": "mail_spool",
		"user": str(u.name), "mailbox": "/var/mail/" + str(u.name)}


## The targets of an alias in /etc/aliases (nothing if none).
func _alias(local_part: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var text := p.machine.vfs.read_text(_root, ALIASES).replace("\n\t", " ").replace("\n ", " ")
	for line in text.split("\n", false):
		if line.strip_edges().begins_with("#") or not line.contains(":"):
			continue
		if line.get_slice(":", 0).strip_edges().to_lower() != local_part:
			continue
		for t in line.substr(line.find(":") + 1).split(",", false):
			t = t.strip_edges().trim_prefix("\"").trim_suffix("\"")
			if not t.is_empty() and not t.begins_with("|") and not t.begins_with("/"):
				out.append(t)
		break
	return out


## The addresses in a user's ~/.forward.
func _forward(u: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	var text := p.machine.vfs.read_text(p.machine.users.cred_for(str(u.name)), str(u.home) + "/.forward")
	for line in text.split("\n", false):
		if line.strip_edges().begins_with("#"):
			continue
		for t in line.split(",", false):
			t = t.strip_edges().trim_prefix("\"").trim_suffix("\"")
			if not t.is_empty() and not t.begins_with("|") and not t.begins_with("/"):
				out.append(t)
	return out


func _test_addresses(list: PackedStringArray) -> int:
	var code := 0
	for a in list:
		var addr := _qualify(a)
		for r: Dictionary in route(addr):
			match r.kind:
				"fail":
					p.outln("%s is undeliverable: %s" % [addr, r.error])
					code = 2
				"local":
					var shown: String = r.get("shown", "%s@%s" % [r.addr, addr.get_slice("@", 1)])
					p.outln(shown)
					if shown != addr:
						p.outln("    <-- " + addr)
					p.outln("  router = %s, transport = %s" % [r.router, r.transport])
				"remote":
					p.outln(r.addr)
					p.outln("  router = %s, transport = %s" % [r.router, r.transport])
					var hosts := await _hosts_for(r)
					for h: Dictionary in hosts.get("hosts", []):
						p.outln("  host %s [%s]%s" % [h.name, AgoraInet.to_str(h.addr), " MX=%d" % h.pref if h.has("pref") else ""])
	return code


# --- delivery ------------------------------------------------------------------

func _lock_key(id: String) -> String:
	return "%d:%s" % [p.machine.get_instance_id(), id]


## Tries every recipient of a queued message that is still waiting.
func deliver(id: String, force: bool = false) -> void:
	var key := _lock_key(id)
	if _busy.has(key):
		return
	_busy[key] = true
	await _deliver(id, force)
	_busy.erase(key)


func _deliver(id: String, force: bool) -> void:
	var msg := load_message(id)
	if msg.is_empty() or (msg.frozen and not force):
		return
	if msg.frozen:
		msg.frozen = false
		_log("%s Unfrozen by forced delivery" % id)
	var failed: Array = []
	var deferred := false
	var received := 0
	for h: String in msg.headers:
		if h.to_lower().begins_with("received:"):
			received += 1
	var remote := {} # domain or smarthost -> [route]
	for rcpt: String in msg.recipients:
		if (msg.delivered as PackedStringArray).has(rcpt):
			continue
		if received > MAX_RECEIVED:
			failed.append({"addr": rcpt, "error": "Too many \"Received\" headers - suspected mail loop"})
			_log("%s ** %s: Too many \"Received\" headers - suspected mail loop" % [id, rcpt])
			continue
		var routes := route(rcpt)
		var all_done := true
		for r: Dictionary in routes:
			match r.kind:
				"fail":
					failed.append({"addr": r.orig, "error": r.error})
					_log("%s ** %s%s: %s" % [id, r.addr, " R=%s" % r.router if r.has("router") else "", r.error])
				"local":
					var code := _deliver_local(msg, r)
					if code == AgoraErrno.OK:
						var shown: String = r.get("shown", r.addr)
						_log("%s => %s%s R=%s T=%s" % [id, shown, " <%s>" % r.orig if shown != r.orig else "", r.router, r.transport])
					else:
						all_done = false
						_log("%s == %s <%s> R=%s T=%s defer (%d): %s" % [id, r.addr, r.orig, r.router, r.transport, code, AgoraErrno.describe(code)])
				"remote":
					var group: String = r.get("hosts", r.domain)
					if not remote.has(group):
						remote[group] = []
					remote[group].append(r)
		if not all_done:
			deferred = true
		elif not routes.any(func(r: Dictionary) -> bool: return r.kind == "remote"):
			msg.delivered.append(rcpt)
	for group: String in remote:
		var routes: Array = remote[group]
		var results: Dictionary = await _deliver_remote(msg, routes)
		for r: Dictionary in routes:
			var res: Dictionary = results.get(r.addr, {"status": "defer", "error": "unknown error"})
			match res.status:
				"ok":
					_log("%s => %s%s R=%s T=%s H=%s [%s]" % [id, r.addr, " <%s>" % r.orig if r.addr != r.orig else "", r.router, r.transport, res.host, res.ip])
					if not (msg.delivered as PackedStringArray).has(r.orig):
						msg.delivered.append(r.orig)
				"fail":
					failed.append({"addr": r.addr, "error": res.error})
					_log("%s ** %s R=%s T=%s: %s" % [id, r.addr, r.router, r.transport, str(res.error).replace("\n", " ")])
					if not (msg.delivered as PackedStringArray).has(r.orig):
						msg.delivered.append(r.orig)
				_:
					if p.machine.clock.now() - float(msg.time) > RETRY_LIMIT:
						failed.append({"addr": r.addr, "error": "retry timeout exceeded"})
						_log("%s ** %s R=%s T=%s: retry timeout exceeded" % [id, r.addr, r.router, r.transport])
						msg.delivered.append(r.orig)
					else:
						deferred = true
						_log("%s == %s R=%s T=%s defer (%s): %s" % [id, r.addr, r.router, r.transport, str(res.get("errno", -1)), res.error])
	# Addresses that failed for good count as done.
	for f: Dictionary in failed:
		if not (msg.delivered as PackedStringArray).has(f.addr) and (msg.recipients as PackedStringArray).has(f.addr):
			msg.delivered.append(f.addr)
	var bounce_id := ""
	if not failed.is_empty():
		if str(msg.sender).is_empty():
			# A bounce that can't be delivered stays, frozen, for the postmaster.
			_log("%s Frozen (delivery error message)" % id)
			msg.frozen = true
			write_spool(msg)
			return
		bounce_id = _bounce(msg, failed)
	var done := true
	for rcpt: String in msg.recipients:
		if not (msg.delivered as PackedStringArray).has(rcpt):
			done = false
	if done and not deferred:
		_remove(id)
		_log("%s Completed" % id)
	else:
		write_spool(msg)
	if not bounce_id.is_empty():
		await deliver(bounce_id)


## Appends the message to a local mailbox. Returns an errno.
func _deliver_local(msg: Dictionary, r: Dictionary) -> int:
	var vfs := p.machine.vfs
	var path: String = r.mailbox
	var u := p.machine.users.find(str(r.user))
	var mail_group := p.machine.users.find_group("mail")
	var gid := int(mail_group.get("gid", u.get("gid", 0)))
	if not vfs.exists(_root, path):
		vfs.make_dirs(_root, AgoraPath.dirname(path))
		if vfs.write_text(_root, path, "", "/", false, 432) != AgoraErrno.OK: # 0o660
			return vfs.errno
		vfs.chmod(_root, path, 432) # the umask doesn't apply
		vfs.chown(_root, path, int(u.get("uid", 0)), gid)
	var sender: String = msg.sender if not str(msg.sender).is_empty() else "MAILER-DAEMON"
	var text := "From %s %s\n" % [sender, _ctime()]
	text += "Return-path: <%s>\n" % msg.sender
	text += "Envelope-to: %s\n" % r.orig
	text += "Delivery-date: %s\n" % _rfc822_date()
	text += "".join(msg.headers) + "\n"
	var body: String = msg.body
	var lines := body.split("\n")
	for k in lines.size():
		if lines[k].begins_with("From "):
			lines[k] = ">" + lines[k]
	body = "\n".join(lines)
	if not body.is_empty() and not body.ends_with("\n"):
		body += "\n"
	text += body + "\n"
	return vfs.write_text(_root, path, text, "/", true)


## The hosts to try for a remote route, best first: {hosts: [{name, addr,
## pref}]} or {error, status} when there are none.
func _hosts_for(r: Dictionary) -> Dictionary:
	var names: Array = [] # [pref, name]
	if r.has("hosts"):
		for h in str(r.hosts).replace(";", ":").split(":", false):
			names.append([0, h.strip_edges()])
	else:
		var mx: Dictionary = await AgoraResolver.query(p, r.domain, "MX")
		if mx.has("answer"):
			for rr: Dictionary in mx.answer:
				if rr.type == "MX":
					names.append([str(rr.data).get_slice(" ", 0).to_int(), str(rr.data).get_slice(" ", 1).trim_suffix(".")])
		elif mx.error == "AGAIN":
			return {"status": "defer", "error": "host lookup did not complete", "errno": -1}
		elif mx.has("reply") and mx.reply.rcode == "NXDOMAIN":
			return {"status": "fail", "error": "Unrouteable address"}
		if names.is_empty():
			names.append([-1, r.domain]) # no MX: the domain's own address
		names.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var hosts: Array = []
	var again := false
	for n: Array in names:
		var addr := AgoraInet.parse(n[1])
		if addr < 0:
			var a: Dictionary = await AgoraResolver.query(p, n[1], "A")
			if a.has("answer"):
				for rr: Dictionary in a.answer:
					if rr.type == "A":
						addr = AgoraInet.parse(rr.data)
						break
			elif a.error == "AGAIN":
				again = true
		if addr >= 0:
			var h := {"name": n[1], "addr": addr}
			if n[0] >= 0 and not r.has("hosts"):
				h.pref = n[0]
			hosts.append(h)
	if hosts.is_empty():
		if again:
			return {"status": "defer", "error": "host lookup did not complete", "errno": -1}
		if names.size() == 1 and names[0][0] == -1:
			return {"status": "fail", "error": "Unrouteable address"}
		return {"status": "fail", "error": "all relevant MX records point to non-existent hosts"}
	return {"hosts": hosts}


## Sends a message to the recipients of one domain by SMTP. Returns
## {addr: {status: ok|fail|defer, error, host, ip}}.
func _deliver_remote(msg: Dictionary, routes: Array) -> Dictionary:
	var results := {}
	var found := await _hosts_for(routes[0])
	if not found.has("hosts"):
		for r: Dictionary in routes:
			results[r.addr] = found
		return results
	var last := {"status": "defer", "error": "no host to try", "errno": -1}
	for h: Dictionary in found.hosts:
		var ip := AgoraInet.to_str(h.addr)
		var opened: Dictionary = await p.machine.net.tcp.open_connection(p, h.addr, 25)
		if opened.has("error"):
			last = {"status": "defer", "error": AgoraErrno.describe(opened.error), "errno": opened.error}
			continue
		var conn: AgoraTcp.Conn = opened.conn
		var r := await _smtp_session(conn, msg, routes, str(h.name), ip)
		conn.close()
		if r.has("next"):
			last = r.next
			continue
		return r.results
	for r: Dictionary in routes:
		results[r.addr] = last
	return results


func _smtp_session(conn: AgoraTcp.Conn, msg: Dictionary, routes: Array, host: String, ip: String) -> Dictionary:
	var where := "host %s [%s]" % [host, ip]
	var reply := await _read_reply(conn)
	if reply.code == 0:
		return {"next": {"status": "defer", "error": "Remote host %s [%s] closed connection in response to initial connection" % [host, ip], "errno": -18}}
	if reply.code >= 400:
		return {"next": {"status": "defer", "error": "SMTP error from remote mail server after initial connection: %s: %s" % [where, reply.text], "errno": -44}}
	var me := p.machine.hostname
	conn.output.write("EHLO %s\r\n" % me)
	reply = await _read_reply(conn)
	if reply.code >= 500:
		conn.output.write("HELO %s\r\n" % me)
		reply = await _read_reply(conn)
	if reply.code == 0 or reply.code >= 400:
		return {"next": {"status": "defer", "error": "SMTP error from remote mail server after EHLO %s: %s: %s" % [me, where, reply.text], "errno": -44}}
	var results := {}
	conn.output.write("MAIL FROM:<%s>\r\n" % msg.sender)
	reply = await _read_reply(conn)
	if reply.code == 0 or reply.code >= 400:
		var status := "fail" if reply.code >= 500 else "defer"
		for r: Dictionary in routes:
			results[r.addr] = {"status": status, "errno": -44, "error": "SMTP error from remote mail server after MAIL FROM:<%s>:\n%s: %s" % [msg.sender, where, reply.text]}
		conn.output.write("QUIT\r\n")
		return {"results": results}
	var accepted: Array = []
	for r: Dictionary in routes:
		conn.output.write("RCPT TO:<%s>\r\n" % r.addr)
		reply = await _read_reply(conn)
		if reply.code >= 200 and reply.code < 300:
			accepted.append(r)
		else:
			results[r.addr] = {"status": "fail" if reply.code >= 500 else "defer", "errno": -44,
				"error": "SMTP error from remote mail server after RCPT TO:<%s>:\n%s: %s" % [r.addr, where, reply.text]}
	if not accepted.is_empty():
		conn.output.write("DATA\r\n")
		reply = await _read_reply(conn)
		if reply.code == 354:
			var lines := message_text(msg).trim_suffix("\n").split("\n")
			var data := ""
			for line in lines:
				data += ("." + line if line.begins_with(".") else line) + "\r\n"
			conn.output.write(data + ".\r\n")
			reply = await _read_reply(conn)
		for r: Dictionary in accepted:
			if reply.code >= 200 and reply.code < 300:
				results[r.addr] = {"status": "ok", "host": host, "ip": ip}
			else:
				results[r.addr] = {"status": "fail" if reply.code >= 500 else "defer", "errno": -44,
					"error": "SMTP error from remote mail server after end of data:\n%s: %s" % [where, reply.text if reply.code else "connection lost"]}
	conn.output.write("QUIT\r\n")
	await _read_reply(conn)
	return {"results": results}


## One SMTP reply, all its lines: {code, text}; code 0 if the connection
## closed or nothing came in time.
func _read_reply(conn: AgoraTcp.Conn) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(REPLY_TIMEOUT * 1000)
	var stop := func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline
	var lines: PackedStringArray = []
	while true:
		var line: Variant = await conn.input.read_line(stop)
		if line == null:
			return {"code": 0, "text": "\n".join(lines)}
		var text := str(line).trim_suffix("\r")
		lines.append(text)
		if text.length() < 4 or text[3] != "-":
			return {"code": text.left(3).to_int(), "text": "\n".join(lines)}
	return {}


## Sends the "Mail delivery failed" message back to the sender. Returns its id.
func _bounce(msg: Dictionary, failed: Array) -> String:
	var host := p.machine.hostname
	var fail_list: PackedStringArray = []
	var text := "This message was created automatically by mail delivery software.\n\n"
	text += "A message that you sent could not be delivered to one or more of its\n"
	text += "recipients. This is a permanent error. The following address(es) failed:\n\n"
	for f: Dictionary in failed:
		fail_list.append(f.addr)
		text += "  %s\n" % f.addr
		for line in str(f.error).split("\n"):
			text += "    %s\n" % line
	text += "\n------ This is a copy of the message, including all the headers. ------\n\n"
	text += "Return-path: <%s>\n" % msg.sender + message_text(msg)
	var b := new_message()
	b.sender = ""
	b.recipients = PackedStringArray([msg.sender])
	b.headers = [
		"X-Failed-Recipients: %s\n" % ", ".join(fail_list),
		"Auto-Submitted: auto-replied\n",
		"From: Mail Delivery System <Mailer-Daemon@%s>\n" % host,
		"To: %s\n" % msg.sender,
		"Subject: Mail delivery failed: returning message to sender\n",
	]
	b.body = text
	return accept(b, {"user": EXIM_USER, "bounce_of": msg.id})


## A queue run: every message that isn't frozen.
func run_queue() -> void:
	for id in queued_ids():
		if p.is_dead():
			return
		await deliver(id)


# --- the queue -----------------------------------------------------------------

func _list_queue() -> int:
	if not _is_admin():
		p.errln("exim: permission denied")
		return 1
	var now := p.machine.clock.now()
	for id in queued_ids():
		var msg := load_message(id)
		if msg.is_empty():
			continue
		var minutes := int(now - float(msg.time)) / 60
		var age: String
		if minutes > 90:
			var hours := (minutes + 30) / 60
			age = "%2dd" % ((hours + 12) / 24) if hours > 72 else "%2dh" % hours
		else:
			age = "%2dm" % minutes
		var size := text_size(message_text(msg))
		p.outln("%s %s %s <%s>%s" % [age, _size_str(size), id, msg.sender, " *** frozen ***" if msg.frozen else ""])
		for rcpt: String in msg.recipients:
			p.outln(("        D %s" if (msg.delivered as PackedStringArray).has(rcpt) else "          %s") % rcpt)
		p.outln()
	return 0


static func _size_str(size: int) -> String:
	if size < 1024:
		return "%5d" % size
	if size < 10 * 1024:
		return "%4.1fK" % (size / 1024.0)
	if size < 1024 * 1024:
		return "%4dK" % (size / 1024)
	if size < 10 * 1024 * 1024:
		return "%4.1fM" % (size / 1048576.0)
	return "%4dM" % (size / 1048576)


## -M ID...: deliver now; -Mrm ID...: remove from the queue.
func _manage(flag: String, ids: PackedStringArray) -> int:
	if not _is_admin():
		p.errln("exim: permission denied")
		return 1
	var code := 0
	for id in ids:
		var msg := load_message(id)
		if msg.is_empty():
			p.errln("Spool data file for %s does not exist" % id) if flag == "-M" else p.outln("Message %s has been removed or did not exist" % id)
			code = 1
			continue
		if flag == "-Mrm":
			_remove(id)
			_log("%s removed by %s" % [id, p.machine.users.name_of(p.cred.ruid)])
			_log("%s Completed" % id)
			p.outln("Message %s has been removed" % id)
		else:
			await deliver(id, true)
	return code


# --- the daemon ----------------------------------------------------------------

func _daemon(args: PackedStringArray) -> int:
	if not p.cred.is_root():
		p.errln("exim: only root can start the daemon")
		return 1
	var interval := 0.0
	var q_arg := ""
	for a in args:
		if a.begins_with("-q") and a.length() > 2:
			q_arg = a
			interval = _parse_time(a.substr(2))
	var where: PackedStringArray = []
	var addresses_to_use: Array[int] = []
	for item in str(_conf.local_interfaces).replace(";", ":").split(":", false):
		var addr := AgoraInet.parse(item.strip_edges())
		if addr >= 0:
			addresses_to_use.append(addr)
	if addresses_to_use.is_empty():
		addresses_to_use.append(0)
	for addr in addresses_to_use:
		var l := p.machine.net.tcp.listen(p, 25, addr)
		if l == null:
			var msg := "socket bind() to port 25 for address %s failed: %s: daemon abandoned" % [
				AgoraInet.to_str(addr) if addr else "(any IPv4)", AgoraErrno.describe(p.machine.net.tcp.last_error)]
			_log(msg)
			for other in _listeners:
				other.close()
			p.errln("exim: " + msg)
			return 1
		_listeners.append(l)
		where.append("[%s]:25" % AgoraInet.to_str(addr) if addr else "port 25 (IPv4)")
	_log("exim %s daemon started: pid=%d, %slistening for SMTP on %s" % [VERSION, p.pid, q_arg.substr(0) + ", " if not q_arg.is_empty() else "", " ".join(where)])
	for l in _listeners:
		_accept_loop(l)
	var next_run := Time.get_ticks_msec()
	while p.is_running():
		if interval > 0.0 and Time.get_ticks_msec() >= next_run:
			next_run = Time.get_ticks_msec() + int(interval * 1000.0)
			_log("Start queue run: pid=%d" % p.pid)
			await run_queue()
			_log("End queue run: pid=%d" % p.pid)
		await p.sleep(1.0)
	for l in _listeners:
		l.close()
	return 0


## "30m", "1h", "90s", "2d" in seconds.
static func _parse_time(text: String) -> float:
	var total := 0.0
	var num := ""
	for c in text:
		if c.is_valid_int():
			num += c
			continue
		var n := num.to_int()
		num = ""
		match c:
			"s": total += n
			"m": total += n * 60
			"h": total += n * 3600
			"d": total += n * 86400
			"w": total += n * 604800
	if not num.is_empty():
		total += num.to_int()
	return total


func _accept_loop(l: AgoraTcp.Listener) -> void:
	while p.is_running():
		var conn: AgoraTcp.Conn = await l.accept(p.is_dead)
		if conn == null:
			return
		_smtp_server(conn)


func _send(conn: AgoraTcp.Conn, text: String) -> void:
	conn.output.write(text.replace("\n", "\r\n") + "\r\n")


## May this client send mail to other domains through us?
func _may_relay(addr: int) -> bool:
	var nets: PackedStringArray = ["127.0.0.1"]
	nets.append_array(_conf.relay_nets)
	for n in nets:
		var c := AgoraInet.parse_cidr(n.strip_edges())
		if not c.is_empty() and AgoraInet.in_subnet(addr, c[0], c[1]):
			return true
	return false


## One SMTP conversation with a client.
func _smtp_server(conn: AgoraTcp.Conn) -> void:
	var host := p.machine.hostname
	var ip := AgoraInet.to_str(conn.remote_addr)
	var name := ""
	if conn.remote_addr != AgoraInet.parse("127.0.0.1"):
		name = await AgoraResolver.reverse(p, conn.remote_addr)
	else:
		name = "localhost"
	_send(conn, "220 %s ESMTP Exim %s %s" % [host, VERSION, _rfc822_date()])
	var helo := ""
	var protocol := "smtp"
	var sender: Variant = null
	var rcpts: PackedStringArray = []
	var deadline := [Time.get_ticks_msec() + int(SMTP_TIMEOUT * 1000)]
	var stop := func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline[0]
	while p.is_running():
		var line: Variant = await conn.input.read_line(stop)
		if line == null:
			if Time.get_ticks_msec() > deadline[0]:
				_send(conn, "421 %s SMTP incoming data timeout - closing connection." % host)
				_log("SMTP command timeout on connection from %s" % client_desc(name, helo, ip).replace("H=", ""))
			else:
				_log("unexpected disconnection while reading SMTP command from %s" % client_desc(name, helo, ip).replace("H=", "").strip_edges())
			break
		deadline[0] = Time.get_ticks_msec() + int(SMTP_TIMEOUT * 1000)
		var text := str(line).trim_suffix("\r")
		var verb := text.get_slice(" ", 0).to_upper()
		var arg := text.substr(verb.length()).strip_edges()
		if verb.begins_with("MAIL") or verb.begins_with("RCPT"):
			verb = text.get_slice(":", 0).to_upper().replace(" ", "")
			arg = text.substr(text.find(":") + 1).strip_edges() if text.contains(":") else ""
		match verb:
			"HELO", "EHLO":
				if arg.is_empty() or arg.contains(" "):
					_send(conn, "501 Syntactically invalid %s argument(s)" % verb)
					continue
				helo = arg
				protocol = "esmtp" if verb == "EHLO" else "smtp"
				sender = null
				rcpts.clear()
				var greeting := "%s Hello %s [%s]" % [host, name if not name.is_empty() else helo, ip]
				if verb == "HELO":
					_send(conn, "250 " + greeting)
				else:
					_send(conn, "250-%s\n250-SIZE 52428800\n250-PIPELINING\n250 HELP" % greeting)
			"MAILFROM":
				if sender != null:
					_send(conn, "503 sender already given")
					continue
				var addr: Variant = _angle(arg)
				if addr == null:
					_send(conn, "501 %s: missing or malformed local part" % arg)
					continue
				if not str(addr).is_empty() and not str(addr).contains("@"):
					_send(conn, "501 <%s>: sender address must contain a domain" % addr)
					continue
				sender = addr
				_send(conn, "250 OK")
			"RCPTTO":
				if sender == null:
					_send(conn, "503 sender not yet given")
					continue
				var addr: Variant = _angle(arg)
				if addr == null or str(addr).is_empty():
					_send(conn, "501 %s: missing or malformed local part" % arg)
					continue
				if not str(addr).contains("@"):
					_send(conn, "501 <%s>: recipient address must contain a domain" % addr)
					continue
				var domain := str(addr).substr(str(addr).rfind("@") + 1)
				var refusal := ""
				if _is_local_domain(domain):
					var routes := route(str(addr))
					if routes.any(func(r: Dictionary) -> bool: return r.kind == "fail"):
						refusal = "Unrouteable address"
						if str(addr).get_slice("@", 0).to_lower() == "postmaster":
							refusal = ""
				elif not _may_relay(conn.remote_addr):
					refusal = "relay not permitted"
				if not refusal.is_empty():
					_send(conn, "550 " + refusal)
					_log("%s F=<%s> rejected RCPT <%s>: %s" % [client_desc(name, helo, ip), sender, addr, refusal], true)
					continue
				rcpts.append(str(addr))
				_send(conn, "250 Accepted")
			"DATA":
				if rcpts.is_empty():
					_send(conn, "503 valid RCPT command must precede DATA")
					continue
				_send(conn, "354 Enter message, ending with \".\" on a line by itself")
				var lines: PackedStringArray = []
				var complete := false
				while true:
					var l: Variant = await conn.input.read_line(stop)
					if l == null:
						break
					var t := str(l).trim_suffix("\r")
					if t == ".":
						complete = true
						break
					lines.append(t.substr(1) if t.begins_with(".") else t)
				if not complete:
					_log("SMTP connection from %s lost while reading message data" % client_desc(name, helo, ip).replace("H=", "").strip_edges())
					break
				var parsed := parse_text("\n".join(lines) + "\n")
				var msg := new_message()
				msg.sender = sender
				msg.recipients = rcpts.duplicate()
				msg.headers = parsed.headers
				msg.body = parsed.body
				var id := accept(msg, {"ip": ip, "port": conn.remote_port, "name": name, "helo": helo, "protocol": protocol})
				_send(conn, "250 OK id=" + id)
				sender = null
				rcpts.clear()
				deliver(id)
			"RSET":
				sender = null
				rcpts.clear()
				_send(conn, "250 Reset OK")
			"NOOP":
				_send(conn, "250 OK")
			"VRFY", "EXPN":
				_send(conn, "252 Administrative prohibition" if verb == "VRFY" else "550 Administrative prohibition")
			"HELP":
				_send(conn, "214-Commands supported:\n214 AUTH HELO EHLO MAIL RCPT DATA NOOP QUIT RSET HELP")
			"QUIT":
				_send(conn, "221 %s closing connection" % host)
				break
			"":
				_send(conn, "500 unrecognized command")
			_:
				_send(conn, "500 unrecognized command")
	conn.close()


## The address in "<addr>" (or a bare one), with ESMTP parameters dropped.
## null if it is malformed.
static func _angle(arg: String) -> Variant:
	arg = arg.strip_edges()
	if arg.begins_with("<"):
		var end := arg.find(">")
		if end < 0:
			return null
		return arg.substr(1, end - 1).strip_edges()
	var bare := arg.get_slice(" ", 0)
	return bare if not bare.is_empty() else null
