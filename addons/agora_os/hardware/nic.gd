class_name AgoraNic
extends RefCounted
## A network port (eth0, eth1, ...) with a MAC address and a PHY. An
## [AgoraCable] links two ports and negotiates speed and duplex between
## them; [member carrier] is true while that gives a link. Frames sent with
## [method transmit] go through the cable's queue and arrive at the other
## end's [member receiver]; one damaged on the way has "bad_fcs" set (or
## "runt" for a collision fragment), and the driver counts and drops it.

signal link_changed(up: bool)

## Link modes as ethtool names them, in its order, with their bits in
## ethtool's advertising mask.
const MODES := [
	["10baseT/Half", 10, "half", 0x001], ["10baseT/Full", 10, "full", 0x002],
	["100baseT/Half", 100, "half", 0x004], ["100baseT/Full", 100, "full", 0x008],
	["1000baseT/Half", 1000, "half", 0x010], ["1000baseT/Full", 1000, "full", 0x020],
]

var name := "eth0"
var mac := "00:00:00:00:00:00"
var label := "" # printed next to the socket: "WAN", "LAN1"...
## The Linux driver for the chip: "e100" (Fast Ethernet), "e1000"
## (Gigabit), "b44" (the router's), "ne2k-pci" (an NE2000 clone with a BNC
## socket for thin coax); "switch" and "hub" for the ports of those.
var driver := "e100"
## The socket: "tp" (RJ-45, twisted pair) or "bnc" (10BASE2 coax).
var media := "tp"
## The coax bus a BNC card's T-connector is on.
var coax: AgoraCoax
## For a hub's port: the hub's collision domain, which the cards cabled to
## its ports share.
var segment: AgoraSegment
## PCI address, as ethtool -i shows it.
var bus_info := "0000:00:00.0"
## The fastest the card can go. Changing it is fitting another chip.
var speed_mbps := 100:
	set(v):
		speed_mbps = v
		reset_phy()
## Extra one-way delay of the card in milliseconds, on top of what the
## cable takes. Frames record the delay they picked up ("lat") so tools can
## report round-trip times. Slow long-haul links (the game's WAN) really
## take that long to deliver.
var latency_ms := 0.1

## PHY settings, changed with ethtool -s. With autoneg the card offers the
## modes in [member advertising]; without, it runs at
## [member forced_speed] and [member forced_duplex].
var autoneg := true
var advertising := 0
var forced_speed := 100
var forced_duplex := "full"

## MAC counters the driver reads: transmit collisions and deferrals.
var counters := {}

## Called with each frame that arrives over the cable. The kernel's driver
## sets it while the machine runs.
var receiver: Callable
## Called with "collision", "late_collision" or "excessive_collisions"
## when the MAC has trouble sending; the driver counts them.
var tx_event: Callable

var cable: AgoraCable
## Frames sent and received, for activity lights.
var frames := 0


func _init() -> void:
	reset_phy()


## What a driver does when it loads: autonegotiation with every mode the
## card has, and fresh counters.
func reset_phy() -> void:
	autoneg = true
	advertising = supported_mask()
	forced_speed = mini(speed_mbps, 100)
	forced_duplex = "full"
	if driver == "hub" or media == "bnc":
		# No autonegotiation: link pulses (or nothing, on coax) at 10, half.
		autoneg = false
		forced_speed = 10
		forced_duplex = "half"
	counters = {
		"tx_deferred": 0, "tx_single_collisions": 0, "tx_multi_collisions": 0,
		"tx_late_collisions": 0, "tx_excessive_collisions": 0,
	}
	if cable:
		cable.negotiate()


## The modes the card supports: everything up to its speed, but no
## 1000baseT/Half (no gigabit chip of the time did it).
func supported_mask() -> int:
	var m := 0
	for mode: Array in MODES:
		if mode[1] <= speed_mbps and mode[0] != "1000baseT/Half":
			m |= mode[3]
	return m


## Changes the PHY settings and renegotiates the link.
func configure(p_autoneg: bool, speed: int, duplex: String, p_advertising: int = -1) -> void:
	autoneg = p_autoneg
	forced_speed = speed
	forced_duplex = duplex
	if p_advertising >= 0:
		advertising = p_advertising & supported_mask()
	if cable:
		cable.negotiate()


var peer: AgoraNic:
	get:
		return cable.other(self) if cable else null


var carrier: bool:
	get:
		if media == "bnc":
			return true # no link detection on coax: the driver always says so
		return cable != null and cable.link_up


## The speed the link runs at, 0 without one.
var link_speed: int:
	get:
		if media == "bnc":
			return 10
		return cable.speed_mbps if carrier else 0


## "full", "half", or "" without a link.
var duplex: String:
	get:
		if media == "bnc":
			return "half"
		return cable.duplex_of(self) if carrier else ""


## Plugs a cable [param length_m] metres long between this port and
## [param other], unplugging whatever was connected to either before.
func plug(other: AgoraNic, length_m: float = 2.0) -> void:
	if other == self:
		return
	unplug()
	other.unplug()
	var c := AgoraCable.new(self, other, length_m)
	cable = c
	other.cable = c
	c.negotiate()


func unplug() -> void:
	var c := cable
	if c == null:
		return
	var other := peer
	var was_up := c.link_up
	if other and other.segment:
		other.segment.detach(self)
	if segment and other:
		segment.detach(other)
	c.cut()
	cable = null
	if other:
		other.cable = null
	if was_up:
		if other:
			other.link_changed.emit(false)
		link_changed.emit(false)


## Frames waiting in the cable's transmit queue from this port.
func queued() -> int:
	if media == "bnc":
		return coax.queued(self) if coax else 0
	return cable.queued(self) if cable else 0


## Puts an Ethernet frame ({dst, src, type, payload, len}) on the cable.
## Returns false without a link. The receiver gets its own copy.
func transmit(frame: Dictionary) -> bool:
	if not carrier:
		return false
	var extra := latency_ms * randf_range(0.85, 1.25) / 1000.0
	frames += 1
	if media == "bnc":
		if coax:
			coax.send(self, frame.duplicate(true), extra)
		else:
			# An open BNC socket: the frame comes straight back, every try.
			counters.tx_excessive_collisions += 1
			_tx_event("excessive_collisions")
		return true
	cable.send(self, frame.duplicate(true), extra)
	return true


func _arrive(frame: Dictionary) -> void:
	frames += 1
	if receiver.is_valid():
		receiver.call(frame)


func _tx_event(kind: String) -> void:
	if tx_event.is_valid():
		tx_event.call(kind)


static func random_mac(vendor: String = "00:16:3e") -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%s:%02x:%02x:%02x" % [vendor, rng.randi() & 255, rng.randi() & 255, rng.randi() & 255]
