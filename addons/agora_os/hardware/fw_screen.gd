class_name AgoraFwScreen
extends RefCounted
## The screen and keyboard of the firmware. Before a kernel runs, the BIOS
## and GRUB draw on the text console themselves (80x25, with colours) and
## read keys from it in raw mode, the way they would read the keyboard
## controller. Every wait gives up when [member alive] says the boot was
## abandoned (the power was cut).

const COLS := 80
const ROWS := 25
## Key names [method key] returns for escape sequences.
const SEQUENCES := {
	"\u001b[A": "up", "\u001b[B": "down", "\u001b[C": "right", "\u001b[D": "left",
	"\u001b[H": "home", "\u001b[F": "end", "\u001b[1~": "home", "\u001b[4~": "end",
	"\u001b[2~": "insert", "\u001b[3~": "delete", "\u001b[5~": "pageup", "\u001b[6~": "pagedown",
	"\u001bOP": "f1", "\u001bOQ": "f2", "\u001bOR": "f3", "\u001bOS": "f4",
	"\u001b[15~": "f5", "\u001b[17~": "f6", "\u001b[18~": "f7", "\u001b[19~": "f8",
	"\u001b[20~": "f9", "\u001b[21~": "f10", "\u001b[23~": "f11", "\u001b[24~": "f12",
}
## Poll interval while waiting for a key, in seconds.
const POLL := 0.03

var tty: AgoraTty
var alive: Callable
var _pending := ""
var _reading := false


func _init(p_tty: AgoraTty, p_alive: Callable) -> void:
	tty = p_tty
	alive = p_alive


## Takes the keyboard: raw mode, no echo, nothing typed before counts.
func begin() -> void:
	if not _reading:
		# Keys reach a terminal only while something reads it.
		tty.input.add_reader()
		_reading = true
	tty.raw = true
	tty.echo = false
	tty.input.read_available()
	_pending = ""
	write("\u001b[?25l")


## Gives the console back as the kernel expects it.
func end() -> void:
	write("\u001b[0m\u001b[?25h")
	tty.input.read_available()
	_pending = ""
	tty.raw = false
	tty.echo = true
	if _reading:
		tty.input.release_reader()
		_reading = false


func is_alive() -> bool:
	return alive.call()


func write(text: String) -> void:
	tty.output.write(text)


## Clears the screen to [param bg] (a colour number 0-7).
func clear(fg: int = 7, bg: int = 0) -> void:
	write("\u001b[0m" + sgr(fg, bg) + "\u001b[2J\u001b[H")
	if bg != 0:
		# The terminal paints a background only under characters.
		var blank := " ".repeat(COLS)
		var text := ""
		for r in ROWS:
			text += "\u001b[%d;1H%s" % [r + 1, blank]
		write(text + "\u001b[H")


## [param text] at [param row], [param col] (from 0) in the colours given.
## Foreground colours 8-15 are the bright ones.
func put(row: int, col: int, text: String, fg: int = 7, bg: int = 0) -> void:
	write("\u001b[%d;%dH%s%s" % [row + 1, col + 1, sgr(fg, bg), text])


## A row from [param col] to the right edge, filled with spaces.
func fill(row: int, col: int, width: int, fg: int, bg: int, text: String = "") -> void:
	put(row, col, text.rpad(width).left(width), fg, bg)


static func sgr(fg: int, bg: int) -> String:
	return "\u001b[0;%d;%dm" % [90 + fg - 8 if fg >= 8 else 30 + fg, 40 + bg % 8]


## A box drawn with single lines; [param double] for the BIOS's double ones.
func box(top: int, left: int, height: int, width: int, fg: int, bg: int, double: bool = false) -> void:
	var c := "╔═╗║╚╝" if double else "┌─┐│└┘"
	put(top, left, c[0] + c[1].repeat(width - 2) + c[2], fg, bg)
	for r in range(top + 1, top + height - 1):
		put(r, left, c[3] + " ".repeat(width - 2) + c[3], fg, bg)
	put(top + height - 1, left, c[4] + c[1].repeat(width - 2) + c[5], fg, bg)


## Moves the cursor (shown) to [param row], [param col].
func cursor(row: int, col: int) -> void:
	write("\u001b[%d;%dH\u001b[?25h" % [row + 1, col + 1])


func hide_cursor() -> void:
	write("\u001b[?25l")


## Waits for a key and returns its name: a character, "enter", "esc",
## "backspace", "tab", "up", "f12", "delete", ... Returns "" after
## [param timeout] seconds (never with a negative one), or when the boot
## was abandoned.
func key(timeout: float = -1.0) -> String:
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while true:
		if not is_alive():
			return ""
		_pending += tty.input.read_available()
		if not _pending.is_empty():
			return _take()
		if timeout >= 0.0 and Time.get_ticks_msec() >= deadline:
			return ""
		if tree == null:
			return ""
		await tree.create_timer(POLL).timeout
	return ""


## Waits [param seconds], returning the first key typed meanwhile (or "").
func pause(seconds: float) -> String:
	return await key(seconds)


func _take() -> String:
	var ch := _pending[0]
	if ch == "\u001b":
		for seq: String in SEQUENCES:
			if _pending.begins_with(seq):
				_pending = _pending.substr(seq.length())
				return SEQUENCES[seq]
		# An unknown sequence: drop it whole.
		var end := 1
		if _pending.length() > 1 and _pending[1] in ["[", "O"]:
			end = 2
			while end < _pending.length() and _pending.unicode_at(end) < 0x40:
				end += 1
			end = mini(end + 1, _pending.length())
			_pending = _pending.substr(end)
			return "?"
		_pending = _pending.substr(1)
		return "esc"
	_pending = _pending.substr(1)
	match ch:
		"\n", "\r": return "enter"
		"\t": return "tab"
		"\u007f", "\b": return "backspace"
	return ch


## A line editor in raw mode at the cursor: printable keys, backspace,
## delete, left/right, home/end. Returns the line on Enter, null on Esc (or
## when the boot was abandoned). [param mask] shows "*" for each character;
## [param max_length] limits it. [param on_tab] gets the text and returns
## the new one (completion).
func read_line(row: int, col: int, initial: String = "", mask: bool = false, max_length: int = 255, fg: int = 7, bg: int = 0, on_tab: Callable = Callable()) -> Variant:
	var text := initial
	var pos := text.length()
	var width := COLS - col - 1
	while true:
		var start := maxi(0, pos - width + 1)
		var shown := ("*".repeat(text.length()) if mask else text).substr(start, width)
		fill(row, col, width, fg, bg, shown)
		cursor(row, col + pos - start)
		var k: String = await key()
		if not is_alive():
			return null
		match k:
			"enter":
				hide_cursor()
				return text
			"esc":
				hide_cursor()
				return null
			"backspace":
				if pos > 0:
					text = text.substr(0, pos - 1) + text.substr(pos)
					pos -= 1
			"delete":
				text = text.substr(0, pos) + text.substr(pos + 1)
			"left":
				pos = maxi(0, pos - 1)
			"right":
				pos = mini(text.length(), pos + 1)
			"home", "\u0001":
				pos = 0
			"end", "\u0005":
				pos = text.length()
			"tab":
				if on_tab.is_valid():
					text = on_tab.call(text)
					pos = text.length()
			_:
				if k.length() == 1 and k.unicode_at(0) >= 32 and text.length() < max_length:
					text = text.substr(0, pos) + k + text.substr(pos)
					pos += 1
	return null


## A line typed where the cursor is, on a screen that scrolls (GRUB's
## command line): printable keys and backspace. Returns the line on Enter,
## null on Esc. [param on_tab] gets the text and returns the new one,
## printing what it likes (possible completions).
func type_line(on_tab: Callable = Callable()) -> Variant:
	var text := ""
	write("\u001b[?25h")
	while true:
		var k: String = await key()
		if not is_alive():
			return null
		match k:
			"enter":
				write("\n")
				return text
			"esc":
				return null
			"backspace":
				if not text.is_empty():
					text = text.substr(0, text.length() - 1)
					write("\b \b")
			"tab":
				if on_tab.is_valid():
					var done: String = on_tab.call(text)
					write(done.substr(text.length()) if done.begins_with(text) else "")
					text = done
			_:
				if k.length() == 1 and k.unicode_at(0) >= 32:
					text += k
					write(k)
	return null
