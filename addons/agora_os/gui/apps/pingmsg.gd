extends AgoraGuiProgram
## Ping! Messenger: instant messages over the Ping! network (see pingd).
## The main window holds the contact list, grouped into online, offline and
## people not on the list, with a status menu at the bottom. Double-click a
## contact to talk; each conversation has its own window. Messages that
## come in open their window.
##
## The server comes from /etc/pingmsg.conf ("server=", "port="). The
## account is kept in ~/.pingmsg/account (number, password if saved,
## status, sounds), conversations in ~/.pingmsg/history/NUMBER.
##
## An icon in the panel's notification area shows the status (an envelope
## while a message waits) and shows or hides the list when clicked; the
## buttons of conversations with a new message blink. Messages and friends
## coming online make a sound on /dev/dsp (/usr/share/sounds/pingmsg).
##
## Files go to a contact through the server (Send File in a conversation);
## what one accepts lands in ~/Received Files. Chat rooms ("#name", Rooms
## in the main window) each have a window with the people in them.

const CONF := "/etc/pingmsg.conf"
const DEFAULT_SERVER := "login.pingmsg.com"
const STATUS_COLORS := {
	"online": "#38b438", "ffc": "#2fd0a0", "away": "#e3bd1c", "na": "#e8861a",
	"occupied": "#d8571c", "dnd": "#c42424", "invisible": "#8aa4c8", "offline": "#9c2b2b",
}
const HISTORY_LINES := 50
const SOUNDS := "/usr/share/sounds/pingmsg"

static var _status_icons := {}

var p: AgoraProcess
var client: AgoraPingClient
var win: AgoraWindow
## {uin, password, nick, status, server, port, save_password}
var account := {}
## uin -> {nick, status, listed}
var contacts := {}
## uin -> {win, log (RichTextLabel), input (TextEdit), status (Label)}
var chats := {}
var status := "offline"

var _root := VBoxContainer.new()
var _login := VBoxContainer.new()
var _list_page := VBoxContainer.new()
var _server_edit := LineEdit.new()
var _uin_edit := LineEdit.new()
var _password_edit := LineEdit.new()
var _save_box := CheckBox.new()
var _login_note := Label.new()
var _me := Label.new()
var _tree := Tree.new()
var _status_menu := OptionButton.new()
var _note := Label.new()
var _context := PopupMenu.new()
var _context_uin := ""
var _busy := false
var _display: AgoraDisplay
var _tray_id := 0
## File transfers: "uin:id" -> {dir ("out"/"in"), uin, id, name, size,
## bytes (out), chunks (in), state}
var transfers := {}
## Chat rooms: "#name" -> {win, log, list (ItemList), members (uin -> nick)}
var rooms := {}


func summary() -> String:
	return "Ping! instant messenger"


func usage() -> String:
	return "usage: pingmsg"


func main(proc: AgoraProcess) -> int:
	p = proc
	client = AgoraPingClient.new(p)
	client.received.connect(_on_received)
	client.disconnected.connect(_on_disconnected)
	_load_account()
	_build()
	win = open_window(p, _root, {"title": "Ping!", "size": Vector2(250, 470), "min_size": Vector2(200, 260)})
	if win == null:
		return 1
	_display = display_for(p)
	if _display:
		_tray_id = _display.tray_add(p, status_icon("offline"), "Ping! - Offline", toggle_list)
	_show_page()
	if not str(account.get("uin", "")).is_empty() and not str(account.get("password", "")).is_empty():
		login(str(account.uin), str(account.password), str(account.get("status", "online")))
	await win.closed
	for name: String in rooms.keys():
		rooms[name].win.close()
	client.close()
	for uin: String in chats.keys():
		if chats[uin].win.open:
			chats[uin].win.close()
	_disconnect_signals()
	return 0


func _disconnect_signals() -> void:
	if client.received.is_connected(_on_received):
		client.received.disconnect(_on_received)
	if client.disconnected.is_connected(_on_disconnected):
		client.disconnected.disconnect(_on_disconnected)


# --- settings ------------------------------------------------------------------

func _dir() -> String:
	return p.home() + "/.pingmsg"


func _load_account() -> void:
	account = {"server": conf_value(p, PackedStringArray([CONF]), "server", DEFAULT_SERVER),
		"port": conf_value(p, PackedStringArray([CONF]), "port", str(AgoraPing.PORT)).to_int(), "status": "online", "save_password": true}
	for line in p.read_text(_dir() + "/account").split("\n", false):
		if line.contains("="):
			account[line.get_slice("=", 0).strip_edges()] = line.substr(line.find("=") + 1).strip_edges()
	account.port = int(str(account.port).to_int())
	account.save_password = str(account.get("save_password", "true")) != "false"


func _save_account() -> void:
	p.make_dirs(_dir())
	p.chmod(_dir(), AgoraStat.MODE_PRIVATE_DIR)
	var lines: PackedStringArray = []
	for key in ["uin", "nick", "server", "port", "status", "save_password", "sounds"]:
		if account.has(key):
			lines.append("%s=%s" % [key, str(account[key])])
	if account.save_password and account.has("password"):
		lines.append("password=%s" % account.password)
	p.write_text(_dir() + "/account", "\n".join(lines) + "\n", false, AgoraStat.MODE_PRIVATE_FILE)


func _history_path(uin: String) -> String:
	return "%s/history/%s" % [_dir(), uin]


func _append_history(uin: String, time: int, incoming: bool, text: String) -> void:
	p.make_dirs(_dir() + "/history")
	p.write_text(_history_path(uin), "%d\t%s\t%s\n" % [time, "<" if incoming else ">", AgoraPing.escape(text)], true, AgoraStat.MODE_PRIVATE_FILE)


# --- the main window -----------------------------------------------------------

func _build() -> void:
	_root.add_theme_constant_override("separation", 6)
	var logo := Label.new()
	logo.text = "Ping!"
	logo.add_theme_font_override("font", AgoraStyle.MONO_BOLD)
	logo.add_theme_font_size_override("font_size", 26)
	logo.add_theme_color_override("font_color", Color(STATUS_COLORS.online))
	logo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(logo)
	# Logging in.
	_login.add_theme_constant_override("separation", 4)
	for pair in [["Server:", _server_edit], ["Ping! number:", _uin_edit], ["Password:", _password_edit]]:
		var l := Label.new()
		l.text = pair[0]
		_login.add_child(l)
		_login.add_child(pair[1])
	_password_edit.secret = true
	_password_edit.text_submitted.connect(func(_t: String) -> void: _on_login_pressed())
	_save_box.text = "Save password"
	_login.add_child(_save_box)
	var log_in := Button.new()
	log_in.text = "Log in"
	log_in.pressed.connect(_on_login_pressed)
	_login.add_child(log_in)
	var new_number := Button.new()
	new_number.text = "Get a new Ping! number..."
	new_number.pressed.connect(_on_register_pressed)
	_login.add_child(new_number)
	_login_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_login_note.custom_minimum_size = Vector2(180, 0)
	_login.add_child(_login_note)
	_login.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_login)
	# The contact list.
	_me.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_me.clip_text = true
	_list_page.add_child(_me)
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(_on_item_activated)
	_tree.allow_rmb_select = true
	_tree.item_mouse_selected.connect(_on_item_clicked)
	_list_page.add_child(_tree)
	var buttons := HBoxContainer.new()
	var add := Button.new()
	add.text = "Add"
	add.tooltip_text = "Add a contact by Ping! number"
	add.pressed.connect(_on_add_pressed)
	buttons.add_child(add)
	var find := Button.new()
	find.text = "Find"
	find.tooltip_text = "Find people by nick or number"
	find.pressed.connect(_on_find_pressed)
	buttons.add_child(find)
	var rooms_button := Button.new()
	rooms_button.text = "Rooms"
	rooms_button.tooltip_text = "Chat rooms"
	rooms_button.pressed.connect(_on_rooms_pressed)
	buttons.add_child(rooms_button)
	_list_page.add_child(buttons)
	for s in AgoraPing.STATUSES:
		_status_menu.add_icon_item(status_icon(s), AgoraPing.STATUS_NAMES[s])
	_status_menu.item_selected.connect(func(i: int) -> void: set_status(AgoraPing.STATUSES[i]))
	_list_page.add_child(_status_menu)
	_note.add_theme_font_size_override("font_size", 11)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size = Vector2(180, 0)
	_list_page.add_child(_note)
	_list_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_list_page)
	_context.add_item("Send message", 0)
	_context.add_item("User info", 1)
	_context.add_item("Remove from list", 2)
	_context.id_pressed.connect(_on_context)
	_root.add_child(_context)
	_server_edit.text = str(account.server)
	_uin_edit.text = str(account.get("uin", ""))
	_save_box.button_pressed = account.save_password


## The login form until there is an account, the list after.
func _show_page() -> void:
	var have := not str(account.get("uin", "")).is_empty()
	_login.visible = not have
	_list_page.visible = have
	_me.text = "%s (%s)" % [account.get("nick", ""), account.get("uin", "")]
	_select_status(status)
	if win and win.open:
		win.title = "Ping! %s" % account.get("uin", "") if have else "Ping!"


func _select_status(s: String) -> void:
	_status_menu.select(AgoraPing.STATUSES.find(s))
	update_tray()


## The tray icon: the status light, or an envelope while a conversation
## with a new message waits to be looked at.
func update_tray() -> void:
	if _display == null or _tray_id == 0:
		return
	var waiting: PackedStringArray = []
	for uin: String in chats:
		if chats[uin].win.open and chats[uin].win.urgent:
			waiting.append(_nick(uin))
	if not waiting.is_empty():
		_display.tray_set(_tray_id, message_icon(), "Ping! - message from " + ", ".join(waiting))
	else:
		_display.tray_set(_tray_id, status_icon(status), "Ping! - " + str(AgoraPing.STATUS_NAMES.get(status, status)))


## Shows the contact list, or hides it when it is in front.
func toggle_list() -> void:
	if win.is_focused() and not win.minimized:
		win.set_minimized(true)
	else:
		win.focus()


## A small yellow envelope.
static func message_icon() -> Texture2D:
	if not _status_icons.has("#message"):
		var img := Image.create_empty(14, 14, false, Image.FORMAT_RGBA8)
		img.fill_rect(Rect2i(1, 3, 12, 9), Color("#7a5a10"))
		img.fill_rect(Rect2i(2, 4, 10, 7), Color("#f2d24a"))
		for k in 6:
			img.set_pixel(2 + k, 4 + k / 2 + 1, Color("#7a5a10"))
			img.set_pixel(11 - k, 4 + k / 2 + 1, Color("#7a5a10"))
		_status_icons["#message"] = ImageTexture.create_from_image(img)
	return _status_icons["#message"]


## Plays a sound of the messenger ("message", "online") on the sound card,
## unless sounds are switched off (sounds=false in the account file).
func play_sound(name: String) -> bool:
	if str(account.get("sounds", "true")) == "false" or not p.exists("/dev/dsp"):
		return false
	var file := "%s/%s.wav" % [SOUNDS, name]
	if not p.exists(file):
		return false
	return p.write_bytes("/dev/dsp", p.read_bytes(file)) == AgoraErrno.OK


## A round status light of [param s].
static func status_icon(s: String) -> Texture2D:
	if not _status_icons.has(s):
		var img := Image.create_empty(14, 14, false, Image.FORMAT_RGBA8)
		var color := Color(STATUS_COLORS.get(s, "#888888"))
		for y in 14:
			for x in 14:
				var d := Vector2(x - 6.5, y - 6.5).length()
				if d <= 6.0:
					var c := color.darkened(0.35) if d > 5.0 else color
					if Vector2(x - 4.5, y - 4.5).length() < 1.6:
						c = c.lightened(0.6)
					img.set_pixel(x, y, c)
		if s == "away" or s == "na":
			img.fill_rect(Rect2i(6, 3, 2, 4), Color.WHITE) # a clock hand
			img.fill_rect(Rect2i(6, 6, 3, 2), Color.WHITE)
		elif s == "dnd" or s == "occupied":
			img.fill_rect(Rect2i(3, 6, 8, 2), Color.WHITE)
		_status_icons[s] = ImageTexture.create_from_image(img)
	return _status_icons[s]


func _refresh_list() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var groups := {"online": [], "offline": [], "unlisted": []}
	for uin: String in contacts:
		var c: Dictionary = contacts[uin]
		var g := "unlisted" if not c.listed else ("offline" if c.status == "offline" else "online")
		groups[g].append(uin)
	for g: String in ["online", "offline", "unlisted"]:
		var list: Array = groups[g]
		if list.is_empty() and g == "unlisted":
			continue
		list.sort_custom(func(a: String, b: String) -> bool: return str(contacts[a].nick).to_lower() < str(contacts[b].nick).to_lower())
		var head := _tree.create_item(root)
		head.set_text(0, "%s (%d)" % [{"online": "Online", "offline": "Offline", "unlisted": "Not in list"}[g], list.size()])
		head.set_selectable(0, false)
		head.set_custom_color(0, Color("#7f8fa6"))
		for uin: String in list:
			var item := _tree.create_item(head)
			item.set_icon(0, status_icon(contacts[uin].status))
			item.set_text(0, str(contacts[uin].nick))
			item.set_tooltip_text(0, "%s (%s)\n%s" % [contacts[uin].nick, uin, AgoraPing.STATUS_NAMES[contacts[uin].status]])
			item.set_metadata(0, uin)


func _say(text: String) -> void:
	_note.text = text
	_login_note.text = text


# --- talking to the server -----------------------------------------------------

func _connect() -> String:
	if client.is_connected_to_server():
		return ""
	_say("Connecting to %s..." % account.server)
	return await client.open(str(account.server), int(account.port))


## Logs in. Returns "" or the reason it failed.
func login(uin: String, password: String, wanted: String = "online") -> String:
	if _busy:
		return "busy"
	_busy = true
	var error := await _connect()
	if error.is_empty():
		_say("Logging in...")
		var r := await client.request(["LOGIN", uin, password, wanted if wanted != "offline" else "online"], false, PackedStringArray(["WELCOME"]))
		if r.cmd == "WELCOME":
			account.uin = uin
			account.password = password
			account.nick = r.args[2] if r.args.size() > 2 else uin
			status = r.args[1]
			account.status = status
			_save_account()
			_say("")
		else:
			error = r.args[r.args.size() - 1] if not r.args.is_empty() else "refused"
			client.close()
	_busy = false
	if not error.is_empty():
		_say(error)
	_show_page()
	return error


## Gets a new Ping! number and logs in with it. Returns the number, or "".
func register_account(nick: String, password: String) -> String:
	if _busy:
		return ""
	_busy = true
	var error := await _connect()
	var uin := ""
	if error.is_empty():
		var r := await client.request(["REGISTER", password, nick], true, PackedStringArray(["REGISTERED"]))
		if r.cmd == "REGISTERED":
			uin = r.args[0]
		else:
			error = r.args[r.args.size() - 1] if not r.args.is_empty() else "refused"
	_busy = false
	if uin.is_empty():
		_say(error)
		return ""
	await login(uin, password)
	return uin


func _on_login_pressed() -> void:
	account.server = _server_edit.text.strip_edges()
	account.save_password = _save_box.button_pressed
	await login(_uin_edit.text.strip_edges(), _password_edit.text)


func _on_register_pressed() -> void:
	account.server = _server_edit.text.strip_edges()
	account.save_password = _save_box.button_pressed
	if _password_edit.text.is_empty():
		_say("Choose a password first.")
		return
	var nick: Variant = await AgoraDialog.ask_text(_root, "Your nick:", p.user_name())
	if nick == null or str(nick).strip_edges().is_empty():
		return
	var uin := await register_account(str(nick).strip_edges(), _password_edit.text)
	if not uin.is_empty():
		await AgoraDialog.message(_root, "Your Ping! number is %s.\nTell your friends!" % uin)


func set_status(s: String) -> void:
	if s == status:
		return
	if s == "offline":
		status = "offline"
		client.close()
		_all_offline()
		_say("")
	elif status == "offline":
		await login(str(account.get("uin", "")), str(account.get("password", "")), s)
	else:
		var r := await client.request(["STATUS", s], false, PackedStringArray(["STATUS"]))
		if r.cmd == "STATUS":
			status = s
	account.status = status
	_save_account()
	_select_status(status)


func add_contact(uin: String) -> String:
	var r := await client.request(["ADD", uin], false, PackedStringArray(["CONTACT"]))
	if r.cmd != "CONTACT":
		var why: String = r.args[r.args.size() - 1] if not r.args.is_empty() else "failed"
		_say("%s: %s" % [uin, why])
		return why
	_on_received("CONTACT", r.args)
	return ""


func remove_contact(uin: String) -> void:
	await client.request(["DEL", uin], false, PackedStringArray(["REMOVED"]))
	contacts.erase(uin)
	_refresh_list()


func send_message(uin: String, text: String) -> String:
	if text.strip_edges().is_empty():
		return ""
	if not client.is_connected_to_server():
		return "You are offline"
	var r := await client.request(["MSG", uin, text], true, PackedStringArray(["SENT", "STORED"]))
	if r.cmd == "ERROR":
		var why: String = r.args[r.args.size() - 1]
		_chat_note(uin, "Not sent: " + why)
		return why
	var now := int(p.machine.clock.now())
	_append_history(uin, now, false, text)
	_chat_line(uin, now, false, text)
	if r.cmd == "STORED":
		_chat_note(uin, "%s is offline; the message will wait on the server." % _nick(uin))
	return ""


func _nick(uin: String) -> String:
	return str(contacts[uin].nick) if contacts.has(uin) else uin


func _all_offline() -> void:
	for uin: String in contacts:
		contacts[uin].status = "offline"
	_refresh_list()


func _on_received(cmd: String, args: PackedStringArray) -> void:
	match cmd:
		"CONTACT", "INFO", "FOUND":
			if args.size() < 3:
				return
			var listed: bool = cmd == "CONTACT" or (contacts.has(args[0]) and contacts[args[0]].listed)
			if cmd == "FOUND" and not contacts.has(args[0]):
				return
			contacts[args[0]] = {"nick": args[2], "status": args[1], "listed": listed}
			_refresh_list()
			_update_chat_title(args[0])
		"PRESENCE":
			if args.size() >= 2 and contacts.has(args[0]):
				var before: String = contacts[args[0]].status
				contacts[args[0]].status = args[1]
				_refresh_list()
				if before == "offline" and args[1] != "offline" and contacts[args[0]].listed:
					play_sound("online")
				if before != args[1] and chats.has(args[0]):
					_chat_note(args[0], "%s is %s" % [_nick(args[0]), AgoraPing.STATUS_NAMES.get(args[1], args[1])])
					_update_chat_title(args[0])
		"MSG", "OFFLINE":
			if args.size() >= 3:
				_incoming(args[0], args[1].to_int(), args[2], cmd == "OFFLINE")
		"NICK":
			if args.size() >= 2 and args[0] == str(account.get("uin", "")):
				account.nick = args[1]
				_save_account()
				_show_page()
		"FILE":
			if args.size() >= 4:
				_file_offered(args[0], args[1], args[2].to_int(), args[3])
		"ACCEPTED":
			if args.size() >= 2:
				_send_file_data("%s:%s" % [args[0], args[1]])
		"DECLINED":
			var key := "%s:%s" % [args[0], args[1]] if args.size() >= 2 else ""
			if transfers.has(key):
				transfers[key].state = "declined"
				_chat_note(args[0], "%s declined %s." % [_nick(args[0]), transfers[key].name])
		"DATA":
			var key := "%s:%s" % [args[0], args[1]] if args.size() >= 2 else ""
			if transfers.has(key) and transfers[key].state == "accepted":
				var chunks: PackedStringArray = transfers[key].chunks
				chunks.append(args[2] if args.size() > 2 else "")
				transfers[key].chunks = chunks
		"DONE":
			if args.size() >= 2:
				_file_received("%s:%s" % [args[0], args[1]])
		"JOINED", "MEMBER":
			if args.size() >= 3 and rooms.has(args[0]):
				var fresh := not (rooms[args[0]].members as Dictionary).has(args[1])
				rooms[args[0]].members[args[1]] = args[2]
				_room_members(args[0])
				if cmd == "JOINED" and fresh and args[1] != str(account.get("uin", "")):
					_room_note(args[0], "%s joined %s" % [args[2], args[0]])
		"PARTED":
			if args.size() >= 2 and rooms.has(args[0]):
				var nick := str(rooms[args[0]].members.get(args[1], args[1]))
				(rooms[args[0]].members as Dictionary).erase(args[1])
				_room_members(args[0])
				_room_note(args[0], "%s left" % nick)
		"SAID":
			if args.size() >= 4 and rooms.has(args[0]):
				_room_line(args[0], args[1], args[2].to_int(), args[3])
		"KICKED":
			status = "offline"
			_all_offline()
			_select_status(status)
			_say(args[0] if not args.is_empty() else "Disconnected by the server")


func _on_disconnected(reason: String) -> void:
	if status != "offline" and not reason.is_empty():
		_say(reason)
	status = "offline"
	_all_offline()
	_select_status(status)


func _incoming(uin: String, time: int, text: String, waited: bool) -> void:
	if not contacts.has(uin):
		contacts[uin] = {"nick": uin, "status": "offline", "listed": false}
		_refresh_list()
		client.send(["INFO", uin])
	open_chat(uin, false)
	_chat_line(uin, time, true, text, waited)
	_append_history(uin, time, true, text)
	play_sound("message")
	var w: AgoraWindow = chats[uin].win if chats.has(uin) else null
	if w and not w.is_focused():
		w.urgent = true
		update_tray()


# --- conversations -------------------------------------------------------------

func _on_item_activated() -> void:
	var item := _tree.get_selected()
	if item and item.get_metadata(0) != null:
		open_chat(str(item.get_metadata(0)))


func _on_item_clicked(_pos: Vector2, button: int) -> void:
	var item := _tree.get_selected()
	if button != MOUSE_BUTTON_RIGHT or item == null or item.get_metadata(0) == null:
		return
	_context_uin = str(item.get_metadata(0))
	_context.reset_size()
	_context.popup(Rect2i(Vector2i(_tree.get_global_mouse_position()), Vector2i.ZERO))


func _on_context(id: int) -> void:
	match id:
		0:
			open_chat(_context_uin)
		1:
			var r := await client.request(["INFO", _context_uin], false, PackedStringArray(["INFO"]))
			if r.cmd == "INFO":
				_on_received("INFO", r.args)
				await AgoraDialog.message(_root, "%s\nPing! number: %s\nStatus: %s" % [r.args[2], r.args[0], AgoraPing.STATUS_NAMES.get(r.args[1], r.args[1])])
		2:
			if await AgoraDialog.choose(_root, "Remove %s from your list?" % _nick(_context_uin), PackedStringArray(["Remove", "Cancel"])) == 0:
				await remove_contact(_context_uin)


func _on_add_pressed() -> void:
	var uin: Variant = await AgoraDialog.ask_text(_root, "Ping! number to add:", "")
	if uin != null and not str(uin).strip_edges().is_empty():
		await add_contact(str(uin).strip_edges())


func _on_find_pressed() -> void:
	var what: Variant = await AgoraDialog.ask_text(_root, "Find people (nick or number):", "")
	if what == null:
		return
	var found := await search(str(what))
	if found.is_empty():
		await AgoraDialog.message(_root, "Nobody found.")
		return
	var names: PackedStringArray = []
	for f: Dictionary in found.slice(0, 3):
		names.append("%s (%s)" % [f.nick, f.uin])
	var buttons := names.duplicate()
	buttons.append("Cancel")
	var choice := await AgoraDialog.choose(_root, "Found %d. Add one to your list:" % found.size(), buttons)
	if choice >= 0 and choice < names.size():
		await add_contact(str(found[choice].uin))


## People whose nick contains [param what] (or with that number):
## [{uin, nick, status}].
func search(what: String) -> Array:
	var r := await client.request(["SEARCH", what], true, PackedStringArray(["END"]), PackedStringArray(["FOUND"]))
	var out: Array = []
	for line: Dictionary in r.get("lines", []):
		if line.args.size() >= 3:
			out.append({"uin": line.args[0], "status": line.args[1], "nick": line.args[2]})
	return out


## Opens (or brings up) the conversation with [param uin].
func open_chat(uin: String, focus: bool = true) -> void:
	if chats.has(uin) and chats[uin].win.open:
		if focus:
			chats[uin].win.focus()
		return
	var box := VBoxContainer.new()
	var log := RichTextLabel.new()
	log.bbcode_enabled = true
	log.scroll_following = true
	log.selection_enabled = true
	log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(log)
	var state := Label.new()
	state.add_theme_font_size_override("font_size", 11)
	box.add_child(state)
	var input := TextEdit.new()
	input.custom_minimum_size = Vector2(0, 64)
	input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	box.add_child(input)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	var send_file := Button.new()
	send_file.text = "Send File..."
	send_file.pressed.connect(func() -> void:
		var path: Variant = await AgoraDialog.ask_text(box, "File to send (from your home folder):", "")
		if path != null:
			var why := await offer_file(uin, str(path))
			if not why.is_empty():
				_chat_note(uin, why))
	row.add_child(send_file)
	var offers := HBoxContainer.new()
	box.add_child(offers)
	box.move_child(offers, box.get_child_count() - 2)
	var send := Button.new()
	send.text = "Send"
	row.add_child(send)
	box.add_child(row)
	var w := open_window(p, box, {"title": "", "size": Vector2(380, 340), "min_size": Vector2(240, 200), "focus": focus})
	if w == null:
		return
	w.focus_target = input
	chats[uin] = {"win": w, "log": log, "input": input, "status": state, "offers": offers}
	var submit := func() -> void:
		var text := input.text
		input.text = ""
		await send_message(uin, text)
	send.pressed.connect(submit)
	input.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventKey and e.pressed and e.keycode in [KEY_ENTER, KEY_KP_ENTER] and not e.shift_pressed:
			input.accept_event()
			submit.call())
	w.closed.connect(func() -> void:
		chats.erase(uin)
		update_tray(), CONNECT_ONE_SHOT)
	# Looking at the window answers its blinking.
	w.changed.connect(func() -> void:
		if not w.urgent:
			update_tray())
	_update_chat_title(uin)
	# The end of earlier conversations.
	var lines := p.read_text(_history_path(uin)).split("\n", false)
	for line in lines.slice(maxi(0, lines.size() - HISTORY_LINES)):
		var f := line.split("\t")
		if f.size() >= 3:
			_chat_line(uin, f[0].to_int(), f[1] == "<", AgoraPing.unescape(f[2]), false, true)


func _update_chat_title(uin: String) -> void:
	if not chats.has(uin):
		return
	var c: Dictionary = contacts.get(uin, {"nick": uin, "status": "offline"})
	chats[uin].win.title = "%s (%s) - Ping!" % [c.nick, uin]
	chats[uin].status.text = AgoraPing.STATUS_NAMES.get(c.status, c.status)


static func _bb(text: String) -> String:
	return text.replace("[", "[lb]")


func _chat_line(uin: String, time: int, incoming: bool, text: String, waited: bool = false, old: bool = false) -> void:
	if not chats.has(uin):
		return
	var d := p.machine.clock.local_datetime(float(time))
	var who := _nick(uin) if incoming else str(account.get("nick", "me"))
	var color := "#d04040" if incoming else "#3a70c8"
	if old:
		color = Color(color).lerp(Color("#888888"), 0.5).to_html(false)
	var stamp := "%02d:%02d" % [d.hour, d.minute]
	if waited:
		stamp = "%02d.%02d.%d %s" % [d.day, d.month, d.year, stamp]
	var log: RichTextLabel = chats[uin].log
	log.append_text("[color=%s][b]%s[/b] (%s)[/color]\n%s\n" % [color, _bb(who), stamp, _bb(text)])


func _chat_note(uin: String, text: String) -> void:
	if chats.has(uin):
		(chats[uin].log as RichTextLabel).append_text("[color=#808080][i]%s[/i][/color]\n" % _bb(text))


# --- files ---------------------------------------------------------------------

## Offers the file at [param path] (from the home folder) to [param uin].
## Returns "" or why not; the file goes once the other one accepts.
func offer_file(uin: String, path: String) -> String:
	var full := path if path.begins_with("/") else p.home() + "/" + path
	if not p.exists(full) or p.is_dir(full):
		return "There is no file %s." % path
	var bytes := p.read_bytes(full)
	if bytes.size() > AgoraPing.MAX_FILE:
		return "%s is too big to send (at most 1 MB)." % AgoraPath.basename(full)
	var id := str(randi() % 1000000)
	var name := AgoraPath.basename(full)
	var r := await client.request(["FILE", uin, id, str(bytes.size()), name], true, PackedStringArray(["OFFERED"]))
	if r.cmd == "ERROR":
		return str(r.args[-1])
	transfers["%s:%s" % [uin, id]] = {"dir": "out", "uin": uin, "id": id, "name": name, "size": bytes.size(), "bytes": bytes, "state": "offered"}
	open_chat(uin, false)
	_chat_note(uin, "Offering %s (%s) to %s..." % [name, _size_text(bytes.size()), _nick(uin)])
	return ""


static func _size_text(n: int) -> String:
	return "%d bytes" % n if n < 1024 else "%d KB" % ceili(n / 1024.0)


func _send_file_data(key: String) -> void:
	if not transfers.has(key) or transfers[key].dir != "out" or transfers[key].state != "offered":
		return
	var t: Dictionary = transfers[key]
	t.state = "sending"
	var text := Marshalls.raw_to_base64(t.bytes)
	for k in range(0, text.length(), AgoraPing.CHUNK):
		client.send(["DATA", t.uin, t.id, text.substr(k, AgoraPing.CHUNK)], true)
		await p.tick()
	client.send(["DONE", t.uin, t.id])
	t.state = "sent"
	_chat_note(t.uin, "%s sent." % t.name)


func _file_offered(uin: String, id: String, size: int, name: String) -> void:
	var key := "%s:%s" % [uin, id]
	transfers[key] = {"dir": "in", "uin": uin, "id": id, "name": AgoraPath.basename(name), "size": size, "chunks": PackedStringArray(), "state": "offered"}
	if not contacts.has(uin):
		contacts[uin] = {"nick": uin, "status": "online", "listed": false}
		client.send(["INFO", uin])
	open_chat(uin, false)
	_chat_note(uin, "%s sends you %s (%s)." % [_nick(uin), name, _size_text(size)])
	play_sound("message")
	if chats.has(uin):
		var bar: HBoxContainer = chats[uin].offers
		var label := Label.new()
		label.text = name
		bar.add_child(label)
		for pair in [["Accept", accept_file], ["Decline", decline_file]]:
			var b := Button.new()
			b.text = pair[0]
			b.pressed.connect(func() -> void:
				for c in bar.get_children():
					c.queue_free()
				(pair[1] as Callable).call(uin, id))
			bar.add_child(b)
		if not chats[uin].win.is_focused():
			chats[uin].win.urgent = true
			update_tray()


func accept_file(uin: String, id: String) -> void:
	var key := "%s:%s" % [uin, id]
	if transfers.has(key) and transfers[key].state == "offered":
		transfers[key].state = "accepted"
		client.send(["ACCEPT", uin, id])
		_chat_note(uin, "Receiving %s..." % transfers[key].name)


func decline_file(uin: String, id: String) -> void:
	var key := "%s:%s" % [uin, id]
	if transfers.has(key) and transfers[key].state == "offered":
		transfers[key].state = "declined"
		client.send(["DECLINE", uin, id])


func _file_received(key: String) -> void:
	if not transfers.has(key) or transfers[key].dir != "in" or transfers[key].state != "accepted":
		return
	var t: Dictionary = transfers[key]
	var bytes := Marshalls.base64_to_raw("".join(t.chunks))
	var dir := p.home() + "/Received Files"
	p.make_dirs(dir)
	var path := dir + "/" + str(t.name)
	var n := 1
	while p.exists(path):
		path = "%s/%s.%d" % [dir, t.name, n]
		n += 1
	p.write_bytes(path, bytes)
	t.state = "received"
	t.path = path
	_chat_note(t.uin, "Received %s (%s), saved as %s" % [t.name, _size_text(bytes.size()), path])


# --- chat rooms ----------------------------------------------------------------

## The rooms on the server: [{name, people}].
func list_rooms() -> Array:
	var r := await client.request(["ROOMS"], false, PackedStringArray(["END"]), PackedStringArray(["ROOM"]))
	var out: Array = []
	for line: Dictionary in r.get("lines", []):
		out.append({"name": line.args[0], "people": int(line.args[1])})
	return out


## Joins [param name] ("#linux") and opens its window. Returns "" or why not.
func join_room(name: String) -> String:
	name = name.strip_edges().to_lower()
	if not name.begins_with("#"):
		name = "#" + name
	if rooms.has(name):
		rooms[name].win.focus()
		return ""
	if not AgoraPing.is_room(name):
		return "A room's name is # and letters or digits."
	_open_room(name)
	var r := await client.request(["JOIN", name], false, PackedStringArray(["END"]), PackedStringArray(["MEMBER"]))
	if r.cmd == "ERROR":
		rooms[name].win.close()
		return str(r.args[-1])
	for line: Dictionary in r.get("lines", []):
		if line.args.size() >= 3:
			rooms[name].members[line.args[1]] = line.args[2]
	_room_members(name)
	return ""


func say_room(name: String, text: String) -> void:
	if not text.strip_edges().is_empty() and rooms.has(name):
		client.send(["SAY", name, text], true)


func part_room(name: String) -> void:
	if rooms.has(name):
		rooms[name].win.close()


func _open_room(name: String) -> void:
	var split := HSplitContainer.new()
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var log := RichTextLabel.new()
	log.bbcode_enabled = true
	log.scroll_following = true
	log.selection_enabled = true
	log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(log)
	var input := LineEdit.new()
	left.add_child(input)
	split.add_child(left)
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(110, 0)
	split.add_child(list)
	var w := open_window(p, split, {"title": "%s - Ping! chat" % name, "size": Vector2(460, 320), "min_size": Vector2(280, 200)})
	if w == null:
		return
	w.focus_target = input
	rooms[name] = {"win": w, "log": log, "list": list, "members": {}}
	input.text_submitted.connect(func(t: String) -> void:
		input.text = ""
		say_room(name, t))
	w.closed.connect(func() -> void:
		rooms.erase(name)
		client.send(["PART", name]), CONNECT_ONE_SHOT)


func _room_members(name: String) -> void:
	var list: ItemList = rooms[name].list
	list.clear()
	var nicks: Array = (rooms[name].members as Dictionary).values()
	nicks.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	for nick: String in nicks:
		list.add_item(nick)


func _room_line(name: String, uin: String, time: int, text: String) -> void:
	var d := p.machine.clock.local_datetime(float(time))
	var nick := str(rooms[name].members.get(uin, uin))
	var color := "#3a70c8" if uin == str(account.get("uin", "")) else "#d04040"
	(rooms[name].log as RichTextLabel).append_text("[color=%s][b]%s[/b] (%02d:%02d)[/color] %s\n" % [color, _bb(nick), d.hour, d.minute, _bb(text)])


func _room_note(name: String, text: String) -> void:
	if rooms.has(name):
		(rooms[name].log as RichTextLabel).append_text("[color=#808080][i]%s[/i][/color]\n" % _bb(text))


## A room window's text, without markup (tests).
func room_text(name: String) -> String:
	return (rooms[name].log as RichTextLabel).get_parsed_text() if rooms.has(name) else ""


func _on_rooms_pressed() -> void:
	var listed: Array = await list_rooms()
	var names: PackedStringArray = []
	for r: Dictionary in listed:
		names.append("%s (%d)" % [r.name, r.people])
	var prompt := "Rooms now: %s\nJoin which room?" % (", ".join(names) if not names.is_empty() else "none yet")
	var what: Variant = await AgoraDialog.ask_text(_root, prompt, "#")
	if what != null:
		var why := await join_room(str(what))
		if not why.is_empty():
			await AgoraDialog.message(_root, why)


## The text shown in a conversation window, without markup (for tests and
## screen readers).
func chat_text(uin: String) -> String:
	return (chats[uin].log as RichTextLabel).get_parsed_text() if chats.has(uin) else ""
