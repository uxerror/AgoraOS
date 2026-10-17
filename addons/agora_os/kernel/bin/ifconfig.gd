extends AgoraProgram
## net-tools ifconfig (the classic 1.60 output, which busybox shares):
## shows interfaces and their aliases (eth0:1), sets addresses, netmasks,
## the MTU and the hardware address, and brings interfaces up or down.

const FLAG_ORDER := [
	[AgoraNetStack.IFF_UP, "UP"], [AgoraNetStack.IFF_BROADCAST, "BROADCAST"],
	[AgoraNetStack.IFF_LOOPBACK, "LOOPBACK"], [AgoraNetStack.IFF_RUNNING, "RUNNING"],
	[AgoraNetStack.IFF_MULTICAST, "MULTICAST"],
]


func summary() -> String:
	return "configure a network interface"


func usage() -> String:
	return "Usage:\n  ifconfig [-a] [-s] <interface> [<address>] [netmask <address>] [broadcast <address>]\n  [mtu <NN>] [hw ether <HW>] [up|down] ..."


func main(p: AgoraProcess) -> int:
	var net := p.machine.net
	var args := p.argv.slice(1)
	var all := false
	while not args.is_empty() and args[0].begins_with("-") and args[0].length() > 1:
		match args[0]:
			"-a": all = true
			"-v", "-s": pass
			_:
				p.errln(usage())
				return 1
		args = args.slice(1)
	if args.is_empty():
		for entry in _entries(net):
			if all or (entry[0] as AgoraNetStack.Iface).admin_up:
				_print(p, entry)
		return 0
	var name := args[0]
	var dev := name.get_slice(":", 0)
	var iface := net.iface(dev)
	if args.size() == 1:
		for entry in _entries(net):
			if entry[1] == name:
				_print(p, entry)
				return 0
		if iface == null:
			p.errln("%s: error fetching interface information: Device not found" % name)
			return 1
		# An alias without an address doesn't exist.
		p.errln("%s: error fetching interface information: Device not found" % name)
		return 1
	if iface == null:
		p.errln("SIOCSIFADDR: No such device")
		return 1
	return _configure(p, net, iface, name, args.slice(1))


## [iface, name, address entry or {}]: the interface itself, then each
## alias label, sorted by name like net-tools does.
static func _entries(net: AgoraNetStack) -> Array:
	var out: Array = []
	for i in net.interfaces:
		var main := {}
		var labels := {}
		for a in i.addrs:
			if a.label == i.name:
				if main.is_empty():
					main = a
			elif not labels.has(a.label):
				labels[a.label] = a
		out.append([i, i.name, main])
		for label: String in labels:
			out.append([i, label, labels[label]])
	out.sort_custom(func(x: Array, y: Array) -> bool: return (x[1] as String).naturalnocasecmp_to(y[1]) < 0)
	return out


static func _bytes(n: int) -> String:
	var units := [[1073741824, "GiB"], [1048576, "MiB"], [1024, "KiB"]]
	for u: Array in units:
		if n > u[0]:
			var tenths := n * 10 / int(u[0])
			return "%d.%d %s" % [tenths / 10, tenths % 10, u[1]]
	return "%d.%d B" % [n, 0]


static func _print(p: AgoraProcess, entry: Array) -> void:
	var i: AgoraNetStack.Iface = entry[0]
	var name: String = entry[1]
	var a: Dictionary = entry[2]
	if i.is_loopback():
		p.outln("%-9s Link encap:Local Loopback  " % name)
	else:
		p.outln("%-9s Link encap:Ethernet  HWaddr %s  " % [name, i.mac.to_upper()])
	if not a.is_empty():
		var line := "          inet addr:%s " % AgoraInet.to_str(a.address)
		if i.flags() & AgoraNetStack.IFF_BROADCAST:
			line += " Bcast:%s " % AgoraInet.to_str(maxi(a.broadcast, 0))
		p.outln(line + " Mask:%s" % AgoraInet.to_str(AgoraInet.mask(a.prefix)))
	var flags := ""
	var f := i.link_flags()
	for pair: Array in FLAG_ORDER:
		if f & pair[0]:
			flags += pair[1] + " "
	p.outln("          %s MTU:%d  Metric:1" % [flags, i.mtu])
	if name == i.name:
		var st := i.stats
		p.outln("          RX packets:%d errors:%d dropped:%d overruns:0 frame:0" % [st.rx_packets, st.rx_errors, st.rx_dropped])
		p.outln("          TX packets:%d errors:%d dropped:%d overruns:0 carrier:0" % [st.tx_packets, st.tx_errors, st.tx_dropped])
		p.outln("          collisions:0 txqueuelen:%d " % i.tx_queue_len)
		p.outln("          RX bytes:%d (%s)  TX bytes:%d (%s)" % [st.rx_bytes, _bytes(st.rx_bytes), st.tx_bytes, _bytes(st.tx_bytes)])
	p.outln()


## The netmask a classful network would have: /8, /16 or /24.
static func _classful_prefix(addr: int) -> int:
	var first := addr >> 24
	if first < 128:
		return 8
	if first < 192:
		return 16
	return 24


func _configure(p: AgoraProcess, net: AgoraNetStack, iface: AgoraNetStack.Iface, label: String, args: PackedStringArray) -> int:
	# Collect the changes first, then apply them in one go.
	var addr := -1
	var prefix := -1
	var broadcast := -1
	var up := -1
	var mtu := -1
	var mac := ""
	var i := 0
	while i < args.size():
		var a := args[i]
		var v := args[i + 1] if i + 1 < args.size() else ""
		match a:
			"up":
				up = 1
			"down":
				up = 0
			"netmask", "broadcast", "mtu":
				if v.is_empty():
					p.errln(usage())
					return 1
				if a == "mtu":
					if not v.is_valid_int():
						p.errln("SIOCSIFMTU: Invalid argument")
						return 1
					mtu = int(v)
				else:
					var n := AgoraInet.parse(v)
					if n < 0:
						p.errln("%s: Unknown host" % v)
						return 1
					if a == "netmask":
						prefix = AgoraInet.prefix_of_mask(n)
						if prefix < 0:
							p.errln("SIOCSIFNETMASK: Invalid argument")
							return 1
					else:
						broadcast = n
				i += 1
			"hw":
				if v != "ether" or i + 2 >= args.size():
					p.errln("hw: unknown hardware type")
					return 1
				mac = args[i + 2]
				if not AgoraNetStack.is_valid_mac(mac):
					p.errln("%s: invalid ether address." % mac)
					return 1
				i += 2
			"arp", "-arp", "multicast", "-multicast", "promisc", "-promisc", "allmulti", "-allmulti":
				pass
			_:
				var cidr := AgoraInet.parse_cidr(a, -1)
				if cidr.is_empty():
					p.errln("%s: Unknown host" % a)
					return 1
				addr = cidr[0]
				if cidr[1] >= 0:
					prefix = cidr[1]
		i += 1
	if not p.cred.is_root():
		var what := "SIOCSIFADDR" if addr >= 0 else "SIOCSIFNETMASK" if prefix >= 0 else "SIOCSIFMTU" if mtu >= 0 else "SIOCSIFHWADDR" if not mac.is_empty() else "SIOCSIFFLAGS"
		p.errln("%s: Permission denied" % what)
		return 1
	var alias := label != iface.name
	var current: Dictionary = {}
	for a in iface.addrs:
		if a.label == label:
			current = a
			break
	if not mac.is_empty():
		if iface.admin_up:
			p.errln("SIOCSIFHWADDR: Device or resource busy")
			return 1
		net.set_mac(iface.name, mac)
	if mtu >= 0 and net.set_mtu(iface.name, mtu) != AgoraErrno.OK:
		p.errln("SIOCSIFMTU: Invalid argument")
		return 1
	if addr == 0:
		# "ifconfig eth0 0.0.0.0" removes the address (and, like any
		# address change, brings the interface up).
		if not current.is_empty():
			net.del_address(iface.name, current.address, current.prefix)
		addr = -1
		current = {}
		if up != 0:
			up = 1
	if addr >= 0 or ((prefix >= 0 or broadcast >= 0) and not current.is_empty()):
		var new_addr: int = addr if addr >= 0 else current.address
		var new_prefix := prefix
		if new_prefix < 0:
			new_prefix = current.prefix if not current.is_empty() and addr < 0 else _classful_prefix(new_addr)
		var new_brd := broadcast if broadcast >= 0 else AgoraInet.broadcast_of(new_addr, new_prefix)
		if not current.is_empty():
			net.del_address(iface.name, current.address, current.prefix)
		var code := net.add_address(iface.name, new_addr, new_prefix, {"broadcast": new_brd, "label": label})
		if code != AgoraErrno.OK:
			p.errln("SIOCSIFADDR: " + AgoraErrno.describe(code))
			return 1
		if addr >= 0 and up != 0:
			up = 1 # setting an address brings the interface up
	if up == 0 and alias:
		# Taking an alias down removes it.
		if not current.is_empty():
			net.del_address(iface.name, current.address, current.prefix)
	elif up >= 0:
		net.set_link(iface.name, up == 1)
	return 0
