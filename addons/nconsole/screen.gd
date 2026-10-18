class_name NConsoleScreen
extends Control
## Shows an [NConsole] and plays it with the keyboard: arrows or WASD,
## Z/J for A, X/K for B, Enter for start, Shift for select. F3 shows how
## busy the CPU and the emulator are, F5 resets, F2 opens the debugger
## ([NConsoleDebugger]): F7 step, F8 step over, F9 continue or pause.

## A .nc8 cartridge, or an .asm source to assemble on load.
@export_file("*.nc8", "*.asm") var cartridge_path := ""

var console := NConsole.new()
## The picture, updated after each frame.
var texture: ImageTexture
var _texture: ImageTexture
var _time := 0.0
var _stats: Label
var _frame_usec := 0
var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var monitor: NCMonitor
var debugger: NConsoleDebugger
var _refresh_in := 0

const KEYS := {
	NConsole.BTN_UP: [KEY_UP, KEY_W], NConsole.BTN_DOWN: [KEY_DOWN, KEY_S],
	NConsole.BTN_LEFT: [KEY_LEFT, KEY_A], NConsole.BTN_RIGHT: [KEY_RIGHT, KEY_D],
	NConsole.BTN_A: [KEY_Z, KEY_J], NConsole.BTN_B: [KEY_X, KEY_K],
	NConsole.BTN_START: [KEY_ENTER], NConsole.BTN_SELECT: [KEY_SHIFT],
}


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_texture = ImageTexture.create_from_image(console.video.image)
	texture = _texture
	_stats = Label.new()
	_stats.visible = false
	_stats.add_theme_color_override("font_color", Color.YELLOW)
	add_child(_stats)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = NConsole.SAMPLE_RATE
	gen.buffer_length = 0.1
	_player = AudioStreamPlayer.new()
	_player.stream = gen
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback()
	if not cartridge_path.is_empty():
		var cart := NCCartridge.load_file(cartridge_path)
		if cart:
			console.insert(cart)
	monitor = NCMonitor.new(console)
	debugger = NConsoleDebugger.new(monitor)
	debugger.anchor_left = 0.5
	debugger.anchor_right = 1.0
	debugger.anchor_bottom = 1.0
	debugger.hide()
	debugger.picture_changed.connect(_show_picture)
	add_child(debugger)
	resized.connect(queue_redraw)


func _toggle_debugger() -> void:
	if debugger.visible:
		debugger.hide()
	else:
		debugger.open()
	queue_redraw()


func _show_picture() -> void:
	_texture.update(console.video.image)
	queue_redraw()


## The picture fills the free area (the left half while the debugger is
## open), keeping its shape; whole-number scales when they fit, so pixels
## stay square and sharp.
func _draw() -> void:
	var area := Rect2(Vector2.ZERO, size)
	if debugger and debugger.visible:
		area.size.x *= 0.5
	var scale := minf(area.size.x / NCVideo.WIDTH, area.size.y / NCVideo.HEIGHT)
	if scale >= 1.0:
		scale = floorf(scale)
	var picture := Vector2(NCVideo.WIDTH, NCVideo.HEIGHT) * scale
	draw_texture_rect(_texture, Rect2(area.position + (area.size - picture) / 2.0, picture), false)


func _process(delta: float) -> void:
	if console.cartridge == null:
		return
	if console.paused:
		_time = 0.0
		return
	var buttons := 0
	if not debugger.is_typing():
		for bit: int in KEYS:
			for key: int in KEYS[bit]:
				if Input.is_physical_key_pressed(key):
					buttons |= bit
	console.pads[0] = buttons
	_time = minf(_time + delta, 3.0 / NConsole.FPS) # don't try to catch up after a stall
	var ran := false
	while _time >= 1.0 / NConsole.FPS:
		_time -= 1.0 / NConsole.FPS
		var t := Time.get_ticks_usec()
		console.run_frame()
		_frame_usec = Time.get_ticks_usec() - t
		ran = true
		if console.paused:
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
		if _stats.visible:
			_stats.text = "CPU %d%%  emulation %.1f ms" % [console.last_cycles * 100 / NConsole.CYCLES_PER_FRAME, _frame_usec / 1000.0]


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo:
		match k.physical_keycode:
			KEY_F2:
				_toggle_debugger()
				accept_event()
			KEY_F3:
				_stats.visible = not _stats.visible
				accept_event()
			KEY_F5:
				console.reset()
				accept_event()
