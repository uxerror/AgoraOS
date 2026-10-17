class_name AgoraNic
extends RefCounted
## A network port (eth0, eth1, ...) with a MAC address. An [AgoraCable]
## links two ports; [member carrier] is true while one is plugged in at both
## ends. Frames sent with [method transmit] go through the cable's queue
## and arrive at the other end's [member receiver].

signal link_changed(up: bool)

var name := "eth0"
var mac := "00:00:00:00:00:00"
var label := "" # printed next to the socket: "WAN", "LAN1"...
## The fastest the card can go; a link runs at the slower end's speed.
var speed_mbps := 100
## Extra one-way delay of the card in milliseconds, on top of what the
## cable takes. Frames record the delay they picked up ("lat") so tools can
## report round-trip times. Slow long-haul links (the game's WAN) really
## take that long to deliver.
var latency_ms := 0.1

## Called with each frame that arrives over the cable. The kernel's driver
## sets it while the machine runs.
var receiver: Callable

var cable: AgoraCable


var peer: AgoraNic:
	get:
		return cable.other(self) if cable else null


var carrier: bool:
	get:
		return peer != null


## The speed the link runs at, 0 without one.
var link_speed: int:
	get:
		return cable.speed_mbps if cable else 0


## Plugs a cable [param length_m] metres long between this port and
## [param other], unplugging whatever was connected to either before.
func plug(other: AgoraNic, length_m: float = 2.0) -> void:
	if other == self:
		return
	unplug()
	other.unplug()
	cable = AgoraCable.new(self, other, length_m)
	other.cable = cable
	link_changed.emit(true)
	other.link_changed.emit(true)


func unplug() -> void:
	var other := peer
	if cable:
		cable.cut()
	cable = null
	if other:
		other.cable = null
		other.link_changed.emit(false)
		link_changed.emit(false)


## Frames waiting in the cable's transmit queue from this port.
func queued() -> int:
	return cable.queued(self) if cable else 0


## Puts an Ethernet frame ({dst, src, type, payload, len}) on the cable.
## Returns false if nothing is plugged in. The receiver gets its own copy.
func transmit(frame: Dictionary) -> bool:
	if peer == null:
		return false
	cable.send(self, frame.duplicate(true), latency_ms * randf_range(0.85, 1.25) / 1000.0)
	return true


func _arrive(frame: Dictionary) -> void:
	if receiver.is_valid():
		receiver.call(frame)


static func random_mac(vendor: String = "00:16:3e") -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%s:%02x:%02x:%02x" % [vendor, rng.randi() & 255, rng.randi() & 255, rng.randi() & 255]
