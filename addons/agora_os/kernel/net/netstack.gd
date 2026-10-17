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

const ETH_MIN_MTU := 68
const ETH_MAX_MTU := 1500
const LO_MTU := 65536


## A network interface: lo, or one per hardware NIC.
class Iface:
	var name := ""
	var index := 0
	## The port behind it, null for the loopback device.
	var nic: AgoraNic
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
		return nic == null

	var mac: String:
		get:
			return nic.mac if nic else "00:00:00:00:00:00"

	## Physical link: a cable plugged in at both ends. The loopback device
	## has a link whenever it is up.
	var carrier: bool:
		get:
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

var _machine: WeakRef


func _init(machine: AgoraMachine) -> void:
	_machine = weakref(machine)
	var lo := Iface.new()
	lo.name = "lo"
	lo.index = 1
	lo.mtu = LO_MTU
	interfaces.append(lo)
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


## Drops the hardware hooks. The kernel calls this when it stops.
func detach() -> void:
	for iface in interfaces:
		if iface.nic and iface.nic.link_changed.is_connected(_on_link_changed):
			iface.nic.link_changed.disconnect(_on_link_changed)


func _m() -> AgoraMachine:
	return _machine.get_ref() as AgoraMachine


func _on_link_changed(up: bool, iface: Iface) -> void:
	var m := _m()
	if m and iface.admin_up:
		if up:
			m.klog("%s: link up, %dMbps, full-duplex" % [iface.name, iface.nic.speed_mbps])
		else:
			m.klog("%s: link down" % iface.name)


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
	if up:
		for a in i.primary_addrs():
			_add_prefix_route(i, a)
		if i.nic and i.carrier:
			_on_link_changed(true, i)
	else:
		routes = routes.filter(func(r: Dictionary) -> bool: return r.dev != name)
	return AgoraErrno.OK


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


func _add_prefix_route(i: Iface, a: Dictionary) -> void:
	if a.prefix == 32 or a.scope == "host":
		return
	_insert_route({
		"dst": AgoraInet.network(a.address, a.prefix), "prefix": a.prefix, "gateway": 0,
		"dev": i.name, "metric": 0, "proto": "kernel", "scope": "link", "src": a.address,
		"type": "unicast",
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
		"src": opts.get("src", 0), "type": type,
	})
	return AgoraErrno.OK


## ip route del. Fields given in [param opts] (gateway, dev, metric) must
## match too. ESRCH if no route matches.
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
			var base := {"gateway": 0, "dev": i.name, "metric": 0, "proto": "kernel", "src": a.address}
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
