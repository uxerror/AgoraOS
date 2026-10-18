extends Node3D
## The 3D console on a table. Drag with the mouse to look around it, the
## wheel to come closer; the keyboard plays (see NConsolePlayer).

@onready var _pivot: Node3D = $Pivot
@onready var _camera: Camera3D = $Pivot/Camera3D
var _yaw := 0.0
var _pitch := -42.0
var _distance := 21.0


func _ready() -> void:
	($Sun as DirectionalLight3D).rotation_degrees = Vector3(-55.0, 35.0, 0.0)
	_apply()


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion and motion.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT):
		_yaw -= motion.relative.x * 0.3
		_pitch = clampf(_pitch - motion.relative.y * 0.3, -85.0, -5.0)
		_apply()
	var button := event as InputEventMouseButton
	if button and button.pressed:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(9.0, _distance - 1.0)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(40.0, _distance + 1.0)
		_apply()


func _apply() -> void:
	_pivot.rotation_degrees = Vector3(_pitch, _yaw, 0.0)
	_camera.position = Vector3(0.0, 0.0, _distance)
