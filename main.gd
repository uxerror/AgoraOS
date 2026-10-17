extends Control
## Demo front end: one PC with a monitor.
##
## The first start gives an empty PC with the AgoraOS install CD in the
## drive: the installer runs on the text console. Start with
## "-- --preinstalled" to get a ready desktop (user/user, root/root)
## instead. The whole PC, disks included, is saved when the window closes or
## the system powers off.

const IMAGE := "user://machines/local.agx"

var hardware: AgoraHardware
var view: AgoraDisplayView

## The running kernel, if any.
var machine: AgoraMachine:
	get:
		return hardware.machine if hardware else null


func _ready() -> void:
	get_window().min_size = Vector2i(800, 600)
	if FileAccess.file_exists(IMAGE):
		hardware = AgoraHardware.load_from(IMAGE)
	if hardware == null:
		hardware = AgoraHardware.from_template("pc")
		if OS.get_cmdline_user_args().has("--preinstalled"):
			AgoraInstaller.install_disk(hardware.disks[0], "agora", {
				"root_password": "root",
				"users": [{"name": "user", "password": "user", "groups": ["sudo"]}],
			}, hardware.clock)
		else:
			hardware.insert(AgoraMedia.installer(false, hardware.clock))
	# Systems saved by older versions get the packages they are missing.
	for disk in hardware.disks:
		if disk.is_formatted() and not disk.read_only:
			AgoraInstaller.upgrade_vfs(AgoraInstaller.target_vfs(disk, hardware.clock))
	view = AgoraDisplayView.new()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(view)
	view.attach(hardware.display, hardware.console)
	hardware.powered_off.connect(_on_powered_off)
	hardware.power_on()


## "poweroff" inside the OS closes the game window.
func _on_powered_off() -> void:
	_save()
	get_tree().quit()


func _save() -> void:
	DirAccess.make_dir_recursive_absolute(IMAGE.get_base_dir())
	hardware.save(IMAGE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and hardware:
		_save()
		hardware.power_off()
