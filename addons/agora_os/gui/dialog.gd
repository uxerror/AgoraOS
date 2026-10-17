class_name AgoraDialog
extends Control
## Modal dialog drawn inside a program's own window (not a separate engine
## window), so it moves, minimizes and dies with that window.
##
## [codeblock]
## var name = await AgoraDialog.ask_text(content, "New folder", "untitled")
## var choice = await AgoraDialog.choose(content, "Discard changes?", ["Save", "Discard", "Cancel"])
## [/codeblock]

signal finished(result: Variant)

var _edit: LineEdit
var _buttons: PackedStringArray
var _done := false


## Asks for a line of text. Returns the text, or null if cancelled.
static func ask_text(host: Control, prompt: String, initial: String = "") -> Variant:
	var d := AgoraDialog.new()
	d._build(host, prompt, PackedStringArray(["OK", "Cancel"]), true, initial)
	var r: Variant = await d.finished
	return r


## Shows [param text] with [param buttons]. Returns the index of the button
## pressed, or -1 when dismissed with Escape.
static func choose(host: Control, text: String, buttons: PackedStringArray) -> int:
	var d := AgoraDialog.new()
	d._build(host, text, buttons, false, "")
	var r: Variant = await d.finished
	return r


static func message(host: Control, text: String) -> void:
	await choose(host, text, PackedStringArray(["OK"]))


func _build(host: Control, text: String, buttons: PackedStringArray, with_edit: bool, initial: String) -> void:
	_buttons = buttons
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#20262e")
	style.border_color = Color("#4a5a6e")
	style.set_border_width_all(1)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.custom_minimum_size = Vector2(minf(320, maxf(160, host.size.x - 40)), 0)
	panel.add_child(col)
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(label)
	if with_edit:
		_edit = LineEdit.new()
		_edit.text = initial
		_edit.select_all_on_focus = true
		_edit.text_submitted.connect(func(_t: String) -> void: _finish(0))
		col.add_child(_edit)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	col.add_child(row)
	for i in buttons.size():
		var b := Button.new()
		b.text = buttons[i]
		b.pressed.connect(_finish.bind(i))
		row.add_child(b)
	host.add_child(self)
	if _edit:
		_edit.grab_focus.call_deferred()
	else:
		(row.get_child(0) as Control).grab_focus.call_deferred()


func _gui_input(event: InputEvent) -> void:
	accept_event()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and is_visible_in_tree():
		var owner := get_viewport().gui_get_focus_owner()
		if owner and is_ancestor_of(owner):
			get_viewport().set_input_as_handled()
			_finish(-1)


func _finish(index: int) -> void:
	if _done:
		return
	_done = true
	var result: Variant = index
	if _edit:
		result = _edit.text if index == 0 else null
	queue_free()
	finished.emit(result)


func _notification(what: int) -> void:
	# The window was closed under us: report a cancel so awaiting code
	# resumes. (Not on tree exit: a window manager restart reparents windows.)
	if what == NOTIFICATION_PREDELETE and not _done:
		_done = true
		finished.emit(null if _edit else -1)
