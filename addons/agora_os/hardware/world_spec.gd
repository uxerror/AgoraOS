@tool
class_name AgoraWorldSpec
extends Resource
## A world as a resource (a .tres under res://worlds/, edited in the
## inspector): the boxes, what is installed on them, how they are cabled
## and the clock. [method build] makes the [AgoraWorld].

## Local date and time the world starts at, "YYYY-MM-DD HH:MM:SS";
## empty for the real time.
@export var start_time := ""
@export_range(0.0, 3600.0, 0.1, "or_greater") var clock_speed := 1.0
@export var boxes: Array[AgoraBoxSpec] = []
@export var cables: Array[AgoraCableSpec] = []

## Why the last [method build] failed.
var error := ""


## The box called [param box_name], or null.
func box(box_name: String) -> AgoraBoxSpec:
	for b in boxes:
		if b and b.name == box_name:
			return b
	return null


## Builds the world, with [param p_clock] instead of a new clock if given.
## Returns null with [member error] set if the spec is wrong.
func build(p_clock: AgoraClock = null) -> AgoraWorld:
	error = ""
	var clock := p_clock
	if clock == null:
		clock = AgoraClock.new()
		if not start_time.is_empty():
			# The string is local time in the clock's time zone.
			clock.set_time(Time.get_unix_time_from_datetime_string(start_time) - clock.tz_offset_minutes * 60)
		clock.speed = clock_speed
	var world := AgoraWorld.new(clock)
	for bs in boxes:
		if bs == null:
			continue
		if not AgoraHardware.TEMPLATES.has(bs.template):
			error = "%s: unknown template \"%s\"" % [bs.name, bs.template]
			return null
		var hw := AgoraHardware.from_template(bs.template, clock)
		if bs.install:
			var host := bs.hostname if not bs.hostname.is_empty() else bs.name
			AgoraInstaller.install_disk(hw.disks[0], host, bs.install_options(), clock)
		for m in bs.media:
			match m:
				AgoraBoxSpec.Media.INSTALL_CD, AgoraBoxSpec.Media.INSTALL_USB:
					hw.insert(AgoraMedia.installer(m == AgoraBoxSpec.Media.INSTALL_USB, clock))
				AgoraBoxSpec.Media.USB_STICK:
					hw.insert(AgoraMedia.usb_stick())
		if not world.add(bs.name, hw, bs.power):
			error = "%s: two boxes with this name" % bs.name
			return null
	for cs in cables:
		if cs == null:
			continue
		for d in cs.defects:
			if not AgoraCable.DEFECTS.has(d):
				error = "cable %s - %s: unknown defect \"%s\"" % [cs.a, cs.b, d]
				return null
		if world.port(cs.a) == null or world.port(cs.b) == null:
			error = "cable %s - %s: no such port" % [cs.a, cs.b]
			return null
		world.plug(cs.a, cs.b, cs.length_m, PackedStringArray(cs.defects))
	return world
