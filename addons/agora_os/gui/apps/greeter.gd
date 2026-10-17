extends AgoraGuiProgram
## Graphical login. Runs as root on the display, asks for a user name and
## password, then starts the user's session: ~/.xinitrc if present, otherwise
## /etc/X11/xinitrc. When the session leader exits, everything left in the
## session is killed and the login screen comes back.
##
## /etc/greeter.conf may set "autologin=<user>" (first login only).

signal submitted(user: String, password: String)

var _user := LineEdit.new()
var _password := LineEdit.new()
var _message := Label.new()


func summary() -> String:
	return "graphical login screen"


func main(p: AgoraProcess) -> int:
	if not p.cred.is_root():
		return p.fail("must be run as root")
	var d := display_for(p)
	if d == null:
		return p.fail("cannot open display")
	var ui := _build(p)
	var win := open_window(p, ui, {
		"layer": AgoraWindow.Layer.OVERLAY, "decorated": false,
		"position": Vector2.ZERO, "size": d.size,
	})
	win.focus_target = _user
	d.resized.connect(_fit.bind(win))
	var autologin := conf_value(p, ["/etc/greeter.conf"], "autologin")
	while win.open and p.is_running():
		var user := autologin
		autologin = ""
		if user.is_empty() or p.machine.users.find(user).is_empty():
			var answer: Array = await submitted
			if not win.open or not p.is_running():
				break
			user = answer[0]
			if not _authenticate(p, user, answer[1]):
				continue
		win.set_minimized(true)
		await _run_session(p, user)
		_password.text = ""
		_message.text = ""
		if win.open:
			win.set_minimized(false)
			_password.grab_focus.call_deferred()
	return 0


func _authenticate(p: AgoraProcess, user: String, password: String) -> bool:
	var users := p.machine.users
	if not users.find(user).is_empty() and not users.is_locked(user) and users.check_password(user, password):
		return true
	p.machine.log_event("auth.log", "greeter", "authentication failure for %s" % user)
	_message.text = "Login incorrect"
	_password.text = ""
	_password.grab_focus.call_deferred()
	return false


func _run_session(p: AgoraProcess, user: String) -> void:
	var m := p.machine
	var u := m.users.find(user)
	var env := {
		"HOME": u.home, "USER": user, "LOGNAME": user, "SHELL": u.shell,
		"PATH": AgoraMachine.DEFAULT_PATH, "DISPLAY": p.getenv("DISPLAY"), "TERM": "agora",
	}
	var cred := m.users.cred_for(user)
	var script: String = u.home + "/.xinitrc"
	if not m.vfs.exists(cred, script):
		script = "/etc/X11/xinitrc"
	# Session output goes to ~/.xsession-errors, as on a real desktop.
	var log := AgoraStream.new()
	log.add_reader()
	var log_path: String = u.home + "/.xsession-errors"
	m.vfs.write_text(cred, log_path, "")
	var append_log := func() -> void: m.vfs.write_text(cred, log_path, log.read_available(), "/", true)
	log.changed.connect(append_log)
	var leader := m.spawn(PackedStringArray(["/bin/sh", script]), {
		"cred": cred, "cwd": u.home, "env": env, "parent": p, "new_session": true,
		"stdin": AgoraStream.empty(), "stdout": log, "stderr": log,
	})
	if leader == null:
		log.changed.disconnect(append_log)
		_message.text = "Cannot start session: %s" % AgoraErrno.describe(m.errno)
		return
	m.log_event("auth.log", "greeter", "session opened for user %s" % user)
	await leader.wait()
	m.kill_session(leader.sid, AgoraProcess.SIGTERM)
	m.kill_session(leader.sid, AgoraProcess.SIGKILL)
	log.changed.disconnect(append_log)
	log.release_reader()
	m.log_event("auth.log", "greeter", "session closed for user %s" % user)


func _fit(win: AgoraWindow) -> void:
	if win.open:
		win.set_rect(Rect2(Vector2.ZERO, win.display.size))


func _build(p: AgoraProcess) -> Control:
	var root := ColorRect.new()
	root.color = Color("#0b1118")
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#16202b")
	style.border_color = Color("#2d4560")
	style.set_border_width_all(1)
	style.set_content_margin_all(24)
	box.add_theme_stylebox_override("panel", style)
	center.add_child(box)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(300, 0)
	col.add_theme_constant_override("separation", 10)
	box.add_child(col)
	var title := Label.new()
	title.text = p.machine.hostname
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)
	var sub := Label.new()
	sub.text = "%s %s" % [AgoraMachine.KERNEL_NAME, AgoraMachine.KERNEL_VERSION]
	sub.modulate = Color(1, 1, 1, 0.5)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(sub)
	_user.placeholder_text = "login"
	_password.placeholder_text = "password"
	_password.secret = true
	col.add_child(_user)
	col.add_child(_password)
	var button := Button.new()
	button.text = "Log in"
	col.add_child(button)
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.add_theme_color_override("font_color", Color("#e57373"))
	col.add_child(_message)
	_user.text_submitted.connect(func(_t: String) -> void: _password.grab_focus())
	_password.text_submitted.connect(func(_t: String) -> void: _submit())
	button.pressed.connect(_submit)
	return root


func _submit() -> void:
	submitted.emit(_user.text.strip_edges(), _password.text)
