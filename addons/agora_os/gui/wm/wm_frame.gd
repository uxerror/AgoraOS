class_name AgoraWmFrame
extends Control
## Decoration the window manager puts around a window: border, title bar,
## minimize/maximize/close buttons. Drag the title bar to move, the border
## to resize, double-click the title to maximize. Shift while resizing from
## a corner keeps the aspect ratio.

const EDGE_GRAB := 6.0


## A title bar button drawn with lines, so it needs no font or icon asset.
class WmButton extends Control:
	enum Kind { MINIMIZE, MAXIMIZE, CLOSE }
	signal clicked
	var kind: Kind
	var wm_theme: AgoraWmTheme
	var _hover := false

	func _init(p_kind: Kind, p_theme: AgoraWmTheme) -> void:
		kind = p_kind
		wm_theme = p_theme
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_entered.connect(_set_hover.bind(true))
		mouse_exited.connect(_set_hover.bind(false))

	func _set_hover(value: bool) -> void:
		_hover = value
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			if Rect2(Vector2.ZERO, size).has_point(event.position):
				clicked.emit()
			accept_event()
		elif event is InputEventMouseButton:
			accept_event()

	func _draw() -> void:
		if _hover:
			draw_rect(Rect2(Vector2.ZERO, size), wm_theme.color("close_hover") if kind == Kind.CLOSE else wm_theme.color("button_hover"))
		var c := wm_theme.color("button_fg")
		var r := Rect2(size * 0.3, size * 0.4).abs()
		match kind:
			Kind.MINIMIZE:
				draw_line(Vector2(r.position.x, r.end.y), r.end, c, 2.0)
			Kind.MAXIMIZE:
				draw_rect(r, c, false, 1.5)
			Kind.CLOSE:
				draw_line(r.position, r.end, c, 1.5, true)
				draw_line(Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), c, 1.5, true)


var win: AgoraWindow
var wm_theme: AgoraWmTheme

var _title := Label.new()
var _buttons := HBoxContainer.new()
var _drag_from := Vector2.ZERO
var _dragging := false
var _resize_edges := Vector2i.ZERO # -1/0/1 per axis
var _resize_start := Rect2()
var _resize_mouse := Vector2.ZERO


func _init(p_win: AgoraWindow, p_theme: AgoraWmTheme) -> void:
	win = p_win
	wm_theme = p_theme
	mouse_filter = Control.MOUSE_FILTER_STOP
	var b := wm_theme.num("border")
	var th := wm_theme.num("title_height")
	win.frame_extra = Vector2(b * 2, b * 2 + th)

	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.add_theme_font_size_override("font_size", wm_theme.num("font_size"))
	add_child(_title)

	_buttons.add_theme_constant_override("separation", 0)
	for kind in [WmButton.Kind.MINIMIZE, WmButton.Kind.MAXIMIZE, WmButton.Kind.CLOSE]:
		if kind == WmButton.Kind.MAXIMIZE and not win.resizable:
			continue
		var btn := WmButton.new(kind, wm_theme)
		btn.custom_minimum_size = Vector2(th + 4, th)
		btn.clicked.connect(_on_button.bind(kind))
		_buttons.add_child(btn)
	add_child(_buttons)

	add_child(win.content)
	win.changed.connect(_refresh)
	resized.connect(_layout)
	_refresh()


func _layout() -> void:
	var b := float(wm_theme.num("border"))
	var th := float(wm_theme.num("title_height"))
	var bw := _buttons.get_combined_minimum_size().x
	_buttons.position = Vector2(size.x - b - bw, b)
	_buttons.size = Vector2(bw, th)
	_title.position = Vector2(b + 6, b)
	_title.size = Vector2(maxf(0, size.x - b * 2 - bw - 8), th)
	if is_instance_valid(win.content) and win.content.get_parent() == self:
		win.content.position = Vector2(b, b + th)
		win.content.size = size - win.frame_extra


func _refresh() -> void:
	_title.text = win.title
	_title.add_theme_color_override("font_color", wm_theme.color("title_fg", win.is_focused()))
	_layout()
	queue_redraw()


func _draw() -> void:
	var active := win.is_focused()
	var b := float(wm_theme.num("border"))
	var th := float(wm_theme.num("title_height"))
	draw_rect(Rect2(Vector2.ZERO, size), wm_theme.color("border_color", active))
	draw_rect(Rect2(b, b, size.x - b * 2, th), wm_theme.color("title_bg", active))


func _on_button(kind: WmButton.Kind) -> void:
	match kind:
		WmButton.Kind.MINIMIZE:
			win.set_minimized(true)
		WmButton.Kind.MAXIMIZE:
			win.set_maximized(not win.maximized)
		WmButton.Kind.CLOSE:
			win.request_close()


func _edges_at(pos: Vector2) -> Vector2i:
	if not win.resizable or win.maximized:
		return Vector2i.ZERO
	var e := Vector2i.ZERO
	if pos.x < EDGE_GRAB:
		e.x = -1
	elif pos.x > size.x - EDGE_GRAB:
		e.x = 1
	if pos.y < EDGE_GRAB:
		e.y = -1
	elif pos.y > size.y - EDGE_GRAB:
		e.y = 1
	return e


func _cursor_for(e: Vector2i) -> CursorShape:
	if e.x != 0 and e.y != 0:
		return Control.CURSOR_FDIAGSIZE if e.x == e.y else Control.CURSOR_BDIAGSIZE
	if e.x != 0:
		return Control.CURSOR_HSIZE
	if e.y != 0:
		return Control.CURSOR_VSIZE
	return Control.CURSOR_ARROW


func _gui_input(event: InputEvent) -> void:
	var th := float(wm_theme.num("title_height")) + wm_theme.num("border")
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			win.focus()
			var e := _edges_at(mb.position)
			if e != Vector2i.ZERO:
				_resize_edges = e
				_resize_start = win.rect()
				_resize_mouse = mb.global_position
			elif mb.position.y < th:
				if mb.double_click and win.resizable:
					win.set_maximized(not win.maximized)
				else:
					_dragging = true
					_drag_from = mb.global_position
		else:
			_dragging = false
			_resize_edges = Vector2i.ZERO
		accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			_drag(mm.global_position)
		elif _resize_edges != Vector2i.ZERO:
			_resize(mm.global_position, mm.shift_pressed)
		else:
			mouse_default_cursor_shape = _cursor_for(_edges_at(mm.position))
		accept_event()


func _drag(mouse: Vector2) -> void:
	var delta := mouse - _drag_from
	_drag_from = mouse
	if win.maximized:
		# Pull the window out of maximized state under the cursor.
		var ratio := (mouse.x - win.position.x) / maxf(1.0, win.size.x)
		win.set_maximized(false)
		win.position = Vector2(mouse.x - win.size.x * ratio, mouse.y - wm_theme.num("title_height") / 2.0)
	var area := win.display.work_area()
	var pos := win.position + delta
	pos.x = clampf(pos.x, area.position.x - win.size.x + 80, area.end.x - 80)
	pos.y = clampf(pos.y, area.position.y, area.end.y - wm_theme.num("title_height"))
	win.move_to(pos)


func _resize(mouse: Vector2, keep_aspect: bool) -> void:
	var delta := mouse - _resize_mouse
	var r := _resize_start
	var min_size := win.min_size + win.frame_extra
	var new_size := r.size
	if _resize_edges.x != 0:
		new_size.x = maxf(min_size.x, r.size.x + delta.x * _resize_edges.x)
	if _resize_edges.y != 0:
		new_size.y = maxf(min_size.y, r.size.y + delta.y * _resize_edges.y)
	if keep_aspect and _resize_edges.x != 0 and _resize_edges.y != 0:
		var aspect := r.size.x / maxf(1.0, r.size.y)
		new_size.y = maxf(min_size.y, new_size.x / aspect)
		new_size.x = new_size.y * aspect
	var pos := r.position
	if _resize_edges.x < 0:
		pos.x = r.end.x - new_size.x
	if _resize_edges.y < 0:
		pos.y = r.end.y - new_size.y
	win.set_rect(Rect2(pos, new_size))
