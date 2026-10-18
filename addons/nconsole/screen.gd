class_name NConsoleScreen
extends Control
## The console as a flat picture: an [NConsolePlayer] drawn into this
## control (see it for the keys). The picture fills the free area, the left
## half while the debugger is open.

## A .nc8 cartridge, or an .asm source to assemble on load.
@export_file("*.nc8", "*.asm") var cartridge_path := ""

var player := NConsolePlayer.new()
var console: NConsole:
	get:
		return player.console
var texture: ImageTexture:
	get:
		return player.texture
var monitor: NCMonitor:
	get:
		return player.monitor
var debugger: NConsoleDebugger:
	get:
		return player.debugger


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(player)
	add_child(player.stats)
	var d := player.debugger
	d.anchor_left = 0.5
	d.anchor_right = 1.0
	d.anchor_bottom = 1.0
	add_child(d)
	player.picture_updated.connect(queue_redraw)
	player.debugger_toggled.connect(func(_open: bool) -> void: queue_redraw())
	resized.connect(queue_redraw)
	if not cartridge_path.is_empty():
		player.load_cartridge(cartridge_path)


## Whole-number scales when they fit, so pixels stay square and sharp.
func _draw() -> void:
	var area := Rect2(Vector2.ZERO, size)
	if debugger.visible:
		area.size.x *= 0.5
	var scale := minf(area.size.x / NCVideo.WIDTH, area.size.y / NCVideo.HEIGHT)
	if scale >= 1.0:
		scale = floorf(scale)
	var picture := Vector2(NCVideo.WIDTH, NCVideo.HEIGHT) * scale
	draw_texture_rect(texture, Rect2(area.position + (area.size - picture) / 2.0, picture), false)
