extends AgoraProgram
## ircd: an IRC server in the manner of ircd-hybrid 7.0 (RFC 1459 and
## 2812). Clients register with NICK and USER, get the welcome numerics and
## the MOTD, join channels (#name; the first one in is a channel operator;
## modes +n and +t), talk with PRIVMSG and NOTICE, and use TOPIC, NAMES,
## LIST, WHO, WHOIS, AWAY, MODE, KICK, INVITE, PING, ISON and QUIT.
##
## /etc/ircd-hybrid/ircd.conf is in hybrid's block syntax; what is read:
## serverinfo { name, description, network_name }, listen { port },
## admin { email }. The MOTD is /etc/ircd-hybrid/ircd.motd. Connections
## are logged to daemon.

const VERSION := "hybrid-7.0.3"
const CONF := "/etc/ircd-hybrid/ircd.conf"
const MOTD := "/etc/ircd-hybrid/ircd.motd"
const NICKLEN := 9
const TOPICLEN := 160
const IDLE_TIMEOUT := 900.0

var p: AgoraProcess
var _conf := {}
## nick (lower) -> client {nick, user, host, real, conn, channels, away,
## modes, signon, last}
var _clients := {}
## channel (lower) -> {name, topic, topic_by, topic_at, modes, members:
## {nick lower: "@" or ""}, invites, created}
var _channels := {}
var _started := 0


func summary() -> String:
	return "an Internet Relay Chat server"


func usage() -> String:
	return "usage: ircd [-f CONFIG]"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "f")
	_conf = _read_conf(a.value("f", CONF))
	var listener := p.machine.net.tcp.listen(p, int(_conf.port))
	if listener == null:
		return p.fail("ircd: cannot listen on port %d: %s" % [_conf.port, AgoraErrno.describe(p.machine.net.tcp.last_error)], 1)
	_started = p.machine.clock.now_int()
	_log("Server Ready: %s (%s) on port %d" % [_conf.name, VERSION, _conf.port])
	while p.is_running():
		var conn: AgoraTcp.Conn = await listener.accept(p.is_dead)
		if conn == null:
			break
		_session(conn)
	listener.close()
	return 0


func _read_conf(path: String) -> Dictionary:
	var c := {"name": p.machine.hostname, "network": "AgoraNet", "description": "AgoraOS IRC server", "port": AgoraIrc.PORT, "admin": "root@" + p.machine.hostname}
	var keys := {"name": "name", "network_name": "network", "description": "description", "port": "port", "email": "admin"}
	var text := ""
	for line in p.read_text(path).split("\n"):
		text += line.get_slice("#", 0) + "\n"
	var seen := {}
	var re := RegEx.create_from_string("(\\w+)\\s*=\\s*(\"([^\"]*)\"|[^;\\s]+)\\s*;")
	for m in re.search_all(text):
		var key := m.get_string(1)
		if keys.has(key) and not seen.has(key):
			seen[key] = true
			var value := m.get_string(3) if m.get_string(2).begins_with("\"") else m.get_string(2)
			c[keys[key]] = value.to_int() if key == "port" else value
	return c


func _log(message: String) -> void:
	p.machine.log_event("daemon", "ircd[%d]" % p.pid, message)


# --- talking to clients --------------------------------------------------------

func _send(c: Dictionary, line: String) -> void:
	var conn: AgoraTcp.Conn = c.conn
	if conn.is_open() and not conn.write_closed:
		conn.output.write(line + "\r\n")


## A numeric reply: ":server 001 nick ...".
func _num(c: Dictionary, code: String, text: String) -> void:
	_send(c, ":%s %s %s %s" % [_conf.name, code, c.nick if not str(c.nick).is_empty() else "*", text])


func _mask(c: Dictionary) -> String:
	return "%s!%s@%s" % [c.nick, c.user, c.host]


## Sends [param line] to everyone on [param chan] (but [param skip]).
func _to_channel(chan: Dictionary, line: String, skip: String = "") -> void:
	for n: String in chan.members:
		if n != skip and _clients.has(n):
			_send(_clients[n], line)


## Sends [param line] once to everyone sharing a channel with [param c].
func _to_neighbours(c: Dictionary, line: String) -> void:
	var told := {str(c.nick).to_lower(): true}
	for ch: String in c.channels:
		for n: String in _channels[ch].members:
			if not told.has(n) and _clients.has(n):
				told[n] = true
				_send(_clients[n], line)


static func _valid_nick(nick: String) -> bool:
	if nick.is_empty() or nick.length() > NICKLEN:
		return false
	var first := nick.unicode_at(0)
	if (first >= 0x30 and first <= 0x39) or nick[0] == "-":
		return false
	for ch in nick:
		var u := ch.unicode_at(0)
		if not ((u >= 0x41 and u <= 0x7D) or (u >= 0x30 and u <= 0x39) or ch == "-"):
			return false
	return true


# --- a connection --------------------------------------------------------------

func _session(conn: AgoraTcp.Conn) -> void:
	var host := AgoraInet.to_str(conn.remote_addr)
	var name: String = await AgoraResolver.reverse(p, conn.remote_addr)
	if not name.is_empty():
		host = name
	var c := {"nick": "", "user": "", "host": host, "real": "", "conn": conn, "channels": [], "away": "", "modes": "",
		"signon": p.machine.clock.now_int(), "last": p.machine.clock.now_int(), "registered": false}
	_send(c, ":%s NOTICE AUTH :*** Looking up your hostname..." % _conf.name)
	_send(c, ":%s NOTICE AUTH :*** %s" % [_conf.name, "Found your hostname" if not name.is_empty() else "Couldn't look up your hostname"])
	var deadline := [Time.get_ticks_msec() + int(IDLE_TIMEOUT * 1000)]
	var stop := func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline[0]
	var reason := "Connection closed"
	while p.is_running():
		var raw: Variant = await conn.input.read_line(stop)
		if raw == null:
			reason = "Ping timeout" if Time.get_ticks_msec() > deadline[0] else "Remote host closed the connection"
			break
		deadline[0] = Time.get_ticks_msec() + int(IDLE_TIMEOUT * 1000)
		var m := AgoraIrc.parse(str(raw))
		if m.cmd.is_empty():
			continue
		if m.cmd == "QUIT":
			reason = "Quit: " + (m.params[0] if not m.params.is_empty() else "")
			_send(c, "ERROR :Closing Link: %s (%s)" % [host, reason])
			break
		if not c.registered:
			_register_step(c, m)
		else:
			c.last = p.machine.clock.now_int()
			_command(c, m)
	_gone(c, reason)
	conn.close()


func _register_step(c: Dictionary, m: Dictionary) -> void:
	var params: PackedStringArray = m.params
	match m.cmd:
		"NICK":
			if params.is_empty():
				_num(c, "431", ":No nickname given")
				return
			var nick := params[0]
			if not _valid_nick(nick):
				_num(c, "432", "%s :Erroneous Nickname" % nick)
				return
			if _clients.has(nick.to_lower()):
				_num(c, "433", "%s :Nickname is already in use." % nick)
				return
			c.nick = nick
		"USER":
			if params.size() < 4:
				_num(c, "461", "USER :Not enough parameters")
				return
			c.user = params[0].left(10)
			c.real = params[3]
		"PING":
			_send(c, ":%s PONG %s :%s" % [_conf.name, _conf.name, params[0] if not params.is_empty() else ""])
			return
		"PASS", "CAP":
			return
		_:
			_num(c, "451", "%s :You have not registered" % m.cmd)
			return
	if not str(c.nick).is_empty() and not str(c.user).is_empty():
		if _clients.has(str(c.nick).to_lower()):
			_num(c, "433", "%s :Nickname is already in use." % c.nick)
			c.nick = ""
			return
		c.registered = true
		_clients[str(c.nick).to_lower()] = c
		_log("Client connecting: %s (%s@%s)" % [c.nick, c.user, c.host])
		_welcome(c)


func _welcome(c: Dictionary) -> void:
	_num(c, "001", ":Welcome to the %s Internet Relay Chat Network %s" % [_conf.network, c.nick])
	_num(c, "002", ":Your host is %s[%s/%d], running version %s" % [_conf.name, _conf.name, _conf.port, VERSION])
	_num(c, "003", ":This server was created %s" % p.machine.clock.format_long(_started))
	_num(c, "004", "%s %s oOiwszcrkfydnxbauglZCD biklmnopstveIh bkloveIh" % [_conf.name, VERSION])
	_num(c, "005", "WALLCHOPS KNOCK EXCEPTS INVEX MODES=4 MAXCHANNELS=25 MAXBANS=25 MAXTARGETS=4 NICKLEN=%d TOPICLEN=%d KICKLEN=160 :are supported by this server" % [NICKLEN, TOPICLEN])
	_num(c, "005", "CHANTYPES=#& PREFIX=(ov)@+ CHANMODES=eIb,k,l,imnpst NETWORK=%s CASEMAPPING=rfc1459 CALLERID :are supported by this server" % _conf.network)
	_lusers(c)
	_motd(c)
	c.modes = "i"
	_send(c, ":%s MODE %s :+i" % [c.nick, c.nick])


func _lusers(c: Dictionary) -> void:
	_num(c, "251", ":There are %d users and 0 invisible on 1 servers" % _clients.size())
	_num(c, "254", "%d :channels formed" % _channels.size())
	_num(c, "255", ":I have %d clients and 0 servers" % _clients.size())


func _motd(c: Dictionary) -> void:
	var text := p.read_text(MOTD)
	if text.is_empty():
		_num(c, "422", ":MOTD File is missing")
		return
	_num(c, "375", ":- %s Message of the Day - " % _conf.name)
	for line in text.trim_suffix("\n").split("\n"):
		_num(c, "372", ":- " + line)
	_num(c, "376", ":End of /MOTD command.")


## [param c] leaves: QUIT to the others, out of every channel.
func _gone(c: Dictionary, reason: String) -> void:
	if not c.registered:
		return
	_to_neighbours(c, ":%s QUIT :%s" % [_mask(c), reason])
	for ch: String in (c.channels as Array).duplicate():
		_leave(c, ch)
	_clients.erase(str(c.nick).to_lower())
	_log("Client exiting: %s (%s@%s) [%s]" % [c.nick, c.user, c.host, reason])


func _leave(c: Dictionary, ch: String) -> void:
	if not _channels.has(ch):
		return
	(_channels[ch].members as Dictionary).erase(str(c.nick).to_lower())
	(c.channels as Array).erase(ch)
	if (_channels[ch].members as Dictionary).is_empty():
		_channels.erase(ch)


# --- commands ------------------------------------------------------------------

func _command(c: Dictionary, m: Dictionary) -> void:
	var params: PackedStringArray = m.params
	var me := str(c.nick).to_lower()
	match m.cmd:
		"PING":
			_send(c, ":%s PONG %s :%s" % [_conf.name, _conf.name, params[0] if not params.is_empty() else ""])
		"PONG", "USERHOST", "PASS", "CAP":
			if m.cmd == "USERHOST" and not params.is_empty():
				var found := _clients.get(params[0].to_lower(), {}) as Dictionary
				_num(c, "302", ":%s" % ("%s=+%s@%s" % [found.nick, found.user, found.host] if not found.is_empty() else ""))
		"NICK":
			if params.is_empty():
				_num(c, "431", ":No nickname given")
			elif not _valid_nick(params[0]):
				_num(c, "432", "%s :Erroneous Nickname" % params[0])
			elif _clients.has(params[0].to_lower()) and params[0].to_lower() != me:
				_num(c, "433", "%s :Nickname is already in use." % params[0])
			else:
				var line := ":%s NICK :%s" % [_mask(c), params[0]]
				_send(c, line)
				_to_neighbours(c, line)
				_clients.erase(me)
				for ch: String in c.channels:
					var members: Dictionary = _channels[ch].members
					var flag: String = members[me]
					members.erase(me)
					members[params[0].to_lower()] = flag
				c.nick = params[0]
				_clients[params[0].to_lower()] = c
		"JOIN":
			if params.is_empty():
				_num(c, "461", "JOIN :Not enough parameters")
				return
			for name in params[0].split(",", false):
				_join(c, name)
		"PART":
			if params.is_empty():
				_num(c, "461", "PART :Not enough parameters")
				return
			for name in params[0].split(",", false):
				var ch := name.to_lower()
				if not _channels.has(ch):
					_num(c, "403", "%s :No such channel" % name)
				elif not (c.channels as Array).has(ch):
					_num(c, "442", "%s :You're not on that channel" % name)
				else:
					var line := ":%s PART %s" % [_mask(c), _channels[ch].name] + (" :" + params[1] if params.size() > 1 else "")
					_to_channel(_channels[ch], line)
					_leave(c, ch)
		"PRIVMSG", "NOTICE":
			if params.size() < 2 or params[1].is_empty():
				if m.cmd == "PRIVMSG":
					_num(c, "411" if params.is_empty() else "412", ":No recipient given (PRIVMSG)" if params.is_empty() else ":No text to send")
				return
			for target in params[0].split(",", false):
				_message(c, m.cmd, target, params[1])
		"TOPIC":
			_topic(c, params)
		"NAMES":
			if params.is_empty():
				_num(c, "366", "* :End of /NAMES list.")
			else:
				for name in params[0].split(",", false):
					_names(c, name.to_lower())
		"LIST":
			_num(c, "321", "Channel :Users  Name")
			for ch: String in _channels:
				var chan: Dictionary = _channels[ch]
				if not str(chan.modes).contains("s") or (c.channels as Array).has(ch):
					_num(c, "322", "%s %d :%s" % [chan.name, (chan.members as Dictionary).size(), chan.topic])
			_num(c, "323", ":End of /LIST")
		"WHO":
			var mask := params[0] if not params.is_empty() else "*"
			var ch := mask.to_lower()
			var people: Array = []
			if _channels.has(ch):
				for n: String in _channels[ch].members:
					people.append([_clients[n], _channels[ch].name, _channels[ch].members[n]])
			else:
				for n: String in _clients:
					if mask == "*" or n == mask.to_lower():
						people.append([_clients[n], "*", ""])
			for who: Array in people:
				var o: Dictionary = who[0]
				_num(c, "352", "%s %s %s %s %s %s%s :0 %s" % [who[1], o.user, o.host, _conf.name, o.nick, "G" if not str(o.away).is_empty() else "H", who[2], o.real])
			_num(c, "315", "%s :End of /WHO list." % mask)
		"WHOIS":
			if params.is_empty():
				_num(c, "431", ":No nickname given")
				return
			var target := params[-1]
			var o: Dictionary = _clients.get(target.to_lower(), {})
			if o.is_empty():
				_num(c, "401", "%s :No such nick/channel" % target)
				_num(c, "318", "%s :End of /WHOIS list." % target)
				return
			_num(c, "311", "%s %s %s * :%s" % [o.nick, o.user, o.host, o.real])
			var chans: PackedStringArray = []
			for ch: String in o.channels:
				chans.append(_channels[ch].members[str(o.nick).to_lower()] + _channels[ch].name)
			if not chans.is_empty():
				_num(c, "319", "%s :%s" % [o.nick, " ".join(chans)])
			_num(c, "312", "%s %s :%s" % [o.nick, _conf.name, _conf.description])
			if not str(o.away).is_empty():
				_num(c, "301", "%s :%s" % [o.nick, o.away])
			_num(c, "317", "%s %d %d :seconds idle, signon time" % [o.nick, p.machine.clock.now_int() - int(o.last), o.signon])
			_num(c, "318", "%s :End of /WHOIS list." % o.nick)
		"AWAY":
			if params.is_empty() or params[0].is_empty():
				c.away = ""
				_num(c, "305", ":You are no longer marked as being away")
			else:
				c.away = params[0]
				_num(c, "306", ":You have been marked as being away")
		"ISON":
			var on: PackedStringArray = []
			for n in " ".join(params).split(" ", false):
				if _clients.has(n.to_lower()):
					on.append(_clients[n.to_lower()].nick)
			_num(c, "303", ":" + " ".join(on))
		"MODE":
			_mode(c, params)
		"KICK":
			_kick(c, params)
		"INVITE":
			if params.size() < 2:
				_num(c, "461", "INVITE :Not enough parameters")
				return
			var o: Dictionary = _clients.get(params[0].to_lower(), {})
			var ch := params[1].to_lower()
			if o.is_empty():
				_num(c, "401", "%s :No such nick/channel" % params[0])
			elif _channels.has(ch) and not (c.channels as Array).has(ch):
				_num(c, "442", "%s :You're not on that channel" % params[1])
			else:
				if _channels.has(ch):
					(_channels[ch].invites as Array).append(str(o.nick).to_lower())
				_num(c, "341", "%s %s" % [o.nick, params[1]])
				_send(o, ":%s INVITE %s :%s" % [_mask(c), o.nick, params[1]])
		"MOTD":
			_motd(c)
		"LUSERS":
			_lusers(c)
		"VERSION":
			_num(c, "351", "%s. %s :%s" % [VERSION, _conf.name, _conf.description])
		"TIME":
			_num(c, "391", "%s :%s" % [_conf.name, p.machine.clock.format_long()])
		"ADMIN":
			_num(c, "256", "%s :Administrative info" % _conf.name)
			_num(c, "257", ":%s" % _conf.description)
			_num(c, "259", ":%s" % _conf.admin)
		"USER":
			_num(c, "462", ":You may not reregister")
		_:
			_num(c, "421", "%s :Unknown command" % m.cmd)


func _join(c: Dictionary, name: String) -> void:
	if not (name.begins_with("#") or name.begins_with("&")) or name.length() > 50 or name.contains(" ") or name.contains(","):
		_num(c, "403", "%s :No such channel" % name)
		return
	var ch := name.to_lower()
	if (c.channels as Array).has(ch):
		return
	var me := str(c.nick).to_lower()
	if not _channels.has(ch):
		_channels[ch] = {"name": name, "topic": "", "topic_by": "", "topic_at": 0, "modes": "nt", "members": {}, "invites": [],
			"created": p.machine.clock.now_int(), "key": ""}
		_channels[ch].members[me] = "@"
	else:
		var chan: Dictionary = _channels[ch]
		if str(chan.modes).contains("i") and not (chan.invites as Array).has(me):
			_num(c, "473", "%s :Cannot join channel (+i)" % chan.name)
			return
		chan.members[me] = ""
		(chan.invites as Array).erase(me)
	(c.channels as Array).append(ch)
	var chan: Dictionary = _channels[ch]
	_to_channel(chan, ":%s JOIN :%s" % [_mask(c), chan.name])
	if not str(chan.topic).is_empty():
		_num(c, "332", "%s :%s" % [chan.name, chan.topic])
		_num(c, "333", "%s %s %d" % [chan.name, chan.topic_by, chan.topic_at])
	_names(c, ch)


func _names(c: Dictionary, ch: String) -> void:
	if _channels.has(ch):
		var chan: Dictionary = _channels[ch]
		var names: PackedStringArray = []
		for n: String in chan.members:
			names.append(chan.members[n] + str(_clients[n].nick))
		_num(c, "353", "%s %s :%s" % ["@" if str(chan.modes).contains("s") else "=", chan.name, " ".join(names)])
		_num(c, "366", "%s :End of /NAMES list." % chan.name)
	else:
		_num(c, "366", "%s :End of /NAMES list." % ch)


func _message(c: Dictionary, cmd: String, target: String, text: String) -> void:
	var line := ":%s %s %s :%s" % [_mask(c), cmd, target, text]
	if AgoraIrc.is_channel(target):
		var ch := target.to_lower()
		if not _channels.has(ch):
			if cmd == "PRIVMSG":
				_num(c, "401", "%s :No such nick/channel" % target)
			return
		var chan: Dictionary = _channels[ch]
		if str(chan.modes).contains("n") and not (c.channels as Array).has(ch):
			if cmd == "PRIVMSG":
				_num(c, "404", "%s :Cannot send to channel" % chan.name)
			return
		if str(chan.modes).contains("m") and chan.members.get(str(c.nick).to_lower(), "") == "":
			if cmd == "PRIVMSG":
				_num(c, "404", "%s :Cannot send to channel" % chan.name)
			return
		_to_channel(chan, line, str(c.nick).to_lower())
		return
	var o: Dictionary = _clients.get(target.to_lower(), {})
	if o.is_empty():
		if cmd == "PRIVMSG":
			_num(c, "401", "%s :No such nick/channel" % target)
		return
	_send(o, line)
	if cmd == "PRIVMSG" and not str(o.away).is_empty():
		_num(c, "301", "%s :%s" % [o.nick, o.away])


func _topic(c: Dictionary, params: PackedStringArray) -> void:
	if params.is_empty():
		_num(c, "461", "TOPIC :Not enough parameters")
		return
	var ch := params[0].to_lower()
	if not _channels.has(ch):
		_num(c, "403", "%s :No such channel" % params[0])
		return
	var chan: Dictionary = _channels[ch]
	if params.size() < 2:
		if str(chan.topic).is_empty():
			_num(c, "331", "%s :No topic is set." % chan.name)
		else:
			_num(c, "332", "%s :%s" % [chan.name, chan.topic])
			_num(c, "333", "%s %s %d" % [chan.name, chan.topic_by, chan.topic_at])
		return
	if not (c.channels as Array).has(ch):
		_num(c, "442", "%s :You're not on that channel" % chan.name)
		return
	if str(chan.modes).contains("t") and chan.members[str(c.nick).to_lower()] != "@":
		_num(c, "482", "%s :You're not channel operator" % chan.name)
		return
	chan.topic = params[1].left(TOPICLEN)
	chan.topic_by = c.nick
	chan.topic_at = p.machine.clock.now_int()
	_to_channel(chan, ":%s TOPIC %s :%s" % [_mask(c), chan.name, chan.topic])


func _mode(c: Dictionary, params: PackedStringArray) -> void:
	if params.is_empty():
		_num(c, "461", "MODE :Not enough parameters")
		return
	var target := params[0]
	if not (target.begins_with("#") or target.begins_with("&")):
		if target.to_lower() != str(c.nick).to_lower():
			_num(c, "502", ":Can't change mode for other users")
		elif params.size() < 2:
			_num(c, "221", "+" + str(c.modes))
		return
	var ch := target.to_lower()
	if not _channels.has(ch):
		_num(c, "403", "%s :No such channel" % target)
		return
	var chan: Dictionary = _channels[ch]
	if params.size() < 2:
		_num(c, "324", "%s +%s" % [chan.name, chan.modes])
		_num(c, "329", "%s %d" % [chan.name, chan.created])
		return
	if chan.members.get(str(c.nick).to_lower(), "") != "@":
		_num(c, "482", "%s :You're not channel operator" % chan.name)
		return
	var adding := true
	var arg := 2
	var applied := ""
	var applied_args: PackedStringArray = []
	for flag in params[1]:
		match flag:
			"+": adding = true
			"-": adding = false
			"o", "v":
				if arg >= params.size():
					continue
				var who := params[arg].to_lower()
				arg += 1
				if not (chan.members as Dictionary).has(who):
					_num(c, "441", "%s %s :They aren't on that channel" % [params[arg - 1], chan.name])
					continue
				if flag == "o":
					chan.members[who] = "@" if adding else ""
				elif chan.members[who] != "@":
					chan.members[who] = "+" if adding else ""
				applied += ("+" if adding else "-") + flag
				applied_args.append(_clients[who].nick)
			"n", "t", "i", "m", "s":
				var modes := str(chan.modes)
				if adding and not modes.contains(flag):
					chan.modes = modes + flag
				elif not adding:
					chan.modes = modes.replace(flag, "")
				applied += ("+" if adding else "-") + flag
			_:
				_num(c, "472", "%s :is unknown mode char to me" % flag)
	if not applied.is_empty():
		_to_channel(chan, ":%s MODE %s %s%s" % [_mask(c), chan.name, _squash(applied), (" " + " ".join(applied_args)) if not applied_args.is_empty() else ""])


## "+o+o-t" -> "+oo-t".
static func _squash(modes: String) -> String:
	var out := ""
	var sign := ""
	for k in range(0, modes.length(), 2):
		if modes[k] != sign:
			sign = modes[k]
			out += sign
		out += modes[k + 1]
	return out


func _kick(c: Dictionary, params: PackedStringArray) -> void:
	if params.size() < 2:
		_num(c, "461", "KICK :Not enough parameters")
		return
	var ch := params[0].to_lower()
	if not _channels.has(ch):
		_num(c, "403", "%s :No such channel" % params[0])
		return
	var chan: Dictionary = _channels[ch]
	if chan.members.get(str(c.nick).to_lower(), "") != "@":
		_num(c, "482", "%s :You're not channel operator" % chan.name)
		return
	var who := params[1].to_lower()
	if not (chan.members as Dictionary).has(who):
		_num(c, "441", "%s %s :They aren't on that channel" % [params[1], chan.name])
		return
	var o: Dictionary = _clients[who]
	_to_channel(chan, ":%s KICK %s %s :%s" % [_mask(c), chan.name, o.nick, params[2] if params.size() > 2 else c.nick])
	_leave(o, ch)
