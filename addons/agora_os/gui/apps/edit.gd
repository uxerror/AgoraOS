extends AgoraGuiProgram
## Text editor. Ctrl+S saves, Ctrl+Shift+S saves under another name. Files
## you may not write open read-only; closing with unsaved changes asks first.

var p: AgoraProcess
var win: AgoraWindow
var path := ""
var read_only := false

var _root := VBoxContainer.new()
var _code := CodeEdit.new()
var _status := Label.new()
var _position := Label.new()
var _saved_text := ""


func summary() -> String:
	return "text editor"


func usage() -> String:
	return "usage: edit [file]"


func main(proc: AgoraProcess) -> int:
	p = proc
	_build()
	win = open_window(p, _root, {"title": "edit", "size": Vector2(760, 520), "min_size": Vector2(300, 160)})
	if win == null:
		return 1
	win.focus_target = _code
	win.close_requested.connect(_on_close_requested)
	if p.argv.size() > 1:
		path = p.abspath(p.argv[1])
		_load()
	_update_title()
	await win.closed
	return 0


func _build() -> void:
	_root.add_theme_constant_override("separation", 0)
	_code.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code.add_theme_font_override("font", AgoraStyle.MONO)
	_code.add_theme_font_size_override("font_size", 14)
	_code.gutters_draw_line_numbers = true
	_code.highlight_current_line = true
	_code.indent_automatic = true
	_code.text_changed.connect(_update_title)
	_code.text_set.connect(_update_title)
	_code.caret_changed.connect(_update_position)
	_code.gui_input.connect(_on_key)
	_root.add_child(_code)
	var bar := HBoxContainer.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	for l in [_status, _position]:
		l.add_theme_font_size_override("font_size", 12)
		bar.add_child(l)
	_root.add_child(bar)
	_update_position()


func _load() -> void:
	var st := p.stat(path)
	if st == null:
		if p.errno == AgoraErrno.ENOENT:
			_say("New file")
		else:
			_say("%s: %s" % [path, AgoraErrno.describe(p.errno)])
		return
	if st.is_dir():
		_say("%s is a directory" % path)
		path = ""
		return
	var text := p.read_text(path)
	if p.errno != AgoraErrno.OK:
		_say("Cannot open %s: %s" % [path, AgoraErrno.describe(p.errno)])
		read_only = true
		return
	_code.text = text
	_saved_text = text
	_code.clear_undo_history()
	read_only = not AgoraVfs.can_access(p.cred, st, AgoraStat.W)
	_say("Read-only: you can't write this file" if read_only else "%d lines" % _code.get_line_count())


func is_modified() -> bool:
	return _code.text != _saved_text


func save() -> bool:
	if path.is_empty():
		return await save_as()
	var e := p.write_text(path, _code.text)
	if e != AgoraErrno.OK:
		_say("Cannot save %s: %s" % [path, AgoraErrno.describe(e)])
		return false
	_saved_text = _code.text
	read_only = false
	_say("Saved %s" % path)
	_update_title()
	return true


func save_as() -> bool:
	var suggestion := path if not path.is_empty() else AgoraPath.join(p.cwd, "untitled.txt")
	var answer: Variant = await AgoraDialog.ask_text(_root, "Save as:", suggestion)
	if answer == null or (answer as String).strip_edges().is_empty():
		return false
	path = AgoraPath.normalize((answer as String).strip_edges(), p.cwd)
	return await save()


func _on_key(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.ctrl_pressed and event.keycode == KEY_S:
		_code.accept_event()
		if event.shift_pressed:
			await save_as()
		else:
			await save()


func _on_close_requested() -> void:
	if not is_modified():
		win.close()
		return
	var name := AgoraPath.basename(path) if not path.is_empty() else "untitled"
	var choice := await AgoraDialog.choose(_root, "Save changes to \"%s\" before closing?" % name,
		PackedStringArray(["Save", "Discard", "Cancel"]))
	if choice == 0 and await save():
		win.close()
	elif choice == 1:
		win.close()


func _update_title() -> void:
	if win == null or not win.open:
		return
	var name := AgoraPath.basename(path) if not path.is_empty() else "untitled"
	win.title = "%s%s%s - edit" % ["*" if is_modified() else "", name, " [read-only]" if read_only else ""]


func _update_position() -> void:
	_position.text = "Ln %d, Col %d " % [_code.get_caret_line() + 1, _code.get_caret_column() + 1]


func _say(text: String) -> void:
	_status.text = " " + text
