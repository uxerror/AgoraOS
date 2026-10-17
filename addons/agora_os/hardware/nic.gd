class_name AgoraNic
extends RefCounted
## A network port (eth0, eth1, ...) with a MAC address. A cable links two
## ports; [member carrier] is true while one is plugged in at both ends.
## Frames sent with [method transmit] arrive at the other end's
## [member receiver] on the next engine frame, like bits on a wire.

signal link_changed(up: bool)

var name := "eth0"
var mac := "00:00:00:00:00:00"
var label := "" # printed next to the socket: "WAN", "LAN1"...
var speed_mbps := 100

## Called with each frame that arrives over the cable. The kernel's driver
## sets it while the machine runs.
var receiver: Callable

var _peer_ref: WeakRef


var peer: AgoraNic:
	get:
		return _peer_ref.get_ref() as AgoraNic if _peer_ref else null


var carrier: bool:
	get:
		return peer != null


## Plugs a cable between this port and [param other], unplugging whatever
## was connected to either before.
func plug(other: AgoraNic) -> void:
	if other == self or other == peer:
		return
	unplug()
	other.unplug()
	_peer_ref = weakref(other)
	other._peer_ref = weakref(self)
	link_changed.emit(true)
	other.link_changed.emit(true)


func unplug() -> void:
	var other := peer
	_peer_ref = null
	if other:
		other._peer_ref = null
		other.link_changed.emit(false)
		link_changed.emit(false)


## Puts an Ethernet frame ({dst, src, type, payload}) on the cable. Returns
## false if nothing is plugged in. The receiver gets its own copy.
func transmit(frame: Dictionary) -> bool:
	var other := peer
	if other == null:
		return false
	other._arrive.call_deferred(frame.duplicate(true))
	return true


func _arrive(frame: Dictionary) -> void:
	if receiver.is_valid():
		receiver.call(frame)


static func random_mac(vendor: String = "00:16:3e") -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%s:%02x:%02x:%02x" % [vendor, rng.randi() & 255, rng.randi() & 255, rng.randi() & 255]
