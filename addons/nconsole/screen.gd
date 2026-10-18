class_name NConsoleScreen
extends TextureRect
## Shows an [NConsole] and plays it with the keyboard: arrows or WASD,
## Z/J for A, X/K for B, Enter for start, Shift for select. F3 shows how
## busy the CPU and the emulator are, F5 resets.

## A .nc8 cartridge, or an .asm source to assemble on load.
@export_file("*.nc8", "*.asm") var cartridge_path := ""

var console := NConsole.new()
var _texture: ImageTexture
var _time := 0.0
var _stats: Label
var _frame_usec := 0

const KEYS := {
	NConsole.BTN_UP: [KEY_UP, KEY_W], NConsole.BTN_DOWN: [KEY_DOWN, KEY_S],
	NConsole.BTN_LEFT: [KEY_LEFT, KEY_A], NConsole.BTN_RIGHT: [KEY_RIGHT, KEY_D],
	NConsole.BTN_A: [KEY_Z, KEY_J], NConsole.BTN_B: [KEY_X, KEY_K],
	NConsole.BTN_START: [KEY_ENTER], NConsole.BTN_SELECT: [KEY_SHIFT],
}


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_texture = ImageTexture.create_from_image(console.video.image)
	texture = _texture
	_stats = Label.new()
	_stats.visible = false
	_stats.add_theme_color_override("font_color", Color.YELLOW)
	add_child(_stats)
	if not cartridge_path.is_empty():
		var cart := NCCartridge.load_file(cartridge_path)
		if cart:
			console.insert(cart)


func _process(delta: float) -> void:
	if console.cartridge == null:
		return
	var buttons := 0
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
	if ran:
		_texture.update(console.video.image)
		if _stats.visible:
			_stats.text = "CPU %d%%  emulation %.1f ms" % [console.last_cycles * 100 / NConsole.CYCLES_PER_FRAME, _frame_usec / 1000.0]


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo:
		match k.physical_keycode:
			KEY_F3:
				_stats.visible = not _stats.visible
				accept_event()
			KEY_F5:
				console.reset()
				accept_event()
