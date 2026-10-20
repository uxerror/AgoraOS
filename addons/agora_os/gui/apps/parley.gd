extends AgoraGuiProgram
## Parley: an IRC client in the manner of mIRC and X-Chat. A connect form
## (server, port, nickname, real name), then tabs: the server's messages,
## one per channel (topic on top, the people on the right) and one per
## private conversation. The line at the bottom talks to the open tab;
## commands start with "/": /join, /part, /msg, /query, /me, /nick, /topic,
## /whois, /away, /list, /names, /kick, /op, /deop, /quote and /quit.
##
## Settings in ~/.parley/parley.conf ("server=", "port=", "nick=",
## "name=", "join=#a,#b"), the defaults from /etc/parley.conf. A message
## naming one's nick, or a private one, makes the window blink.

const CONF := "/etc/parley.conf"
const STATUS := "Status"

var p: AgoraProcess
var client: AgoraIrcClient
var win: AgoraWindow
var settings := {}
## Tab name (a channel, a nick or STATUS) -> {log, list, topic, page,
## nicks: {lower nick: prefix + nick}}
var tabs := {}

var _root := VBoxContainer.new()
var _form := VBoxContainer.new()
var _tabs := TabContainer.new()
var _input := LineEdit.new()
var _server_edit := LineEdit.new()
var _port_edit := LineEdit.new()
var _nick_edit := LineEdit.new()
var _name_edit := LineEdit.new()
var _note := Label.new()
var _chat := VBoxContainer.new()
## The open tab's key (kept here: the TabContainer is only sure of it on
## screen).
var _here := ""


func summary() -> String:
	return "Parley, the IRC client"


func usage() -> String:
	return "usage: parley [SERVER]"


func main(proc: AgoraProcess) -> int:
	p = proc
	client = AgoraIrcClient.new(p)
	client.received.connect(_on_line)
	client.disconnected.connect(_on_disconnected)
	_load_settings()
	if p.argv.size() > 1:
		settings.server = p.argv[1]
	_build()
	win = open_window(p, _root, {"title": "Parley", "size": Vector2(620, 420), "min_size": Vector2(360, 240)})
	if win == null:
		return 1
	win.focus_target = _nick_edit
	if p.argv.size() > 1:
		connect_to(str(settings.server), int(settings.port), str(settings.nick))
	await win.closed
	client.close("Parley")
	client.received.disconnect(_on_line)
	client.disconnected.disconnect(_on_disconnected)
	return 0


# --- settings ------------------------------------------------------------------

func _conf_path() -> String:
	return p.home() + "/.parley/parley.conf"


func _load_settings() -> void:
	settings = {"server": "irc.lanlink.net", "port": AgoraIrc.PORT, "nick": p.user_name(), "name": p.user_name(), "join": ""}
	for path in [CONF, _conf_path()]:
		for line in p.read_text(path).split("\n", false):
			line = line.get_slice("#", 0) if not line.strip_edges().begins_with("join=") else line
			var eq := line.find("=")
			if eq > 0 and settings.has(line.substr(0, eq).strip_edges()):
				settings[line.substr(0, eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	settings.port = int(settings.port)


func _save_settings() -> void:
	p.machine.vfs.make_dirs(p.cred, p.home() + "/.parley")
	var text := "# Parley settings\n"
	for key in ["server", "port", "nick", "name", "join"]:
		text += "%s=%s\n" % [key, settings[key]]
	p.machine.vfs.write_text(p.cred, _conf_path(), text)


# --- the window ----------------------------------------------------------------

func _build() -> void:
	_root.add_theme_constant_override("separation", 4)
	_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var grid := GridContainer.new()
	grid.columns = 2
	for pair in [["Server:", _server_edit], ["Port:", _port_edit], ["Nickname:", _nick_edit], ["Real name:", _name_edit]]:
		var l := Label.new()
		l.text = pair[0]
		grid.add_child(l)
		(pair[1] as LineEdit).custom_minimum_size = Vector2(220, 0)
		grid.add_child(pair[1])
	_form.add_child(grid)
	var go := Button.new()
	go.text = "Connect"
	go.pressed.connect(_on_connect_pressed)
	_nick_edit.text_submitted.connect(func(_t: String) -> void: _on_connect_pressed())
	_form.add_child(go)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_form.add_child(_note)
	_root.add_child(_form)
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(func(i: int) -> void:
		for key: String in tabs:
			if tabs[key].page == _tabs.get_tab_control(i):
				_here = key
		_update_title())
	_chat.add_child(_tabs)
	_input.text_submitted.connect(_on_input)
	_chat.add_child(_input)
	_chat.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat.visible = false
	_root.add_child(_chat)
	_server_edit.text = str(settings.server)
	_port_edit.text = str(settings.port)
	_nick_edit.text = str(settings.nick)
	_name_edit.text = str(settings.name)


func _on_connect_pressed() -> void:
	settings.name = _name_edit.text.strip_edges()
	var why := await connect_to(_server_edit.text.strip_edges(), _port_edit.text.to_int(), _nick_edit.text.strip_edges())
	if not why.is_empty():
		_note.text = why


## Connects and shows the tabs. Returns "" or what went wrong.
func connect_to(server: String, port: int, nick: String) -> String:
	if server.is_empty() or nick.is_empty():
		return "A server and a nickname, please."
	_note.text = "Connecting to %s..." % server
	_open_tab(STATUS)
	_status("* Connecting to %s (%d)" % [server, port])
	var why := await client.open(server, port if port > 0 else AgoraIrc.PORT, nick, p.user_name(), str(settings.name))
	if not why.is_empty():
		_status("* " + why)
		_close_tab(STATUS)
		return why
	settings.server = server
	settings.port = port
	settings.nick = nick
	_save_settings()
	_form.visible = false
	_chat.visible = true
	win.focus_target = _input
	if _input.is_inside_tree():
		_input.grab_focus.call_deferred()
	_update_title()
	for ch in str(settings.join).split(",", false):
		client.send("JOIN " + ch.strip_edges())
	return ""


func _update_title() -> void:
	if win == null:
		return
	var here := current_tab()
	var title := "Parley - %s on %s" % [client.nick, client.server] if client.is_connected_to_server() else "Parley"
	if here != STATUS and not here.is_empty():
		title += " - " + here
	win.title = title


func _open_tab(name: String) -> Dictionary:
	var key := name.to_lower()
	if tabs.has(key):
		return tabs[key]
	var page := VBoxContainer.new()
	page.name = name
	var topic := LineEdit.new()
	topic.editable = false
	topic.visible = AgoraIrc.is_channel(name)
	page.add_child(topic)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var log := RichTextLabel.new()
	log.bbcode_enabled = true
	log.scroll_following = true
	log.selection_enabled = true
	log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log.add_theme_font_override("normal_font", AgoraStyle.MONO)
	split.add_child(log)
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(110, 0)
	list.visible = AgoraIrc.is_channel(name)
	list.item_activated.connect(func(i: int) -> void: query(list.get_item_text(i).trim_prefix("@").trim_prefix("+")))
	split.add_child(list)
	page.add_child(split)
	_tabs.add_child(page)
	if _here.is_empty():
		_here = key
	tabs[key] = {"name": name, "page": page, "log": log, "list": list, "topic": topic, "nicks": {}}
	return tabs[key]


func _close_tab(name: String) -> void:
	var key := name.to_lower()
	if tabs.has(key):
		(tabs[key].page as Control).queue_free()
		_tabs.remove_child(tabs[key].page)
		tabs.erase(key)
		if _here == key:
			_here = ""
			show_tab(tabs.values()[-1].name if not tabs.is_empty() else "")


## The name of the open tab.
func current_tab() -> String:
	return tabs[_here].name if tabs.has(_here) else ""


func show_tab(name: String) -> void:
	var key := name.to_lower()
	if not tabs.has(key):
		return
	_here = key
	var i := _tabs.get_tab_idx_from_control(tabs[key].page)
	if i >= 0 and _tabs.current_tab != i:
		_tabs.current_tab = i
	_update_title()


## A tab's text without markup (tests).
func tab_text(name: String) -> String:
	return (tabs[name.to_lower()].log as RichTextLabel).get_parsed_text() if tabs.has(name.to_lower()) else ""


## The people on a channel as shown, ops first.
func nicks(name: String) -> PackedStringArray:
	var out: PackedStringArray = []
	if tabs.has(name.to_lower()):
		var list: ItemList = tabs[name.to_lower()].list
		for i in list.item_count:
			out.append(list.get_item_text(i))
	return out


func _stamp() -> String:
	var d := p.machine.clock.local_datetime()
	return "[%02d:%02d]" % [d.hour, d.minute]


func _print(name: String, text: String, color: String = "") -> void:
	var tab := _open_tab(name)
	var line := "%s %s" % [_stamp(), text.replace("[", "[lb]")]
	if not color.is_empty():
		line = "[color=%s]%s[/color]" % [color, line]
	(tab.log as RichTextLabel).append_text(line + "\n")


func _status(text: String) -> void:
	_print(STATUS, text, "#606060")


func _attention() -> void:
	if win != null and (win.display == null or win.display.focused != win):
		win.urgent = true


func _refresh_nicks(name: String) -> void:
	var tab: Dictionary = tabs.get(name.to_lower(), {})
	if tab.is_empty():
		return
	var list: ItemList = tab.list
	list.clear()
	var shown: Array = (tab.nicks as Dictionary).values()
	shown.sort_custom(func(a: String, b: String) -> bool:
		var ra := "@+".find(a[0]) if "@+".contains(a[0]) else 2
		var rb := "@+".find(b[0]) if "@+".contains(b[0]) else 2
		return ra < rb if ra != rb else a.to_lower() < b.to_lower())
	for n: String in shown:
		list.add_item(n)


static func _bare(n: String) -> String:
	return n.trim_prefix("@").trim_prefix("+")


# --- what the server says ------------------------------------------------------

func _on_line(m: Dictionary) -> void:
	var params: PackedStringArray = m.params
	var last := params[-1] if not params.is_empty() else ""
	match m.cmd:
		"PRIVMSG", "NOTICE":
			if params.size() < 2:
				return
			var to := params[0]
			var tab: String = to if AgoraIrc.is_channel(to) else m.nick
			if m.cmd == "NOTICE" and (not AgoraIrc.is_channel(to)) and (m.nick.contains(".") or m.nick.is_empty()):
				_status("-%s- %s" % [m.prefix, last])
				return
			var act := AgoraIrc.action(last)
			if m.cmd == "PRIVMSG" and last.begins_with("\u0001") and act.is_empty():
				_ctcp(m.nick, last.trim_prefix("\u0001").trim_suffix("\u0001"))
				return
			if not act.is_empty():
				_print(tab, "* %s %s" % [m.nick, act], "#9c009c")
			elif m.cmd == "NOTICE":
				_print(tab, "-%s- %s" % [m.nick, last], "#a05000")
			else:
				var mine := last.to_lower().contains(client.nick.to_lower())
				_print(tab, "<%s> %s" % [m.nick, last], "#c00000" if mine else "")
				if mine or not AgoraIrc.is_channel(to):
					_attention()
		"JOIN":
			var ch := last
			if m.nick == client.nick:
				_open_tab(ch)
				show_tab(ch)
				_print(ch, "* Now talking in " + ch, "#009000")
			else:
				_print(ch, "* %s (%s) has joined %s" % [m.nick, m.prefix.get_slice("!", 1), ch], "#009000")
			(tabs[ch.to_lower()].nicks as Dictionary)[m.nick.to_lower()] = m.nick
			_refresh_nicks(ch)
		"PART":
			var ch := params[0]
			if m.nick == client.nick:
				_close_tab(ch)
			elif tabs.has(ch.to_lower()):
				_print(ch, "* %s has left %s%s" % [m.nick, ch, (" (%s)" % params[1]) if params.size() > 1 else ""], "#009000")
				(tabs[ch.to_lower()].nicks as Dictionary).erase(m.nick.to_lower())
				_refresh_nicks(ch)
		"KICK":
			var ch := params[0]
			if params.size() >= 2 and tabs.has(ch.to_lower()):
				var whom := params[1]
				if whom.to_lower() == client.nick.to_lower():
					_print(ch, "* You were kicked from %s by %s (%s)" % [ch, m.nick, last], "#c00000")
					(tabs[ch.to_lower()].nicks as Dictionary).clear()
					_attention()
				else:
					_print(ch, "* %s was kicked by %s (%s)" % [whom, m.nick, last], "#009000")
					(tabs[ch.to_lower()].nicks as Dictionary).erase(whom.to_lower())
				_refresh_nicks(ch)
		"QUIT":
			for key: String in tabs:
				if (tabs[key].nicks as Dictionary).has(m.nick.to_lower()):
					_print(tabs[key].name, "* %s has quit IRC (%s)" % [m.nick, last], "#00007f")
					(tabs[key].nicks as Dictionary).erase(m.nick.to_lower())
					_refresh_nicks(tabs[key].name)
		"NICK":
			for key: String in tabs:
				var ns: Dictionary = tabs[key].nicks
				if ns.has(m.nick.to_lower()):
					var prefix := str(ns[m.nick.to_lower()]).left(1) if "@+".contains(str(ns[m.nick.to_lower()]).left(1)) else ""
					ns.erase(m.nick.to_lower())
					ns[last.to_lower()] = prefix + last
					_print(tabs[key].name, "* %s is now known as %s" % [m.nick, last], "#009000")
					_refresh_nicks(tabs[key].name)
			_update_title()
		"TOPIC":
			_set_topic(params[0], last)
			_print(params[0], "* %s changes topic to '%s'" % [m.nick, last], "#009000")
		"MODE":
			if AgoraIrc.is_channel(params[0]) and tabs.has(params[0].to_lower()):
				_apply_modes(params)
				_print(params[0], "* %s sets mode: %s" % [m.nick, " ".join(params.slice(1))], "#009000")
		"332":
			if params.size() >= 3:
				_set_topic(params[1], last)
				_print(params[1], "* Topic is '%s'" % last, "#009000")
		"353":
			if params.size() >= 4 and tabs.has(params[2].to_lower()):
				var ns: Dictionary = tabs[params[2].to_lower()].nicks
				for n in last.split(" ", false):
					ns[_bare(n).to_lower()] = n
				_refresh_nicks(params[2])
		"366", "333", "329", "315", "318", "321", "376", "005", "004":
			pass
		"322":
			if params.size() >= 3:
				_status("%s (%s) %s" % [params[1], params[2], last])
		"311":
			_status("%s is %s@%s * %s" % [params[1], params[2], params[3], last])
		"319":
			_status("%s on %s" % [params[1], last])
		"312":
			_status("%s using %s %s" % [params[1], params[2], last])
		"301":
			_print(params[1] if tabs.has(params[1].to_lower()) else STATUS, "%s is away: %s" % [params[1], last], "#606060")
		"317":
			_status("%s has been idle %ss" % [params[1], params[2]])
		"ERROR":
			_status("* " + last)
		_:
			if m.cmd.is_valid_int():
				var shown := params.slice(1)
				var code: int = m.cmd.to_int()
				var where: String = current_tab() if code >= 400 else STATUS
				_print(where if not where.is_empty() else STATUS, " ".join(shown.slice(0, shown.size() - 1) + PackedStringArray([last])) if shown.size() > 1 else last, "#c00000" if code >= 400 else "#606060")


func _ctcp(from: String, what: String) -> void:
	var word := what.get_slice(" ", 0).to_upper()
	match word:
		"VERSION":
			client.send("NOTICE %s :\u0001VERSION Parley 1.0 on AgoraOS\u0001" % from)
		"PING":
			client.send("NOTICE %s :\u0001%s\u0001" % [from, what])
		"TIME":
			client.send("NOTICE %s :\u0001TIME %s\u0001" % [from, p.machine.clock.format_long()])
	_status("[%s %s]" % [from, word])


func _set_topic(ch: String, text: String) -> void:
	var tab := _open_tab(ch)
	(tab.topic as LineEdit).text = text


func _apply_modes(params: PackedStringArray) -> void:
	var ns: Dictionary = tabs[params[0].to_lower()].nicks
	var adding := true
	var arg := 2
	for flag in params[1] if params.size() > 1 else "":
		match flag:
			"+": adding = true
			"-": adding = false
			"o", "v":
				if arg < params.size():
					var who := params[arg].to_lower()
					arg += 1
					if ns.has(who):
						var bare := _bare(str(ns[who]))
						var had := str(ns[who]).left(1)
						if flag == "o":
							ns[who] = ("@" + bare) if adding else bare
						elif had != "@":
							ns[who] = ("+" + bare) if adding else bare
	_refresh_nicks(params[0])


func _on_disconnected(reason: String) -> void:
	_status("* Disconnected" + ((" (%s)" % reason) if not reason.is_empty() else ""))
	_update_title()


# --- what the user types -------------------------------------------------------

func _on_input(text: String) -> void:
	_input.text = ""
	command(text)


## Handles a line typed in the open tab.
func command(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	var here := current_tab()
	if not text.begins_with("/") or text.begins_with("//"):
		say(here, text.trim_prefix("/"))
		return
	var word := text.substr(1).get_slice(" ", 0).to_lower()
	var rest := text.substr(word.length() + 2).strip_edges()
	var arg := rest.get_slice(" ", 0)
	var tail := rest.substr(arg.length()).strip_edges()
	match word:
		"join", "j":
			client.send("JOIN " + (arg if AgoraIrc.is_channel(arg) else "#" + arg))
		"part", "leave":
			var ch := arg if AgoraIrc.is_channel(arg) else here
			var why := tail if AgoraIrc.is_channel(arg) else rest
			if AgoraIrc.is_channel(ch):
				client.send("PART %s%s" % [ch, (" :" + why) if not why.is_empty() else ""])
			elif tabs.has(ch.to_lower()) and ch != STATUS:
				_close_tab(ch)
		"msg":
			client.send("PRIVMSG %s :%s" % [arg, tail])
			if tabs.has(arg.to_lower()):
				_print(arg, "<%s> %s" % [client.nick, tail])
			else:
				_status("-> *%s* %s" % [arg, tail])
		"query":
			query(arg)
			if not tail.is_empty():
				say(arg, tail)
		"me":
			if here != STATUS and not here.is_empty():
				client.send("PRIVMSG %s :\u0001ACTION %s\u0001" % [here, rest])
				_print(here, "* %s %s" % [client.nick, rest], "#9c009c")
		"nick":
			client.send("NICK " + arg)
		"topic":
			if AgoraIrc.is_channel(arg):
				client.send("TOPIC %s%s" % [arg, (" :" + tail) if not tail.is_empty() else ""])
			else:
				client.send("TOPIC %s%s" % [here, (" :" + rest) if not rest.is_empty() else ""])
		"whois":
			client.send("WHOIS " + arg)
		"away":
			client.send("AWAY" + ((" :" + rest) if not rest.is_empty() else ""))
		"list":
			client.send("LIST")
		"names":
			client.send("NAMES " + (arg if not arg.is_empty() else here))
		"kick":
			client.send("KICK %s %s%s" % [here, arg, (" :" + tail) if not tail.is_empty() else ""])
		"op", "deop", "voice", "devoice":
			var sign := "-" if word.begins_with("de") else "+"
			client.send("MODE %s %s%s %s" % [here, sign, "o" if word.ends_with("op") else "v", arg])
		"quote", "raw":
			client.send(rest)
		"quit":
			client.close(rest if not rest.is_empty() else "Parley")
		"clear":
			if tabs.has(here.to_lower()):
				(tabs[here.to_lower()].log as RichTextLabel).clear()
		_:
			_print(here if not here.is_empty() else STATUS, "* Unknown command: /" + word, "#c00000")


## Says [param text] in the tab [param where] (a channel or a nick).
func say(where: String, text: String) -> void:
	if where == STATUS or where.is_empty():
		_status("* You are not in a channel; /join #channel")
		return
	for line in text.split("\n", false):
		client.send("PRIVMSG %s :%s" % [where, line])
		_print(where, "<%s> %s" % [client.nick, line], "#00007f")


## Opens a tab for talking to [param nick].
func query(nick: String) -> void:
	if nick.is_empty():
		return
	_open_tab(nick)
	show_tab(nick)
