extends AgoraGuiProgram
## The desktop: background color plus an icon for everything in ~/Desktop.
## Double-click opens an icon with "open". Right-click the background for a
## small menu. Configured with "background=#rrggbb" in ~/.config/desktop.conf
## or /etc/desktop.conf.

const CELL := Vector2(96, 86)
const MARGIN := Vector2(12, 12)


class Backdrop extends Control:
	signal open_requested(path: String)
	signal menu_requested(at: Vector2)
	var color := Color("#1d2b38")
	var caption := ""
	## [{name, path, kind, rect}]
	var icons: Array[Dictionary] = []
	var selected := -1

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), color)
		var font := get_theme_default_font()
		var cap_size := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		draw_string(font, Vector2(size.x - cap_size.x - 12, 12 + cap_size.y), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.35))
		for i in icons.size():
			var r: Rect2 = icons[i].rect
			if i == selected:
				draw_rect(r, Color(0.4, 0.6, 0.9, 0.35))
				draw_rect(r, Color(0.6, 0.8, 1.0, 0.6), false, 1.0)
			draw_texture(AgoraStyle.icon(icons[i].kind), r.position + Vector2((r.size.x - 48) / 2, 6))
			var label: String = icons[i].name
			var pos := r.position + Vector2(4, 70)
			draw_string(font, pos + Vector2(1, 1), label, HORIZONTAL_ALIGNMENT_CENTER, r.size.x - 8, 13, Color(0, 0, 0, 0.8))
			draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_CENTER, r.size.x - 8, 13, Color.WHITE)

	func _gui_input(event: InputEvent) -> void:
		if not event is InputEventMouseButton or not event.pressed:
			return
		var mb := event as InputEventMouseButton
		var hit := -1
		for i in icons.size():
			if (icons[i].rect as Rect2).has_point(mb.position):
				hit = i
		selected = hit
		queue_redraw()
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click and hit >= 0:
			open_requested.emit(icons[hit].path)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and hit < 0:
			menu_requested.emit(mb.position)
		accept_event()


var p: AgoraProcess
var _backdrop := Backdrop.new()
var _menu := PopupMenu.new()
var _listing: PackedStringArray = []


func summary() -> String:
	return "desktop background and icons"


func main(proc: AgoraProcess) -> int:
	p = proc
	var d := display_for(p)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.color = Color.from_string(conf_value(p, [p.home() + "/.config/desktop.conf", "/etc/desktop.conf"], "background"), _backdrop.color)
	_backdrop.caption = "%s %s  -  %s" % [AgoraMachine.KERNEL_NAME, AgoraMachine.KERNEL_VERSION, p.machine.hostname]
	_backdrop.open_requested.connect(func(path: String) -> void: _spawn(PackedStringArray(["open", path])))
	_backdrop.menu_requested.connect(_show_menu)
	_backdrop.add_child(_menu)
	_menu.add_item("Terminal", 0)
	_menu.add_item("Files", 1)
	_menu.add_item("Open Desktop Folder", 2)
	_menu.id_pressed.connect(_on_menu)
	var win := open_window(p, _backdrop, {
		"layer": AgoraWindow.Layer.DESKTOP, "decorated": false, "focus": false,
		"position": Vector2.ZERO, "size": d.size if d else Vector2.ZERO,
	})
	if win == null:
		return 1
	d.resized.connect(_fit.bind(win))
	if not p.exists(_desktop_dir()):
		p.mkdir(_desktop_dir())
	while win.open and p.is_running():
		var names := p.list_dir(_desktop_dir())
		if names != _listing:
			_listing = names
			_layout()
		await p.sleep(2.0)
	return 0


func _desktop_dir() -> String:
	return p.home() + "/Desktop"


func _layout() -> void:
	_backdrop.icons.clear()
	var area := Rect2(Vector2.ZERO, _backdrop.size)
	var pos := MARGIN
	for name in _listing:
		if name.begins_with("."):
			continue
		var path := AgoraPath.join(_desktop_dir(), name)
		var st := p.stat(path)
		var mime := AgoraMime.type_of(p, path) if st and st.is_file() else ""
		_backdrop.icons.append({"name": name, "path": path, "kind": AgoraStyle.kind_for(st, mime), "rect": Rect2(pos, CELL)})
		pos.y += CELL.y
		if pos.y + CELL.y > area.size.y - 40:
			pos = Vector2(pos.x + CELL.x, MARGIN.y)
	_backdrop.selected = -1
	_backdrop.queue_redraw()


func _fit(win: AgoraWindow) -> void:
	if win.open:
		win.set_rect(Rect2(Vector2.ZERO, win.display.size))
		_layout()


func _show_menu(at: Vector2) -> void:
	_menu.reset_size()
	_menu.popup(Rect2i(Vector2i(_backdrop.global_position + at), Vector2i.ZERO))


func _on_menu(id: int) -> void:
	match id:
		0: _spawn(PackedStringArray(["terminal"]))
		1: _spawn(PackedStringArray(["files"]))
		2: _spawn(PackedStringArray(["files", _desktop_dir()]))


func _spawn(argv: PackedStringArray) -> void:
	p.spawn(argv, {"stdin": AgoraStream.empty(), "cwd": p.home()})
