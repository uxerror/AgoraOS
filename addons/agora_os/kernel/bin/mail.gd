extends AgoraProgram
## mail (bsd-mailx 8.1.2): send and read mail.
##
##   mail [-s SUBJECT] [-c CC] [-b BCC] ADDRESS...   send: the text comes
##                         from standard input, up to "." or end of input
##   mail [-N] [-f [FILE]] [-u USER]                 read /var/mail/$USER
##                         (or FILE, ~/mbox by default with -f)
##   mail -e               exit 0 if there is mail, 1 if not
##
## Reading shows a list of the messages and takes commands at the "&"
## prompt: a number or Enter shows a message; p, n, -, d, u, h, f, r
## (reply to all), R (to the sender), s FILE, m ADDRESS, q (read messages
## go to ~/mbox, the rest stays), x (leave everything as it was), ?.
## /etc/mail.rc sets the options (ask, askcc, dot, append) and the header
## lines hidden when a message is shown (ignore).
##
## Messages go out through /usr/sbin/sendmail.

const VERSION := "8.1.2 01/15/2001"
const SENDMAIL := "/usr/sbin/sendmail"
const HELP := """    Mail   Commands
t <message list>		type messages
n			goto and type next message
e <message list>		edit messages
f <message list>		give head lines of messages
d <message list>		delete messages
s <message list> file		append messages to file
u <message list>		undelete messages
R <message list>		reply to message senders
r <message list>		reply to message senders and all recipients
pre <message list>		make messages go back to /var/mail
m <user list>		mail to specific users
q			quit, saving unresolved messages in mbox
x			quit, do not remove system mailbox
h			print out active message headers
!			shell escape
cd [directory]		chdir to directory or home if none given

A <message list> consists of integers, ranges of same, or other criteria
separated by spaces.  If omitted, Mail uses the last message typed.

A <user list> consists of user names or aliases separated by spaces.
Aliases are defined in .mailrc in your home directory.
"""

var p: AgoraProcess
var _opts := {}
var _ignore: PackedStringArray = []
var _interactive := false
## The mailbox being read and what it held when it was read.
var _file := ""
var _system_box := false
var _original := ""
## The messages: {from_line, headers (Array of "Name: value\n"), body,
## lines, size, new, unread, read, deleted, saved, preserved}.
var _msgs: Array = []
var _cur := 0
var _shown := false


func summary() -> String:
	return "send and receive mail"


func usage() -> String:
	return "usage: mail [-eiInNv] [-s subject] [-c cc-addr] [-b bcc-addr] to-addr ...\n       mail [-eiInNv] -f [name]\n       mail [-eiInNv] [-u user]"


func main(proc: AgoraProcess) -> int:
	p = proc
	_interactive = is_terminal(p)
	_read_rc()
	var subject: Variant = null
	var cc: PackedStringArray = []
	var bcc: PackedStringArray = []
	var to: PackedStringArray = []
	var file := ""
	var use_file := false
	var check := false
	var no_headers := false
	var verbose := false
	var k := 1
	while k < p.argv.size():
		var a := p.argv[k]
		k += 1
		if a == "--":
			to.append_array(p.argv.slice(k))
			break
		if not a.begins_with("-") or a == "-":
			to.append(a)
			continue
		var j := 1
		while j < a.length():
			var c := a[j]
			j += 1
			if c in ["s", "c", "b", "u"]:
				var value := a.substr(j)
				if value.is_empty():
					if k >= p.argv.size():
						p.errln("mail: option requires an argument -- %s" % c)
						return p.fail(usage(), 1)
					value = p.argv[k]
					k += 1
				match c:
					"s": subject = value
					"c": cc.append_array(_split_list(value))
					"b": bcc.append_array(_split_list(value))
					"u": file = "/var/mail/" + value
				break
			match c:
				"f":
					use_file = true
				"e":
					check = true
				"N":
					no_headers = true
				"v":
					verbose = true
				"i", "I", "n":
					pass
				_:
					p.errln("mail: illegal option -- %s" % c)
					return p.fail(usage(), 1)
	if use_file:
		file = to[0] if not to.is_empty() else p.home() + "/mbox"
		to.clear()
	if not to.is_empty():
		var head := {"to": to, "subject": subject, "cc": cc, "bcc": bcc}
		return await _compose(head, verbose)
	if file.is_empty():
		file = "/var/mail/" + p.user_name()
		_system_box = true
	if check:
		return 0 if _has_mail(file) else 1
	return await _read_mode(file, no_headers)


func _read_rc() -> void:
	_opts = {"ask": false, "askcc": false, "dot": false, "append": false}
	for path in ["/etc/mail.rc", p.home() + "/.mailrc"]:
		for line in p.read_text(path).split("\n", false):
			var words := line.strip_edges().split(" ", false)
			if words.is_empty() or words[0].begins_with("#"):
				continue
			match words[0]:
				"set", "se":
					for w in words.slice(1):
						_opts[w.get_slice("=", 0)] = w.get_slice("=", 1) if w.contains("=") else true
				"unset", "uns":
					for w in words.slice(1):
						_opts.erase(w)
				"ignore", "ig", "discard":
					for w in words.slice(1):
						_ignore.append(w.to_lower())


func _opt(name: String) -> bool:
	return _opts.has(name) and _opts[name] != false


static func _split_list(text: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for part in text.replace(",", " ").split(" ", false):
		out.append(part)
	return out


# --- sending -------------------------------------------------------------------

## Collects a message and hands it to sendmail. [param head] has to,
## subject (null if not given), cc, bcc.
func _compose(head: Dictionary, verbose: bool = false) -> int:
	if head.subject == null and _interactive and (_opt("ask") or _opt("asksub")):
		p.out("Subject: ")
		var s: Variant = await p.read_line()
		head.subject = str(s) if s != null else ""
	var body := ""
	while true:
		var line: Variant = await p.read_line()
		if line == null:
			if _interactive:
				p.outln("EOT")
			break
		var text := str(line)
		if text == "." and (_opt("dot") or not _interactive):
			break
		if _interactive and text.begins_with("~") and text.length() >= 2:
			var arg := text.substr(2).strip_edges()
			match text[1]:
				".":
					break
				"s":
					head.subject = arg
					continue
				"t":
					head.to = (head.to as PackedStringArray) + _split_list(arg)
					continue
				"c":
					head.cc = (head.cc as PackedStringArray) + _split_list(arg)
					continue
				"b":
					head.bcc = (head.bcc as PackedStringArray) + _split_list(arg)
					continue
				"p":
					p.outln("-------\nMessage contains:")
					p.out(_head_text(head, true))
					p.out(body)
					p.outln("(continue)")
					continue
				"q", "x":
					if text[1] == "q":
						p.write_text(p.home() + "/dead.letter", _head_text(head, false) + "\n" + body, true)
					return 1
				"~":
					text = text.substr(1)
				"?":
					p.outln("-------------------- ~ ESCAPES ----------------------------\n~~\t\tQuote a single tilde\n~b users\tAdd users to \"blind\" cc list\n~c users\tAdd users to cc list\n~p\t\tPrint the message buffer\n~q\t\tQuit, save letter in $HOME/dead.letter\n~s subject\tSet subject\n~t users\tAdd users to To list\n~x\t\tQuit, do not save letter\n----------------------------------------------------------")
					continue
				_:
					p.outln("Unknown tilde escape.")
					continue
		body += text + "\n"
	if _interactive and _opt("askcc"):
		p.out("Cc: ")
		var more: Variant = await p.read_line()
		if more != null:
			head.cc = (head.cc as PackedStringArray) + _split_list(str(more))
	if head.subject == null:
		head.subject = ""
	if body.is_empty():
		p.outln("No message, no subject; hope that's ok" if str(head.subject).is_empty() else "Null message body; hope that's ok")
	var rcpts: PackedStringArray = []
	for list in [head.to, head.cc, head.bcc]:
		rcpts.append_array(list)
	var argv := PackedStringArray([SENDMAIL, "-i"])
	if verbose:
		argv.append("-v")
	argv.append("--")
	argv.append_array(rcpts)
	var text := _head_text(head, false) + "\n" + body
	var child := p.spawn(argv, {"stdin": AgoraStream.from_text(text)})
	if child == null:
		p.errln("%s: %s" % [SENDMAIL, AgoraErrno.describe(p.errno)])
		p.write_text(p.home() + "/dead.letter", text, true)
		p.errln(". . . message not sent.")
		return 1
	var code := await child.wait()
	return 0 if code == 0 else 1


func _head_text(head: Dictionary, with_bcc: bool) -> String:
	var out := ""
	if not (head.to as PackedStringArray).is_empty():
		out += "To: %s\n" % ", ".join(head.to)
	if head.subject != null and not str(head.subject).is_empty():
		out += "Subject: %s\n" % head.subject
	if not (head.cc as PackedStringArray).is_empty():
		out += "Cc: %s\n" % ", ".join(head.cc)
	if with_bcc and not (head.bcc as PackedStringArray).is_empty():
		out += "Bcc: %s\n" % ", ".join(head.bcc)
	return out


# --- the mailbox ---------------------------------------------------------------

func _has_mail(file: String) -> bool:
	return not _parse(p.read_text(file)).is_empty()


## The messages of an mbox file, with what this session does to them.
static func _parse(text: String) -> Array:
	var out := AgoraMbox.parse(text)
	for m: Dictionary in out:
		var status: String = m.status
		m.merge({"new": not status.contains("O"), "unread": status.contains("O") and not status.contains("R"),
			"read": status.contains("R"), "deleted": false, "saved": false, "preserved": false, "touched": false})
	return out


static func _field(headers: Array, name: String) -> String:
	return AgoraMbox.field(headers, name)


static func _skin(text: String) -> String:
	return AgoraMbox.skin(text)


func _sender(m: Dictionary) -> String:
	var from := _field(m.headers, "from")
	if from.is_empty():
		from = _field(m.headers, "sender")
	if from.is_empty():
		from = str(m.from_line).get_slice(" ", 1)
	return _skin(from)


## The date part of the From line: "Sat Oct 18 21:30:05 2003".
static func _from_date(m: Dictionary) -> String:
	var line: String = m.from_line
	var parts := line.split(" ", false)
	return " ".join(parts.slice(2)) if parts.size() > 2 else ""


static func _mbox_text(m: Dictionary, status: String) -> String:
	return AgoraMbox.to_text(m, status)


func _read_mode(file: String, no_headers: bool) -> int:
	_file = file
	_original = p.read_text(file)
	if p.errno != AgoraErrno.OK and p.errno != AgoraErrno.ENOENT:
		return p.fail("%s: %s" % [file, AgoraErrno.describe(p.errno)], 1)
	_msgs = _parse(_original)
	if _msgs.is_empty():
		if _system_box:
			p.errln("No mail for %s" % file.get_file())
			return 1
		return p.fail("%s: %s" % [file, "No such file or directory" if not p.exists(file) else "empty mailbox"], 1)
	p.outln("Mail version %s.  Type ? for help." % VERSION)
	# Start at the first new message.
	_cur = 0
	for k in _msgs.size():
		if _msgs[k].new or _msgs[k].unread:
			_cur = k
			break
	_summary_line()
	if not no_headers:
		_headers()
	while p.is_running():
		if _interactive:
			p.out("& ")
		var line: Variant = await p.read_line()
		if line == null:
			return _quit()
		var text := str(line).strip_edges()
		var verb := text.get_slice(" ", 0)
		var arg := text.substr(verb.length()).strip_edges()
		if text.is_empty():
			_next()
			continue
		if verb.is_valid_int():
			var n := verb.to_int()
			if n < 1 or n > _msgs.size():
				p.outln("%d: Invalid message number" % n)
			elif _msgs[n - 1].deleted:
				p.outln("%d: Inappropriate message" % n)
			else:
				_cur = n - 1
				_type([_cur])
			continue
		match verb:
			"p", "print", "t", "type", "P", "T", "Print", "Type":
				_type(_list(arg))
			"n", "next", "+":
				_next()
			"-":
				var k := _cur - 1
				while k >= 0 and _msgs[k].deleted:
					k -= 1
				if k < 0:
					p.outln("Referencing before 1")
				else:
					_cur = k
					_type([k])
			"d", "delete", "dp", "dt":
				for k in _list(arg):
					_msgs[k].deleted = true
					_msgs[k].touched = true
				_advance()
				if verb in ["dp", "dt"]:
					_next()
			"u", "undelete":
				for k in _list(arg, true):
					_msgs[k].deleted = false
					_cur = k
			"h", "headers", "f", "from":
				if verb.begins_with("f") and not arg.is_empty():
					for k in _list(arg):
						p.outln(_head_line(k))
				else:
					_headers()
			"pre", "preserve", "ho", "hold":
				for k in _list(arg):
					_msgs[k].preserved = true
			"s", "save", "w", "write":
				_save(arg, verb.begins_with("w"))
			"r", "reply", "respond", "R", "Reply", "Respond":
				var list := _list("")
				if not list.is_empty():
					await _reply(list[0], verb[0] == "r")
			"m", "mail":
				if arg.is_empty():
					p.outln("No recipients specified")
				else:
					await _compose({"to": _split_list(arg), "subject": null, "cc": PackedStringArray(), "bcc": PackedStringArray()})
			"q", "quit":
				return _quit()
			"x", "ex", "exit", "xit":
				return 0
			"?", "help":
				p.out(HELP)
			"=":
				p.outln(str(_cur + 1))
			_:
				p.outln("Unknown command: \"%s\"" % verb)
	return 0


func _summary_line() -> void:
	var new := 0
	var unread := 0
	var deleted := 0
	for m: Dictionary in _msgs:
		if m.deleted:
			deleted += 1
		elif m.new:
			new += 1
		elif m.unread:
			unread += 1
	var text := "\"%s\": %d message%s" % [_file, _msgs.size(), "" if _msgs.size() == 1 else "s"]
	if new > 0:
		text += " %d new" % new
	if unread > 0:
		text += " %d unread" % unread
	if deleted > 0:
		text += " %d deleted" % deleted
	p.outln(text)


func _head_line(k: int) -> String:
	var m: Dictionary = _msgs[k]
	var mark := " "
	if m.deleted:
		mark = "D"
	elif m.saved:
		mark = "*"
	elif m.preserved:
		mark = "P"
	elif m.read:
		mark = " "
	elif m.new:
		mark = "N"
	elif m.unread:
		mark = "U"
	var name := _sender(m).left(20)
	var date := _from_date(m).left(16)
	var count := "%3d/%-5d" % [m.lines, m.size]
	var line := "%s%s%3d %-20s  %16s %s %s" % [">" if k == _cur else " ", mark, k + 1, name, date, count, _field(m.headers, "subject")]
	return line.left(79).strip_edges(false, true)


func _headers() -> void:
	# A screenful around the current message.
	var start := (_cur / 18) * 18
	for k in range(start, mini(start + 18, _msgs.size())):
		if not _msgs[k].deleted:
			p.outln(_head_line(k))


## Message numbers in [param arg] (0-based), or the current one.
func _list(arg: String, deleted_too: bool = false) -> Array[int]:
	var out: Array[int] = []
	if arg.is_empty():
		if _cur < _msgs.size() and (deleted_too or not _msgs[_cur].deleted):
			out.append(_cur)
		else:
			p.outln("No applicable messages")
		return out
	for word in arg.split(" ", false):
		var lo := -1
		var hi := -1
		match word:
			"*":
				lo = 1
				hi = _msgs.size()
			"$":
				lo = _msgs.size()
				hi = lo
			".":
				lo = _cur + 1
				hi = lo
			"^":
				lo = 1
				hi = 1
			_:
				if word.contains("-") and word.get_slice("-", 0).is_valid_int() and word.get_slice("-", 1).is_valid_int():
					lo = word.get_slice("-", 0).to_int()
					hi = word.get_slice("-", 1).to_int()
				elif word.is_valid_int():
					lo = word.to_int()
					hi = lo
				else:
					# A name: the messages from that sender.
					for k in _msgs.size():
						if _sender(_msgs[k]).to_lower().contains(word.to_lower()) and (deleted_too or not _msgs[k].deleted):
							out.append(k)
					continue
		for n in range(lo, hi + 1):
			if n < 1 or n > _msgs.size():
				p.outln("%d: Invalid message number" % n)
				return []
			if deleted_too or not _msgs[n - 1].deleted:
				out.append(n - 1)
	if out.is_empty():
		p.outln("No applicable messages")
	return out


func _type(list: Array[int]) -> void:
	for k in list:
		var m: Dictionary = _msgs[k]
		_cur = k
		_shown = true
		m.read = true
		m.new = false
		m.unread = false
		m.touched = true
		p.outln("Message %d:" % (k + 1))
		p.outln(m.from_line)
		for h: String in m.headers:
			if not _ignore.has(h.get_slice(":", 0).to_lower()):
				p.out(h)
		p.outln()
		p.out(m.body)


func _next() -> void:
	if not _shown and _cur < _msgs.size() and not _msgs[_cur].deleted:
		_type([_cur])
		return
	var k := _cur + 1
	while k < _msgs.size() and _msgs[k].deleted:
		k += 1
	if k >= _msgs.size():
		p.outln("At EOF")
		return
	_type([k])


## After a delete: the next message that is left becomes current.
func _advance() -> void:
	var k := _cur
	while k < _msgs.size() and _msgs[k].deleted:
		k += 1
	if k >= _msgs.size():
		k = _cur
		while k >= 0 and _msgs[k].deleted:
			k -= 1
	if k >= 0:
		_cur = k
	_shown = false


func _save(arg: String, body_only: bool) -> void:
	var words := arg.split(" ", false)
	var file := p.home() + "/mbox"
	if not words.is_empty():
		file = words[-1]
		words.resize(words.size() - 1)
	var list := _list(" ".join(words))
	if list.is_empty():
		return
	file = file.replace("~", p.home()) if file.begins_with("~") else file
	var existed := p.exists(file)
	var text := ""
	var lines := 0
	var size := 0
	for k in list:
		var m: Dictionary = _msgs[k]
		text += str(m.body) if body_only else _mbox_text(m, "RO")
		lines += int(m.lines)
		size += int(m.size)
	if p.write_text(file, text, true) != AgoraErrno.OK:
		p.outln("%s: %s" % [file, AgoraErrno.describe(p.errno)])
		return
	for k in list:
		_msgs[k].saved = true
		_msgs[k].touched = true
	p.outln("\"%s\" %s %d/%d" % [file, "[Appended]" if existed else "[New file]", lines, size])


func _reply(k: int, to_all: bool) -> void:
	var m: Dictionary = _msgs[k]
	var reply_to := _field(m.headers, "reply-to")
	var to := PackedStringArray([_skin(reply_to) if not reply_to.is_empty() else _sender(m)])
	var cc: PackedStringArray = []
	if to_all:
		var me := p.user_name()
		for a in _field(m.headers, "to").split(",", false):
			a = _skin(a)
			if not a.is_empty() and a.get_slice("@", 0) != me and not to.has(a):
				to.append(a)
		for a in _field(m.headers, "cc").split(",", false):
			a = _skin(a)
			if not a.is_empty() and a.get_slice("@", 0) != me:
				cc.append(a)
	var subject := _field(m.headers, "subject")
	if not subject.to_lower().begins_with("re:"):
		subject = "Re: " + subject
	var head := {"to": to, "subject": subject, "cc": cc, "bcc": PackedStringArray()}
	p.out(_head_text(head, false))
	await _compose(head)


## Leaves the mailbox: read messages go to ~/mbox, the rest stays, and mail
## that came in meanwhile is kept.
func _quit() -> int:
	var current := p.read_text(_file)
	var arrived := current.substr(_original.length()) if current.begins_with(_original) else ""
	var keep := ""
	var to_mbox := ""
	var held := 0
	var moved := 0
	var mbox := p.home() + "/mbox"
	var untouched := _msgs.all(func(m: Dictionary) -> bool: return not m.touched and not m.new)
	for m: Dictionary in _msgs:
		if m.deleted:
			continue
		if _system_box and m.saved and not m.preserved:
			continue
		if _system_box and m.read and not m.preserved and _file != mbox:
			to_mbox += _mbox_text(m, "RO")
			moved += 1
			continue
		held += 1
		keep += _mbox_text(m, "RO" if m.read else "O")
	if untouched and arrived.is_empty() and _system_box:
		p.outln("Held %d message%s in %s" % [held, "" if held == 1 else "s", _file])
		return 0
	if not to_mbox.is_empty():
		p.write_text(mbox, to_mbox, true, AgoraStat.MODE_PRIVATE_FILE)
		p.outln("Saved %d message%s in %s" % [moved, "" if moved == 1 else "s", mbox])
	p.write_text(_file, keep + arrived)
	if not arrived.is_empty():
		p.outln("New mail has arrived.")
	if _system_box:
		if held > 0:
			p.outln("Held %d message%s in %s" % [held, "" if held == 1 else "s", _file])
	else:
		p.outln("\"%s\" %s" % [_file, "removed" if keep.is_empty() else "complete"])
	return 0
