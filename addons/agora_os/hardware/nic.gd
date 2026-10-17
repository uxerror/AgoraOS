class_name AgoraNic
extends RefCounted
## A network port (eth0, eth1, ...) with a MAC address. A cable links two
## ports; [member carrier] is true while one is plugged in at both ends.
## Addresses, routing and packets come with the network layer.

signal link_changed(up: bool)

var name := "eth0"
var mac := "00:00:00:00:00:00"
var label := "" # printed next to the socket: "WAN", "LAN1"...
var speed_mbps := 100

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


static func random_mac(vendor: String = "00:16:3e") -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%s:%02x:%02x:%02x" % [vendor, rng.randi() & 255, rng.randi() & 255, rng.randi() & 255]
