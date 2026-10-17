class_name AgoraDisplayView
extends Control
## Shows an [AgoraDisplay] in the scene tree: the "monitor" of a machine.
##
## It keeps one layer per [enum AgoraWindow.Layer], places window frames,
## follows their geometry and stacking, forwards the screen size to the
## display, focuses windows on click, and passes keys to the window manager.

var display: AgoraDisplay

var _layers: Array[Control] = []


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in AgoraWindow.Layer.size():
		var layer := Control.new()
		layer.name = AgoraWindow.Layer.keys()[i].capitalize()
		layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(layer)
		_layers.append(layer)
	resized.connect(_on_resized)


func attach(p_display: AgoraDisplay) -> void:
	display = p_display
	display.window_framed.connect(_on_window_framed)
	display.stacking_changed.connect(_restack)
	display.focus_changed.connect(_on_focus_changed)
	_on_resized()
	for w in display.windows:
		_on_window_framed(w)


func _on_resized() -> void:
	if display:
		display.size = size


func _on_window_framed(win: AgoraWindow) -> void:
	var frame := win.frame
	if frame.get_parent():
		frame.get_parent().remove_child(frame)
	_layers[win.layer].add_child(frame)
	if not win.changed.is_connected(_apply.bind(win)):
		win.changed.connect(_apply.bind(win))
	_apply(win)
	_restack()
	if win == display.focused:
		_on_focus_changed(win)


func _apply(win: AgoraWindow) -> void:
	if not win.open or not is_instance_valid(win.frame):
		return
	win.frame.position = win.position
	win.frame.size = win.size
	win.frame.visible = not win.minimized


func _restack() -> void:
	for w in display.windows:
		if is_instance_valid(w.frame) and w.frame.get_parent():
			w.frame.move_to_front()


func _on_focus_changed(win: AgoraWindow) -> void:
	if win == null:
		var owner := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
		if owner and is_ancestor_of(owner):
			owner.release_focus()
		return
	var target := win.focus_target
	if target and is_instance_valid(target):
		target.call_deferred("grab_focus")


## Topmost visible window under [param pos] (view coordinates).
func window_at(pos: Vector2) -> AgoraWindow:
	for layer in [AgoraWindow.Layer.OVERLAY, AgoraWindow.Layer.PANEL, AgoraWindow.Layer.NORMAL, AgoraWindow.Layer.DESKTOP]:
		for i in range(display.windows.size() - 1, -1, -1):
			var w := display.windows[i]
			if w.layer == layer and not w.minimized and w.rect().has_point(pos):
				return w
	return null


func _input(event: InputEvent) -> void:
	if display == null:
		return
	if event is InputEventMouseButton and event.pressed:
		var local := get_global_transform_with_canvas().affine_inverse() * (event as InputEventMouseButton).position
		var w := window_at(local)
		if w and w != display.focused and w.layer in [AgoraWindow.Layer.NORMAL, AgoraWindow.Layer.OVERLAY]:
			display.focus_window(w)
	elif event is InputEventKey and event.pressed:
		var m := display.manager
		if m and m.has_method("handle_key") and m.handle_key(event):
			get_viewport().set_input_as_handled()
