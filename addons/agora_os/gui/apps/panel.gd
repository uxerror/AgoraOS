extends AgoraGuiProgram
## The taskbar: an application menu built from /usr/share/applications,
## one button per window, a clock and a logout button.

const HEIGHT := 30.0

var p: AgoraProcess
var display: AgoraDisplay
var win: AgoraWindow
var theme: AgoraWmTheme
var _tasks := HBoxContainer.new()
var _tray := HBoxContainer.new()
var _clock := Label.new()
var _blink_on := false
var _menu := PopupMenu.new()
var _apps: Array[Dictionary] = []


func summary() -> String:
	return "taskbar and application menu"


func main(proc: AgoraProcess) -> int:
	p = proc
	display = display_for(p)
	if display == null:
		return p.fail("cannot open display")
	theme = AgoraWmTheme.load_for(p)
	var bar := _build()
	win = open_window(p, bar, {
		"layer": AgoraWindow.Layer.PANEL, "decorated": false, "focus": false,
		"position": Vector2(0, display.size.y - HEIGHT), "size": Vector2(display.size.x, HEIGHT),
	})
	display.set_strut("bottom", HEIGHT)
	display.resized.connect(_fit)
	for sig: Signal in [display.window_opened, display.window_closed, display.focus_changed]:
		sig.connect(_on_windows_changed.unbind(1))
	display.tray_changed.connect(_rebuild_tray)
	_rebuild_tasks()
	_rebuild_tray()
	while win.open and p.is_running():
		var d := p.machine.clock.local_datetime()
		_clock.text = "%02d:%02d" % [d.hour, d.minute]
		_blink()
		await p.sleep(0.5)
	display.tray_changed.disconnect(_rebuild_tray)
	display.set_strut("bottom", 0)
	return 0


## Buttons of windows that want attention flash.
func _blink() -> void:
	_blink_on = not _blink_on
	for b in _tasks.get_children():
		var w: AgoraWindow = b.get_meta("window") if b.has_meta("window") else null
		if w and w.urgent:
			b.modulate = Color(1.6, 1.3, 0.6) if _blink_on else Color.WHITE
		else:
			b.modulate = Color.WHITE


## The notification area: an icon per entry, a click does its thing.
func _rebuild_tray() -> void:
	if not is_instance_valid(_tray):
		return
	for c in _tray.get_children():
		c.queue_free()
	for t in display.tray:
		var b := TextureButton.new()
		b.texture_normal = t.icon
		b.ignore_texture_size = true
		b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		b.custom_minimum_size = Vector2(22, 22)
		b.tooltip_text = t.tooltip
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(display.tray_click.bind(t.id))
		_tray.add_child(b)


## The tooltips of the icons in the notification area (tests).
func tray_tooltips() -> PackedStringArray:
	var out: PackedStringArray = []
	for t in display.tray:
		out.append(t.tooltip)
	return out


func _build() -> Control:
	var bar := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = theme.color("panel_bg")
	style.border_color = theme.color("title_bg")
	style.border_width_top = 1
	style.content_margin_left = 4
	style.content_margin_right = 8
	bar.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	bar.add_child(row)
	# Every child inherits the panel's text colors through this Theme.
	var colors := Theme.new()
	for type in ["Button", "Label"]:
		for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
			colors.set_color(key, type, theme.color("panel_fg"))
	var fg := theme.color("panel_fg")
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color(fg, {"hover": 0.08, "pressed": 0.18, "hover_pressed": 0.22}.get(state, 0.0))
		box.content_margin_left = 8
		box.content_margin_right = 8
		colors.set_stylebox(state, "Button", box)
	bar.theme = colors

	var start := Button.new()
	start.text = " Menu "
	start.flat = true
	start.pressed.connect(_open_menu.bind(start))
	row.add_child(start)
	start.add_child(_menu)
	_menu.id_pressed.connect(_launch)

	_tasks.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tasks.add_theme_constant_override("separation", 2)
	row.add_child(_tasks)

	_tray.add_theme_constant_override("separation", 2)
	row.add_child(_tray)
	_clock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_clock)

	var logout := Button.new()
	logout.text = "Log out"
	logout.flat = true
	logout.pressed.connect(_logout)
	row.add_child(logout)
	return bar


func _fit() -> void:
	if win.open:
		win.set_rect(Rect2(0, display.size.y - HEIGHT, display.size.x, HEIGHT))


func _open_menu(anchor: Button) -> void:
	_menu.clear()
	_apps.clear()
	for entry in AgoraMime.applications(p):
		if entry.has("Name") and entry.get("NoDisplay", "false") != "true":
			_apps.append(entry)
	_apps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.Name < b.Name)
	for i in _apps.size():
		_menu.add_item(_apps[i].Name, i)
		_menu.set_item_tooltip(i, _apps[i].get("Comment", ""))
	_menu.reset_size()
	var menu_size := _menu.get_contents_minimum_size()
	_menu.popup(Rect2i(Vector2i(anchor.global_position - Vector2(0, menu_size.y)), Vector2i(menu_size)))


func _launch(id: int) -> void:
	if id < 0 or id >= _apps.size():
		return
	var argv := (_apps[id].Exec as String).split(" ", false)
	if p.spawn(argv, {"stdin": AgoraStream.empty()}) == null:
		p.fail("%s: %s" % [argv[0], AgoraErrno.describe(p.errno)])


func _logout() -> void:
	p.machine.kill_session(p.sid, AgoraProcess.SIGTERM)


func _on_windows_changed() -> void:
	_rebuild_tasks.call_deferred()


func _rebuild_tasks() -> void:
	if not is_instance_valid(_tasks):
		return
	for c in _tasks.get_children():
		c.queue_free()
	for w in display.windows:
		if w.layer != AgoraWindow.Layer.NORMAL:
			continue
		var b := Button.new()
		b.text = w.title
		b.clip_text = true
		b.custom_minimum_size = Vector2(150, 0)
		b.toggle_mode = true
		b.button_pressed = w.is_focused() and not w.minimized
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_on_task.bind(w))
		b.set_meta("window", w)
		if not w.changed.is_connected(_on_windows_changed):
			w.changed.connect(_on_windows_changed)
		_tasks.add_child(b)


func _on_task(w: AgoraWindow) -> void:
	if not w.open:
		return
	if w.is_focused() and not w.minimized:
		w.set_minimized(true)
	else:
		w.focus()
