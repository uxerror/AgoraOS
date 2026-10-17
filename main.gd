extends Control
## Demo front end: one machine with a monitor. Loads the saved machine (or
## installs a new one), attaches a display and boots it; init starts the
## login screen. The machine is saved when the window closes.
##
## Default accounts on a fresh install: user/user (sudo), root/root.

const IMAGE := "user://machines/local.agx"

var machine: AgoraMachine
var view: AgoraDisplayView


func _ready() -> void:
	get_window().min_size = Vector2i(800, 600)
	# Attach the screen before booting, so init's login screen service
	# finds /dev/fb0 and starts.
	if FileAccess.file_exists(IMAGE):
		machine = AgoraMachine.load_image(IMAGE, null, false)
	if machine == null:
		machine = AgoraMachine.create("agora", {
			"root_password": "root",
			"users": [{"name": "user", "password": "user", "groups": ["sudo"]}],
		}, null, false)
	AgoraInstaller.upgrade(machine)
	var display := machine.attach_display()
	view = AgoraDisplayView.new()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(view)
	view.attach(display)
	machine.powered_off.connect(_on_powered_off)
	machine.boot()


## "poweroff" inside the OS closes the game window.
func _on_powered_off() -> void:
	_save()
	get_tree().quit()


func _save() -> void:
	DirAccess.make_dir_recursive_absolute(IMAGE.get_base_dir())
	machine.save_image(IMAGE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and machine:
		_save()
		machine.shutdown()
