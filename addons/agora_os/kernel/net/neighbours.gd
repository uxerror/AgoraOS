class_name AgoraNeighbours
extends RefCounted
## The neighbour table (ARP cache) of one network stack, with the state
## machine Linux uses (see ip-neighbour(8)):
##
##   INCOMPLETE  a request was broadcast, no answer yet; packets wait
##   REACHABLE   confirmed recently (by an ARP reply)
##   STALE       not confirmed for a while, still used
##   DELAY       used while stale; probe soon unless confirmed
##   PROBE       unicast requests sent to the known address
##   FAILED      no answer; the waiting packets were dropped
##   PERMANENT   added by hand, never expires
##
## Times are real seconds, like process sleeps.

const ETH_P_ARP := 0x0806
const ARPOP_REQUEST := 1
const ARPOP_REPLY := 2
const ZERO_MAC := "00:00:00:00:00:00"

## Defaults of /proc/sys/net/ipv4/neigh/default/*.
const BASE_REACHABLE_TIME := 30.0
const RETRANS_TIME := 1.0
const DELAY_FIRST_PROBE_TIME := 5.0
const MCAST_SOLICIT := 3
const UCAST_SOLICIT := 3
const UNRES_QLEN := 3

## "dev|ip" -> {ip, dev, mac, state, confirmed, probes, queue, reachable_time}
var _entries := {}
## Addresses that answered an ARP request lately: ip -> MAC.
var _answers := {}
var _stack: WeakRef


func _init(stack: AgoraNetStack) -> void:
	_stack = weakref(stack)


func _net() -> AgoraNetStack:
	return _stack.get_ref() as AgoraNetStack


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func _key(dev: String, ip: int) -> String:
	return "%s|%d" % [dev, ip]


func _after(seconds: float, what: Callable) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		tree.create_timer(seconds).timeout.connect(what)


## Entries sorted by device and address. Expired REACHABLE entries are
## reported as STALE, as the kernel does when it looks at them.
func entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in _entries.values():
		_age(e)
		out.append(e)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.ip < b.ip if a.dev == b.dev else a.dev < b.dev)
	return out


func find(dev: String, ip: int) -> Dictionary:
	var e: Dictionary = _entries.get(_key(dev, ip), {})
	if not e.is_empty():
		_age(e)
	return e


func _age(e: Dictionary) -> void:
	if e.state == "REACHABLE" and _now() - e.confirmed > e.reachable_time:
		e.state = "STALE"


func _new_entry(dev: String, ip: int, state: String) -> Dictionary:
	var e := {
		"ip": ip, "dev": dev, "mac": "", "state": state, "confirmed": 0.0, "probes": 0,
		"queue": [], "reachable_time": BASE_REACHABLE_TIME * randf_range(0.5, 1.5),
	}
	_entries[_key(dev, ip)] = e
	return e


## ip neigh add/replace. [param state] is "PERMANENT", "REACHABLE",
## "STALE" or "NOARP".
func add(dev: String, ip: int, mac: String, state: String = "PERMANENT") -> void:
	var e := find(dev, ip)
	if e.is_empty():
		e = _new_entry(dev, ip, state)
	e.mac = mac
	e.state = state
	e.confirmed = _now()
	_flush_queue(e)


func remove(dev: String, ip: int) -> bool:
	return _entries.erase(_key(dev, ip))


## Drops the entries of [param dev] (all of them if ""). Permanent ones
## stay unless [param permanent_too].
func flush(dev: String = "", permanent_too: bool = false) -> void:
	for k in _entries.keys():
		var e: Dictionary = _entries[k]
		if (dev.is_empty() or e.dev == dev) and (permanent_too or e.state != "PERMANENT"):
			_entries.erase(k)


# --- resolution ---------------------------------------------------------------

## Sends [param packet] (an IP datagram) to the neighbour [param ip] on
## [param iface], asking for its MAC address first if needed.
func output(iface: AgoraNetStack.Iface, ip: int, packet: Dictionary) -> void:
	var e := find(iface.name, ip)
	if e.is_empty() or e.state == "FAILED":
		e = _new_entry(iface.name, ip, "INCOMPLETE")
	match e.state:
		"INCOMPLETE":
			e.queue.append(packet)
			if e.queue.size() > UNRES_QLEN:
				e.queue.pop_front()
			if e.queue.size() == 1 and e.probes == 0:
				_solicit(iface.name, ip, packet.src)
		"STALE":
			e.state = "DELAY"
			_after(DELAY_FIRST_PROBE_TIME, _delay_expired.bind(iface.name, ip, e))
			_net()._send_ip_frame(iface, e.mac, packet)
		_:
			_net()._send_ip_frame(iface, e.mac, packet)


## Broadcasts a who-has request and retries every second.
func _solicit(dev: String, ip: int, src: int) -> void:
	var net := _net()
	var e := find(dev, ip)
	if net == null or e.is_empty() or e.state != "INCOMPLETE":
		return
	if e.probes >= MCAST_SOLICIT:
		_fail(e)
		return
	e.probes += 1
	_send_request(net.iface(dev), ip, src, AgoraNetStack.BROADCAST_MAC)
	_after(RETRANS_TIME, _solicit.bind(dev, ip, src))


func _delay_expired(dev: String, ip: int, e: Dictionary) -> void:
	if _entries.get(_key(dev, ip)) != e or e.state != "DELAY":
		return
	e.state = "PROBE"
	e.probes = 0
	_probe(dev, ip, e)


## Asks the cached address directly whether it is still there.
func _probe(dev: String, ip: int, e: Dictionary) -> void:
	var net := _net()
	if net == null or _entries.get(_key(dev, ip)) != e or e.state != "PROBE":
		return
	if e.probes >= UCAST_SOLICIT:
		_fail(e)
		return
	e.probes += 1
	_send_request(net.iface(dev), ip, 0, e.mac)
	_after(RETRANS_TIME, _probe.bind(dev, ip, e))


func _fail(e: Dictionary) -> void:
	e.state = "FAILED"
	e.mac = ""
	e.probes = 0
	var waiting: Array = e.queue
	e.queue = []
	var net := _net()
	if net:
		for packet: Dictionary in waiting:
			net._link_failure(packet)


func _send_request(iface: AgoraNetStack.Iface, ip: int, src: int, dst_mac: String) -> void:
	var net := _net()
	if iface == null or net == null:
		return
	# The sender address is the packet's source if it belongs to this
	# interface (arp_announce=0), else the interface's own address.
	var spa := src if net.iface_has_address(iface, src) else net.select_source(iface.name, ip)
	net.send_frame(iface, dst_mac, ETH_P_ARP, {
		"op": ARPOP_REQUEST, "sha": iface.mac, "spa": spa, "tha": ZERO_MAC, "tpa": ip,
	}, 28)


func _flush_queue(e: Dictionary) -> void:
	var net := _net()
	var waiting: Array = e.queue
	e.queue = []
	if net == null:
		return
	var iface := net.iface(e.dev)
	for packet: Dictionary in waiting:
		net._send_ip_frame(iface, e.mac, packet)


## Asks whether anyone on [param iface] has [param ip] (an ARP probe, as
## arping or a DHCP server does) and waits up to [param timeout] seconds.
## Returns the MAC address that answered, or "".
func probe(iface: AgoraNetStack.Iface, ip: int, src: int, timeout: float = 1.0) -> String:
	_answers.erase(ip)
	var net := _net()
	net.send_frame(iface, AgoraNetStack.BROADCAST_MAC, ETH_P_ARP, {
		"op": ARPOP_REQUEST, "sha": iface.mac, "spa": src, "tha": ZERO_MAC, "tpa": ip,
	}, 28)
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := _now() + timeout
	while _now() < deadline and not _answers.has(ip) and tree:
		await tree.create_timer(0.016).timeout
	return _answers.get(ip, "")


# --- incoming ARP -------------------------------------------------------------

## Handles an ARP packet that arrived on [param iface]: answers requests
## for our addresses and learns the sender.
func receive(iface: AgoraNetStack.Iface, arp: Dictionary) -> void:
	var net := _net()
	var spa: int = arp.get("spa", 0)
	var tpa: int = arp.get("tpa", 0)
	var sha: String = arp.get("sha", "")
	if arp.op == ARPOP_REPLY:
		_answers[spa] = sha
	# Loopback addresses are never answered for (no route_localnet).
	var for_us: bool = net.is_local(tpa) and not AgoraInet.in_subnet(tpa, 0x7F000000, 8)
	if spa != 0:
		var e := find(iface.name, spa)
		if e.is_empty() and arp.op == ARPOP_REQUEST and for_us:
			e = _new_entry(iface.name, spa, "STALE")
		if not e.is_empty() and e.state != "PERMANENT" and e.state != "NOARP":
			var solicited: bool = arp.op == ARPOP_REPLY and arp.get("tha") == iface.mac
			if solicited and e.state in ["INCOMPLETE", "PROBE", "DELAY", "REACHABLE", "STALE"]:
				e.state = "REACHABLE"
				e.confirmed = _now()
			elif e.state in ["INCOMPLETE", "FAILED"] or e.mac != sha:
				e.state = "STALE"
			e.mac = sha
			e.probes = 0
			_flush_queue(e)
	if arp.op == ARPOP_REQUEST and for_us:
		net.send_frame(iface, sha, ETH_P_ARP, {
			"op": ARPOP_REPLY, "sha": iface.mac, "spa": tpa, "tha": sha, "tpa": spa,
		}, 28)
