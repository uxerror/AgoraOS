class_name AgoraNetStack
extends RefCounted
## The kernel's IPv4 network stack, one per running machine: interfaces,
## addresses and the routing tables. Tools (ip, ifconfig, route) talk to it
## the way real ones use netlink and ioctls; /proc/net and /sys/class/net
## show its state.
##
## Kernel state is not saved: after a boot every interface is down and has
## no address until init scripts configure it.

## Interface flags, as in <linux/if.h>.
const IFF_UP := 0x1
const IFF_BROADCAST := 0x2
const IFF_LOOPBACK := 0x8
const IFF_RUNNING := 0x40
const IFF_MULTICAST := 0x1000
const IFF_LOWER_UP := 0x10000

const ARPHRD_ETHER := 1
const ARPHRD_LOOPBACK := 772

const ETH_P_IP := 0x0800
const ETH_P_ARP := 0x0806
const BROADCAST_MAC := "ff:ff:ff:ff:ff:ff"
const ETH_HLEN := 14
const ETH_ZLEN := 60

## IP protocol numbers.
const IPPROTO_ICMP := 1
const IPPROTO_TCP := 6
const IPPROTO_UDP := 17
const IPDEFTTL := 64
## Time a host takes to handle a packet, added to its "lat" (milliseconds).
const HOST_DELAY_MS := 0.012

const ETH_MIN_MTU := 68
const ETH_MAX_MTU := 1500
const LO_MTU := 65536


## A network interface: lo, one per hardware NIC, or a bridge.
class Iface:
	var name := ""
	var index := 0
	## "loopback", "ether" (a NIC) or "bridge".
	var kind := "ether"
	## The port behind it, null for virtual devices.
	var nic: AgoraNic
	## The bridge this interface is a port of, or "".
	var master := ""
	var port_no := 0
	## "forwarding" or "disabled" while it is a bridge port.
	var port_state := "disabled"
	## Bridges: their ports in order, the forwarding database
	## {mac: {port, updated}}, STP and the ageing time in seconds.
	var ports: PackedStringArray = []
	var fdb := {}
	var stp := false
	var ageing_time := 300.0
	## Users of promiscuous mode (a bridge, tcpdump): the card then accepts
	## every frame, not only those for its address.
	var promisc := 0
	var own_mac := ""
	var _net: WeakRef
	var mtu := ETH_MAX_MTU
	var admin_up := false
	var tx_queue_len := 1000
	## {address, prefix, broadcast (-1 if none), scope, label, secondary}
	var addrs: Array[Dictionary] = []
	var stats := {
		"rx_bytes": 0, "rx_packets": 0, "rx_errors": 0, "rx_dropped": 0,
		"tx_bytes": 0, "tx_packets": 0, "tx_errors": 0, "tx_dropped": 0,
	}

	func is_loopback() -> bool:
		return kind == "loopback"

	func is_bridge() -> bool:
		return kind == "bridge"

	func _port_ifaces() -> Array:
		var net := _net.get_ref() as AgoraNetStack if _net else null
		var out: Array = []
		if net:
			for p in ports:
				var i := net.iface(p)
				if i:
					out.append(i)
		return out

	## Set with ip link set DEV address; the NIC's burned-in address
	## otherwise.
	var mac_override := ""

	var mac: String:
		get:
			if not mac_override.is_empty():
				return mac_override
			if nic:
				return nic.mac
			if is_bridge():
				# A bridge takes the lowest address of its ports, as Linux does.
				var lowest := ""
				for p: Iface in _port_ifaces():
					if lowest.is_empty() or p.mac < lowest:
						lowest = p.mac
				return lowest if not lowest.is_empty() else own_mac
			return "00:00:00:00:00:00"

	## Physical link: a cable plugged in at both ends. The loopback device
	## has a link whenever it is up.
	var carrier: bool:
		get:
			if is_bridge():
				for p: Iface in _port_ifaces():
					if p.port_state == "forwarding":
						return true
				return false
			return admin_up if nic == null else nic.carrier

	## dev->flags: what was configured, as /sys/class/net/*/flags shows.
	func flags() -> int:
		var f := IFF_LOOPBACK if is_loopback() else IFF_BROADCAST | IFF_MULTICAST
		return f | IFF_UP if admin_up else f

	## Flags as reported to ip(8): adds RUNNING and LOWER_UP with a link.
	func link_flags() -> int:
		var f := flags()
		if admin_up and carrier:
			f |= IFF_RUNNING | IFF_LOWER_UP
		return f

	## RFC 2863 operational state: "up", "down" or "unknown" (the loopback
	## device has no real link state to report).
	func operstate() -> String:
		if not admin_up:
			return "down"
		if is_loopback():
			return "unknown"
		return "up" if carrier else "down"

	func primary_addrs() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for a in addrs:
			if not a.secondary:
				out.append(a)
		return out


var interfaces: Array[Iface] = []
## The main routing table, sorted the way the kernel walks it: by
## destination, then prefix length, then metric. Each route is
## {dst, prefix, gateway, dev, metric, proto, scope, src, type}.
var routes: Array[Dictionary] = []
## /proc/sys/net/ipv4/ip_forward and ip_default_ttl.
var ip_forward := false
var default_ttl := IPDEFTTL
var neigh: AgoraNeighbours
var icmp: AgoraIcmp
var bridge: AgoraBridge
var udp: AgoraUdp
var netfilter: AgoraNetfilter
var tcp: AgoraTcp
var captures: Array[AgoraCapture] = []

var _machine: WeakRef
var _protocols := {} # IP protocol number -> Callable(packet, iface)
var _alive := true
var _next_id := 1


func _init(machine: AgoraMachine) -> void:
	_machine = weakref(machine)
	var lo := Iface.new()
	lo.name = "lo"
	lo.index = 1
	lo.kind = "loopback"
	lo.mtu = LO_MTU
	interfaces.append(lo)
	neigh = AgoraNeighbours.new(self)
	bridge = AgoraBridge.new(self)
	icmp = AgoraIcmp.new(self)
	register_protocol(IPPROTO_ICMP, icmp.receive)
	udp = AgoraUdp.new(self)
	netfilter = AgoraNetfilter.new(self)
	tcp = AgoraTcp.new(self)
	register_protocol(IPPROTO_TCP, tcp.receive)
	register_protocol(IPPROTO_UDP, udp.receive)
	var hw := machine.hardware
	if hw == null:
		return
	for n in hw.nics:
		var iface := Iface.new()
		iface.name = n.name
		iface.index = interfaces.size() + 1
		iface.nic = n
		interfaces.append(iface)
		n.link_changed.connect(_on_link_changed.bind(iface))
		n.receiver = _on_frame.bind(iface)


## Drops the hardware hooks. The kernel calls this when it stops.
func detach() -> void:
	_alive = false
	for iface in interfaces:
		if iface.nic and iface.nic.link_changed.is_connected(_on_link_changed):
			iface.nic.link_changed.disconnect(_on_link_changed)
		if iface.nic:
			iface.nic.receiver = Callable()
	neigh.flush("", true)
	tcp.shutdown()
	captures.clear()


func _m() -> AgoraMachine:
	return _machine.get_ref() as AgoraMachine


func _on_link_changed(up: bool, iface: Iface) -> void:
	var m := _m()
	if m and iface.admin_up:
		if up:
			m.klog("%s: link up, %dMbps, full-duplex" % [iface.name, iface.nic.speed_mbps])
		else:
			m.klog("%s: link down" % iface.name)
	if not iface.master.is_empty():
		bridge.update_ports(iface(iface.master))


# --- interfaces ---------------------------------------------------------------

func iface(name: String) -> Iface:
	for i in interfaces:
		if i.name == name:
			return i
	return null


func iface_by_index(index: int) -> Iface:
	for i in interfaces:
		if i.index == index:
			return i
	return null


## ip link set DEV up/down. Taking a link down removes every route through
## it; bringing it up restores the routes of its addresses.
func set_link(name: String, up: bool) -> int:
	var i := iface(name)
	if i == null:
		return AgoraErrno.ENODEV
	if i.admin_up == up:
		return AgoraErrno.OK
	i.admin_up = up
	if up and i.is_loopback() and i.addrs.is_empty():
		# Like Linux, the loopback device gets 127.0.0.1/8 when it comes up.
		i.addrs.append({
			"address": 0x7F000001, "prefix": 8, "broadcast": -1, "scope": "host",
			"label": "lo", "secondary": false,
		})
	if up:
		for a in i.primary_addrs():
			_add_prefix_route(i, a)
		if i.nic and i.carrier:
			_on_link_changed(true, i)
	else:
		routes = routes.filter(func(r: Dictionary) -> bool: return r.dev != name)
		neigh.flush(name)
	if i.is_bridge():
		bridge.update_ports(i)
	elif not i.master.is_empty():
		bridge.update_ports(iface(i.master))
	return AgoraErrno.OK


## ip link add NAME type bridge (brctl addbr).
func add_bridge(name: String) -> int:
	if iface(name) != null:
		return AgoraErrno.EEXIST
	if name.is_empty() or name.length() > 15 or name.contains("/") or name.contains(" "):
		return AgoraErrno.EINVAL
	var b := Iface.new()
	b.name = name
	b.kind = "bridge"
	b._net = weakref(self)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	b.own_mac = "%02x:%02x:%02x:%02x:%02x:%02x" % [(rng.randi() & 0xFE) | 0x02, rng.randi() & 255,
		rng.randi() & 255, rng.randi() & 255, rng.randi() & 255, rng.randi() & 255]
	var top := 0
	for i in interfaces:
		top = maxi(top, i.index)
	b.index = top + 1
	interfaces.append(b)
	return AgoraErrno.OK


## ip link del: removes a virtual device (a bridge), freeing its ports.
func del_link(name: String) -> int:
	var i := iface(name)
	if i == null:
		return AgoraErrno.ENODEV
	if not i.is_bridge():
		return AgoraErrno.EOPNOTSUPP
	for port in i.ports.duplicate():
		set_master(port, "")
	set_link(name, false)
	neigh.flush(name, true)
	interfaces.erase(i)
	return AgoraErrno.OK


## Makes [param port] a port of the bridge [param master] (ip link set
## PORT master BR, brctl addif), or frees it with "".
func set_master(port: String, master: String) -> int:
	var p := iface(port)
	if p == null:
		return AgoraErrno.ENODEV
	if master.is_empty():
		if not p.master.is_empty():
			bridge.remove_port(iface(p.master), p)
		return AgoraErrno.OK
	var b := iface(master)
	if b == null:
		return AgoraErrno.ENODEV
	if not b.is_bridge():
		return AgoraErrno.EOPNOTSUPP
	if p.is_loopback() or p.is_bridge():
		return AgoraErrno.ELOOP if p.is_bridge() else AgoraErrno.EINVAL
	if p.master == master:
		return AgoraErrno.OK
	if not p.master.is_empty():
		return AgoraErrno.EBUSY
	bridge.add_port(b, p)
	return AgoraErrno.OK


## Changes the hardware address the interface uses (ip link set address).
func set_mac(name: String, mac: String) -> int:
	var i := iface(name)
	if i == null:
		return AgoraErrno.ENODEV
	if i.is_loopback() or not is_valid_mac(mac):
		return AgoraErrno.EINVAL
	i.mac_override = mac.to_lower()
	return AgoraErrno.OK


static func is_valid_mac(mac: String) -> bool:
	var parts := mac.split(":")
	if parts.size() != 6:
		return false
	for part in parts:
		if part.length() != 2 or not part.is_valid_hex_number():
			return false
	return true


func set_mtu(name: String, mtu: int) -> int:
	var i := iface(name)
	if i == null:
		return AgoraErrno.ENODEV
	var max_mtu := LO_MTU if i.is_loopback() else ETH_MAX_MTU
	if mtu < ETH_MIN_MTU or mtu > max_mtu:
		return AgoraErrno.EINVAL
	i.mtu = mtu
	return AgoraErrno.OK


# --- addresses ----------------------------------------------------------------

## ip addr add. [param opts]: broadcast (int, default none), scope ("global",
## "link", "host"; 127.0.0.0/8 defaults to host), label.
func add_address(name: String, addr: int, prefix: int, opts: Dictionary = {}) -> int:
	var i := iface(name)
	if i == null:
		return AgoraErrno.ENODEV
	if prefix < 0 or prefix > 32:
		return AgoraErrno.EINVAL
	var secondary := false
	for a in i.addrs:
		if a.prefix == prefix and AgoraInet.in_subnet(a.address, addr, prefix):
			if a.address == addr:
				return AgoraErrno.EEXIST
			secondary = true
	var default_scope := "host" if AgoraInet.in_subnet(addr, 0x7F000000, 8) else "global"
	var entry := {
		"address": addr, "prefix": prefix, "broadcast": opts.get("broadcast", -1),
		"scope": opts.get("scope", default_scope), "label": opts.get("label", name),
		"secondary": secondary,
	}
	i.addrs.append(entry)
	if i.admin_up and not secondary:
		_add_prefix_route(i, entry)
	return AgoraErrno.OK


## ip addr del. Removing a primary address also removes its secondaries,
## as Linux does without promote_secondaries. A [param prefix] of -1
## matches any prefix.
func del_address(name: String, addr: int, prefix: int = -1) -> int:
	var i := iface(name)
	if i == null:
		return AgoraErrno.ENODEV
	var found: Dictionary = {}
	for a in i.addrs:
		if a.address == addr and (prefix < 0 or a.prefix == prefix):
			found = a
			break
	if found.is_empty():
		return AgoraErrno.EADDRNOTAVAIL
	var gone: Array[Dictionary] = [found]
	if not found.secondary:
		for a in i.addrs:
			if a.secondary and a.prefix == found.prefix and AgoraInet.in_subnet(a.address, found.address, found.prefix):
				gone.append(a)
	for a in gone:
		i.addrs.erase(a)
		# Routes that use the address as their source go with it.
		routes = routes.filter(func(r: Dictionary) -> bool: return not (r.dev == name and r.src == a.address))
	return AgoraErrno.OK


## Flushes every address of [param name] (ip addr flush dev DEV).
func flush_addresses(name: String) -> int:
	var i := iface(name)
	if i == null:
		return AgoraErrno.ENODEV
	while not i.addrs.is_empty():
		del_address(name, i.addrs[0].address, i.addrs[0].prefix)
	return AgoraErrno.OK


## True if [param addr] belongs to this machine (on an interface that is up).
func is_local(addr: int) -> bool:
	for i in interfaces:
		if not i.admin_up:
			continue
		for a in i.addrs:
			if a.address == addr:
				return true
			if i.is_loopback() and AgoraInet.in_subnet(addr, a.address, a.prefix):
				return true
	return false


func iface_has_address(i: Iface, addr: int) -> bool:
	for a in i.addrs:
		if a.address == addr:
			return true
	return false


## True if [param addr] is the limited broadcast or the broadcast address
## of a subnet on [param i].
func is_broadcast(i: Iface, addr: int) -> bool:
	if addr == AgoraInet.BROADCAST:
		return true
	for a in i.addrs:
		if a.broadcast == addr or (a.prefix < 31 and AgoraInet.broadcast_of(a.address, a.prefix) == addr):
			return true
	return false


func _add_prefix_route(i: Iface, a: Dictionary) -> void:
	if a.prefix == 32 or a.scope == "host":
		return
	_insert_route({
		"dst": AgoraInet.network(a.address, a.prefix), "prefix": a.prefix, "gateway": 0,
		"dev": i.name, "metric": 0, "proto": "kernel", "scope": "link", "src": a.address,
		"type": "unicast", "onlink": false,
	})


# --- routes -------------------------------------------------------------------

## ip route add. [param opts]: gateway (int), dev, metric, proto ("boot"),
## scope, src, type ("unicast", "blackhole", "unreachable", "prohibit"),
## onlink (bool: trust that the gateway is on the link).
##
## Errors: EEXIST for the same destination and metric, ENETUNREACH if the
## gateway isn't on a connected network, ENETDOWN if the device is down,
## ENODEV without any device.
func add_route(dst: int, prefix: int, opts: Dictionary = {}) -> int:
	if prefix < 0 or prefix > 32:
		return AgoraErrno.EINVAL
	dst = AgoraInet.network(dst, prefix)
	var type: String = opts.get("type", "unicast")
	var gateway: int = opts.get("gateway", 0)
	var dev: String = opts.get("dev", "")
	var metric: int = opts.get("metric", 0)
	var src: int = opts.get("src", 0)
	if src != 0 and not is_local(src):
		return AgoraErrno.EINVAL
	for r in routes:
		if r.dst == dst and r.prefix == prefix and r.metric == metric:
			return AgoraErrno.EEXIST
	if type == "unicast":
		if not dev.is_empty() and iface(dev) == null:
			return AgoraErrno.ENODEV
		if gateway != 0 and not opts.get("onlink", false):
			var via := _connected_route(gateway, dev)
			if via.is_empty():
				return AgoraErrno.ENETUNREACH
			dev = via.dev
		if dev.is_empty():
			return AgoraErrno.ENODEV
		if not iface(dev).admin_up:
			return AgoraErrno.ENETDOWN
	_insert_route({
		"dst": dst, "prefix": prefix, "gateway": gateway, "dev": dev, "metric": metric,
		"proto": opts.get("proto", "boot"),
		"scope": opts.get("scope", "global" if gateway != 0 or type != "unicast" else "link"),
		"src": src, "type": type, "onlink": opts.get("onlink", false),
	})
	return AgoraErrno.OK


## ip route del. Fields given in [param opts] (gateway, dev, metric, type)
## must match too. ESRCH if no route matches.
func del_route(dst: int, prefix: int, opts: Dictionary = {}) -> int:
	dst = AgoraInet.network(dst, prefix)
	for r in routes:
		if r.dst != dst or r.prefix != prefix:
			continue
		if opts.has("gateway") and r.gateway != opts.gateway:
			continue
		if opts.has("dev") and r.dev != opts.dev:
			continue
		if opts.has("metric") and r.metric != opts.metric:
			continue
		if opts.has("type") and r.type != opts.type:
			continue
		routes.erase(r)
		return AgoraErrno.OK
	return AgoraErrno.ESRCH


## A directly connected route (no gateway) covering [param addr], on
## [param dev] if given.
func _connected_route(addr: int, dev: String = "") -> Dictionary:
	var best: Dictionary = {}
	for r in routes:
		if r.gateway != 0 or r.type != "unicast" or not AgoraInet.in_subnet(addr, r.dst, r.prefix):
			continue
		if not dev.is_empty() and r.dev != dev:
			continue
		if best.is_empty() or r.prefix > best.prefix:
			best = r
	return best


func _insert_route(route: Dictionary) -> void:
	var at := 0
	while at < routes.size() and _route_before(routes[at], route):
		at += 1
	routes.insert(at, route)


static func _route_before(a: Dictionary, b: Dictionary) -> bool:
	if a.dst != b.dst:
		return a.dst < b.dst
	if a.prefix != b.prefix:
		return a.prefix < b.prefix
	return a.metric <= b.metric


## The local table, which the kernel keeps for its own addresses: what
## ip route show table local prints.
func local_routes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in interfaces:
		if not i.admin_up:
			continue
		for a in i.addrs:
			var base := {"gateway": 0, "dev": i.name, "metric": 0, "proto": "kernel", "src": a.address, "onlink": false}
			if i.is_loopback() and a.prefix < 32:
				out.append(base.merged({"type": "local", "dst": AgoraInet.network(a.address, a.prefix), "prefix": a.prefix, "scope": "host"}))
			out.append(base.merged({"type": "local", "dst": a.address, "prefix": 32, "scope": "host"}))
			var brd: int = a.broadcast
			if i.is_loopback() and a.prefix < 31:
				brd = AgoraInet.broadcast_of(a.address, a.prefix)
			if brd > 0:
				out.append(base.merged({"type": "broadcast", "dst": brd, "prefix": 32, "scope": "link"}))
	out.sort_custom(_route_before)
	return out


## Where a packet to [param dst] goes: {type, dev, gateway, src}, gateway
## being 0 when the destination is on the link. Local addresses go through
## lo. Returns {} if there is no route (ENETUNREACH).
func lookup(dst: int) -> Dictionary:
	if is_local(dst):
		return {"type": "local", "dev": "lo", "gateway": 0, "src": dst}
	var best: Dictionary = {}
	for r in routes:
		if not AgoraInet.in_subnet(dst, r.dst, r.prefix):
			continue
		var i := iface(r.dev)
		if r.type == "unicast" and (i == null or not i.admin_up):
			continue
		if best.is_empty() or r.prefix > best.prefix or (r.prefix == best.prefix and r.metric < best.metric):
			best = r
	if best.is_empty():
		return {}
	var src: int = best.src if best.src != 0 else select_source(best.dev, best.gateway if best.gateway != 0 else dst)
	return {"type": best.type, "dev": best.dev, "gateway": best.gateway, "src": src}


## Source address for talking to [param dst] through [param dev]: an
## address of the device on the same subnet, else its first global one,
## else any global address of the machine.
func select_source(dev: String, dst: int) -> int:
	var i := iface(dev)
	if i:
		for a in i.primary_addrs():
			if AgoraInet.in_subnet(dst, a.address, a.prefix):
				return a.address
		for a in i.primary_addrs():
			if a.scope == "global":
				return a.address
	for other in interfaces:
		if other.admin_up:
			for a in other.primary_addrs():
				if a.scope == "global":
					return a.address
	return 0


# --- link layer ---------------------------------------------------------------

## Sends an Ethernet frame out of [param i]. [param length] is the size of
## the payload in bytes, for the counters.
# --- capture ------------------------------------------------------------------

## Why the last [method open_capture] failed.
var last_capture_error := AgoraErrno.OK


## Opens a packet socket on [param device] (or "any") for [param p], like
## tcpdump does. Returns null with [member last_capture_error]: EPERM for
## users, ENODEV for an unknown device, ENETDOWN for one that is down.
func open_capture(p: AgoraProcess, device: String, promiscuous: bool) -> AgoraCapture:
	if not p.cred.is_root():
		last_capture_error = AgoraErrno.EPERM
		return null
	var i := iface(device)
	if device != "any":
		if i == null:
			last_capture_error = AgoraErrno.ENODEV
			return null
		if not i.admin_up:
			last_capture_error = AgoraErrno.ENETDOWN
			return null
	var c := AgoraCapture.new()
	c.device = device
	c.promisc = promiscuous and device != "any"
	c.pid = p.pid
	c._stack = weakref(self)
	captures.append(c)
	if c.promisc:
		set_promisc(i, 1)
	last_capture_error = AgoraErrno.OK
	return c


func close_capture(c: AgoraCapture) -> void:
	if not captures.has(c):
		return
	captures.erase(c)
	if c.promisc and iface(c.device):
		set_promisc(iface(c.device), -1)


## Closes the captures of a process that went away.
func close_captures_for(pid: int) -> void:
	for c in captures.duplicate():
		if c.pid == pid:
			close_capture(c)


func set_promisc(i: Iface, delta: int) -> void:
	var was := i.promisc
	i.promisc = maxi(0, i.promisc + delta)
	var m := _m()
	if m and was == 0 and i.promisc > 0:
		m.klog("device %s entered promiscuous mode" % i.name)
	elif m and was > 0 and i.promisc == 0:
		m.klog("device %s left promiscuous mode" % i.name)


## Gives the packet sockets a copy of [param frame], seen on [param i]
## going [param dir].
func _tap(i: Iface, dir: String, frame: Dictionary, otherhost: bool = false) -> void:
	if captures.is_empty():
		return
	var now := _m().clock.now() if _m() else 0.0
	for c in captures:
		if c.device != "any" and c.device != i.name:
			continue
		if c.direction != "inout" and c.direction != dir:
			continue
		c.inbox.append({"time": now, "iface": i.name, "dir": dir, "otherhost": otherhost, "frame": frame.duplicate(true)})


func send_frame(i: Iface, dst_mac: String, type: int, payload: Dictionary, length: int) -> void:
	if not _alive or i == null or not i.admin_up or i.is_loopback():
		return
	var frame := {"dst": dst_mac, "src": i.mac, "type": type, "payload": payload, "len": length}
	if i.is_bridge():
		i.stats.tx_packets += 1
		i.stats.tx_bytes += maxi(ETH_ZLEN, ETH_HLEN + length)
		_tap(i, "out", frame)
		bridge.output(i, frame)
		return
	xmit(i, frame)


## Puts a finished frame on the wire of a NIC.
func xmit(i: Iface, frame: Dictionary) -> void:
	if i.nic == null or not i.admin_up:
		return
	if not i.carrier:
		i.stats.tx_dropped += 1
		return
	i.stats.tx_packets += 1
	i.stats.tx_bytes += maxi(ETH_ZLEN, ETH_HLEN + int(frame.get("len", 0)))
	_tap(i, "out", frame)
	i.nic.transmit(frame)


func _send_ip_frame(i: Iface, dst_mac: String, packet: Dictionary) -> void:
	send_frame(i, dst_mac, ETH_P_IP, packet, packet.len)


## A frame arrived from the cable. The NIC only takes frames addressed to
## it or to everyone.
func _on_frame(frame: Dictionary, i: Iface) -> void:
	if not _alive or not i.admin_up:
		return
	var for_us: bool = frame.dst == i.mac or AgoraBridge.is_multicast(frame.dst)
	if not for_us and i.promisc == 0:
		return # the card's filter
	i.stats.rx_packets += 1
	i.stats.rx_bytes += maxi(ETH_ZLEN, ETH_HLEN + int(frame.get("len", 0)))
	_tap(i, "in", frame, not for_us)
	if not i.master.is_empty():
		# A bridge port takes every frame and hands it to its bridge.
		bridge.input(iface(i.master), i, frame)
		return
	if for_us:
		deliver_frame(i, frame)


## Hands a received frame to ARP or IP on [param i].
func deliver_frame(i: Iface, frame: Dictionary) -> void:
	var payload: Dictionary = frame.payload
	match frame.type:
		ETH_P_ARP:
			neigh.receive(i, payload)
		ETH_P_IP:
			# Tracking marks belong to the sender's kernel.
			payload.erase("_ct")
			payload.erase("_dir")
			payload.erase("_state")
			payload.lat = float(payload.get("lat", 0.0)) + float(frame.get("lat", 0.0)) + HOST_DELAY_MS
			ip_receive(i, payload)
		_:
			i.stats.rx_dropped += 1


# --- IP layer -----------------------------------------------------------------

## Makes an IP datagram. [param data_len] is the size of what it carries;
## [param payload] holds the upper protocol's header and data.
func make_packet(src: int, dst: int, proto: int, payload: Dictionary, data_len: int, ttl: int = -1) -> Dictionary:
	_next_id = (_next_id + 1) & 0xFFFF
	if ttl < 0:
		ttl = default_ttl
	return {"src": src, "dst": dst, "proto": proto, "ttl": ttl, "id": _next_id, "len": 20 + data_len, "payload": payload, "lat": 0.0}


## Hands incoming datagrams of [param proto] to [param handler]
## (packet, iface).
func register_protocol(proto: int, handler: Callable) -> void:
	_protocols[proto] = handler


## Routes and sends a datagram. A zero source address is filled in from
## the route. Returns ENETUNREACH without a route, EHOSTUNREACH or EACCES
## for unreachable and prohibit routes.
func ip_output(packet: Dictionary) -> int:
	if not _alive:
		return AgoraErrno.ENETDOWN
	var r := lookup(packet.dst)
	if r.is_empty():
		return AgoraErrno.ENETUNREACH
	match r.type:
		"blackhole":
			return AgoraErrno.OK
		"unreachable":
			return AgoraErrno.EHOSTUNREACH
		"prohibit":
			return AgoraErrno.EACCES
	if packet.src == 0:
		packet.src = r.src
	var i := iface(r.dev)
	var dst_before: int = packet.dst
	if not netfilter.local_out(packet, i):
		return AgoraErrno.EPERM
	if packet.dst != dst_before:
		# Destination NAT on output: route again.
		r = lookup(packet.dst)
		if r.is_empty():
			return AgoraErrno.ENETUNREACH
		i = iface(r.dev)
	if r.type == "local":
		i = iface("lo")
	if not netfilter.filter("OUTPUT", packet, null, i):
		return AgoraErrno.EPERM
	if not netfilter.postrouting(packet, i):
		return AgoraErrno.EPERM
	if r.type == "local":
		i.stats.tx_packets += 1
		i.stats.tx_bytes += packet.len
		_loopback.call_deferred(packet.duplicate(true))
		return AgoraErrno.OK
	if is_broadcast(i, packet.dst):
		_send_ip_frame(i, BROADCAST_MAC, packet)
	else:
		neigh.output(i, r.gateway if r.gateway != 0 else packet.dst, packet)
	return AgoraErrno.OK


func _loopback(packet: Dictionary) -> void:
	var lo := iface("lo")
	if not _alive or not lo.admin_up:
		return
	lo.stats.rx_packets += 1
	lo.stats.rx_bytes += packet.len
	_tap(lo, "in", {"dst": lo.mac, "src": lo.mac, "type": ETH_P_IP, "payload": packet, "len": packet.len})
	packet.lat = float(packet.get("lat", 0.0)) + HOST_DELAY_MS
	ip_receive(lo, packet)


## A datagram arrived on [param i]: deliver it if it is for this machine.
func ip_receive(i: Iface, packet: Dictionary) -> void:
	if not netfilter.prerouting(packet, i):
		return
	if is_local(packet.dst) or is_broadcast(i, packet.dst):
		if not netfilter.filter("INPUT", packet, i, null):
			return
		netfilter.delivered(packet)
		var handler: Callable = _protocols.get(packet.proto, Callable())
		if handler.is_valid():
			handler.call(packet, i)
		return
	if packet.proto == IPPROTO_UDP and udp.wants_raw(i, int(packet.payload.get("dport", -1))):
		udp.receive(packet, i, true)
		return
	if ip_forward:
		forward(i, packet)
	else:
		netfilter.dropped(packet)


## Routes a datagram that isn't for us on to its destination, as a router
## does: TTL down by one, ICMP errors when it can't go on.
func forward(i: Iface, packet: Dictionary) -> void:
	if packet.ttl <= 1:
		icmp.send_error(packet, AgoraIcmp.TIME_EXCEEDED, 0)
		return
	var r := lookup(packet.dst)
	if r.is_empty():
		icmp.send_error(packet, AgoraIcmp.DEST_UNREACH, AgoraIcmp.NET_UNREACH)
		return
	match r.type:
		"blackhole", "local":
			return
		"unreachable":
			icmp.send_error(packet, AgoraIcmp.DEST_UNREACH, AgoraIcmp.HOST_UNREACH)
			return
		"prohibit":
			icmp.send_error(packet, AgoraIcmp.DEST_UNREACH, AgoraIcmp.PKT_FILTERED)
			return
	var out := iface(r.dev)
	if is_broadcast(out, packet.dst):
		return # directed broadcasts are not forwarded
	var fwd := packet.duplicate(true)
	fwd.ttl -= 1
	if not netfilter.filter("FORWARD", fwd, i, out) or not netfilter.postrouting(fwd, out):
		return
	neigh.output(out, r.gateway if r.gateway != 0 else fwd.dst, fwd)


## Sends a datagram out of [param i] to [param dst_mac] as it is, without
## routing or ARP: broadcasts from 0.0.0.0, a DHCP server's replies.
func send_on(i: Iface, packet: Dictionary, dst_mac: String) -> int:
	if i == null:
		return AgoraErrno.ENODEV
	if not i.admin_up:
		return AgoraErrno.ENETDOWN
	_send_ip_frame(i, dst_mac, packet)
	return AgoraErrno.OK


## The neighbour layer gave up on [param packet] (no ARP answer): tell
## the sender the host is unreachable, as Linux does.
func _link_failure(packet: Dictionary) -> void:
	icmp.send_error(packet, AgoraIcmp.DEST_UNREACH, AgoraIcmp.HOST_UNREACH)
