class_name AgoraWorld
extends RefCounted
## A set of boxes (see [AgoraHardware]) under one clock, with the cables
## between their ports: a home network, an office, the game's internet.
## The world is what gets saved: every box with its disks, which ports are
## cabled and how (length, defects), and which boxes were switched on.
## Loading it is like coming back to the room: the cables are where they
## were, and the boxes that were on boot again.
##
## A world can also be built from a description (see [method from_spec]),
## a Dictionary or JSON file listing the boxes, what to install on them and
## how they are cabled.

signal changed

const FORMAT := 1

var clock: AgoraClock
## Box name -> AgoraHardware, in the order they were added.
var boxes := {}
## Boxes to switch on when the world starts.
var _power := {}


func _init(p_clock: AgoraClock = null) -> void:
	clock = p_clock if p_clock else AgoraClock.new()


# --- boxes ---------------------------------------------------------------------

## Adds a new box from a template ("pc", "server", "router", "virtual").
func create(name: String, template: String) -> AgoraHardware:
	var hw := AgoraHardware.from_template(template, clock)
	add(name, hw)
	return hw


## Adds an existing box. Returns false if the name is taken.
func add(name: String, hw: AgoraHardware, power: bool = true) -> bool:
	if boxes.has(name):
		return false
	hw.clock = clock
	boxes[name] = hw
	_power[name] = power
	changed.emit()
	return true


## Takes a box out of the world: it is switched off and its cables pulled.
func remove(name: String) -> bool:
	var hw := box(name)
	if hw == null:
		return false
	hw.power_off()
	for n in hw.nics:
		n.unplug()
	boxes.erase(name)
	_power.erase(name)
	changed.emit()
	return true


func box(name: String) -> AgoraHardware:
	return boxes.get(name) as AgoraHardware


func names() -> PackedStringArray:
	return PackedStringArray(boxes.keys())


## The name of [param hw] in this world, or "".
func name_of(hw: AgoraHardware) -> String:
	for name: String in boxes:
		if boxes[name] == hw:
			return name
	return ""


# --- cables --------------------------------------------------------------------

## Cables port [param a] ("box:port") to port [param b]. Whatever was in
## either port is unplugged first.
func plug(a: String, b: String, length_m: float = 2.0, defects: PackedStringArray = []) -> AgoraCable:
	var na := port(a)
	var nb := port(b)
	if na == null or nb == null or na == nb:
		return null
	na.plug(nb, length_m)
	if not defects.is_empty():
		na.cable.defects = defects
	changed.emit()
	return na.cable


func unplug(a: String) -> bool:
	var n := port(a)
	if n == null or n.cable == null:
		return false
	n.unplug()
	changed.emit()
	return true


## The network port named "box:port", or null.
func port(spec: String) -> AgoraNic:
	var parts := spec.split(":")
	if parts.size() != 2:
		return null
	var hw := box(parts[0])
	return hw.nic(parts[1]) if hw else null


## The "box:port" name of [param nic], or "" if it isn't in this world.
func port_name(nic: AgoraNic) -> String:
	for name: String in boxes:
		if (boxes[name] as AgoraHardware).nics.has(nic):
			return "%s:%s" % [name, nic.name]
	return ""


## Every cable once: {a, b, length, defects, cable}, a and b as "box:port".
func cables() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen := {}
	for name: String in boxes:
		for n: AgoraNic in (boxes[name] as AgoraHardware).nics:
			var c := n.cable
			if c == null or seen.has(c):
				continue
			var other := port_name(c.other(n))
			if other.is_empty():
				continue # cabled to a box outside the world
			seen[c] = true
			out.append({"a": "%s:%s" % [name, n.name], "b": other, "length": c.length_m,
				"defects": c.defects, "cable": c})
	return out


# --- power ---------------------------------------------------------------------

## Switches on the boxes that should be on.
func start() -> void:
	for name: String in boxes:
		if _power.get(name, true):
			box(name).power_on()


## Cuts the power to every box, as when the game quits; [method serialize]
## still remembers which ones were on.
func stop() -> void:
	for name: String in boxes:
		var hw := box(name)
		_power[name] = hw.power == AgoraHardware.Power.ON
		hw.power_off()


## Whether [param name] is on, or will be when the world starts.
func is_on(name: String) -> bool:
	var hw := box(name)
	if hw == null:
		return false
	return hw.power == AgoraHardware.Power.ON or (_power.get(name, false) and hw.machine == null)


# --- persistence ---------------------------------------------------------------

func serialize() -> Dictionary:
	var box_data := {}
	for name: String in boxes:
		var hw := box(name)
		var data := hw.serialize()
		data.erase("clock")
		data.power = hw.power == AgoraHardware.Power.ON or (hw.machine == null and _power.get(name, false))
		box_data[name] = data
	var cable_data: Array = []
	for c in cables():
		cable_data.append({"a": c.a, "b": c.b, "length": c.length, "defects": Array(c.defects)})
	return {"format": FORMAT, "clock": clock.serialize(), "boxes": box_data, "cables": cable_data}


static func deserialize(data: Dictionary, p_clock: AgoraClock = null) -> AgoraWorld:
	var clock := p_clock
	if clock == null:
		clock = AgoraClock.new()
		clock.deserialize(data.get("clock", {}))
	var world := AgoraWorld.new(clock)
	var box_data: Dictionary = data.get("boxes", {})
	for name: String in box_data:
		var bd: Dictionary = box_data[name]
		world.add(name, AgoraHardware.deserialize(bd, clock), bd.get("power", true))
	for c: Dictionary in data.get("cables", []):
		world.plug(c.a, c.b, c.get("length", 2.0), PackedStringArray(c.get("defects", [])))
	return world


## Saves the whole world, every disk included, compressed. Boxes that are
## on are saved as they are; nothing that runs in them survives.
func save(path: String) -> int:
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var(serialize())
	return OK


static func load_from(path: String, p_clock: AgoraClock = null) -> AgoraWorld:
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return null
	var data: Variant = f.get_var()
	if not data is Dictionary or data.get("format", 0) != FORMAT:
		return null
	return deserialize(data, p_clock)


# --- descriptions --------------------------------------------------------------

## Builds a world from a description:
## [codeblock]
## {
##   "clock": {"start": "2003-06-14 22:00:00", "speed": 1.0},
##   "boxes": {
##     "pc": {"template": "pc", "media": ["installer"]},
##     "gw": {"template": "router", "install": {"profile": "router", "root_password": "admin"}},
##     "srv": {"template": "server", "install": {"hostname": "www", "users": [...]}, "power": false},
##   },
##   "cables": [["pc:eth0", "gw:eth1"], {"a": "gw:eth0", "b": "srv:eth0", "length": 40, "defects": ["bad_crimp"]}],
## }
## [/codeblock]
## "install" puts a system on the first disk, with the installer's options
## (the hostname defaults to the box's name). "media" inserts removable
## media: "installer" is the install CD, "installer-usb" the same on a USB
## stick, "usb" an empty stick. Returns null
## and sets [member spec_error] if the description is wrong.
static func from_spec(spec: Dictionary, p_clock: AgoraClock = null) -> AgoraWorld:
	spec_error = ""
	var clock := p_clock
	if clock == null:
		var c: Dictionary = spec.get("clock", {})
		var start := -1.0
		if c.get("start") is String:
			start = Time.get_unix_time_from_datetime_string(c.start)
		elif c.has("start"):
			start = float(c.start)
		clock = AgoraClock.new(start)
		clock.speed = float(c.get("speed", 1.0))
		if c.has("tz"):
			clock.tz_offset_minutes = int(c.tz)
	var world := AgoraWorld.new(clock)
	var box_specs: Dictionary = spec.get("boxes", {})
	for name: String in box_specs:
		var bs: Dictionary = box_specs[name]
		var template: String = bs.get("template", "pc")
		if not AgoraHardware.TEMPLATES.has(template):
			spec_error = "%s: unknown template \"%s\"" % [name, template]
			return null
		var hw := AgoraHardware.from_template(template, clock)
		if bs.has("install"):
			var opts: Dictionary = bs.install
			AgoraInstaller.install_disk(hw.disks[0], opts.get("hostname", name), opts, clock)
		for m: String in bs.get("media", []):
			match m:
				"installer", "installer-usb":
					hw.insert(AgoraMedia.installer(m == "installer-usb", clock))
				"usb":
					hw.insert(AgoraMedia.usb_stick())
				_:
					spec_error = "%s: unknown media \"%s\"" % [name, m]
					return null
		world.add(name, hw, bs.get("power", true))
	for c: Variant in spec.get("cables", []):
		var a := ""
		var b := ""
		var length := 2.0
		var defects := PackedStringArray()
		if c is Array and c.size() == 2:
			a = c[0]
			b = c[1]
		elif c is Dictionary:
			a = c.get("a", "")
			b = c.get("b", "")
			length = float(c.get("length", 2.0))
			defects = PackedStringArray(c.get("defects", []))
		for d in defects:
			if not AgoraCable.DEFECTS.has(d):
				spec_error = "cable %s - %s: unknown defect \"%s\"" % [a, b, d]
				return null
		if world.port(a) == null or world.port(b) == null:
			spec_error = "cable %s - %s: no such port" % [a, b]
			return null
		world.plug(a, b, length, defects)
	return world


## Why the last [method from_spec] or [method from_json] failed.
static var spec_error := ""


## [method from_spec] with a JSON file, e.g. under res://worlds/.
static func from_json(path: String, p_clock: AgoraClock = null) -> AgoraWorld:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		spec_error = "%s: cannot read" % path
		return null
	var data: Variant = JSON.parse_string(text)
	if not data is Dictionary:
		spec_error = "%s: not a JSON object" % path
		return null
	return from_spec(data, p_clock)
