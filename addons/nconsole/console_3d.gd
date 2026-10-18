class_name NConsole3D
extends Node3D
## The console as a 3D model: the game shows on its screen, the buttons,
## the d-pad and start/select move with the keyboard ([NConsolePlayer]
## has the keys), the power LED is lit while a cartridge is in, and the
## cartridge's label carries the game's title. F2 opens the debugger over
## the view.
##
## The model (assets/NConsole.glb) lies flat, Y up, its front toward +Z.
## The parts it needs by name: Display_Screen, Button_A, Button_B,
## DPad_Cross, Menu_Start, Menu_Select, Shell_PowerLED,
## Cartridge_LabelText, Cartridge_GRP.

## A .nc8 cartridge, or an .asm source to assemble on load.
@export_file("*.nc8", "*.asm") var cartridge_path := ""
## How bright the screen glows (1 is the picture as it is).
@export_range(0.0, 4.0) var screen_brightness := 1.0

const MODEL := preload("res://addons/nconsole/assets/NConsole.glb")
## How far a pressed button goes down, in model units.
const BUTTON_TRAVEL := 0.09
const PILL_TRAVEL := 0.05
## How far the d-pad tilts, in degrees.
const DPAD_TILT := 7.0

var player := NConsolePlayer.new()
var console: NConsole:
	get:
		return player.console
var model: Node3D
var screen: MeshInstance3D
## Each moving part: [node, its rest position, the button bit].
var _buttons: Array = []
var _dpad: Node3D
var _led: MeshInstance3D
var _led_material := StandardMaterial3D.new()
var _title: Label3D
var _shown_buttons := -1


func _ready() -> void:
	model = MODEL.instantiate()
	add_child(model)
	add_child(player)
	var layer := CanvasLayer.new()
	add_child(layer)
	layer.add_child(player.stats)
	var d := player.debugger
	d.anchor_left = 0.5
	d.anchor_right = 1.0
	d.anchor_bottom = 1.0
	layer.add_child(d)

	screen = _part("Display_Screen") as MeshInstance3D
	if screen:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED # it gives light, not takes it
		mat.albedo_texture = player.texture
		mat.albedo_color = Color(screen_brightness, screen_brightness, screen_brightness)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		screen.set_surface_override_material(0, mat)
	for pair: Array in [["Button_A", NConsole.BTN_A, BUTTON_TRAVEL], ["Button_B", NConsole.BTN_B, BUTTON_TRAVEL],
			["Menu_Start", NConsole.BTN_START, PILL_TRAVEL], ["Menu_Select", NConsole.BTN_SELECT, PILL_TRAVEL]]:
		var node := _part(pair[0])
		if node:
			_buttons.append([node, node.position, pair[1], pair[2]])
	_dpad = _part("DPad_Cross")
	_led = _part("Shell_PowerLED") as MeshInstance3D
	if _led:
		_led_material.albedo_color = Color(0.05, 0.25, 0.08)
		_led_material.emission = Color(0.2, 1.0, 0.3)
		_led.set_surface_override_material(0, _led_material)
	# The game's title on the cartridge label, over the model's placeholder.
	var placeholder := _part("Cartridge_LabelText")
	var cart_group := _part("Cartridge_GRP")
	if placeholder and cart_group:
		placeholder.hide()
		_title = Label3D.new()
		_title.position = placeholder.position + Vector3(0, 0.002, 0)
		_title.rotation_degrees.x = -90.0 # lying on the label, read from the front
		_title.pixel_size = 0.006
		_title.font_size = 48
		_title.modulate = Color(0.12, 0.12, 0.14)
		_title.outline_size = 0
		_title.double_sided = false
		placeholder.get_parent().add_child(_title)
	if not cartridge_path.is_empty():
		insert(cartridge_path)
	_update_parts()


## Puts in a cartridge and switches on.
func insert(path: String) -> bool:
	if not player.load_cartridge(path):
		return false
	if _title:
		_title.text = console.cartridge.title.to_upper()
	_update_parts()
	return true


func _part(part_name: String) -> Node3D:
	var node := model.find_child(part_name, true, false) as Node3D
	if node == null:
		push_warning("NConsole3D: the model has no part named " + part_name)
	return node


func _process(_delta: float) -> void:
	_update_parts()


func _update_parts() -> void:
	var held := int(console.pads[0])
	_led_material.emission_enabled = console.cartridge != null
	if held == _shown_buttons:
		return
	_shown_buttons = held
	for b: Array in _buttons:
		var node: Node3D = b[0]
		node.position = b[1] - Vector3(0, b[3], 0) if held & int(b[2]) else b[1]
	if _dpad:
		# Tilt toward the pressed arm: up is the far side (-Z), right is +X.
		var tilt := Vector3.ZERO
		if held & NConsole.BTN_UP:
			tilt.x -= DPAD_TILT
		if held & NConsole.BTN_DOWN:
			tilt.x += DPAD_TILT
		if held & NConsole.BTN_RIGHT:
			tilt.z -= DPAD_TILT
		if held & NConsole.BTN_LEFT:
			tilt.z += DPAD_TILT
		_dpad.rotation_degrees = tilt
