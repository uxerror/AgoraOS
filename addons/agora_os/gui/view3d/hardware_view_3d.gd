class_name AgoraHardwareView3D
extends Control
## A box seen in 3D: the model of the hardware on a desk, turned with the
## mouse (drag to turn, wheel to come closer), live and usable. Its lights
## follow the machine (power, link, speed, traffic, disk activity), the
## monitor shows the machine's real screen, and the parts answer clicks:
## power, reset and eject buttons, the CD tray, cables in their ports
## (pulled out and plugged back), the power cord, the case's side panel,
## media lying on the desk. Clicking the monitor's screen sits down at the
## computer: the mouse and keys go to the machine until the right button
## (or "Stand up") gets up again.
##
## The models are .glb files in [member model_dir] with named nodes: ports
## named like the NICs (eth0, WAN, LAN1, port3...), led_* lights with a
## material each, btn_* buttons, cd_tray with a cd_disc point, screen,
## side_panel, power_in, label, mount points for parts inside.
##
## [codeblock]
## var v := AgoraHardwareView3D.new()
## add_child(v)
## v.show_box(world.box("pc"), {"world": world, "name": "pc", "screen": display_view})
## [/codeblock]

signal closed
## The text under the mouse changed (a part and its state).
signal info_changed(text: String)

const LED_ON := {
	"power": Color("#4cff4c"), "link": Color("#4cff4c"), "act": Color("#ffb020"), "speed": Color("#ffb020"),
	"hdd": Color("#ffb020"), "cd": Color("#ffb020"), "fdd": Color("#4cff4c"), "fault": Color("#ff6020"),
	"psu": Color("#4cff4c"), "wlan": Color("#4cff4c"), "kbd": Color("#4cff4c"),
}
## How each kind of box is put on the desk: the models, where they stand
## (metres, facing -Z, the viewer's side), and the desk.
const LAYOUTS := {
	"pc": {"main": "pc_2400", "at": Vector3(-0.42, 0, 0.05), "desk": Vector3(1.5, 0.03, 0.8), "desk_at": Vector3(-0.15, 0, 0.0),
		"extra": [["monitor", "crt_17", Vector3(0.08, 0, 0.05)], ["keyboard", "keyboard", Vector3(0.08, 0, -0.32)], ["mouse", "mouse", Vector3(-0.22, 0, -0.33)]],
		"cord": "iec"},
	"server": {"main": "server_r1", "at": Vector3(0, 0, 0), "desk": Vector3(0.9, 0.03, 1.0), "desk_at": Vector3(0, 0, 0), "extra": [], "cord": "iec"},
	"router": {"main": "router_wr54", "at": Vector3(0, 0, 0), "desk": Vector3(0.6, 0.03, 0.5), "desk_at": Vector3(0, 0, 0.05), "extra": [], "cord": "dc"},
	"switch": {"main": "switch_fs108", "at": Vector3(0, 0, 0), "desk": Vector3(0.5, 0.03, 0.4), "desk_at": Vector3(0, 0, 0.05), "extra": [], "cord": "dc"},
}
const CABLE_RADIUS := 0.0028
const HOLD_SECONDS := 1.5
const REFRESH := 0.05

## Where the .glb models are.
var model_dir := "res://assets"
var hw: AgoraHardware
var world: AgoraWorld
var box_name := ""
## Media lying on the desk (AgoraDisk): CDs in their sleeves, USB sticks.
var shelf: Array = []
var monitor_on := true
var plugged := true
var tray_open := false
var panel_open := false
## The CD lying on the open tray, if any.
var tray_disc: AgoraDisk
var in_screen := false

var _container := SubViewportContainer.new()
var _vp := SubViewport.new()
var _world_root := Node3D.new()
var _cam := Camera3D.new()
var _info := Label.new()
var _toolbar := HBoxContainer.new()
var _stand := Button.new()
var _devices := {} # role -> Node3D
var _parts := {} # id -> {node, aabb, kind, role, ...}
var _blockers: Array = [] # [node, aabb]
var _leds: Array = [] # {name, role, mat}
var _activity := {} # key -> [last count, busy until msec]
var _screen_vp: SubViewport
var _screen_ctl: Control
var _screen_mat: StandardMaterial3D
var _loose := {} # nic name -> {peer, length, defects}
var _dynamic: Array[Node] = [] # cables, plugs, discs: rebuilt as things change
var _yaw := deg_to_rad(-30.0)
var _pitch := deg_to_rad(-18.0)
var _dist := 1.0
var _focus := Vector3.ZERO
var _dragging := false
var _press_part := ""
var _press_time := 0
var _press_pos := Vector2.ZERO
var _since := 0.0
var _hover := ""
var _cam_tween: Tween
var _cached_scenes := {}
## The desk top seen from above (x, z).
var _desk := Rect2()


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_container)
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.handle_input_locally = false
	_container.add_child(_vp)
	_vp.add_child(_world_root)
	_world_root.add_child(_cam)
	_cam.fov = 40.0
	_cam.near = 0.01
	_build_overlay()


func _build_overlay() -> void:
	_toolbar.position = Vector2(8, 8)
	add_child(_toolbar)
	for pair in [["Front", "front"], ["Back", "back"], ["Left", "left"], ["Right", "right"], ["Top", "top"]]:
		var b := Button.new()
		b.text = pair[0]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(view_from.bind(pair[1]))
		_toolbar.add_child(b)
	_stand.text = "Stand up"
	_stand.focus_mode = Control.FOCUS_NONE
	_stand.visible = false
	_stand.pressed.connect(leave_screen)
	_toolbar.add_child(_stand)
	var close := Button.new()
	close.text = "Close"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func() -> void: closed.emit())
	_toolbar.add_child(close)
	_info.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_info.offset_top = -30
	_info.offset_left = 10
	_info.add_theme_color_override("font_color", Color("#e8e8e8"))
	_info.add_theme_color_override("font_shadow_color", Color.BLACK)
	_info.add_theme_constant_override("shadow_offset_x", 1)
	_info.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_info)


# --- building the scene --------------------------------------------------------

## Shows [param box]. [param opts]: world (AgoraWorld, for cables by name),
## name (the box's name in it), screen (a Control to show on the monitor,
## usually its AgoraDisplayView; give it back with [method release_screen]),
## shelf (media lying on the desk).
func show_box(box: AgoraHardware, opts: Dictionary = {}) -> bool:
	_clear()
	hw = box
	world = opts.get("world")
	box_name = opts.get("name", "")
	shelf = opts.get("shelf", [])
	plugged = hw.mains
	tray_open = false
	panel_open = false
	tray_disc = null
	var layout: Dictionary = LAYOUTS.get(hw.template, {})
	if layout.is_empty():
		_say("No model for a %s %s." % [hw.vendor, hw.model])
		return false
	_build_room(layout)
	var main := _place("main", str(layout.main), layout.at)
	if main == null:
		return false
	for e: Array in layout.extra:
		_place(e[0], e[1], e[2])
	_fit_parts()
	_index_parts()
	_place_cmos_parts()
	_make_labels()
	if opts.has("screen") and _devices.has("monitor"):
		attach_screen(opts.screen)
	_rebuild_dynamic()
	var box_aabb := _aabb_of(main)
	_focus = box_aabb.get_center()
	_dist = clampf(box_aabb.size.length() * 1.9, 0.35, 3.0)
	_update_camera()
	hw.powered_on.connect(_refresh_soon)
	hw.powered_off.connect(_refresh_soon)
	_update_leds()
	return true


func _refresh_soon() -> void:
	_since = REFRESH


func _clear() -> void:
	if hw:
		for sig: Signal in [hw.powered_on, hw.powered_off]:
			if sig.is_connected(_refresh_soon):
				sig.disconnect(_refresh_soon)
	release_screen()
	for c in _world_root.get_children():
		if c != _cam:
			c.queue_free()
	_devices.clear()
	_parts.clear()
	_blockers.clear()
	_leds.clear()
	_activity.clear()
	_loose.clear()
	_dynamic.clear()
	in_screen = false
	_stand.visible = false
	_hover = ""
	_say("")


func _build_room(layout: Dictionary) -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("#23272e")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.64, 0.7)
	e.ambient_light_energy = 0.35
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# (No glow: with the Compatibility renderer it washes the whole picture out.)
	env.environment = e
	_world_root.add_child(env)
	_cam.environment = e
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, 160, 0)
	key.light_energy = 0.75
	key.shadow_enabled = true
	_world_root.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -30, 0)
	fill.light_energy = 0.25
	_world_root.add_child(fill)
	var desk := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = layout.desk
	desk.mesh = bm
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color("#6b5640")
	dm.roughness = 0.8
	desk.material_override = dm
	desk.position = (layout.desk_at as Vector3) + Vector3(0, -(layout.desk as Vector3).y / 2.0, 0)
	_world_root.add_child(desk)
	var half := (layout.desk as Vector3) / 2.0
	_desk = Rect2(Vector2(desk.position.x - half.x, desk.position.z - half.z), Vector2(half.x, half.z) * 2.0)


func _scene(model: String) -> PackedScene:
	if not _cached_scenes.has(model):
		var path := "%s/%s.glb" % [model_dir, model]
		_cached_scenes[model] = load(path) if ResourceLoader.exists(path) else null
	return _cached_scenes[model]


func _instance(model: String) -> Node3D:
	var scene := _scene(model)
	if scene == null:
		push_warning("AgoraHardwareView3D: no model %s/%s.glb" % [model_dir, model])
		return null
	return scene.instantiate() as Node3D


func _place(role: String, model: String, at: Vector3) -> Node3D:
	var n := _instance(model)
	if n == null:
		return null
	n.position = at
	_world_root.add_child(n)
	_devices[role] = n
	return n


## The parts inside that depend on the machine: network cards in PCI
## slots, memory modules.
func _fit_parts() -> void:
	var main: Node3D = _devices.main
	var slot := 2
	for nic in hw.nics:
		if nic.driver in ["e100", "e1000"] and _find(main, nic.name) == null:
			var holder := _find(main, "pci%d" % slot)
			var card := _instance("card_" + nic.driver)
			if holder and card:
				card.name = "card_" + nic.name
				holder.add_child(card)
				var cover := _find(main, "slot_cover%d" % slot)
				if cover:
					cover.visible = false
				slot += 1
	# Memory: 256 MB a module. The model may come with modules in place.
	var sticks := clampi(int(ceil(hw.ram_mb / 256.0)), 1, 4)
	for k in 4:
		var holder := _find(main, "ram%d" % k)
		if holder == null:
			continue
		if holder.get_child_count() > 0:
			for c in holder.get_children():
				(c as Node3D).visible = k < sticks
		elif k < sticks:
			var stick := _instance("ram_dimm")
			if stick:
				holder.add_child(stick)


## Takes [param node] out of its model so it can go elsewhere.
static func _detach(node: Node) -> void:
	for n in [node] + node.find_children("*", "", true, false):
		n.owner = null
	node.get_parent().remove_child(node)


## Finds the first node called [param name] below [param under].
static func _find(under: Node, name: String) -> Node3D:
	if under.name == name and under is Node3D:
		return under
	for c in under.get_children():
		var f := _find(c, name)
		if f:
			return f
	return null


## [param node]'s transform relative to the scene, without needing the tree.
func _xform(node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p and p != _world_root:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


func _aabb_of(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in [node] + node.find_children("*", "MeshInstance3D", true, false):
		if mi is MeshInstance3D and (mi as MeshInstance3D).mesh:
			var b := _xform(mi) * (mi as MeshInstance3D).mesh.get_aabb()
			out = b if first else out.merge(b)
			first = false
	return out


## The local box of a part: its mesh, or a small box around a point.
static func _local_box(node: Node3D, size: Vector3) -> AABB:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		return (node as MeshInstance3D).mesh.get_aabb().grow(0.002)
	return AABB(-size / 2.0, size)


func _add_part(id: String, node: Node3D, kind: String, role: String, extra: Dictionary = {}, size: Vector3 = Vector3(0.016, 0.014, 0.012)) -> void:
	var part := {"node": node, "aabb": _local_box(node, size), "kind": kind, "role": role}
	part.merge(extra, true)
	_parts[id] = part


func _index_parts() -> void:
	for role: String in _devices:
		var dev: Node3D = _devices[role]
		var prefix := "" if role == "main" else role + ":"
		for n in [dev] + dev.find_children("*", "", true, false):
			if not n is Node3D:
				continue
			var name := str(n.name)
			if name == "body" or name.ends_with("_body"):
				_blockers.append([n, (n as MeshInstance3D).mesh.get_aabb() if n is MeshInstance3D and (n as MeshInstance3D).mesh else AABB()])
			if name.begins_with("led_") and n is MeshInstance3D:
				var mi := n as MeshInstance3D
				var mat := StandardMaterial3D.new()
				mat.emission_enabled = true
				mi.material_override = mat
				_leds.append({"name": name, "role": role, "mat": mat, "node": mi})
			elif name.begins_with("btn_") and n is MeshInstance3D and role in ["main", "monitor"]:
				_add_part(prefix + name, n, "button", role)
			elif name == "cd_tray":
				_add_part(prefix + name, n, "tray", role)
			elif name == "side_panel":
				_add_part(prefix + name, n, "panel", role, {"home": (n as Node3D).position})
			elif name == "screen" and role == "monitor":
				_add_part("screen", n, "screen", role)
			elif name in ["jumper_clear_cmos", "cmos_battery"] and role == "main":
				_add_part(name, n, "jumper" if name == "jumper_clear_cmos" else "battery", role, {"home": (n as Node3D).position})
			elif name == "power_in" and role == "main":
				_add_part("power_in", n, "power", role, {}, Vector3(0.03, 0.025, 0.02))
			elif role == "main" and hw.nic(name) != null:
				_add_part(name, n, "port", role)
	# Ports printed by label (WAN, LAN1...) on the router.
	for nic in hw.nics:
		if not _parts.has(nic.name) and not nic.label.is_empty():
			var n := _find(_devices.main, nic.label)
			if n:
				_add_part(nic.name, n, "port", "main")


# --- labels --------------------------------------------------------------------

func _make_labels() -> void:
	var main: Node3D = _devices.main
	var label := _find(main, "label")
	if label is MeshInstance3D:
		var lines: PackedStringArray = [hw.vendor, hw.model, "S/N %s" % _serial()]
		for nic in hw.nics:
			if nic.driver != "switch":
				lines.append("%s %s" % [nic.label if not nic.label.is_empty() else nic.name, nic.mac.to_upper()])
		if hw.template == "switch":
			lines.append("10/100 Mbps  8 ports")
		_label_texture(label as MeshInstance3D, "\n".join(lines))


func _serial() -> String:
	var seed := hw.model + (hw.nics[0].mac if not hw.nics.is_empty() else "")
	return "%s%06d" % [hw.model.left(2).to_upper(), absi(seed.hash()) % 1000000]


func _label_texture(mesh: MeshInstance3D, text: String) -> void:
	var lvp := SubViewport.new()
	lvp.size = Vector2i(512, 256)
	lvp.render_target_update_mode = SubViewport.UPDATE_ONCE
	lvp.transparent_bg = false
	var bg := ColorRect.new()
	bg.color = Color("#f2efe6")
	bg.size = Vector2(512, 256)
	lvp.add_child(bg)
	var l := Label.new()
	l.text = text
	l.position = Vector2(16, 12)
	l.add_theme_font_override("font", AgoraStyle.MONO)
	l.add_theme_font_size_override("font_size", 26)
	l.add_theme_color_override("font_color", Color("#1a1a1a"))
	lvp.add_child(l)
	mesh.add_child(lvp)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = lvp.get_texture()
	mat.roughness = 0.9
	mesh.material_override = mat


# --- the screen ----------------------------------------------------------------

## Shows [param ctl] on the monitor (it is moved into the view).
func attach_screen(ctl: Control) -> void:
	release_screen()
	if not _devices.has("monitor") or ctl == null:
		return
	var mesh := _find(_devices.monitor, "screen") as MeshInstance3D
	if mesh == null:
		return
	_screen_vp = SubViewport.new()
	_screen_vp.size = Vector2i(1024, 768)
	_screen_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_screen_vp.handle_input_locally = true
	mesh.add_child(_screen_vp)
	_screen_ctl = ctl
	if ctl.get_parent():
		ctl.get_parent().remove_child(ctl)
	_screen_vp.add_child(ctl)
	ctl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ctl.visible = true
	_screen_mat = StandardMaterial3D.new()
	_screen_mat.albedo_texture = _screen_vp.get_texture()
	# The tube gives its own light; and the mesh may face either way.
	_screen_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_screen_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material_override = _screen_mat


## Takes the screen's Control out of the view and returns it (or null).
func release_screen() -> Control:
	var ctl := _screen_ctl
	if ctl and is_instance_valid(ctl) and ctl.get_parent() == _screen_vp:
		_screen_vp.remove_child(ctl)
	if _screen_vp and is_instance_valid(_screen_vp):
		_screen_vp.queue_free()
	_screen_vp = null
	_screen_ctl = null
	return ctl


func _screen_lit() -> bool:
	return monitor_on and hw.power == AgoraHardware.Power.ON


# --- cables, cords, discs ------------------------------------------------------

func _rebuild_dynamic() -> void:
	for n in _dynamic:
		if is_instance_valid(n):
			n.queue_free()
	_dynamic.clear()
	for id: String in _parts.keys():
		if _parts[id].kind in ["plug", "disc", "media", "cord"]:
			_parts.erase(id)
	var main: Node3D = _devices.main
	var center := _aabb_of(main).get_center()
	for nic in hw.nics:
		if not _parts.has(nic.name):
			continue
		var port: Node3D = _parts[nic.name].node
		var out := _outward(port, center)
		if nic.cable:
			var variant := "ok"
			for d: String in nic.cable.defects:
				variant = d
			_plug(nic.name, "cable_rj45_plug_" + variant, port, out, true)
		elif _loose.has(nic.name):
			_plug(nic.name, "cable_rj45_plug_" + str(_loose[nic.name].variant), port, out, false)
	_power_cord(center)
	_discs()


## Which way is out of the box at [param port]: along the axis it sits
## furthest out on.
func _outward(port: Node3D, center: Vector3) -> Vector3:
	var p := _xform(port).origin - center
	var size := _aabb_of(_devices.main).size / 2.0
	var ax := absf(p.x) / maxf(size.x, 0.001)
	var az := absf(p.z) / maxf(size.z, 0.001)
	return Vector3(signf(p.x), 0, 0) if ax > az else Vector3(0, 0, signf(p.z) if p.z != 0 else 1.0)


func _plug(id: String, model: String, port: Node3D, out: Vector3, inserted: bool) -> void:
	var plug := _instance(model)
	if plug == null:
		plug = _instance("cable_rj45_plug_ok")
	if plug == null:
		return
	var at := _xform(port).origin
	var basis := Basis.looking_at(-out, Vector3.UP)
	if inserted:
		plug.transform = Transform3D(basis, at - out * 0.012)
	else:
		# Pulled out: lying on the desk in front of the port.
		plug.transform = Transform3D(basis, Vector3(at.x, 0.006, at.z) + out * 0.07)
	_world_root.add_child(plug)
	_dynamic.append(plug)
	_add_part("plug:" + id, plug, "plug", "main", {"nic": id}, Vector3.ZERO)
	_parts["plug:" + id].aabb = _aabb_local(plug).grow(0.002)
	var tail := _find(plug, "cable")
	var start := (plug.transform * tail.position) if tail else plug.transform.origin + out * 0.028
	var points := PackedVector3Array([start, start + out * 0.08, Vector3(start.x, 0.004, start.z) + out * 0.2, Vector3(start.x, 0.004, start.z) + out * 0.6])
	_tube(points, Color("#9aa3ad") if inserted else Color("#808890"))


## The box of [param node] and its meshes in its own coordinates.
func _aabb_local(node: Node3D) -> AABB:
	var inv := node.transform.affine_inverse()
	var world_box := _aabb_of(node)
	# Good enough for picking: the scene box brought back.
	return inv * world_box


func _tube(points: PackedVector3Array, color: Color) -> void:
	# What goes past the edge of the desk hangs down to the floor.
	var last := points[points.size() - 1]
	if not _desk.has_point(Vector2(last.x, last.z)):
		var prev := points[points.size() - 2]
		var dir := (last - prev).normalized()
		var edge := prev
		while _desk.has_point(Vector2(edge.x, edge.z)):
			edge += dir * 0.02
		points[points.size() - 1] = edge + dir * 0.03
		points.append(edge + dir * 0.06 + Vector3(0, -0.12, 0))
		points.append(edge + dir * 0.08 + Vector3(0, -0.7, 0))
	var curve := Curve3D.new()
	for k in points.size():
		var p := points[k]
		var handle := Vector3.ZERO
		if k > 0 and k < points.size() - 1:
			handle = (points[k + 1] - points[k - 1]) * 0.25
		curve.add_point(p, -handle, handle)
	curve.bake_interval = 0.01
	var baked := curve.get_baked_points()
	if baked.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring := 8
	var prev_up := Vector3.UP
	for k in baked.size():
		var dir := (baked[mini(k + 1, baked.size() - 1)] - baked[maxi(k - 1, 0)]).normalized()
		var side := dir.cross(prev_up)
		if side.length() < 0.01:
			side = dir.cross(Vector3.RIGHT)
		side = side.normalized()
		var up := side.cross(dir).normalized()
		prev_up = up
		for r in ring:
			var a := TAU * r / ring
			var n := (side * cos(a) + up * sin(a))
			st.set_normal(n)
			st.add_vertex(baked[k] + n * CABLE_RADIUS)
	for k in baked.size() - 1:
		for r in ring:
			var a := k * ring + r
			var b := k * ring + (r + 1) % ring
			var c := (k + 1) * ring + r
			var d := (k + 1) * ring + (r + 1) % ring
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)
			st.add_index(b)
			st.add_index(c)
			st.add_index(d)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.6
	mi.material_override = mat
	_world_root.add_child(mi)
	_dynamic.append(mi)


func _power_cord(center: Vector3) -> void:
	if not _parts.has("power_in"):
		return
	var port: Node3D = _parts.power_in.node
	var out := _outward(port, center)
	var at := _xform(port).origin
	var kind := str(LAYOUTS[hw.template].cord)
	var model := _instance("power_cord" if kind == "iec" else "power_adapter")
	if model == null:
		return
	var end_name := "end_iec" if kind == "iec" else "end_dc"
	var end := _find(model, end_name)
	if end == null:
		model.free()
		return
	# Only the end that goes in the box, plus the brick for an adapter.
	var holder := Node3D.new()
	_world_root.add_child(holder)
	_dynamic.append(holder)
	var end_x := end.position.x
	_detach(end)
	holder.add_child(end)
	# Some ends carry their place in the model twice: once on the end, once
	# on its mesh. Put the mesh back on the end.
	for c in end.get_children():
		if c is MeshInstance3D and absf((c as Node3D).position.x - end_x) < 0.001 and absf(end_x) > 0.001:
			(c as Node3D).position.x = 0.0
	var basis := Basis.looking_at(-out, Vector3.UP)
	end.transform = Transform3D(basis, at - out * 0.005) if plugged else Transform3D(basis.rotated(Vector3.UP, 0.5), Vector3(at.x, 0.01, at.z) + out * 0.09)
	_add_part("plug:power", end, "cord", "main", {}, Vector3.ZERO)
	_parts["plug:power"].aabb = AABB(Vector3(-0.025, -0.02, -0.01), Vector3(0.05, 0.04, 0.07))
	var tail := _find(end, end_name + "_cable")
	var start := end.transform * tail.position if tail else end.transform.origin + out * 0.05
	var far := Vector3(start.x, 0.004, start.z) + out * 0.5
	if kind == "dc":
		var brick := _find(model, "brick_mesh")
		if brick:
			_detach(brick)
			holder.add_child(brick)
			brick.transform = Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(at.x, 0.03, at.z) + out * 0.25)
			far = brick.position - out * 0.03
	model.free()
	_tube(PackedVector3Array([start, start + out * 0.06, Vector3(start.x, 0.004, start.z) + out * 0.14, far]), Color("#1c1c1c"))


## The disc in (or on) the drive, and the media lying on the desk.
func _discs() -> void:
	var main: Node3D = _devices.main
	var tray := _find(main, "cd_tray")
	var disc_point := _find(main, "cd_disc")
	var in_drive := hw.media(AgoraDisk.Kind.CDROM)
	if tray and disc_point and ((not tray_open and in_drive) or (tray_open and tray_disc)):
		var disc := _instance("cd_agoraos")
		if disc:
			disc_point.add_child(disc)
			_dynamic.append(disc)
			if tray_open:
				_add_part("disc", disc, "disc", "main", {}, Vector3.ZERO)
				_parts.disc.aabb = AABB(Vector3(-0.06, -0.002, -0.06), Vector3(0.12, 0.006, 0.12))
	var k := 0
	for d in shelf:
		var disk := d as AgoraDisk
		var at := Vector3(0.38 - k * 0.16, 0.0, -0.28) + (LAYOUTS[hw.template].desk_at as Vector3)
		if hw.template != "pc":
			at = Vector3(-0.2 + k * 0.16, 0.0, -0.18)
		k += 1
		var model := "cd_sleeve" if disk.kind == AgoraDisk.Kind.CDROM else "usb_flash"
		var item := _instance(model)
		if item == null:
			continue
		item.position = at + Vector3(0, 0.002, 0)
		item.rotation.y = 0.25
		_world_root.add_child(item)
		_dynamic.append(item)
		if disk.kind == AgoraDisk.Kind.CDROM:
			var slot := _find(item, "disc_slot")
			var disc := _instance("cd_agoraos")
			if slot and disc:
				slot.add_child(disc)
		_add_part("media:%d" % (k - 1), item, "media", "desk", {"disk": disk}, Vector3.ZERO)
		_parts["media:%d" % (k - 1)].aabb = AABB(Vector3(-0.07, -0.005, -0.08), Vector3(0.14, 0.02, 0.16)) if disk.kind == AgoraDisk.Kind.CDROM else AABB(Vector3(-0.012, -0.006, -0.002), Vector3(0.024, 0.016, 0.07))
	# A USB stick in a port.
	var usb := hw.media(AgoraDisk.Kind.USB)
	var socket := _find(main, "usb0")
	if usb and socket:
		var stick := _instance("usb_flash")
		if stick:
			var out := _outward(socket, _aabb_of(main).get_center())
			stick.transform = Transform3D(Basis.looking_at(-out, Vector3.UP), _xform(socket).origin - out * 0.004)
			_world_root.add_child(stick)
			_dynamic.append(stick)
			_add_part("usb", stick, "usb", "main", {"disk": usb}, Vector3.ZERO)
			_parts.usb.aabb = AABB(Vector3(-0.012, -0.008, -0.004), Vector3(0.024, 0.016, 0.075))


# --- lights --------------------------------------------------------------------

func _process(delta: float) -> void:
	if hw == null:
		return
	_since += delta
	if _since >= REFRESH:
		_since = 0.0
		_update_leds()


## Whether something moved since the last look (blinks for a moment).
func _busy(key: String, count: int) -> bool:
	var now := Time.get_ticks_msec()
	var last: Array = _activity.get(key, [count, 0])
	if count != int(last[0]):
		last = [count, now + 90]
	_activity[key] = last
	return now < int(last[1])


func _blink(key: String, count: int) -> bool:
	return _busy(key, count) and (Time.get_ticks_msec() / 45) % 2 == 0


## What one light shows: [on, kind of light].
func led_state(name: String, role: String = "main") -> Array:
	var on := hw.power == AgoraHardware.Power.ON
	if role == "monitor":
		return [on and monitor_on, "power"]
	if role == "keyboard":
		return [on and hw.numlock and name == "led_num", "kbd"]
	var key := name.trim_prefix("led_")
	if key == "power":
		return [on, "power"]
	if key == "fault":
		return [false, "fault"]
	if key.begins_with("psu"):
		return [plugged, "psu"]
	if key == "wlan":
		return [on, "wlan"]
	if key == "hdd" or (key.begins_with("hdd") and key.substr(3).is_valid_int()):
		var k := key.substr(3).to_int() if key.length() > 3 else 0
		var fixed := hw.disks.filter(func(d: AgoraDisk) -> bool: return not d.removable)
		if k >= fixed.size():
			return [false, "hdd"]
		var d: AgoraDisk = fixed[k]
		return [on and d.fs != null and _busy("disk%d" % k, d.fs.io), "hdd"]
	if key == "cd":
		var cd := hw.media(AgoraDisk.Kind.CDROM)
		return [on and cd != null and cd.fs != null and _busy("cd", cd.fs.io), "cd"]
	if key == "fdd":
		return [false, "fdd"]
	# Network lights: led_eth0_link, led_eth0_act, led_eth0_front,
	# led_port3_link, led_port3_speed, led_wan, led_lan2.
	var parts := key.split("_")
	var nic: AgoraNic = null
	if key == "wan" or key.begins_with("lan"):
		for n in hw.nics:
			if n.label.to_lower() == key:
				nic = n
		parts = PackedStringArray([key, "link"])
	else:
		nic = hw.nic(parts[0])
	if nic == null:
		return [false, "link"]
	var what := parts[1] if parts.size() > 1 else "link"
	var up := on and nic.carrier
	match what:
		"act":
			return [up and _blink(nic.name, nic.frames), "act"]
		"speed":
			return [up and nic.link_speed >= 100, "speed"]
	return [up and not _blink(nic.name, nic.frames), "link"]


func _update_leds() -> void:
	for l: Dictionary in _leds:
		var st := led_state(l.name, l.role)
		var mat: StandardMaterial3D = l.mat
		var color: Color = LED_ON.get(st[1], Color.WHITE)
		if st[0]:
			mat.albedo_color = color
			mat.emission = color
			mat.emission_energy_multiplier = 1.3
		else:
			mat.albedo_color = color.darkened(0.82)
			mat.emission = Color.BLACK
			mat.emission_energy_multiplier = 0.0
		l.on = st[0]
	if _screen_mat:
		_screen_mat.albedo_color = Color.WHITE if _screen_lit() else Color("#141716")
	if not _hover.is_empty():
		_say(describe(_hover))


## Whether the light [param name] is on now (for tests and tooltips).
func is_lit(name: String, role: String = "main") -> bool:
	for l: Dictionary in _leds:
		if l.name == name and l.role == role:
			return bool(l.get("on", false))
	return false


# --- the camera ----------------------------------------------------------------

func _update_camera() -> void:
	var dir := Vector3(sin(_yaw) * cos(_pitch), -sin(_pitch), -cos(_yaw) * cos(_pitch))
	_cam.transform = Transform3D(Basis.IDENTITY, _focus + dir * _dist)
	_cam.transform = _cam.transform.looking_at(_focus, Vector3.UP)


## Turns the view to look at the box from one side.
func view_from(side: String) -> void:
	if in_screen:
		leave_screen()
	match side:
		"front": _yaw = 0.0; _pitch = deg_to_rad(-12.0)
		"back": _yaw = PI; _pitch = deg_to_rad(-12.0)
		"left": _yaw = PI / 2.0; _pitch = deg_to_rad(-12.0)
		"right": _yaw = -PI / 2.0; _pitch = deg_to_rad(-12.0)
		"top": _yaw = 0.0; _pitch = deg_to_rad(-80.0)
	_update_camera()


## Sits down at the computer: the camera goes to the monitor and input goes
## to the machine.
func enter_screen() -> void:
	var monitor: Node3D = _devices.get("monitor")
	if monitor == null or _screen_vp == null:
		return
	in_screen = true
	_stand.visible = true
	var vp_node := _find(monitor, "view_point")
	var screen: Node3D = _parts.screen.node
	var target := _xform(screen) * (_parts.screen.aabb as AABB).get_center()
	var from := _xform(vp_node).origin if vp_node else target + Vector3(0, 0, -0.6)
	var t := Transform3D(Basis.IDENTITY, from).looking_at(target, Vector3.UP)
	if _cam_tween:
		_cam_tween.kill()
	if is_inside_tree():
		_cam_tween = create_tween()
		_cam_tween.tween_property(_cam, "transform", t, 0.35).set_trans(Tween.TRANS_SINE)
	else:
		_cam.transform = t
	if is_inside_tree():
		grab_focus()
	_say("Using the computer. Right-click or \"Stand up\" to step back.")


func leave_screen() -> void:
	if not in_screen:
		return
	in_screen = false
	_stand.visible = false
	_update_camera()
	_say("")


# --- picking -------------------------------------------------------------------

## The part under [param pos] (in this control), or "".
func part_at(pos: Vector2) -> String:
	if not _cam.is_inside_tree():
		return ""
	var vp_pos := pos * Vector2(_vp.size) / size if size.x > 0 and size.y > 0 else pos
	var from := _cam.project_ray_origin(vp_pos)
	var dir := _cam.project_ray_normal(vp_pos)
	var best := ""
	var best_d := INF
	for id: String in _parts:
		var part: Dictionary = _parts[id]
		var node: Node3D = part.node
		if not is_instance_valid(node) or not node.is_visible_in_tree():
			continue
		var d := _hit(node, part.aabb, from, dir)
		if d < best_d:
			best_d = d
			best = id
	if best.is_empty():
		return ""
	# The case hides what is behind it (with a little slack for things on it).
	for b: Array in _blockers:
		var node: Node3D = b[0]
		if not is_instance_valid(node) or (b[1] as AABB).size == Vector3.ZERO:
			continue
		var d := _hit(node, b[1], from, dir)
		if d + 0.015 < best_d:
			return ""
	return best


func _hit(node: Node3D, box: AABB, from: Vector3, dir: Vector3) -> float:
	var inv := _xform(node).affine_inverse()
	var lf := inv * from
	var ld := (inv.basis * dir)
	var hit: Variant = box.intersects_ray(lf, ld)
	if hit == null:
		return INF
	return (_xform(node) * (hit as Vector3)).distance_to(from)


## The screen position (in this control) of a part's middle, or (-1, -1).
func part_position(id: String) -> Vector2:
	if not _parts.has(id) or not _cam.is_inside_tree():
		return Vector2(-1, -1)
	var part: Dictionary = _parts[id]
	var p := _xform(part.node) * (part.aabb as AABB).get_center()
	if _cam.is_position_behind(p):
		return Vector2(-1, -1)
	return _cam.unproject_position(p) * size / Vector2(_vp.size)


## What a part is and how it is: shown under the mouse.
func describe(id: String) -> String:
	if not _parts.has(id):
		return ""
	var part: Dictionary = _parts[id]
	match str(part.kind):
		"button":
			var name := id.get_slice(":", 1) if id.contains(":") else id
			match name:
				"btn_power":
					if part.role == "monitor":
						return "Monitor power: %s" % ("on" if monitor_on else "off")
					return "Power button (hold to cut the power)" if hw.template in ["pc", "server"] else "Power"
				"btn_reset":
					return "Reset" if hw.template != "router" else "Reset (restarts the router)"
				"btn_eject":
					return "Eject"
			return name
		"port":
			return _port_text(id)
		"plug":
			return _port_text(str(part.nic)) + (" - click to pull the cable out" if hw.nic(str(part.nic)).cable else " - click to plug it back in")
		"cord":
			return "Power cord: %s" % ("plugged in - click to pull it out" if plugged else "pulled out - click to plug it in")
		"power":
			return "Power socket"
		"tray":
			return "CD-ROM drive (%s)" % hw.cdrom_drive
		"disc":
			return "AgoraOS install CD - click to take it"
		"media":
			var d: AgoraDisk = part.disk
			return "%s - click to put it in" % d.model
		"usb":
			return "%s in a USB port - click to take it out" % (part.disk as AgoraDisk).model
		"panel":
			return "Side panel - click to %s" % ("close it" if panel_open else "open the case")
		"jumper":
			if hw.cmos_jumper_clear:
				return "Clear CMOS jumper on pins 2-3: the CMOS is cleared and the board won't start - click to put it back on 1-2"
			return "Clear CMOS jumper on pins 1-2 (normal) - click to move it to 2-3 and clear the CMOS"
		"battery":
			if hw.cmos_battery:
				return "CMOS battery (CR2032, 3 V) - click to take it out"
			return "No CMOS battery: the settings last only while the power cord is in - click to put it back"
		"screen":
			return "Screen - click to use the computer"
	return id


func _port_text(name: String) -> String:
	var nic := hw.nic(name)
	if nic == null:
		return name
	var shown := nic.label if not nic.label.is_empty() else name
	if nic.cable == null:
		return "%s: no cable" % shown
	var peer := ""
	if world and nic.peer:
		peer = world.port_name(nic.peer)
	var defects := ", ".join(nic.cable.defects)
	var state := "link up, %d Mbit/s %s duplex" % [nic.link_speed, nic.duplex] if nic.carrier else "no link"
	return "%s: %s%s%s" % [shown, state, " - to " + peer if not peer.is_empty() else "", " (cable: %s)" % defects if not defects.is_empty() else ""]


func _say(text: String) -> void:
	if _info.text != text:
		_info.text = text
		info_changed.emit(text)


# --- doing things --------------------------------------------------------------

## What a click on [param id] does. [param held]: seconds the button was
## held down (power buttons cut the power when held).
func press(id: String, held: float = 0.0) -> void:
	if not _parts.has(id):
		return
	var part: Dictionary = _parts[id]
	var on := hw.power == AgoraHardware.Power.ON
	match str(part.kind):
		"button":
			_poke(part.node)
			var name := id.get_slice(":", 1) if id.contains(":") else id
			if part.role == "monitor":
				monitor_on = not monitor_on
			elif name == "btn_power":
				if not plugged:
					_say("Nothing happens: the power cord is out.")
				elif hw.cmos_jumper_clear:
					_say("Nothing happens: the clear CMOS jumper is on pins 2-3.")
				elif not on:
					hw.power_on()
				elif held >= HOLD_SECONDS or hw.machine == null:
					hw.power_off()
				else:
					_power_button_event()
			elif name == "btn_reset":
				if on:
					hw.power_off()
					hw.power_on()
			elif name == "btn_eject":
				toggle_tray()
		"tray":
			if tray_open and tray_disc == null:
				_take_from_shelf(AgoraDisk.Kind.CDROM)
			elif not tray_open:
				toggle_tray()
		"disc":
			if tray_disc:
				shelf.append(tray_disc)
				tray_disc = null
		"media":
			var d: AgoraDisk = part.disk
			if d.kind == AgoraDisk.Kind.CDROM:
				if not tray_open:
					_say("Open the CD tray first (the eject button).")
					return
				if tray_disc == null:
					shelf.erase(d)
					tray_disc = d
			else:
				if hw.insert(d):
					shelf.erase(d)
		"usb":
			var d: AgoraDisk = part.disk
			if hw.eject(d):
				shelf.append(d)
		"port", "plug":
			toggle_cable(str(part.get("nic", id)))
		"cord", "power":
			toggle_power_cord()
		"panel":
			toggle_panel()
		"jumper":
			hw.set_cmos_jumper(not hw.cmos_jumper_clear)
			_place_cmos_parts()
		"battery":
			hw.set_cmos_battery(not hw.cmos_battery)
			_place_cmos_parts()
		"screen":
			enter_screen()
	_rebuild_dynamic()
	_update_leds()


## The power button of a running system: ACPI tells the kernel, which shuts
## down as if someone typed poweroff.
func _power_button_event() -> void:
	var m := hw.machine
	if m == null:
		hw.power_off()
		return
	m.klog("ACPI: Power Button (FF) [PWRF]")
	var p := m.spawn(PackedStringArray(["/sbin/poweroff"]), {"cred": AgoraCred.root()})
	if p == null:
		hw.power_off()


func _poke(node: Node3D) -> void:
	if not is_inside_tree():
		return
	var home := node.position
	var tw := create_tween()
	tw.tween_property(node, "position", home + Vector3(0, 0, 0.003), 0.06)
	tw.tween_property(node, "position", home, 0.08)


func toggle_tray() -> void:
	var tray := _find(_devices.main, "cd_tray")
	if tray == null:
		return
	if not tray_open:
		var cd := hw.media(AgoraDisk.Kind.CDROM)
		if cd:
			hw.eject(cd)
			tray_disc = cd
		tray_open = true
	else:
		if tray_disc:
			hw.insert(tray_disc)
			tray_disc = null
		tray_open = false
	var home: Vector3 = tray.get_meta("home", tray.position)
	tray.set_meta("home", home)
	var target := home + Vector3(0, 0, -0.13) if tray_open else home
	if is_inside_tree():
		create_tween().tween_property(tray, "position", target, 0.5).set_trans(Tween.TRANS_SINE)
	else:
		tray.position = target
	_rebuild_dynamic()


func _take_from_shelf(kind: AgoraDisk.Kind) -> void:
	for d in shelf:
		if (d as AgoraDisk).kind == kind:
			shelf.erase(d)
			tray_disc = d
			return


func toggle_panel() -> void:
	var main: Node3D = _devices.main
	var panel := _find(main, "side_panel")
	if panel == null:
		return
	panel_open = not panel_open
	var home: Vector3 = _parts.side_panel.home
	var target := home + Vector3(0.35, 0, -0.1) if panel_open else home
	if is_inside_tree():
		create_tween().tween_property(panel, "position", target, 0.4).set_trans(Tween.TRANS_SINE)
	else:
		panel.position = target
	# With the side off the inside isn't hidden by the case any more.
	for b: Array in _blockers:
		if b[0] == _find(main, "body"):
			b[1] = AABB() if panel_open else (b[0] as MeshInstance3D).mesh.get_aabb()


## Pulls the cable out of [param port], or plugs it back in.
func toggle_cable(port: String) -> void:
	var nic := hw.nic(port)
	if nic == null:
		return
	if nic.cable:
		var variant := "ok"
		for d: String in nic.cable.defects:
			variant = d
		_loose[port] = {"peer": nic.peer, "length": nic.cable.length_m, "defects": nic.cable.defects.duplicate(), "variant": variant}
		if world and not box_name.is_empty():
			world.unplug("%s:%s" % [box_name, port])
		else:
			nic.unplug()
	elif _loose.has(port):
		var l: Dictionary = _loose[port]
		var peer: AgoraNic = l.peer
		if world and not box_name.is_empty() and not world.port_name(peer).is_empty():
			world.plug("%s:%s" % [box_name, port], world.port_name(peer), l.length, l.defects)
		elif peer:
			nic.plug(peer, l.length)
			if not (l.defects as PackedStringArray).is_empty():
				nic.cable.defects = l.defects
		_loose.erase(port)
	_rebuild_dynamic()


## Pulls the power cord out (the power goes) or plugs it in. Boxes
## without a power button come on as soon as they get power.
func toggle_power_cord() -> void:
	plugged = not plugged
	hw.set_mains(plugged)
	if plugged and hw.template in ["router", "switch"]:
		hw.power_on()
	_rebuild_dynamic()


## The jumper on pins 1-2 or 2-3 (one pin, 2.5 mm, along the header), the
## battery in its holder or lying out of it.
func _place_cmos_parts() -> void:
	var moves := {
		"jumper_clear_cmos": Vector3(0, -0.0025, 0) if hw.cmos_jumper_clear else Vector3.ZERO,
		"cmos_battery": Vector3.ZERO if hw.cmos_battery else Vector3(0.025, 0, 0),
	}
	for id: String in moves:
		if not _parts.has(id):
			continue
		var node: Node3D = _parts[id].node
		var target: Vector3 = _parts[id].home + moves[id]
		if is_inside_tree():
			create_tween().tween_property(node, "position", target, 0.25).set_trans(Tween.TRANS_SINE)
		else:
			node.position = target


# --- input ---------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if in_screen:
		_screen_input(event)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_dist = maxf(0.15, _dist * 0.9)
				_update_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				_dist = minf(4.0, _dist * 1.1)
				_update_camera()
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_press_pos = mb.position
					_press_part = part_at(mb.position)
					_press_time = Time.get_ticks_msec()
					_dragging = true
				else:
					_dragging = false
					if mb.position.distance_to(_press_pos) < 5.0 and not _press_part.is_empty():
						press(_press_part, (Time.get_ticks_msec() - _press_time) / 1000.0)
					_press_part = ""
		accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) and mm.position.distance_to(_press_pos) >= 5.0:
			_yaw -= mm.relative.x * 0.008
			_pitch = clampf(_pitch - mm.relative.y * 0.008, deg_to_rad(-85.0), deg_to_rad(10.0))
			_update_camera()
		else:
			var id := part_at(mm.position)
			if id != _hover:
				_hover = id
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not id.is_empty() else Control.CURSOR_ARROW
				_say(describe(id))
		accept_event()


## In the chair: the mouse over the screen and the keys go to the machine.
func _screen_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		leave_screen()
		accept_event()
		return
	if _screen_vp == null:
		return
	if event is InputEventMouse:
		var uv := screen_uv((event as InputEventMouse).position)
		if uv.x < 0:
			return
		var e := event.duplicate() as InputEventMouse
		e.position = uv * Vector2(_screen_vp.size)
		e.global_position = e.position
		_screen_vp.push_input(e, true)
	else:
		_screen_vp.push_input(event, true)
	accept_event()


## Where on the screen [param pos] points, 0..1 each way, or (-1, -1).
func screen_uv(pos: Vector2) -> Vector2:
	if not _parts.has("screen") or not _cam.is_inside_tree():
		return Vector2(-1, -1)
	var part: Dictionary = _parts.screen
	var node: Node3D = part.node
	var vp_pos := pos * Vector2(_vp.size) / size if size.x > 0 else pos
	var inv := _xform(node).affine_inverse()
	var from := inv * _cam.project_ray_origin(vp_pos)
	var dir := inv.basis * _cam.project_ray_normal(vp_pos)
	var box: AABB = part.aabb
	var hit: Variant = box.intersects_ray(from, dir)
	if hit == null:
		return Vector2(-1, -1)
	var h := hit as Vector3
	# Seen from the front (-Z), +X is on the left.
	return Vector2(1.0 - (h.x - box.position.x) / box.size.x, 1.0 - (h.y - box.position.y) / box.size.y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_clear()
