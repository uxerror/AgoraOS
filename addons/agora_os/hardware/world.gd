class_name AgoraWorld
extends RefCounted
## A set of boxes (see [AgoraHardware]) under one clock, with the cables
## between their ports: a home network, an office, the game's internet.
## The world is what gets saved: every box with its disks, which ports are
## cabled and how (length, defects), and which boxes were switched on.
## Loading it is like coming back to the room: the cables are where they
## were, and the boxes that were on boot again.
##
## A world is usually built from an [AgoraWorldSpec] resource that lists
## the boxes, what to install on them and how they are cabled.

signal changed

const FORMAT := 1

var clock: AgoraClock
## Box name -> AgoraHardware, in the order they were added.
var boxes := {}
## Boxes to switch on when the world starts.
var _power := {}
## Thin coax buses (10BASE2) between the boxes' BNC cards.
var coax: Array[AgoraCoax] = []
## Box name -> the media lying on its desk (AgoraDisk: CDs out of the
## drive, USB sticks), saved with the world.
var shelves := {}
## Box name -> the place it stands ("home", "lanlink"): boxes of one place
## are seen together in 3D. Boxes without one stand alone.
var places := {}


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


## Puts [param hw] in place of the box [param name], in the same position
## and with the same cables. The old box is switched off.
func replace(name: String, hw: AgoraHardware) -> bool:
	var old := box(name)
	if old == null:
		return false
	var plugged: Array[Dictionary] = []
	for c in cables():
		if c.a.begins_with(name + ":") or c.b.begins_with(name + ":"):
			plugged.append(c)
	old.power_off()
	for n in old.nics:
		n.unplug()
	hw.clock = clock
	boxes[name] = hw
	for c in plugged:
		plug(c.a, c.b, c.length, c.defects)
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


## A console cable between the serial ports of boxes [param a] and
## [param b].
func plug_serial(a: String, b: String) -> bool:
	var ha := box(a)
	var hb := box(b)
	if ha == null or hb == null or not ha.connect_serial(hb):
		return false
	changed.emit()
	return true


func unplug_serial(a: String) -> void:
	var h := box(a)
	if h:
		h.disconnect_serial()
		changed.emit()


## Every console cable once: [a, b].
func serial_cables() -> Array:
	var out: Array = []
	for name: String in boxes:
		var peer := box(name).serial_peer
		if peer:
			var other := name_of(peer)
			if not other.is_empty() and name < other:
				out.append([name, other])
	return out


## A new thin coax bus [param length_m] metres long, terminated at both
## ends, with no T-connectors yet ([method AgoraCoax.attach]).
func add_coax(length_m: float = 10.0) -> AgoraCoax:
	var bus := AgoraCoax.new(length_m)
	coax.append(bus)
	changed.emit()
	return bus


## The media on [param name]'s desk: the array itself, to change in place.
func shelf(name: String) -> Array:
	if not shelves.has(name):
		shelves[name] = []
	return shelves[name]


## The place of [param name], "" for a box standing alone.
func place_of(name: String) -> String:
	return places.get(name, "")


## The boxes standing in [param place], in the order they were added.
func boxes_in(place: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for name: String in boxes:
		if not place.is_empty() and places.get(name, "") == place:
			out.append(name)
	return out


# --- persistence ---------------------------------------------------------------

func serialize() -> Dictionary:
	var box_data := {}
	for name: String in boxes:
		var hw := box(name)
		var data := hw.serialize()
		data.erase("clock")
		data.power = hw.power == AgoraHardware.Power.ON or (hw.machine == null and _power.get(name, false))
		data.place = place_of(name)
		data.shelf = (shelves.get(name, []) as Array).map(func(d: AgoraDisk) -> Dictionary: return d.serialize())
		box_data[name] = data
	var cable_data: Array = []
	for c in cables():
		cable_data.append({"a": c.a, "b": c.b, "length": c.length, "defects": Array(c.defects)})
	var coax_data: Array = []
	for bus in coax:
		var taps: Array = []
		for t in bus.taps:
			var spec := port_name(t.nic)
			if not spec.is_empty():
				taps.append([spec, t.at_m])
		coax_data.append({"length": bus.length_m, "terminators": bus.terminators.duplicate(), "taps": taps})
	return {"format": FORMAT, "clock": clock.serialize(), "boxes": box_data, "cables": cable_data, "coax": coax_data, "serial": serial_cables()}


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
		if not str(bd.get("place", "")).is_empty():
			world.places[name] = bd.place
		for d: Dictionary in bd.get("shelf", []):
			world.shelf(name).append(AgoraDisk.deserialize(d))
	for c: Dictionary in data.get("cables", []):
		world.plug(c.a, c.b, c.get("length", 2.0), PackedStringArray(c.get("defects", [])))
	for pair: Array in data.get("serial", []):
		world.plug_serial(pair[0], pair[1])
	for x: Dictionary in data.get("coax", []):
		var bus := world.add_coax(x.get("length", 10.0))
		bus.terminators = x.get("terminators", [true, true])
		for t: Array in x.get("taps", []):
			var nic := world.port(t[0])
			if nic:
				bus.attach(nic, t[1])
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

