class_name NConsoleDebugger
extends PanelContainer
## The debugger panel of [NConsoleScreen]: registers and the code at PC on
## top, a [NCMonitor] command line below. F7 steps, F8 steps over a call,
## F9 continues or pauses.

## Called after anything that may have changed the picture.
signal picture_changed

var monitor: NCMonitor
var _view: Label
var _log: RichTextLabel
var _input: LineEdit


func _init(m: NCMonitor) -> void:
	monitor = m
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["DejaVu Sans Mono", "Liberation Mono", "Consolas", "Menlo", "monospace"])
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.07, 0.09, 0.94)
	bg.set_content_margin_all(8)
	add_theme_stylebox_override("panel", bg)
	var box := VBoxContainer.new()
	add_child(box)
	_view = Label.new()
	_view.add_theme_font_override("font", font)
	_view.add_theme_font_size_override("font_size", 13)
	_view.add_theme_color_override("font_color", Color(0.75, 0.95, 0.75))
	box.add_child(_view)
	box.add_child(HSeparator.new())
	_log = RichTextLabel.new()
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.add_theme_font_override("normal_font", font)
	_log.add_theme_font_size_override("normal_font_size", 13)
	box.add_child(_log)
	_input = LineEdit.new()
	_input.placeholder_text = "command (help)"
	_input.add_theme_font_override("font", font)
	_input.add_theme_font_size_override("font_size", 13)
	_input.text_submitted.connect(_on_command)
	box.add_child(_input)


func open() -> void:
	show()
	refresh()
	_input.grab_focus()


## True while the command line has the keyboard.
func is_typing() -> bool:
	return visible and _input.has_focus()


func refresh() -> void:
	if monitor.console.cartridge == null:
		_view.text = "no cartridge"
		return
	var state := "PAUSED" if monitor.console.paused else "running"
	_view.text = "%s\n%s\n\n%s" % [state, monitor.registers(), monitor.disassemble(monitor.console.cpu.pc, 12)]


func print_line(text: String) -> void:
	if not text.is_empty():
		_log.add_text(text + "\n")


func run(cmd: String) -> void:
	print_line("> " + cmd)
	print_line(monitor.command(cmd))
	refresh()
	picture_changed.emit()


## The console stopped by itself (a breakpoint or watch).
func stopped() -> void:
	if not visible:
		open()
	print_line(monitor.stop_message())
	refresh()
	picture_changed.emit()


func _on_command(text: String) -> void:
	_input.clear()
	if not text.strip_edges().is_empty():
		run(text)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if not visible or k == null or not k.pressed or k.echo:
		return
	match k.physical_keycode:
		KEY_F7:
			run("s")
		KEY_F8:
			run("n")
		KEY_F9:
			run("p" if not monitor.console.paused else "c")
		_:
			return
	get_viewport().set_input_as_handled()
