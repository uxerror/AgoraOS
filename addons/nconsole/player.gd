class_name NConsolePlayer
extends Node
## Runs an [NConsole] in real time for a view of it (the flat
## [NConsoleScreen] or the 3D [NConsole3D]): 60 frames a second, the
## keyboard as controller 1, the sound through an AudioStreamGenerator,
## the picture in [member texture]. Keys: arrows or WASD, Z/J for A, X/K
## for B, Enter for start, Shift for select; F2 the debugger, F3 how busy
## the CPU and the emulator are, F5 reset.
##
## The view adds [member debugger] and [member stats] where it wants them.

## The picture changed.
signal picture_updated
## The debugger was opened or closed.
signal debugger_toggled(open: bool)

const KEYS := {
	NConsole.BTN_UP: [KEY_UP, KEY_W], NConsole.BTN_DOWN: [KEY_DOWN, KEY_S],
	NConsole.BTN_LEFT: [KEY_LEFT, KEY_A], NConsole.BTN_RIGHT: [KEY_RIGHT, KEY_D],
	NConsole.BTN_A: [KEY_Z, KEY_J], NConsole.BTN_B: [KEY_X, KEY_K],
	NConsole.BTN_START: [KEY_ENTER], NConsole.BTN_SELECT: [KEY_SHIFT],
}

var console := NConsole.new()
var texture := ImageTexture.create_from_image(console.video.image)
var monitor := NCMonitor.new(console)
var debugger := NConsoleDebugger.new(monitor)
var stats := Label.new()
## Microseconds the last frame took to emulate.
var frame_usec := 0
var _time := 0.0
var _audio: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _refresh_in := 0


func _init() -> void:
	debugger.hide()
	debugger.picture_changed.connect(_show_picture)
	stats.visible = false
	stats.add_theme_color_override("font_color", Color.YELLOW)


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = NConsole.SAMPLE_RATE
	gen.buffer_length = 0.1
	_audio = AudioStreamPlayer.new()
	_audio.stream = gen
	add_child(_audio)
	_audio.play()
	_playback = _audio.get_stream_playback()


func _exit_tree() -> void:
	# Stop the stream first, or its playback outlives the player.
	_playback = null
	if _audio:
		_audio.stop()
		_audio.stream = null


## Puts in a cartridge (.nc8, or .asm to assemble) and switches on.
func load_cartridge(path: String) -> bool:
	var cart := NCAssembler.load_cartridge(path)
	if cart == null:
		return false
	console.insert(cart)
	monitor.refresh_labels()
	_show_picture()
	return true


## The buttons held on the keyboard, as controller bits.
static func keyboard_buttons() -> int:
	var buttons := 0
	for bit: int in KEYS:
		for key: int in KEYS[bit]:
			if Input.is_physical_key_pressed(key):
				buttons |= bit
	return buttons


func toggle_debugger() -> void:
	if debugger.visible:
		debugger.hide()
	else:
		debugger.open()
	debugger_toggled.emit(debugger.visible)


func _show_picture() -> void:
	texture.update(console.video.image)
	picture_updated.emit()


func _process(delta: float) -> void:
	if console.cartridge == null:
		return
	if console.paused:
		_time = 0.0
		return
	console.set_pad(0, 0 if debugger.is_typing() else keyboard_buttons())
	_time = minf(_time + delta, 3.0 / NConsole.FPS) # don't try to catch up after a stall
	var ran := false
	while _time >= 1.0 / NConsole.FPS:
		_time -= 1.0 / NConsole.FPS
		var t := Time.get_ticks_usec()
		console.run_frame()
		frame_usec = Time.get_ticks_usec() - t
		ran = true
		if console.paused:
			if not debugger.visible:
				toggle_debugger()
			debugger.stopped()
			break
		if _playback and _playback.get_frames_available() >= console.sound.size():
			_playback.push_buffer(console.sound)
	if ran:
		_show_picture()
		_refresh_in -= 1
		if debugger.visible and _refresh_in <= 0:
			debugger.refresh()
			_refresh_in = 10
		if stats.visible:
			stats.text = "CPU %d%%  emulation %.1f ms" % [console.last_cycles * 100 / NConsole.CYCLES_PER_FRAME, frame_usec / 1000.0]


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.physical_keycode:
		KEY_F2:
			toggle_debugger()
		KEY_F3:
			stats.visible = not stats.visible
		KEY_F5:
			console.reset()
		_:
			return
	get_viewport().set_input_as_handled()
