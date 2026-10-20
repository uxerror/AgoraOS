extends AgoraProgram
## ircbot: channel bots. Each file in /etc/ircbot/ (or each FILE given) is a
## bot that connects to a server, joins its channels and answers there and
## in private messages:
##
##   server irc.lanlink.net 6667
##   nick Lanbot
##   user lanbot
##   name LanLink help desk
##   channel #lanlink
##   topic #lanlink Welcome to LanLink! Ask away.
##   greet Hello $nick, welcome to $channel!
##   on !help Commands: !help, !time
##   on !time It is $time.
##   hear modem Is the modem's DSL light steady, $nick?
##
## "on WORD" answers a message that starts with WORD, "hear WORD" one that
## has it anywhere; "greet" talks to whoever joins; "topic" is set when the
## bot is the channel's operator. $nick, $channel, $time and $me are filled
## in. A bot that loses the server tries again a minute later. Lines go to
## the daemon log.

const DIR := "/etc/ircbot"
const RETRY := 60.0


func summary() -> String:
	return "IRC channel bots"


func usage() -> String:
	return "usage: ircbot [FILE...]"


func main(p: AgoraProcess) -> int:
	var files: PackedStringArray = p.argv.slice(1)
	if files.is_empty():
		for name in p.machine.vfs.list_dir(p.cred, DIR) if p.machine.vfs.is_dir(p.cred, DIR) else PackedStringArray():
			if name.ends_with(".conf"):
				files.append(DIR + "/" + name)
	var bots: Array = []
	for f in files:
		var conf := read_conf(p.read_text(f))
		if str(conf.nick).is_empty() or str(conf.server).is_empty():
			p.errln("ircbot: %s: no server or nick" % f)
			continue
		bots.append(conf)
		_run(p, conf)
	if bots.is_empty():
		return p.fail("ircbot: no bots configured", 1)
	while p.is_running():
		await p.sleep(3600.0)
	return 0


static func read_conf(text: String) -> Dictionary:
	var c := {"server": "", "port": AgoraIrc.PORT, "nick": "", "user": "", "name": "", "channels": [], "topics": {},
		"greet": "", "on": [], "hear": []}
	for line in text.split("\n", false):
		line = line.strip_edges()
		if line.begins_with("#") or line.is_empty():
			continue
		var key := line.get_slice(" ", 0)
		var rest := line.substr(key.length()).strip_edges()
		var word := rest.get_slice(" ", 0)
		var tail := rest.substr(word.length()).strip_edges()
		match key:
			"server":
				c.server = word
				if not tail.is_empty():
					c.port = tail.to_int()
			"nick": c.nick = rest
			"user": c.user = rest
			"name": c.name = rest
			"channel": (c.channels as Array).append(word)
			"topic": c.topics[word.to_lower()] = tail
			"greet": c.greet = rest
			"on": (c.on as Array).append([word.to_lower(), tail])
			"hear": (c.hear as Array).append([word.to_lower(), tail])
	if str(c.user).is_empty():
		c.user = str(c.nick).to_lower()
	if str(c.name).is_empty():
		c.name = c.nick
	return c


## The answer of a bot with [param conf] to [param text], or "".
static func answer(conf: Dictionary, text: String) -> String:
	var low := text.strip_edges().to_lower()
	var first := low.get_slice(" ", 0)
	for rule: Array in conf.on:
		if first == rule[0]:
			return rule[1]
	for rule: Array in conf.hear:
		if (" " + low + " ").contains(rule[0]):
			return rule[1]
	return ""


static func fill(p: AgoraProcess, text: String, me: String, nick: String, channel: String) -> String:
	return text.replace("$nick", nick).replace("$channel", channel).replace("$me", me).replace("$time", p.machine.clock.format_long())


func _run(p: AgoraProcess, conf: Dictionary) -> void:
	while p.is_running():
		var client := AgoraIrcClient.new(p)
		var why := await client.open(str(conf.server), int(conf.port), str(conf.nick), str(conf.user), str(conf.name))
		if not why.is_empty():
			p.machine.log_event("daemon", "ircbot[%d]" % p.pid, "%s: %s" % [conf.nick, why])
			await p.sleep(RETRY)
			continue
		p.machine.log_event("daemon", "ircbot[%d]" % p.pid, "%s: connected to %s" % [client.nick, client.server])
		var gone := [false]
		var on_line := func(m: Dictionary) -> void: _heard(p, client, conf, m)
		var on_gone := func(_reason: String) -> void: gone[0] = true
		client.received.connect(on_line)
		client.disconnected.connect(on_gone)
		for ch: String in conf.channels:
			client.send("JOIN " + ch)
		while not gone[0] and p.is_running():
			await p.sleep(1.0)
		client.received.disconnect(on_line)
		client.disconnected.disconnect(on_gone)
		if not p.is_running():
			client.close("Shutting down")
			return
		await p.sleep(RETRY)


func _heard(p: AgoraProcess, client: AgoraIrcClient, conf: Dictionary, m: Dictionary) -> void:
	var params: PackedStringArray = m.params
	match m.cmd:
		"JOIN":
			var ch := params[0] if not params.is_empty() else ""
			if m.nick == client.nick:
				return
			if not str(conf.greet).is_empty():
				client.send("PRIVMSG %s :%s" % [ch, fill(p, conf.greet, client.nick, m.nick, ch)])
		"353":
			# NAMES on joining: "@Lanbot" means the bot holds the channel.
			if params.size() >= 4 and (" " + params[3] + " ").contains(" @" + client.nick + " "):
				var topic: String = conf.topics.get(params[2].to_lower(), "")
				if not topic.is_empty():
					client.send("TOPIC %s :%s" % [params[2], topic])
		"PRIVMSG":
			if params.size() < 2 or not AgoraIrc.action(params[1]).is_empty() or params[1].begins_with("\u0001"):
				return
			var to: String = params[0] if AgoraIrc.is_channel(params[0]) else m.nick
			var reply := answer(conf, params[1])
			if not reply.is_empty():
				client.send("PRIVMSG %s :%s" % [to, fill(p, reply, client.nick, m.nick, to)])
