extends Control
## Demo front end: a desk with the boxes of one world (worlds/home.json):
## a PC with a monitor and a home router cabled to it.
##
## The first start gives an empty PC with the AgoraOS install CD in the
## drive: the installer runs on the text console. Start with
## "-- --preinstalled" to get a ready desktop (user/user, root/root)
## instead. The router is ready (root/admin), reached through its serial
## console. The bar on top switches between the boxes like a KVM switch
## (Scroll Lock does the same) and has their power buttons. The whole world,
## disks included, is saved when the window closes.

const WORLD := "user://worlds/home.agw"
const SPEC := "res://worlds/home.json"
## Where versions before worlds kept the PC.
const OLD_IMAGE := "user://machines/local.agx"

var world: AgoraWorld

var _bar: HBoxContainer
var _screen: Control
## Box name -> its screen: an AgoraDisplayView, or an AgoraTermView on the
## serial port for a box without a monitor.
var _views := {}
var _buttons := {}
var _power_buttons := {}
var _current := ""


func _ready() -> void:
	get_window().min_size = Vector2i(800, 600)
	world = _load_world()
	if world == null:
		push_error("AgoraOS: cannot build the world: " + AgoraWorld.spec_error)
		return
	# Systems saved by older versions get the packages they are missing.
	for name in world.names():
		for disk in world.box(name).disks:
			if disk.is_formatted() and not disk.read_only:
				AgoraInstaller.upgrade_vfs(AgoraInstaller.target_vfs(disk, world.clock))
	_build_desk()
	for name in world.names():
		_add_box(name)
	world.start()
	# The first box with a monitor is the one in front of the player.
	var first := world.names()[0]
	for name in world.names():
		if world.box(name).display:
			first = name
			break
	_show(first)


func _load_world() -> AgoraWorld:
	if FileAccess.file_exists(WORLD):
		var saved := AgoraWorld.load_from(WORLD)
		if saved:
			return saved
	var spec: Variant = JSON.parse_string(FileAccess.get_file_as_string(SPEC))
	if not spec is Dictionary:
		AgoraWorld.spec_error = SPEC + ": not a JSON object"
		return null
	if OS.get_cmdline_user_args().has("--preinstalled"):
		var pc: Dictionary = spec.boxes.pc
		pc.erase("media")
		pc.install = {
			"hostname": "agora", "root_password": "root",
			"users": [{"name": "user", "password": "user", "groups": ["sudo"]}],
			"network": {"eth0": {"method": "dhcp"}},
		}
	var w := AgoraWorld.from_spec(spec)
	if w and FileAccess.file_exists(OLD_IMAGE):
		# Bring the PC of an older version over, disks and all.
		var old := AgoraHardware.load_from(OLD_IMAGE, w.clock)
		if old:
			old.add_display()
			w.replace("pc", old)
	return w


# --- the desk ------------------------------------------------------------------

func _build_desk() -> void:
	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 0)
	add_child(column)
	var bar_bg := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color8(28, 28, 32)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	bar_bg.add_theme_stylebox_override("panel", sb)
	column.add_child(bar_bg)
	_bar = HBoxContainer.new()
	bar_bg.add_child(_bar)
	_screen = Control.new()
	_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_screen.clip_contents = true
	column.add_child(_screen)


func _add_box(name: String) -> void:
	var hw := world.box(name)
	var view: Control
	if hw.display:
		var dv := AgoraDisplayView.new()
		dv.set_anchors_preset(Control.PRESET_FULL_RECT)
		_screen.add_child(dv)
		dv.attach(hw.display, hw.console)
		view = dv
	else:
		var tv := AgoraTermView.new()
		tv.background = Color.BLACK
		tv.set_anchors_preset(Control.PRESET_FULL_RECT)
		_screen.add_child(tv)
		if hw.serial:
			tv.attach(hw.serial)
		view = tv
	view.visible = false
	_views[name] = view
	var group: ButtonGroup = _buttons.values()[0].button_group if not _buttons.is_empty() else ButtonGroup.new()
	var b := Button.new()
	b.text = name if hw.display else name + " (serial)"
	b.toggle_mode = true
	b.button_group = group
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	b.add_theme_font_override("font", AgoraStyle.MONO)
	b.add_theme_font_size_override("font_size", 13)
	b.pressed.connect(_show.bind(name))
	_bar.add_child(b)
	_buttons[name] = b
	var power := Button.new()
	power.focus_mode = Control.FOCUS_NONE
	power.flat = true
	power.tooltip_text = "Power: switch on, or cut the power"
	power.add_theme_font_override("font", AgoraStyle.MONO)
	power.add_theme_font_size_override("font_size", 13)
	power.pressed.connect(_toggle_power.bind(name))
	_bar.add_child(power)
	_power_buttons[name] = power
	var spacer := Control.new()
	spacer.custom_minimum_size.x = 12
	_bar.add_child(spacer)
	hw.powered_on.connect(_update_power.bind(name))
	hw.powered_off.connect(_update_power.bind(name))
	_update_power(name)


func _show(name: String) -> void:
	if not _views.has(name):
		return
	_current = name
	for n: String in _views:
		(_views[n] as Control).visible = n == name
	_buttons[name].set_pressed_no_signal(true)
	var view: Control = _views[name]
	if view is AgoraDisplayView:
		var dv := view as AgoraDisplayView
		dv._on_focus_changed(dv.display.focused if dv.display else null)
	else:
		view.grab_focus.call_deferred()


func _toggle_power(name: String) -> void:
	var hw := world.box(name)
	if hw.power == AgoraHardware.Power.ON:
		hw.power_off()
	else:
		hw.power_on()
	_show(name)


func _update_power(name: String) -> void:
	var on := world.box(name).power == AgoraHardware.Power.ON
	var b: Button = _power_buttons[name]
	b.text = "[on]" if on else "[off]"
	b.add_theme_color_override("font_color", Color8(120, 220, 120) if on else Color8(150, 150, 150))


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.keycode == KEY_SCROLLLOCK:
		var names := world.names()
		_show(names[(names.find(_current) + 1) % names.size()])
		get_viewport().set_input_as_handled()


func _save() -> void:
	DirAccess.make_dir_recursive_absolute(WORLD.get_base_dir())
	world.save(WORLD)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and world:
		_save()
		world.stop()
