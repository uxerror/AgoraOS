extends Control
## Demo front end: one machine with a monitor. Loads the saved machine (or
## installs a new one), attaches a display and starts the login screen.
## The machine is saved when the window closes.
##
## Default accounts on a fresh install: user/user (sudo), root/root.

const IMAGE := "user://machines/local.agx"

var machine: AgoraMachine
var view: AgoraDisplayView


func _ready() -> void:
	get_window().min_size = Vector2i(800, 600)
	if FileAccess.file_exists(IMAGE):
		machine = AgoraMachine.load_image(IMAGE)
	if machine == null:
		machine = AgoraMachine.create("agora", {
			"root_password": "root",
			"users": [{"name": "user", "password": "user", "groups": ["sudo"]}],
		})
	AgoraInstaller.upgrade(machine)
	var display := machine.attach_display()
	view = AgoraDisplayView.new()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(view)
	view.attach(display)
	machine.spawn(PackedStringArray(["/bin/greeter"]), {
		"env": {"DISPLAY": display.name, "PATH": AgoraMachine.DEFAULT_PATH, "HOME": "/root"},
	})


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and machine:
		DirAccess.make_dir_recursive_absolute(IMAGE.get_base_dir())
		machine.save_image(IMAGE)
		machine.shutdown()
