class_name AgoraGrubMenu
extends RefCounted
## GRUB's screens, for a box with someone at its keyboard: the boot menu
## with its countdown, the entry editor ('e'), the command line ('c') and
## the password prompt ('p') that a "password" line in menu.lst asks for
## before the other two may be used.

## Rows of entries the menu box shows at once.
const BOX_ROWS := 12
const COLOR_NAMES: PackedStringArray = [
	"black", "blue", "green", "cyan", "red", "magenta", "brown", "light-gray",
	"dark-gray", "light-blue", "light-green", "light-cyan", "light-red", "light-magenta", "yellow", "white",
]
## VGA order (GRUB's) to ANSI order.
const VGA_TO_ANSI: PackedInt32Array = [0, 4, 2, 6, 1, 5, 3, 7, 8, 12, 10, 14, 9, 13, 11, 15]

var grub: AgoraGrub
var screen: AgoraFwScreen
var _normal := Vector2i(7, 0)
var _highlight := Vector2i(0, 7)
var _locked := false


func _init(p_grub: AgoraGrub, p_screen: AgoraFwScreen) -> void:
	grub = p_grub
	screen = p_screen


## Loads GRUB and runs it until something is booted. Returns {boot, disk,
## cmdline}, {reboot}, {halt}, {error} when GRUB could not load, or {}
## when the boot was abandoned.
func run() -> Dictionary:
	screen.clear()
	var err := grub.load()
	if not err.is_empty():
		screen.write(err + "\n")
		return {"error": err}
	var menu := grub.menu
	if (menu.get("entries", []) as Array).is_empty():
		while screen.is_alive():
			var r: Variant = await command_line(false)
			if r is Dictionary:
				return r
		return {}
	_colors(menu.color)
	_locked = not str(menu.password).is_empty()
	var entries: Array = menu.entries
	var sel: int = clampi(menu.default, 0, entries.size() - 1)
	var timeout: int = menu.timeout
	if menu.hidden and timeout > 0:
		timeout = await _hidden_countdown(timeout)
		if not screen.is_alive():
			return {}
	while screen.is_alive():
		if timeout == 0:
			var r: Variant = await _boot(entries[sel])
			if r is Dictionary:
				return r
			timeout = -1
			continue
		_draw_menu(entries, sel, timeout)
		var k: String = await screen.key(1.0 if timeout > 0 else -1.0)
		if not screen.is_alive():
			return {}
		if k.is_empty():
			timeout -= 1
			continue
		timeout = -1
		match k:
			"up":
				sel = maxi(0, sel - 1)
			"down":
				sel = mini(entries.size() - 1, sel + 1)
			"enter":
				timeout = 0
			"e":
				if not _locked:
					var r: Variant = await _edit(entries[sel])
					if r is Dictionary:
						return r
			"c":
				if not _locked:
					var r: Variant = await command_line(true)
					if r is Dictionary:
						return r
			"p":
				if _locked:
					await _ask_password()
	return {}


## "color cyan/blue white/blue": normal and highlighted colours.
func _colors(spec: PackedStringArray) -> void:
	if spec.size() >= 1:
		_normal = _parse_color(spec[0], _normal)
	if spec.size() >= 2:
		_highlight = _parse_color(spec[1], _highlight)
	elif spec.size() == 1:
		_highlight = Vector2i(_normal.y, _normal.x)


static func _parse_color(text: String, fallback: Vector2i) -> Vector2i:
	var parts := text.trim_prefix("blink-").split("/")
	if parts.size() != 2:
		return fallback
	var fg := COLOR_NAMES.find(parts[0])
	var bg := COLOR_NAMES.find(parts[1])
	if fg < 0 or bg < 0 or bg > 7:
		return fallback
	return Vector2i(VGA_TO_ANSI[fg], VGA_TO_ANSI[bg])


func _header() -> void:
	screen.clear(_normal.x, _normal.y)
	screen.put(1, 0, "    GNU GRUB  version %s  (%s)" % [AgoraGrub.VERSION, grub.memory_text()], _normal.x, _normal.y)


## The box with [param lines] in it, [param sel] highlighted.
func _draw_box(lines: PackedStringArray, sel: int) -> void:
	screen.box(3, 1, BOX_ROWS + 2, 77, _normal.x, _normal.y)
	var first := clampi(sel - BOX_ROWS + 1, 0, maxi(0, lines.size() - BOX_ROWS))
	for i in BOX_ROWS:
		var n := first + i
		if n >= lines.size():
			break
		var colors := _highlight if n == sel else _normal
		screen.put(4 + i, 2, (" " + expand_tabs(lines[n])).rpad(75).left(75), colors.x, colors.y)


func _draw_menu(entries: Array, sel: int, timeout: int) -> void:
	_header()
	var titles: PackedStringArray = []
	for e: Dictionary in entries:
		titles.append(e.title)
	_draw_box(titles, sel)
	var help := ["      Use the ^ and v keys to select which entry is highlighted."]
	if _locked:
		help.append_array(["      Press enter to boot the selected OS or 'p' to enter a", "      password to unlock the next set of features."])
	else:
		help.append_array(["      Press enter to boot the selected OS, 'e' to edit the", "      commands before booting, or 'c' for a command-line."])
	for i in help.size():
		screen.put(17 + i, 0, help[i], _normal.x, _normal.y)
	if timeout > 0:
		screen.put(21, 0, "   The highlighted entry will be booted automatically in %d seconds.    " % timeout, _normal.x, _normal.y)


## hiddenmenu: a countdown with no menu. Esc shows the menu (no timeout).
func _hidden_countdown(timeout: int) -> int:
	screen.clear()
	while timeout > 0 and screen.is_alive():
		screen.put(0, 0, "Press `ESC' to enter the menu... %d   " % timeout)
		var k: String = await screen.key(1.0)
		if k == "esc":
			return -1
		if k.is_empty():
			timeout -= 1
	return 0


## Boots an entry: its commands on a cleared screen. Returns the result,
## or null after an error (back to the menu).
func _boot(entry: Dictionary) -> Variant:
	screen.clear()
	screen.write("\u001b[?25h")
	var r := grub.run_entry(entry)
	if r.has("boot") or r.has("reboot") or r.has("halt"):
		return r
	screen.write("\nPress any key to continue...")
	await screen.key()
	return null if screen.is_alive() else {}


## The entry editor: the commands of [param entry], to change before
## booting them with 'b'. Esc goes back (null).
func _edit(entry: Dictionary) -> Variant:
	var lines: PackedStringArray = (entry.lines as PackedStringArray).duplicate()
	var sel := 0
	while screen.is_alive():
		_header()
		_draw_box(lines, sel)
		var help := [
			"      Use the ^ and v keys to select which entry is highlighted.",
			"      Press 'b' to boot, 'e' to edit the selected command in the",
			"      boot sequence, 'c' for a command-line, 'o' to open a new line",
			"      after ('O' for before) the selected line, 'd' to remove the",
			"      selected line, or escape to go back to the main menu.",
		]
		for i in help.size():
			screen.put(17 + i, 0, help[i], _normal.x, _normal.y)
		var k: String = await screen.key()
		match k:
			"up":
				sel = maxi(0, sel - 1)
			"down":
				sel = mini(maxi(0, lines.size() - 1), sel + 1)
			"esc":
				return null
			"b":
				var r: Variant = await _boot({"title": entry.title, "lines": lines, "edited": true})
				if r is Dictionary:
					return r
			"e", "enter":
				if lines.is_empty():
					lines.append("")
				var changed: Variant = await _edit_line(lines[sel])
				if changed != null:
					lines[sel] = changed
			"o", "O":
				var at := sel + 1 if k == "o" and not lines.is_empty() else sel
				var added: Variant = await _edit_line("")
				if added != null:
					lines.insert(at, added)
					sel = at
			"d":
				if not lines.is_empty():
					lines.remove_at(sel)
					sel = clampi(sel, 0, maxi(0, lines.size() - 1))
			"c":
				var r: Variant = await command_line(true)
				if r is Dictionary:
					return r
			"":
				return {}
	return {}


func _edit_line(text: String) -> Variant:
	screen.clear()
	screen.put(0, 0, "    [ Minimal BASH-like line editing is supported.  For the first word, TAB")
	screen.put(1, 0, "      lists possible command completions.  Anywhere else TAB lists the possible")
	screen.put(2, 0, "      completions of a device/filename.  ESC at any time cancels.  ENTER")
	screen.put(3, 0, "      at any time accepts your changes.]")
	screen.put(5, 0, "grub edit> ")
	return await screen.read_line(5, 11, expand_tabs(text))


## Tabs as spaces to the next multiple of 8, as GRUB shows them.
static func expand_tabs(text: String) -> String:
	var out := ""
	for ch in text:
		if ch == "\t":
			out += " ".repeat(8 - out.length() % 8)
		else:
			out += ch
	return out


## The GRUB command line. Returns a boot result, or null when Esc goes
## back to the menu ([param can_leave]).
func command_line(can_leave: bool) -> Variant:
	screen.clear()
	screen.write("    GNU GRUB  version %s  (%s)\n\n" % [AgoraGrub.VERSION, grub.memory_text()])
	screen.write(" [ Minimal BASH-like line editing is supported.  For the first word, TAB\n   lists possible command completions.  Anywhere else TAB lists the possible\n   completions of a device/filename.%s ]\n" % ("  ESC at any time exits." if can_leave else ""))
	while screen.is_alive():
		screen.write("\ngrub> ")
		var line: Variant = await screen.type_line(_complete)
		if not screen.is_alive():
			return {}
		if line == null:
			if can_leave:
				return null
			continue
		var r := grub.execute(str(line))
		if r.has("error"):
			screen.write("\n%s\n" % r.error)
		elif r.has("boot") or r.has("reboot") or r.has("halt"):
			return r
	return {}


## TAB on the command line: completes the command name, or lists the
## possible ones.
func _complete(text: String) -> String:
	if text.contains(" "):
		return text
	var matches: PackedStringArray = []
	for c in AgoraGrub.COMMANDS:
		if c.begins_with(text):
			matches.append(c)
	if matches.size() == 1:
		return matches[0] + " "
	if not matches.is_empty():
		screen.write("\n Possible commands are: %s\n\ngrub> %s" % [" ".join(matches), text])
	return text


func _ask_password() -> void:
	screen.put(21, 0, "Password: ".rpad(79), _normal.x, _normal.y)
	var given: Variant = await screen.read_line(21, 10, "", true, 64, _normal.x, _normal.y)
	if given != null and str(given) == str(grub.menu.password):
		_locked = false
