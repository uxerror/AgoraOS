extends AgoraGuiProgram
## Pigeon Mail: the graphical mail program. Folders on the left, the
## messages of the open folder at the top, the selected message below; a
## window of its own for writing one.
##
## Mail comes from the local mailbox (/var/mail/USER, moved into the
## Inbox) or from a POP3 server, and goes out through /usr/sbin/sendmail
## or an SMTP server, as set under Tools, Accounts. Folders are mbox files
## in ~/Mail (Inbox, Sent, Drafts, Trash and folders of one's own), so other
## mail programs can read them; the account is kept in ~/.pigeon/account,
## the address book in ~/.pigeon/addressbook ("Name<TAB>address" lines).
## Messages are MIME: attachments in and out, quoted-printable and base64,
## encoded headers. The message list sorts by a column when its title is
## clicked.

const VERSION := "1.0"
const FOLDERS: PackedStringArray = ["Inbox", "Sent", "Drafts", "Trash"]
const SENDMAIL := "/usr/sbin/sendmail"
const DAYS: PackedStringArray = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS: PackedStringArray = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var p: AgoraProcess
var win: AgoraWindow
## {name, address, incoming ("local" or "pop3"), pop3_server, pop3_port,
## pop3_user, pop3_password, keep, outgoing ("local" or "smtp"),
## smtp_server, smtp_port, check_minutes}
var account := {}
## The open folder and its messages (AgoraMbox messages).
var folder := "Inbox"
var messages: Array = []
var current := -1
## Compose windows: {win, to, cc, subject, body, draft_of, files}
var composers: Array = []
## How the list is sorted: column (0 From, 1 Subject, 2 Received, -1 as in
## the folder) and direction.
var sort_column := -1
var sort_ascending := true

var _root := VBoxContainer.new()
var _folders := Tree.new()
var _list := Tree.new()
var _head := Label.new()
var _attach_bar := HBoxContainer.new()
var _move_button := MenuButton.new()
var _body := TextEdit.new()
var _html := AgoraHtmlView.new()
var _html_scroll := ScrollContainer.new()
var _status := Label.new()
var _bold: Font
var _checking := false
var _last_check := 0


func summary() -> String:
	return "Pigeon Mail, the mail program"


func usage() -> String:
	return "usage: pigeon"


func main(proc: AgoraProcess) -> int:
	p = proc
	_load_account()
	for f in FOLDERS:
		_ensure_folder(f)
	_build()
	win = open_window(p, _root, {"title": "Inbox - Pigeon Mail", "size": Vector2(860, 600), "min_size": Vector2(420, 300)})
	if win == null:
		return 1
	open_folder("Inbox")
	check_mail()
	while win.open and p.is_running():
		await p.sleep(5.0)
		var every := int(account.get("check_minutes", 10))
		if every > 0 and Time.get_ticks_msec() - _last_check > every * 60000:
			await check_mail()
	for c: Dictionary in composers.duplicate():
		if c.win.open:
			c.win.close()
	return 0


# --- the account ---------------------------------------------------------------

func _dir() -> String:
	return p.home() + "/.pigeon"


func _mail_dir() -> String:
	return p.home() + "/Mail"


func _load_account() -> void:
	var me := p.user_name()
	var mailname := p.read_text("/etc/mailname").strip_edges()
	if mailname.is_empty():
		mailname = p.machine.hostname
	var gecos := str(p.machine.users.find(me).get("gecos", "")).get_slice(",", 0)
	account = {"name": gecos if not gecos.is_empty() else me, "address": "%s@%s" % [me, mailname],
		"incoming": "local", "pop3_server": "", "pop3_port": 110, "pop3_user": me, "pop3_password": "", "keep": false,
		"outgoing": "local", "smtp_server": "", "smtp_port": 25, "check_minutes": 10}
	for line in p.read_text(_dir() + "/account").split("\n", false):
		if not line.contains("="):
			continue
		var key := line.get_slice("=", 0).strip_edges()
		var value := line.substr(line.find("=") + 1).strip_edges()
		if account.has(key):
			match typeof(account[key]):
				TYPE_INT: account[key] = value.to_int()
				TYPE_BOOL: account[key] = value == "true"
				_: account[key] = value


func save_account() -> void:
	p.make_dirs(_dir())
	p.chmod(_dir(), AgoraStat.MODE_PRIVATE_DIR)
	var lines: PackedStringArray = []
	for key: String in account:
		lines.append("%s=%s" % [key, str(account[key])])
	p.write_text(_dir() + "/account", "\n".join(lines) + "\n", false, AgoraStat.MODE_PRIVATE_FILE)


# --- folders -------------------------------------------------------------------

func _folder_path(name: String) -> String:
	return "%s/%s" % [_mail_dir(), name]


## Every folder: the four standard ones, then one's own in name order.
func folder_names() -> PackedStringArray:
	var out := FOLDERS.duplicate()
	var own: Array = []
	for name in p.list_dir(_mail_dir()):
		if not FOLDERS.has(name) and not name.begins_with(".") and not p.is_dir(_folder_path(name)):
			own.append(name)
	own.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	for name: String in own:
		out.append(name)
	return out


## A folder of one's own. Returns "" or why not.
func create_folder(name: String) -> String:
	name = name.strip_edges()
	if name.is_empty() or name.contains("/") or name.begins_with("."):
		return "That is not a name for a folder."
	if folder_names().has(name):
		return "There is a folder called %s already." % name
	_ensure_folder(name)
	_refresh()
	return ""


## Deletes a folder of one's own, its messages going to Trash.
func delete_folder(name: String) -> String:
	if FOLDERS.has(name) or not folder_names().has(name):
		return "Only folders of your own can be deleted."
	_append_folder("Trash", read_folder(name))
	p.unlink(_folder_path(name))
	if folder == name:
		open_folder("Inbox")
	else:
		_refresh()
	return ""


## Moves the selected message to [param target].
func move_selected(target: String) -> void:
	if current < 0 or current >= messages.size() or target == folder or not folder_names().has(target):
		return
	_append_folder(target, [messages[current]])
	messages.remove_at(current)
	_write_folder(folder, messages)
	current = mini(current, messages.size() - 1)
	_refresh()
	_show_message(current)


func _ensure_folder(name: String) -> void:
	if not p.exists(_folder_path(name)):
		p.make_dirs(_mail_dir())
		p.chmod(_mail_dir(), AgoraStat.MODE_PRIVATE_DIR)
		p.write_text(_folder_path(name), "", false, AgoraStat.MODE_PRIVATE_FILE)


func read_folder(name: String) -> Array:
	return AgoraMbox.parse(p.read_text(_folder_path(name)))


func _write_folder(name: String, list: Array) -> void:
	var text := ""
	for m: Dictionary in list:
		text += AgoraMbox.to_text(m)
	p.write_text(_folder_path(name), text, false, AgoraStat.MODE_PRIVATE_FILE)


func _append_folder(name: String, list: Array) -> void:
	var text := ""
	for m: Dictionary in list:
		text += AgoraMbox.to_text(m)
	p.write_text(_folder_path(name), text, true, AgoraStat.MODE_PRIVATE_FILE)


static func is_read(m: Dictionary) -> bool:
	return str(m.status).contains("R")


static func _set_status(m: Dictionary, status: String) -> void:
	m.status = status
	var headers: Array = []
	for h: String in m.headers:
		if h.get_slice(":", 0).to_lower() != "status":
			headers.append(h)
	headers.append("Status: %s\n" % status)
	m.headers = headers


func unread_count(name: String) -> int:
	var list := messages if name == folder else read_folder(name)
	return list.filter(func(m: Dictionary) -> bool: return not is_read(m)).size()


func open_folder(name: String) -> void:
	folder = name
	messages = read_folder(name)
	current = -1
	_refresh()
	_show_message(-1)


# --- the window ----------------------------------------------------------------

func _build() -> void:
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	fv.variation_embolden = 0.8
	_bold = fv
	_root.add_theme_constant_override("separation", 2)
	var bar := HBoxContainer.new()
	for pair in [["New Mail", new_mail], ["Reply", func() -> void: reply(false)], ["Reply All", func() -> void: reply(true)],
			["Forward", forward], ["Delete", delete_selected], ["Send/Recv", check_mail], ["Addresses", address_book_window],
			["New Folder...", new_folder_dialog], ["Accounts...", accounts_dialog]]:
		var b := Button.new()
		b.text = pair[0]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 34)
		b.pressed.connect(pair[1])
		bar.add_child(b)
	_move_button.text = "Move To"
	_move_button.focus_mode = Control.FOCUS_NONE
	_move_button.custom_minimum_size = Vector2(0, 34)
	_move_button.about_to_popup.connect(func() -> void:
		var menu := _move_button.get_popup()
		menu.clear()
		for name in folder_names():
			if name != folder:
				menu.add_item(name))
	_move_button.get_popup().index_pressed.connect(func(i: int) -> void: move_selected(_move_button.get_popup().get_item_text(i)))
	bar.add_child(_move_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	var logo := Label.new()
	logo.text = "Pigeon Mail "
	logo.add_theme_font_override("font", _bold)
	logo.add_theme_color_override("font_color", Color("#8fb4d8"))
	bar.add_child(logo)
	_root.add_child(bar)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_folders.hide_root = true
	_folders.custom_minimum_size = Vector2(150, 0)
	_folders.item_selected.connect(func() -> void:
		var it := _folders.get_selected()
		if it and str(it.get_metadata(0)) != folder:
			open_folder(str(it.get_metadata(0))))
	split.add_child(_folders)
	var right := VSplitContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.columns = 3
	_list.hide_root = true
	_list.column_titles_visible = true
	for k in 3:
		_list.set_column_title(k, ["From", "Subject", "Received"][k])
		_list.set_column_expand(k, k != 2)
	_list.set_column_custom_minimum_width(2, 165)
	_list.select_mode = Tree.SELECT_ROW
	_list.custom_minimum_size = Vector2(0, 180)
	_list.item_selected.connect(func() -> void:
		var it := _list.get_selected()
		if it:
			select_message(int(it.get_metadata(0))))
	_list.column_title_clicked.connect(func(column: int, _button: int) -> void:
		sort_by(column, not sort_ascending if column == sort_column else true))
	_list.item_activated.connect(func() -> void:
		if folder == "Drafts" and current >= 0:
			_open_draft(current))
	right.add_child(_list)
	var pane := VBoxContainer.new()
	pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_head.add_theme_font_size_override("font_size", 13)
	pane.add_child(_head)
	_attach_bar.visible = false
	pane.add_child(_attach_bar)
	_body.editable = false
	_body.add_theme_color_override("font_readonly_color", _body.get_theme_color("font_color"))
	_body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_font_size_override("font_size", 14)
	pane.add_child(_body)
	_html_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_html_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_html.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_html_scroll.add_child(_html)
	_html_scroll.visible = false
	pane.add_child(_html_scroll)
	right.add_child(pane)
	split.add_child(right)
	_root.add_child(split)
	_status.add_theme_font_size_override("font_size", 12)
	_root.add_child(_status)


func _say(text: String) -> void:
	_status.text = " " + text


func _refresh() -> void:
	_folders.clear()
	var root := _folders.create_item()
	for f in folder_names():
		var it := _folders.create_item(root)
		var n := unread_count(f)
		it.set_text(0, "%s (%d)" % [f, n] if n > 0 else f)
		it.set_metadata(0, f)
		if n > 0:
			it.set_custom_font(0, _bold)
		if f == folder:
			it.select(0)
	_list.clear()
	var lroot := _list.create_item()
	for k: int in view_order():
		var m: Dictionary = messages[k]
		var it := _list.create_item(lroot)
		it.set_text(0, _who(m))
		it.set_text(1, AgoraMimeMail.decode_words(AgoraMbox.field(m.headers, "subject")))
		it.set_text(2, received_text(m))
		it.set_metadata(0, k)
		if not is_read(m):
			for c in 3:
				it.set_custom_font(c, _bold)
		if k == current:
			it.select(0)
	for c in 3:
		var title: String = ["From" if not folder in ["Sent", "Drafts"] else "To", "Subject", "Received"][c]
		_list.set_column_title(c, title + (" ▲" if sort_ascending else " ▼") if c == sort_column else title)
	var unread := messages.filter(func(m: Dictionary) -> bool: return not is_read(m)).size()
	_say("%d message(s), %d unread" % [messages.size(), unread])
	if win and win.open:
		win.title = "%s - Pigeon Mail" % folder


func _who(m: Dictionary) -> String:
	var who := AgoraMbox.field(m.headers, "to") if folder in ["Sent", "Drafts"] else AgoraMbox.field(m.headers, "from")
	return AgoraMbox.display_name(AgoraMimeMail.decode_words(who))


## The messages' indexes in the order the list shows them.
func view_order() -> Array:
	var order: Array = range(messages.size())
	if sort_column < 0:
		return order
	var keys := {}
	for k: int in order:
		var m: Dictionary = messages[k]
		match sort_column:
			0: keys[k] = _who(m).to_lower()
			1:
				var subj := AgoraMimeMail.decode_words(AgoraMbox.field(m.headers, "subject")).to_lower()
				for prefix in ["re: ", "fw: ", "fwd: "]:
					subj = subj.trim_prefix(prefix)
				keys[k] = subj
			_: keys[k] = sortable_received(m)
	order.sort_custom(func(a: int, b: int) -> bool:
		if keys[a] == keys[b]:
			return a < b
		return (str(keys[a]) < str(keys[b])) == sort_ascending)
	return order


## Sorts the list by [param column] (0 From, 1 Subject, 2 Received).
func sort_by(column: int, ascending: bool = true) -> void:
	sort_column = column
	sort_ascending = ascending
	_refresh()


## "2003/10/18 21:30:05" from the From line, to sort by.
static func sortable_received(m: Dictionary) -> String:
	var parts := str(m.from_line).split(" ", false)
	if parts.size() < 7:
		return ""
	return "%s/%02d/%02d %s" % [parts[6], MONTHS.find(parts[3]) + 1, parts[4].to_int(), parts[5]]


## "10/18/2003 21:30" from the message's From line.
static func received_text(m: Dictionary) -> String:
	var parts := str(m.from_line).split(" ", false)
	if parts.size() < 7:
		return ""
	var month := MONTHS.find(parts[3]) + 1
	return "%02d/%02d/%s %s" % [month, parts[4].to_int(), parts[6], parts[5].left(5)]


func select_message(k: int) -> void:
	current = k
	if k >= 0 and k < messages.size() and not is_read(messages[k]):
		_set_status(messages[k], "RO")
		_write_folder(folder, messages)
		_refresh()
	_show_message(k)


func _show_message(k: int) -> void:
	if k < 0 or k >= messages.size():
		_head.text = ""
		_body.text = ""
		_html_scroll.visible = false
		_body.visible = true
		return
	var m: Dictionary = messages[k]
	var lines: PackedStringArray = []
	for pair in [["From", "from"], ["Date", "date"], ["To", "to"], ["Cc", "cc"], ["Subject", "subject"]]:
		var v := AgoraMimeMail.decode_words(AgoraMbox.field(m.headers, pair[1]))
		if not v.is_empty():
			lines.append("%s: %s" % [pair[0], v])
	_head.text = "\n".join(lines)
	var mime := AgoraMimeMail.parse(m.headers, str(m.body))
	var shown := AgoraMimeMail.body_of(mime)
	if shown.get("html", false):
		_html.set_page(str(shown.text), "about:blank")
		_html_scroll.visible = true
		_body.visible = false
	else:
		_body.text = str(shown.get("text", ""))
		_html_scroll.visible = false
		_body.visible = true
	_show_attachments(AgoraMimeMail.attachments(mime))


func _show_attachments(files: Array) -> void:
	for c in _attach_bar.get_children():
		c.queue_free()
	_attach_bar.visible = not files.is_empty()
	if files.is_empty():
		return
	var l := Label.new()
	l.text = "Attach:"
	_attach_bar.add_child(l)
	for k in files.size():
		var f: Dictionary = files[k]
		var b := Button.new()
		b.text = "%s (%s)" % [f.filename, _size_text((f.data as PackedByteArray).size())]
		b.tooltip_text = "Save to your home folder"
		b.pressed.connect(func() -> void:
			var r := save_attachment(k)
			_say(r if r.begins_with("Could") else "Saved to " + r))
		_attach_bar.add_child(b)


static func _size_text(n: int) -> String:
	return "%d bytes" % n if n < 1024 else "%d KB" % ceili(n / 1024.0)


## The attachments of the selected message: [{filename, type, data}].
func attachments_of_current() -> Array:
	if current < 0 or current >= messages.size():
		return []
	var m: Dictionary = messages[current]
	return AgoraMimeMail.attachments(AgoraMimeMail.parse(m.headers, str(m.body)))


## Saves attachment [param k] of the selected message to [param path] (by
## default its name in the home folder, numbered if that is taken).
## Returns the path, or "Could not ...".
func save_attachment(k: int, path: String = "") -> String:
	var files := attachments_of_current()
	if k < 0 or k >= files.size():
		return "Could not find that attachment."
	var name := AgoraPath.basename(str(files[k].filename))
	if path.is_empty():
		path = p.home() + "/" + name
		var n := 1
		while p.exists(path):
			path = "%s/%s.%d" % [p.home(), name, n]
			n += 1
	if p.write_bytes(path, files[k].data) != AgoraErrno.OK:
		return "Could not save %s: %s" % [path, AgoraErrno.describe(p.machine.vfs.errno)]
	return path


## The text of a message as one reads it (the plain part, decoded).
static func text_of(m: Dictionary) -> String:
	var shown := AgoraMimeMail.body_of(AgoraMimeMail.parse(m.headers, str(m.body)))
	return str(shown.get("text", ""))


## What the reading pane shows (tests).
func reading_text() -> String:
	return _head.text + "\n\n" + (_html.visible_text() if _html_scroll.visible else _body.text)


func delete_selected() -> void:
	if current < 0 or current >= messages.size():
		return
	var m: Dictionary = messages[current]
	if folder != "Trash":
		_append_folder("Trash", [m])
	messages.remove_at(current)
	_write_folder(folder, messages)
	current = mini(current, messages.size() - 1)
	_refresh()
	_show_message(current)


# --- getting mail --------------------------------------------------------------

## Fetches new mail into the Inbox. Returns {new: n} or {error}.
func check_mail() -> Dictionary:
	if _checking:
		return {"new": 0}
	_checking = true
	_last_check = Time.get_ticks_msec()
	var r: Dictionary
	if str(account.incoming) == "pop3":
		_say("Connecting to %s..." % account.pop3_server)
		r = await _fetch_pop3()
	else:
		r = _fetch_local()
	_checking = false
	if r.has("error"):
		_say(str(r.error))
		return r
	if folder == "Inbox":
		messages = read_folder("Inbox")
	_refresh()
	if int(r.new) > 0:
		_say("%d new message(s)." % r.new)
		if win and win.open and not win.is_focused():
			win.title = "* " + win.title
	return r


## Moves what waits in /var/mail/USER into the Inbox.
func _fetch_local() -> Dictionary:
	var spool := "/var/mail/" + p.user_name()
	var text := p.read_text(spool)
	if text.is_empty():
		return {"new": 0}
	var got := AgoraMbox.parse(text)
	_append_folder("Inbox", got)
	# Keep whatever arrived while we were at it.
	var now := p.read_text(spool)
	p.write_text(spool, now.substr(text.length()) if now.begins_with(text) else "")
	return {"new": got.size()}


func _fetch_pop3() -> Dictionary:
	var seen := p.read_text(_dir() + "/uidl").split("\n", false)
	var r: Dictionary = await AgoraMailNet.pop3_fetch(p, str(account.pop3_server), int(account.pop3_port),
		str(account.pop3_user), str(account.pop3_password), bool(account.keep), seen)
	if r.has("error"):
		return r
	var got: Array = []
	for msg: Dictionary in r.messages:
		var parsed := AgoraMbox.parse_message(str(msg.text))
		var sender := AgoraMbox.skin(AgoraMbox.field(parsed.headers, "return-path"))
		if sender.is_empty():
			sender = AgoraMbox.skin(AgoraMbox.field(parsed.headers, "from"))
		parsed.from_line = AgoraMbox.from_line(sender, p.machine.clock)
		parsed.headers = (parsed.headers as Array).filter(func(h: String) -> bool: return h.get_slice(":", 0).to_lower() != "status")
		parsed.status = ""
		got.append(parsed)
	_append_folder("Inbox", got)
	if bool(account.keep):
		p.make_dirs(_dir())
		p.write_text(_dir() + "/uidl", "\n".join(r.uidls) + "\n")
	return {"new": got.size()}


# --- writing mail --------------------------------------------------------------

## "Sat, 18 Oct 2003 21:30:05 +0000".
func _rfc822_date() -> String:
	return p.machine.clock.format_rfc822()


static func split_addresses(text: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for part in text.replace(";", ",").split(",", false):
		var a := AgoraMbox.skin(part)
		if not a.is_empty():
			out.append(a)
	return out


## The message as it goes out: headers and body. [param files]:
## [{name, data, type}] to attach.
func message_text(to: String, cc: String, subject: String, body: String, files: Array = []) -> String:
	var name := str(account.name)
	var text := "From: %s\n" % ("\"%s\" <%s>" % [name, account.address] if not name.is_empty() else str(account.address))
	text += "To: %s\n" % to
	if not cc.strip_edges().is_empty():
		text += "Cc: %s\n" % cc
	text += "Subject: %s\n" % subject
	text += "Date: %s\n" % _rfc822_date()
	text += "Message-ID: <%d.%d@%s>\n" % [int(p.machine.clock.now()), randi() % 100000, p.machine.hostname]
	var mime := AgoraMimeMail.build(body + ("" if body.ends_with("\n") else "\n"), files)
	text += str(mime.headers) + "X-Mailer: Pigeon Mail %s\n" % VERSION
	return text + "\n" + str(mime.body)


## Files from the disk to attach: [{name, data, type}], or an error text.
func files_for(paths: PackedStringArray) -> Variant:
	var out: Array = []
	for path in paths:
		var full := path if path.begins_with("/") else p.home() + "/" + path
		if not p.exists(full) or p.is_dir(full):
			return "Could not attach %s: no such file." % path
		out.append({"name": AgoraPath.basename(full), "data": p.read_bytes(full), "type": AgoraMime.type_of(p, full)})
	return out


## Sends a message and keeps a copy in Sent. Returns "" or what went wrong.
func send_message(to: String, cc: String, subject: String, body: String, bcc: String = "", files: Array = []) -> String:
	var rcpts := split_addresses(to) + split_addresses(cc) + split_addresses(bcc)
	if rcpts.is_empty():
		return "Please give at least one recipient."
	var text := message_text(to, cc, subject, body, files)
	_say("Sending...")
	if str(account.outgoing) == "smtp":
		var r: Dictionary = await AgoraMailNet.smtp_send(p, str(account.smtp_server), int(account.smtp_port), str(account.address), rcpts, text)
		if r.has("error"):
			_say(str(r.error))
			return str(r.error)
	else:
		var argv := PackedStringArray([SENDMAIL, "-oi", "-f", str(account.address), "--"])
		argv.append_array(rcpts)
		var child := p.spawn(argv, {"stdin": AgoraStream.from_text(text), "stdout": AgoraStream.discard(), "stderr": AgoraStream.discard()})
		if child == null:
			var why := "%s: %s" % [SENDMAIL, AgoraErrno.describe(p.errno)]
			_say(why)
			return why
		if await child.wait() != 0:
			_say("sendmail could not take the message.")
			return "sendmail could not take the message."
	var copy := AgoraMbox.parse_message(text)
	copy.from_line = AgoraMbox.from_line(str(account.address), p.machine.clock)
	_set_status(copy, "RO")
	_append_folder("Sent", [copy])
	if folder == "Sent":
		messages = read_folder("Sent")
	_refresh()
	_say("Message sent.")
	return ""


func new_mail() -> Dictionary:
	return compose({})


## Opens a window to write a message. [param head]: to, cc, subject, body.
func compose(head: Dictionary) -> Dictionary:
	var box := VBoxContainer.new()
	var grid := GridContainer.new()
	grid.columns = 2
	var fields := {}
	for pair in [["From:", "from"], ["To:", "to"], ["Cc:", "cc"], ["Subject:", "subject"]]:
		var l := Label.new()
		l.text = pair[0]
		grid.add_child(l)
		if pair[1] == "from":
			var who := Label.new()
			who.text = "%s <%s>" % [account.name, account.address]
			grid.add_child(who)
			continue
		var e := LineEdit.new()
		e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		e.text = str(head.get(pair[1], ""))
		grid.add_child(e)
		fields[pair[1]] = e
	box.add_child(grid)
	var body := TextEdit.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	body.text = str(head.get("body", ""))
	box.add_child(body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	var note := Label.new()
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.clip_text = true
	row.add_child(note)
	var buttons := {}
	for name in ["Attach...", "Send", "Save Draft", "Cancel"]:
		var b := Button.new()
		b.text = name
		row.add_child(b)
		buttons[name] = b
	box.add_child(row)
	var subject := str(head.get("subject", ""))
	var w := open_window(p, box, {"title": "%s - Message" % (subject if not subject.is_empty() else "New Message"), "size": Vector2(620, 460)})
	if w == null:
		return {}
	var c := {"win": w, "to": fields.to, "cc": fields.cc, "subject": fields.subject, "body": body, "note": note, "draft_of": head.get("draft_of", -1),
		"files": (head.get("files", []) as Array).duplicate()}
	_show_compose_files(c)
	w.focus_target = fields.to if str(head.get("to", "")).is_empty() else body
	composers.append(c)
	w.closed.connect(func() -> void: composers.erase(c), CONNECT_ONE_SHOT)
	buttons["Attach..."].pressed.connect(func() -> void: _attach_dialog(c))
	buttons.Send.pressed.connect(func() -> void: await send_compose(c))
	buttons["Save Draft"].pressed.connect(func() -> void: save_draft(c))
	buttons.Cancel.pressed.connect(func() -> void: w.close())
	return c


## Attaches the file at [param path] (relative to the home folder) to the
## message in [param c]. Returns "" or why not.
func attach_file(c: Dictionary, path: String) -> String:
	var got: Variant = files_for(PackedStringArray([path]))
	if got is String:
		(c.note as Label).text = got
		return got
	(c.files as Array).append_array(got)
	_show_compose_files(c)
	return ""


func _show_compose_files(c: Dictionary) -> void:
	var names: PackedStringArray = []
	for f: Dictionary in c.files:
		names.append("%s (%s)" % [f.name, _size_text((f.data as PackedByteArray).size())])
	(c.note as Label).text = "Attach: " + ", ".join(names) if not names.is_empty() else ""


func _attach_dialog(c: Dictionary) -> void:
	_ask_line("Attach a file", "File (from your home folder):", "", func(path: String) -> void: attach_file(c, path))


## A small window asking for one line; [param done] gets it on OK.
func _ask_line(title: String, label: String, initial: String, done: Callable) -> void:
	var box := VBoxContainer.new()
	var l := Label.new()
	l.text = label
	box.add_child(l)
	var e := LineEdit.new()
	e.text = initial
	e.custom_minimum_size = Vector2(300, 0)
	box.add_child(e)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	var ok := Button.new()
	ok.text = "OK"
	var cancel := Button.new()
	cancel.text = "Cancel"
	row.add_child(ok)
	row.add_child(cancel)
	box.add_child(row)
	var w := open_window(p, box, {"title": title, "size": Vector2(360, 130), "resizable": false})
	if w == null:
		return
	w.focus_target = e
	var finish := func() -> void:
		var text := e.text
		w.close()
		done.call(text)
	ok.pressed.connect(finish)
	e.text_submitted.connect(func(_t: String) -> void: finish.call())
	cancel.pressed.connect(func() -> void: w.close())


func new_folder_dialog() -> void:
	_ask_line("New Folder", "Folder name:", "", func(name: String) -> void:
		var why := create_folder(name)
		if not why.is_empty():
			_say(why))


## Sends what a compose window holds and closes it. Returns "" or the error.
func send_compose(c: Dictionary) -> String:
	(c.note as Label).text = "Sending..."
	var error := await send_message((c.to as LineEdit).text, (c.cc as LineEdit).text, (c.subject as LineEdit).text, (c.body as TextEdit).text, "", c.files)
	if not error.is_empty():
		(c.note as Label).text = error
		return error
	_drop_draft(int(c.draft_of))
	c.win.close()
	return ""


func save_draft(c: Dictionary) -> void:
	_drop_draft(int(c.draft_of))
	var draft := AgoraMbox.parse_message(message_text((c.to as LineEdit).text, (c.cc as LineEdit).text, (c.subject as LineEdit).text, (c.body as TextEdit).text, c.files))
	draft.from_line = AgoraMbox.from_line(str(account.address), p.machine.clock)
	_set_status(draft, "RO")
	_append_folder("Drafts", [draft])
	if folder == "Drafts":
		messages = read_folder("Drafts")
	_refresh()
	c.win.close()


func _drop_draft(k: int) -> void:
	if k < 0:
		return
	var drafts := read_folder("Drafts")
	if k < drafts.size():
		drafts.remove_at(k)
		_write_folder("Drafts", drafts)
		if folder == "Drafts":
			messages = drafts
			current = -1
			_refresh()


func _open_draft(k: int) -> void:
	var m: Dictionary = messages[k]
	var files: Array = []
	for f: Dictionary in AgoraMimeMail.attachments(AgoraMimeMail.parse(m.headers, str(m.body))):
		files.append({"name": f.filename, "data": f.data, "type": f.type})
	compose({"to": AgoraMbox.field(m.headers, "to"), "cc": AgoraMbox.field(m.headers, "cc"),
		"subject": AgoraMimeMail.decode_words(AgoraMbox.field(m.headers, "subject")), "body": text_of(m), "draft_of": k, "files": files})


## The original below a reply or forward, as Outlook Express set it out.
func _quoted(m: Dictionary, prefix: String) -> String:
	var out := "\n\n----- Original Message -----\n"
	for pair in [["From", "from"], ["To", "to"], ["Cc", "cc"], ["Sent", "date"], ["Subject", "subject"]]:
		var v := AgoraMimeMail.decode_words(AgoraMbox.field(m.headers, pair[1]))
		if not v.is_empty():
			out += "%s: %s\n" % [pair[0], v]
	out += "\n"
	for line in text_of(m).trim_suffix("\n").split("\n"):
		out += prefix + line + "\n"
	return out


func reply(to_all: bool) -> Dictionary:
	if current < 0 or current >= messages.size():
		return {}
	var m: Dictionary = messages[current]
	var reply_to := AgoraMbox.field(m.headers, "reply-to")
	var to := reply_to if not reply_to.is_empty() else AgoraMbox.field(m.headers, "from")
	var cc := ""
	if to_all:
		var mine := str(account.address).to_lower()
		var others: PackedStringArray = []
		for a in split_addresses(AgoraMbox.field(m.headers, "to") + "," + AgoraMbox.field(m.headers, "cc")):
			if a.to_lower() != mine and a.to_lower() != AgoraMbox.skin(to).to_lower():
				others.append(a)
		cc = ", ".join(others)
	var subject := AgoraMimeMail.decode_words(AgoraMbox.field(m.headers, "subject"))
	if not subject.to_lower().begins_with("re:"):
		subject = "Re: " + subject
	return compose({"to": to, "cc": cc, "subject": subject, "body": _quoted(m, "> ")})


func forward() -> Dictionary:
	if current < 0 or current >= messages.size():
		return {}
	var m: Dictionary = messages[current]
	var subject := AgoraMimeMail.decode_words(AgoraMbox.field(m.headers, "subject"))
	if not subject.to_lower().begins_with("fw:"):
		subject = "Fw: " + subject
	var files: Array = []
	for f: Dictionary in attachments_of_current():
		files.append({"name": f.filename, "data": f.data, "type": f.type})
	return compose({"subject": subject, "body": _quoted(m, ""), "files": files})


# --- the address book ----------------------------------------------------------

func _book_path() -> String:
	return _dir() + "/addressbook"


## The address book: [{name, address}], by name.
func contacts() -> Array:
	var out: Array = []
	for line in p.read_text(_book_path()).split("\n", false):
		var parts := line.split("\t")
		if parts.size() >= 2:
			out.append({"name": parts[0], "address": parts[1]})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	return out


func _save_contacts(list: Array) -> void:
	p.make_dirs(_dir())
	var lines: PackedStringArray = []
	for c: Dictionary in list:
		lines.append("%s\t%s" % [c.name, c.address])
	p.write_text(_book_path(), "\n".join(lines) + ("\n" if not lines.is_empty() else ""), false, AgoraStat.MODE_PRIVATE_FILE)


## Adds (or renames) a contact. Returns "" or why not.
func add_contact(name: String, address: String) -> String:
	address = AgoraMbox.skin(address)
	if address.is_empty():
		return "Please give an e-mail address."
	var list := contacts().filter(func(c: Dictionary) -> bool: return str(c.address).to_lower() != address.to_lower())
	list.append({"name": name.strip_edges() if not name.strip_edges().is_empty() else address, "address": address})
	_save_contacts(list)
	return ""


func remove_contact(address: String) -> void:
	_save_contacts(contacts().filter(func(c: Dictionary) -> bool: return str(c.address).to_lower() != address.to_lower()))


## Puts the sender of the selected message in the address book.
func add_sender() -> String:
	if current < 0 or current >= messages.size():
		return "Select a message first."
	var from := AgoraMimeMail.decode_words(AgoraMbox.field(messages[current].headers, "from"))
	return add_contact(AgoraMbox.display_name(from), AgoraMbox.skin(from))


func address_book_window() -> void:
	var box := VBoxContainer.new()
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.select_mode = ItemList.SELECT_MULTI
	box.add_child(list)
	var fill := func() -> void:
		list.clear()
		for c: Dictionary in contacts():
			list.add_item("%s <%s>" % [c.name, c.address])
			list.set_item_metadata(list.item_count - 1, c.address)
	fill.call()
	var row := HBoxContainer.new()
	var actions := [
		["New Contact...", func() -> void:
			_ask_line("New Contact", "Name <address>:", "", func(text: String) -> void:
				add_contact(AgoraMbox.display_name(text), AgoraMbox.skin(text))
				fill.call())],
		["Add Sender", func() -> void:
			_say(add_sender())
			fill.call()],
		["Delete", func() -> void:
			for i in list.get_selected_items():
				remove_contact(str(list.get_item_metadata(i)))
			fill.call()],
		["Write To", func() -> void:
			var to: PackedStringArray = []
			for i in list.get_selected_items():
				to.append(list.get_item_text(i))
			if not to.is_empty():
				compose({"to": ", ".join(to)})],
	]
	for a: Array in actions:
		var b := Button.new()
		b.text = a[0]
		b.pressed.connect(a[1])
		row.add_child(b)
	box.add_child(row)
	open_window(p, box, {"title": "Address Book - Pigeon Mail", "size": Vector2(440, 360)})


# --- the Accounts dialog -------------------------------------------------------

func accounts_dialog() -> void:
	var box := VBoxContainer.new()
	var grid := GridContainer.new()
	grid.columns = 2
	var edits := {}
	var rows := [["Your name:", "name"], ["E-mail address:", "address"],
		["Incoming mail:", "incoming"], ["POP3 server:", "pop3_server"], ["Account name:", "pop3_user"], ["Password:", "pop3_password"],
		["", "keep"], ["Outgoing mail:", "outgoing"], ["SMTP server:", "smtp_server"], ["Check every (minutes):", "check_minutes"]]
	for r: Array in rows:
		var l := Label.new()
		l.text = r[0]
		grid.add_child(l)
		var key: String = r[1]
		var c: Control
		match key:
			"incoming", "outgoing":
				var o := OptionButton.new()
				o.add_item("Local mailbox (/var/mail)" if key == "incoming" else "Local mail system (sendmail)")
				o.add_item("POP3 server" if key == "incoming" else "SMTP server")
				o.select(1 if str(account[key]) in ["pop3", "smtp"] else 0)
				c = o
			"keep":
				var b := CheckBox.new()
				b.text = "Leave a copy of messages on the server"
				b.button_pressed = bool(account.keep)
				c = b
			_:
				var e := LineEdit.new()
				e.text = str(account[key])
				e.secret = key == "pop3_password"
				e.custom_minimum_size = Vector2(240, 0)
				c = e
		grid.add_child(c)
		edits[key] = c
	box.add_child(grid)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	var ok := Button.new()
	ok.text = "OK"
	var cancel := Button.new()
	cancel.text = "Cancel"
	row.add_child(ok)
	row.add_child(cancel)
	box.add_child(row)
	var w := open_window(p, box, {"title": "Accounts - Pigeon Mail", "size": Vector2(480, 380), "resizable": false})
	if w == null:
		return
	ok.pressed.connect(func() -> void:
		for key: String in edits:
			var c: Control = edits[key]
			if c is OptionButton:
				account[key] = ("pop3" if key == "incoming" else "smtp") if (c as OptionButton).selected == 1 else "local"
			elif c is CheckBox:
				account[key] = (c as CheckBox).button_pressed
			elif key == "check_minutes":
				account[key] = (c as LineEdit).text.to_int()
			else:
				account[key] = (c as LineEdit).text.strip_edges()
		save_account()
		w.close())
	cancel.pressed.connect(func() -> void: w.close())
