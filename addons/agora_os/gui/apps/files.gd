extends AgoraGuiProgram
## File manager. It runs with the user's own permissions, so it sees exactly
## what "ls" would. Copy, move and delete are done by running cp, mv and rm,
## the way a Unix front end should.

const ITEM_OPEN := 0
const ITEM_TERMINAL := 1
const ITEM_RENAME := 2
const ITEM_COPY := 3
const ITEM_CUT := 4
const ITEM_DELETE := 5
const ITEM_PROPERTIES := 6
const EMPTY_NEW_FOLDER := 10
const EMPTY_NEW_FILE := 11
const EMPTY_PASTE := 12
const EMPTY_TERMINAL := 13
const EMPTY_HIDDEN := 14
const EMPTY_REFRESH := 15

var p: AgoraProcess
var win: AgoraWindow
var cwd := "/"
var show_hidden := false

var _root := VBoxContainer.new()
var _list := ItemList.new()
var _path := LineEdit.new()
var _status := Label.new()
var _menu := PopupMenu.new()
var _listing: PackedStringArray = []
var _clipboard: PackedStringArray = []
var _clipboard_cut := false


func summary() -> String:
	return "file manager"


func usage() -> String:
	return "usage: files [directory]"


func main(proc: AgoraProcess) -> int:
	p = proc
	_build()
	win = open_window(p, _root, {"title": "Files", "size": Vector2(720, 460), "min_size": Vector2(320, 200)})
	if win == null:
		return 1
	win.focus_target = _list
	navigate(p.argv[1] if p.argv.size() > 1 else p.home())
	while win.open and p.is_running():
		await p.sleep(1.5)
		if win.open and p.list_dir(cwd) != _listing:
			reload()
	return 0


# --- UI -----------------------------------------------------------------------

func _build() -> void:
	_root.add_theme_constant_override("separation", 0)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	_root.add_child(bar)
	var up := Button.new()
	up.icon = AgoraStyle.icon("up", 16)
	up.tooltip_text = "Parent folder (Backspace)"
	up.focus_mode = Control.FOCUS_NONE
	up.pressed.connect(func() -> void: navigate(AgoraPath.dirname(cwd)))
	bar.add_child(up)
	var home := Button.new()
	home.text = "Home"
	home.focus_mode = Control.FOCUS_NONE
	home.pressed.connect(func() -> void: navigate(p.home()))
	bar.add_child(home)
	_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path.text_submitted.connect(func(t: String) -> void: navigate(t))
	bar.add_child(_path)

	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.max_columns = 0
	_list.same_column_width = true
	_list.fixed_column_width = 92
	_list.fixed_icon_size = Vector2i(48, 48)
	_list.max_text_lines = 2
	_list.select_mode = ItemList.SELECT_MULTI
	_list.allow_rmb_select = true
	_list.item_activated.connect(_open_index)
	_list.item_clicked.connect(_on_item_clicked)
	_list.empty_clicked.connect(_on_empty_clicked)
	_list.gui_input.connect(_on_list_key)
	_root.add_child(_list)

	_status.add_theme_font_size_override("font_size", 12)
	_status.clip_text = true
	_root.add_child(_status)
	_root.add_child(_menu)
	_menu.id_pressed.connect(_on_menu)


func _say(text: String) -> void:
	_status.text = " " + text


# --- navigation ---------------------------------------------------------------

func navigate(path: String) -> void:
	var target := AgoraPath.normalize(path, cwd)
	var st := p.stat(target)
	if st == null:
		_say("%s: %s" % [target, AgoraErrno.describe(p.errno)])
		return
	if not st.is_dir():
		_spawn(PackedStringArray(["open", target]))
		return
	if not AgoraVfs.can_access(p.cred, st, AgoraStat.X):
		_say("%s: %s" % [target, AgoraErrno.describe(AgoraErrno.EACCES)])
		return
	cwd = p.realpath(target)
	_path.text = cwd
	win.title = "Files - " + cwd
	reload()


func reload() -> void:
	var keep := _selected_names()
	_list.clear()
	_listing = p.list_dir(cwd)
	if p.errno != AgoraErrno.OK:
		_say("%s: %s" % [cwd, AgoraErrno.describe(p.errno)])
		return
	var dirs: Array[Dictionary] = []
	var files: Array[Dictionary] = []
	var hidden := 0
	for name in _listing:
		if name.begins_with(".") and not show_hidden:
			hidden += 1
			continue
		var path := AgoraPath.join(cwd, name)
		var lst := p.stat(path, false)
		var st := p.stat(path) if lst and lst.is_symlink() else lst
		var entry := {"name": name, "lst": lst, "st": st, "path": path}
		if st and st.is_dir():
			dirs.append(entry)
		else:
			files.append(entry)
	var by_name := func(a: Dictionary, b: Dictionary) -> bool: return (a.name as String).naturalnocasecmp_to(b.name) < 0
	dirs.sort_custom(by_name)
	files.sort_custom(by_name)
	for e: Dictionary in dirs + files:
		var st: AgoraStat = e.st
		var lst: AgoraStat = e.lst
		var mime := AgoraMime.type_of(p, e.path) if st and st.is_file() else ""
		var kind := "link" if st == null else AgoraStyle.kind_for(st, mime)
		var idx := _list.add_item(e.name, AgoraStyle.icon(kind))
		_list.set_item_metadata(idx, e.name)
		var info := "%s  %s:%s  %d bytes" % [lst.mode_string(), p.machine.users.name_of(lst.uid),
			p.machine.users.group_name_of(lst.gid), lst.size]
		if lst.is_symlink():
			info += "\n-> " + p.read_link(e.path)
		_list.set_item_tooltip(idx, info)
		if keep.has(e.name):
			_list.select(idx, false)
	_say("%d items%s" % [dirs.size() + files.size(), " (%d hidden)" % hidden if hidden else ""])


func _selected_names() -> PackedStringArray:
	var out: PackedStringArray = []
	for idx in _list.get_selected_items():
		out.append(_list.get_item_metadata(idx))
	return out


func _selected_paths() -> PackedStringArray:
	var out: PackedStringArray = []
	for name in _selected_names():
		out.append(AgoraPath.join(cwd, name))
	return out


func _open_index(idx: int) -> void:
	var path := AgoraPath.join(cwd, _list.get_item_metadata(idx))
	if p.is_dir(path):
		navigate(path)
	else:
		_spawn(PackedStringArray(["open", path]))


func _spawn(argv: PackedStringArray, dir: String = "") -> void:
	if p.spawn(argv, {"stdin": AgoraStream.empty(), "cwd": dir if not dir.is_empty() else cwd}) == null:
		_say("%s: %s" % [argv[0], AgoraErrno.describe(p.errno)])


## Runs a command line tool and shows its first error line, if any.
func _run_tool(argv: PackedStringArray) -> bool:
	var errs := AgoraStream.new()
	errs.add_reader()
	var child := p.spawn(argv, {"stdin": AgoraStream.empty(), "stdout": AgoraStream.discard(), "stderr": errs, "cwd": cwd})
	if child == null:
		_say("%s: %s" % [argv[0], AgoraErrno.describe(p.errno)])
		return false
	var code := await child.wait()
	var message := errs.read_available().strip_edges().get_slice("\n", 0)
	errs.release_reader()
	if win.open:
		reload()
		if code != 0:
			_say(message if not message.is_empty() else "%s failed" % argv[0])
	return code == 0


# --- menus and keys -----------------------------------------------------------

func _popup_at(local: Vector2) -> void:
	_menu.reset_size()
	_menu.popup(Rect2i(Vector2i(_list.global_position + local), Vector2i.ZERO))


func _on_item_clicked(idx: int, at: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT:
		return
	if not _list.is_selected(idx):
		_list.select(idx)
	var is_dir := p.is_dir(AgoraPath.join(cwd, _list.get_item_metadata(idx)))
	_menu.clear()
	_menu.add_item("Open", ITEM_OPEN)
	if is_dir:
		_menu.add_item("Open Terminal Here", ITEM_TERMINAL)
	_menu.add_separator()
	_menu.add_item("Copy", ITEM_COPY)
	_menu.add_item("Cut", ITEM_CUT)
	_menu.add_item("Rename...", ITEM_RENAME)
	_menu.add_item("Delete", ITEM_DELETE)
	_menu.add_separator()
	_menu.add_item("Properties", ITEM_PROPERTIES)
	_popup_at(at)


func _on_empty_clicked(at: Vector2, button: int) -> void:
	_list.deselect_all()
	if button != MOUSE_BUTTON_RIGHT:
		return
	_menu.clear()
	_menu.add_item("New Folder...", EMPTY_NEW_FOLDER)
	_menu.add_item("New File...", EMPTY_NEW_FILE)
	_menu.add_item("Paste", EMPTY_PASTE)
	_menu.set_item_disabled(_menu.get_item_index(EMPTY_PASTE), _clipboard.is_empty())
	_menu.add_separator()
	_menu.add_item("Open Terminal Here", EMPTY_TERMINAL)
	_menu.add_check_item("Show Hidden Files", EMPTY_HIDDEN)
	_menu.set_item_checked(_menu.get_item_index(EMPTY_HIDDEN), show_hidden)
	_menu.add_item("Refresh", EMPTY_REFRESH)
	_popup_at(at)


func _on_list_key(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return
	var k := event as InputEventKey
	var handled := true
	if k.ctrl_pressed:
		match k.keycode:
			KEY_C: _on_menu(ITEM_COPY)
			KEY_X: _on_menu(ITEM_CUT)
			KEY_V: _on_menu(EMPTY_PASTE)
			KEY_H: _on_menu(EMPTY_HIDDEN)
			_: handled = false
	else:
		match k.keycode:
			KEY_DELETE: _on_menu(ITEM_DELETE)
			KEY_F2: _on_menu(ITEM_RENAME)
			KEY_F5: reload()
			KEY_BACKSPACE: navigate(AgoraPath.dirname(cwd))
			_: handled = false
	if handled:
		_list.accept_event()


func _on_menu(id: int) -> void:
	var paths := _selected_paths()
	match id:
		ITEM_OPEN:
			for idx in _list.get_selected_items():
				_open_index(idx)
		ITEM_TERMINAL:
			if not paths.is_empty():
				_spawn(PackedStringArray(["terminal"]), paths[0])
		EMPTY_TERMINAL:
			_spawn(PackedStringArray(["terminal"]))
		ITEM_COPY, ITEM_CUT:
			if not paths.is_empty():
				_clipboard = paths
				_clipboard_cut = id == ITEM_CUT
				_say("%d item(s) %s" % [paths.size(), "cut" if _clipboard_cut else "copied"])
		EMPTY_PASTE:
			await _paste()
		ITEM_RENAME:
			await _rename(paths)
		ITEM_DELETE:
			await _delete(paths)
		ITEM_PROPERTIES:
			if not paths.is_empty():
				await AgoraDialog.message(_root, _properties(paths[0]))
		EMPTY_NEW_FOLDER, EMPTY_NEW_FILE:
			await _create(id == EMPTY_NEW_FOLDER)
		EMPTY_HIDDEN:
			show_hidden = not show_hidden
			reload()
		EMPTY_REFRESH:
			reload()


# --- actions ------------------------------------------------------------------

func _paste() -> void:
	if _clipboard.is_empty():
		return
	for src in _clipboard:
		var dest := AgoraPath.join(cwd, AgoraPath.basename(src))
		if _clipboard_cut:
			if AgoraPath.dirname(src) != cwd:
				await _run_tool(PackedStringArray(["mv", "--", src, dest]))
		else:
			if p.stat(dest, false) != null:
				dest = _unique_name(dest)
			await _run_tool(PackedStringArray(["cp", "-r", "--", src, dest]))
	if _clipboard_cut:
		_clipboard.clear()


func _unique_name(path: String) -> String:
	var dir := AgoraPath.dirname(path)
	var base := AgoraPath.basename(path)
	var ext := base.get_extension()
	var stem := base.get_basename() if not ext.is_empty() and not base.begins_with(".") else base
	var suffix := "." + ext if stem != base else ""
	var n := 1
	while true:
		var candidate := AgoraPath.join(dir, "%s copy%s%s" % [stem, "" if n == 1 else " %d" % n, suffix])
		if p.stat(candidate, false) == null:
			return candidate
		n += 1
	return path


func _rename(paths: PackedStringArray) -> void:
	if paths.size() != 1:
		return
	var old := AgoraPath.basename(paths[0])
	var answer: Variant = await AgoraDialog.ask_text(_root, "Rename \"%s\" to:" % old, old)
	if answer == null or (answer as String).strip_edges().is_empty() or answer == old:
		return
	var new_name := (answer as String).strip_edges()
	if not AgoraPath.is_valid_name(new_name):
		_say("Invalid name: %s" % new_name)
		return
	if p.stat(AgoraPath.join(cwd, new_name), false) != null:
		_say("%s already exists" % new_name)
		return
	await _run_tool(PackedStringArray(["mv", "--", paths[0], AgoraPath.join(cwd, new_name)]))


func _delete(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var what := "\"%s\"" % AgoraPath.basename(paths[0]) if paths.size() == 1 else "%d items" % paths.size()
	var choice := await AgoraDialog.choose(_root, "Delete %s? This can't be undone." % what, PackedStringArray(["Delete", "Cancel"]))
	if choice != 0:
		return
	var argv := PackedStringArray(["rm", "-rf", "--"])
	argv.append_array(paths)
	await _run_tool(argv)


func _create(folder: bool) -> void:
	var answer: Variant = await AgoraDialog.ask_text(_root, "Folder name:" if folder else "File name:", "New Folder" if folder else "untitled.txt")
	if answer == null:
		return
	var name := (answer as String).strip_edges()
	if not AgoraPath.is_valid_name(name):
		_say("Invalid name: %s" % name)
		return
	var path := AgoraPath.join(cwd, name)
	if p.stat(path, false) != null:
		_say("%s already exists" % name)
		return
	var e := p.mkdir(path) if folder else p.write_text(path, "")
	if e != AgoraErrno.OK:
		_say("%s: %s" % [name, AgoraErrno.describe(e)])
	reload()


func _properties(path: String) -> String:
	var lst := p.stat(path, false)
	if lst == null:
		return "%s: %s" % [path, AgoraErrno.describe(p.errno)]
	var users := p.machine.users
	var lines: PackedStringArray = [
		"Name:  %s" % AgoraPath.basename(path),
		"Where: %s" % AgoraPath.dirname(path),
		"Type:  %s" % (AgoraMime.type_of(p, path) if not lst.is_symlink() else "symbolic link -> " + p.read_link(path)),
		"Size:  %d bytes" % lst.size,
		"Owner: %s   Group: %s" % [users.name_of(lst.uid), users.group_name_of(lst.gid)],
		"Mode:  %s (%s)" % [lst.mode_string(), AgoraStat.to_octal(lst.mode & AgoraStat.PERM_MASK)],
		"Modified: %s" % p.machine.clock.format_long(lst.mtime),
	]
	return "\n".join(lines)
