class_name AgoraTermView
extends Control
## Terminal emulator widget connected to an [AgoraTty].
##
## Output: a scrollback buffer of character cells with colors, driven by a
## subset of ANSI escape codes (SGR colors, clear screen, cursor moves).
## Input: canonical line editing like a real tty: the line is edited here and
## sent to the processes when Enter is pressed. Typed text is hidden while
## the tty has echo off (password prompts).

const MAX_LINES := 2000
const PAD := 4.0
## Classic 16-color VGA palette.
const PALETTE: Array[Color] = [
	Color8(0, 0, 0), Color8(170, 0, 0), Color8(0, 170, 0), Color8(170, 85, 0),
	Color8(0, 0, 170), Color8(170, 0, 170), Color8(0, 170, 170), Color8(170, 170, 170),
	Color8(85, 85, 85), Color8(255, 85, 85), Color8(85, 255, 85), Color8(255, 255, 85),
	Color8(85, 85, 255), Color8(255, 85, 255), Color8(85, 255, 255), Color8(255, 255, 255),
]
const FG_DEFAULT := 7
const BG_DEFAULT := 0
const FONTS: PackedStringArray = ["DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Consolas", "Menlo", "monospace"]

## An attribute packs fg (bits 0-7), bg (8-15) and bold (16).
const ATTR_DEFAULT := FG_DEFAULT | (BG_DEFAULT << 8)

var tty: AgoraTty
var font: Font
var font_size := 15:
	set(value):
		font_size = value
		_measure()
var background := Color8(12, 12, 14)

var _cell := Vector2(9, 18)
var _ascent := 14.0
var _lines: Array[Dictionary] = []
var _row := 0
var _col := 0
var _attr := ATTR_DEFAULT
var _in_esc := false
var _esc := ""
var _input := ""
var _caret := 0
var _hist_index := -1
var _hist_saved := ""
var _scroll := 0
var _blink_on := true
var _blink_timer := Timer.new()


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	mouse_default_cursor_shape = Control.CURSOR_IBEAM
	var f := SystemFont.new()
	f.font_names = FONTS
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	font = f
	_measure()
	_lines.append(_new_line())
	_blink_timer.wait_time = 0.55
	_blink_timer.timeout.connect(_on_blink)
	add_child(_blink_timer)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)


func _ready() -> void:
	_blink_timer.start()


func attach(p_tty: AgoraTty) -> void:
	tty = p_tty
	tty.printed.connect(feed)
	tty.mode_changed.connect(queue_redraw)


func _measure() -> void:
	_cell = Vector2(font.get_char_size("M".unicode_at(0), font_size).x, font.get_height(font_size))
	_ascent = font.get_ascent(font_size)


func cols() -> int:
	return maxi(10, int((size.x - PAD * 2.0) / _cell.x))


func rows() -> int:
	return maxi(2, int((size.y - PAD * 2.0) / _cell.y))


## Pixel size that fits [param c] columns and [param r] rows.
func size_for(c: int, r: int) -> Vector2:
	return Vector2(c * _cell.x + PAD * 2.0, r * _cell.y + PAD * 2.0).ceil()


## Text currently in the buffer, for tests and copy.
func screen_text() -> String:
	var out: PackedStringArray = []
	for l in _lines:
		out.append(l.t)
	return "\n".join(out)


# --- output -----------------------------------------------------------------

func _new_line() -> Dictionary:
	return {"t": "", "a": PackedInt32Array()}


func feed(text: String) -> void:
	for ch in text:
		if _in_esc:
			_esc_char(ch)
			continue
		match ch:
			"\u001b":
				_in_esc = true
				_esc = ""
			"\n":
				_newline()
			"\r":
				_col = 0
			"\b":
				_col = maxi(0, _col - 1)
			"\t":
				for i in 8 - _col % 8:
					_put(" ")
			"\u0007":
				pass
			_:
				_put(ch)
	_trim()
	_scroll = 0
	queue_redraw()


func _put(ch: String) -> void:
	if _col >= cols():
		_newline()
	var line: Dictionary = _lines[_row]
	var t: String = line.t
	var a: PackedInt32Array = line.a
	while t.length() < _col:
		t += " "
		a.append(ATTR_DEFAULT)
	if _col < t.length():
		t = t.substr(0, _col) + ch + t.substr(_col + 1)
		a[_col] = _attr
	else:
		t += ch
		a.append(_attr)
	line.t = t
	line.a = a
	_col += 1


func _newline() -> void:
	_row += 1
	_col = 0
	while _row >= _lines.size():
		_lines.append(_new_line())


func _trim() -> void:
	var extra := _lines.size() - MAX_LINES
	if extra > 0:
		_lines = _lines.slice(extra)
		_row = maxi(0, _row - extra)


func _esc_char(ch: String) -> void:
	_esc += ch
	if _esc.length() == 1 and ch != "[":
		_in_esc = false # two-character escapes are ignored
		return
	var code := ch.unicode_at(0)
	if _esc.length() > 1 and code >= 0x40 and code <= 0x7e:
		_in_esc = false
		_csi(_esc.substr(1, _esc.length() - 2), ch)
	elif _esc.length() > 32:
		_in_esc = false


func _csi(params: String, final: String) -> void:
	var nums: Array[int] = []
	for part in params.split(";"):
		nums.append(int(part) if part.is_valid_int() else 0)
	var n: int = nums[0] if not nums.is_empty() else 0
	match final:
		"m":
			_sgr(nums)
		"J":
			if n == 2 or n == 3:
				_lines = [_new_line()]
				_row = 0
				_col = 0
			elif n == 0:
				_lines = _lines.slice(0, _row + 1)
				_clear_to_eol()
		"K":
			_clear_to_eol()
		"H", "f":
			var top := maxi(0, _lines.size() - rows())
			_row = top + maxi(0, n - 1)
			_col = maxi(0, (nums[1] if nums.size() > 1 else 1) - 1)
			while _row >= _lines.size():
				_lines.append(_new_line())
		"A":
			_row = maxi(0, _row - maxi(1, n))
		"B":
			_row += maxi(1, n)
			while _row >= _lines.size():
				_lines.append(_new_line())
		"C":
			_col += maxi(1, n)
		"D":
			_col = maxi(0, _col - maxi(1, n))


func _clear_to_eol() -> void:
	var line: Dictionary = _lines[_row]
	if _col < (line.t as String).length():
		line.t = (line.t as String).substr(0, _col)
		line.a = (line.a as PackedInt32Array).slice(0, _col)


func _sgr(nums: Array[int]) -> void:
	if nums.is_empty():
		nums = [0]
	for n in nums:
		var fg := _attr & 255
		var bg := (_attr >> 8) & 255
		var bold := (_attr >> 16) & 1
		if n == 0:
			fg = FG_DEFAULT
			bg = BG_DEFAULT
			bold = 0
		elif n == 1:
			bold = 1
		elif n == 22:
			bold = 0
		elif n >= 30 and n <= 37:
			fg = n - 30
		elif n == 39:
			fg = FG_DEFAULT
		elif n >= 40 and n <= 47:
			bg = n - 40
		elif n == 49:
			bg = BG_DEFAULT
		elif n >= 90 and n <= 97:
			fg = n - 90 + 8
		elif n >= 100 and n <= 107:
			bg = n - 100 + 8
		_attr = fg | (bg << 8) | (bold << 16)


# --- input ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_scroll = mini(_scroll + 3, maxi(0, _lines.size() - rows()))
			MOUSE_BUTTON_WHEEL_DOWN:
				_scroll = maxi(0, _scroll - 3)
			MOUSE_BUTTON_MIDDLE:
				_paste(DisplayServer.clipboard_get_primary() if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD_PRIMARY) else DisplayServer.clipboard_get())
		grab_focus()
		queue_redraw()
		accept_event()
		return
	if not event is InputEventKey or not event.pressed or tty == null:
		return
	var k := event as InputEventKey
	accept_event()
	_blink_on = true
	_blink_timer.start()
	if k.ctrl_pressed and not k.alt_pressed:
		match k.keycode:
			KEY_C:
				if k.shift_pressed:
					DisplayServer.clipboard_set(screen_text())
				else:
					feed("^C")
					_reset_input()
					tty.interrupt()
			KEY_D:
				if _input.is_empty():
					tty.send_eof()
			KEY_L:
				var last: Dictionary = _lines[_row]
				_lines = [last]
				_row = 0
			KEY_U:
				_input = _input.substr(_caret)
				_caret = 0
			KEY_A:
				_caret = 0
			KEY_E:
				_caret = _input.length()
			KEY_W:
				var cut := _input.substr(0, _caret).strip_edges(false, true)
				var idx := cut.rfind(" ")
				var start := idx + 1 if idx >= 0 else 0
				_input = _input.substr(0, start) + _input.substr(_caret)
				_caret = start
			KEY_V:
				_paste(DisplayServer.clipboard_get())
		queue_redraw()
		return
	match k.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			_submit()
		KEY_BACKSPACE:
			if _caret > 0:
				_input = _input.substr(0, _caret - 1) + _input.substr(_caret)
				_caret -= 1
		KEY_DELETE:
			_input = _input.substr(0, _caret) + _input.substr(_caret + 1)
		KEY_LEFT:
			_caret = maxi(0, _caret - 1)
		KEY_RIGHT:
			_caret = mini(_input.length(), _caret + 1)
		KEY_HOME:
			_caret = 0
		KEY_END:
			_caret = _input.length()
		KEY_UP:
			_history_step(1)
		KEY_DOWN:
			_history_step(-1)
		KEY_PAGEUP:
			_scroll = mini(_scroll + rows() - 1, maxi(0, _lines.size() - rows()))
		KEY_PAGEDOWN:
			_scroll = maxi(0, _scroll - rows() + 1)
		KEY_INSERT:
			if k.shift_pressed:
				_paste(DisplayServer.clipboard_get())
		_:
			if k.unicode >= 32:
				_insert(String.chr(k.unicode))
	queue_redraw()


func _insert(text: String) -> void:
	_input = _input.substr(0, _caret) + text + _input.substr(_caret)
	_caret += text.length()
	_scroll = 0


func _paste(text: String) -> void:
	var lines := text.replace("\r", "").split("\n")
	for i in lines.size():
		_insert(lines[i])
		if i < lines.size() - 1:
			_submit()


func _submit() -> void:
	var line := _input
	if tty.echo:
		feed(line + "\n")
	_reset_input()
	tty.type_line(line)


func _reset_input() -> void:
	_input = ""
	_caret = 0
	_hist_index = -1
	_scroll = 0


func _history_step(direction: int) -> void:
	if not tty.echo:
		return
	var hist := tty.history()
	if hist.is_empty():
		return
	if _hist_index == -1:
		_hist_saved = _input
	_hist_index = clampi(_hist_index + direction, -1, hist.size() - 1)
	_input = _hist_saved if _hist_index == -1 else hist[hist.size() - 1 - _hist_index]
	_caret = _input.length()


func _on_blink() -> void:
	_blink_on = not _blink_on
	queue_redraw()


# --- drawing ----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), background)
	var n_rows := rows()
	var first := maxi(0, _lines.size() - n_rows - _scroll)
	for i in n_rows:
		var li := first + i
		if li >= _lines.size():
			break
		_draw_line(_lines[li], i)
	if _scroll != 0:
		return
	# Pending input, drawn after the cursor position, wrapping like output.
	var c := cols()
	var screen_row := _row - first
	var shown := _input if tty == null or tty.echo else ""
	for i in shown.length():
		var pos := _col + i
		_draw_text(shown[i], screen_row + pos / c, pos % c, PALETTE[FG_DEFAULT])
	var caret_pos := _col + (_caret if not shown.is_empty() else 0)
	var cell_pos := _cell_origin(screen_row + caret_pos / c, caret_pos % c)
	var cursor_rect := Rect2(cell_pos, _cell)
	if has_focus() and _blink_on:
		draw_rect(cursor_rect, Color(PALETTE[FG_DEFAULT], 0.85))
		var under := shown[_caret] if _caret < shown.length() else ""
		if not under.is_empty():
			_draw_text(under, screen_row + caret_pos / c, caret_pos % c, background)
	elif not has_focus():
		draw_rect(cursor_rect, Color(PALETTE[FG_DEFAULT], 0.6), false, 1.0)


func _cell_origin(row: int, col: int) -> Vector2:
	return Vector2(PAD + col * _cell.x, PAD + row * _cell.y)


func _draw_text(text: String, row: int, col: int, color: Color) -> void:
	draw_string(font, _cell_origin(row, col) + Vector2(0, _ascent), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_line(line: Dictionary, row: int) -> void:
	var t: String = line.t
	var a: PackedInt32Array = line.a
	var start := 0
	while start < t.length():
		var attr := a[start]
		var end := start + 1
		while end < t.length() and a[end] == attr:
			end += 1
		var bg := (attr >> 8) & 255
		if bg != BG_DEFAULT:
			draw_rect(Rect2(_cell_origin(row, start), Vector2(_cell.x * (end - start), _cell.y)), PALETTE[bg])
		var fg := attr & 255
		if (attr >> 16) & 1 and fg < 8:
			fg += 8 # bold shows as the bright variant, like old terminals
		_draw_text(t.substr(start, end - start), row, start, PALETTE[fg])
		start = end
