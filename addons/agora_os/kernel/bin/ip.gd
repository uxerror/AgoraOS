extends AgoraProgram
## iproute2's ip: shows and changes links, addresses, routes and the
## neighbour table. Syntax, messages and output follow iproute2 5.10.

const OBJECTS: PackedStringArray = ["address", "route", "neighbor", "neighbour", "link", "help"]
const SCOPES: PackedStringArray = ["global", "site", "link", "host"]
const ROUTE_TYPES: PackedStringArray = ["unicast", "blackhole", "unreachable", "prohibit"]
const NUD_STATES: PackedStringArray = ["permanent", "noarp", "reachable", "stale", "none", "incomplete", "delay", "probe", "failed"]

const USAGE := """Usage: ip [ OPTIONS ] OBJECT { COMMAND | help }
where  OBJECT := { link | address | route | neighbour }
       OPTIONS := { -s[tatistics] | -4 | -6 | -0 | -br[ief] | -o[neline] |
                    -c[olor] | -d[etails] }"""

var _p: AgoraProcess
var _net: AgoraNetStack
var _stats := 0
var _brief := false
var _oneline := false
var _family := 0 # 0 any, 4 inet, 6 inet6, -1 link only


func summary() -> String:
	return "show and change network links, addresses, routes and neighbours"


func usage() -> String:
	return USAGE


## iproute2's matches(): [param word] abbreviates [param full].
static func _matches(word: String, full: String) -> bool:
	return not word.is_empty() and full.begins_with(word)


func main(p: AgoraProcess) -> int:
	_p = p
	_net = p.machine.net
	var args := p.argv.slice(1)
	while not args.is_empty() and args[0].begins_with("-") and args[0].length() > 1:
		var opt := args[0].trim_prefix("-").trim_prefix("-")
		args = args.slice(1)
		if _matches(opt, "statistics"):
			_stats += 1
		elif opt == "ss":
			_stats += 2
		elif _matches(opt, "brief") and opt.length() >= 2:
			_brief = true
		elif _matches(opt, "oneline"):
			_oneline = true
		elif opt == "4":
			_family = 4
		elif opt == "6":
			_family = 6
		elif opt == "0":
			_family = -1
		elif _matches(opt, "color") or _matches(opt, "details") or _matches(opt, "human"):
			pass
		elif _matches(opt, "help"):
			p.outln(USAGE)
			return 0
		else:
			p.errln('Option "-%s" is unknown, try "ip -help".' % opt)
			return 255
	if args.is_empty():
		p.errln(USAGE)
		return 255
	var object := ""
	for o in OBJECTS:
		if _matches(args[0], o):
			object = o
			break
	var rest := args.slice(1)
	match object:
		"link": return _link(rest)
		"address": return _addr(rest)
		"route": return _route(rest)
		"neighbor", "neighbour": return _neigh(rest)
		"help":
			p.outln(USAGE)
			return 0
	p.errln('Object "%s" is unknown, try "ip help".' % args[0])
	return 1


func _is_show(cmd: String) -> bool:
	return _matches(cmd, "show") or _matches(cmd, "list") or cmd == "lst"


func _unknown_command(cmd: String, object: String) -> int:
	_p.errln('Command "%s" is unknown, try "ip %s help".' % [cmd, object])
	return 255


func _rtnl_error(code: int) -> int:
	_p.errln("RTNETLINK answers: " + AgoraErrno.describe(code))
	return 2


func _need_root() -> bool:
	if _p.cred.is_root():
		return true
	_rtnl_error(AgoraErrno.EPERM)
	return false


func _no_device(dev: String) -> int:
	_p.errln('Cannot find device "%s"' % dev)
	return 1


func _incomplete() -> int:
	_p.errln('Command line is not complete. Try option "help"')
	return 255


## Parses "10.0.0.0/8", "10.1.2.3" or "default". Prints iproute2's error
## and returns [] if malformed.
func _prefix_arg(text: String, what: String = "inet prefix") -> Array:
	if text in ["default", "all", "any"]:
		return [0, 0]
	var cidr := AgoraInet.parse_cidr(text)
	if cidr.is_empty():
		_p.errln('Error: %s is expected rather than "%s".' % [what, text])
	return cidr


func _addr_arg(text: String) -> int:
	var a := AgoraInet.parse(text)
	if a < 0:
		_p.errln('Error: inet address is expected rather than "%s".' % text)
	return a


# --- shared formatting ----------------------------------------------------------

static func flag_names(i: AgoraNetStack.Iface) -> String:
	var f := i.link_flags()
	var names: PackedStringArray = []
	if f & AgoraNetStack.IFF_UP and not f & AgoraNetStack.IFF_RUNNING:
		names.append("NO-CARRIER")
	for pair: Array in [[AgoraNetStack.IFF_LOOPBACK, "LOOPBACK"], [AgoraNetStack.IFF_BROADCAST, "BROADCAST"],
			[AgoraNetStack.IFF_MULTICAST, "MULTICAST"], [AgoraNetStack.IFF_UP, "UP"], [AgoraNetStack.IFF_LOWER_UP, "LOWER_UP"]]:
		if f & pair[0]:
			names.append(pair[1])
	return ",".join(names)


static func _qdisc(i: AgoraNetStack.Iface) -> String:
	if not i.admin_up:
		return "noop"
	return "pfifo_fast" if i.nic else "noqueue"


func _link_header(i: AgoraNetStack.Iface, with_mode: bool) -> String:
	var master := "master %s " % i.master if not i.master.is_empty() else ""
	return "%d: %s: <%s> mtu %d qdisc %s %sstate %s %sgroup default qlen %d" % [
		i.index, i.name, flag_names(i), i.mtu, _qdisc(i), master, i.operstate().to_upper(),
		"mode DEFAULT " if with_mode else "", i.tx_queue_len]


func _link_ether(i: AgoraNetStack.Iface) -> String:
	if i.is_loopback():
		return "    link/loopback %s brd 00:00:00:00:00:00" % i.mac
	return "    link/ether %s brd ff:ff:ff:ff:ff:ff" % i.mac


func _link_stats(i: AgoraNetStack.Iface) -> PackedStringArray:
	var st := i.stats
	var row := func(values: Array) -> String:
		return "    %-10s %-8s %-7s %-7s %-7s %-7s " % values
	# -s -s adds the error details under each direction, as iproute2 5.10.
	var details := func(values: Array) -> String:
		var line := "               %-8s " % values[0]
		for v: int in values.slice(1):
			line += "%-7s " % v
		return line
	var lines: PackedStringArray = [
		"    RX: bytes  packets  errors  dropped overrun mcast   ",
		row.call([st.rx_bytes, st.rx_packets, st.rx_errors, st.rx_dropped,
			st.rx_over_errors, st.multicast]),
	]
	if _stats > 1:
		lines.append("    RX errors: length   crc     frame   fifo    missed")
		lines.append(details.call([st.rx_length_errors, st.rx_crc_errors, st.rx_frame_errors,
			st.rx_fifo_errors, st.rx_missed_errors]))
	lines.append("    TX: bytes  packets  errors  dropped carrier collsns ")
	lines.append(row.call([st.tx_bytes, st.tx_packets, st.tx_errors, st.tx_dropped,
		st.tx_carrier_errors, st.collisions]))
	if _stats > 1:
		lines.append("    TX errors: aborted  fifo   window heartbeat transns")
		lines.append(details.call([st.tx_aborted_errors, st.tx_fifo_errors, st.tx_window_errors,
			st.tx_heartbeat_errors, i.carrier_changes]))
	return lines


func _emit(lines: PackedStringArray) -> void:
	if _oneline:
		_p.outln("\\".join(lines))
	else:
		for line in lines:
			_p.outln(line)


## Picks the interfaces a show command is about: "dev NAME", a bare NAME
## or "up". Returns null after printing an error.
func _select_ifaces(args: PackedStringArray) -> Variant:
	var only := ""
	var up_only := false
	var master := ""
	var type := ""
	var i := 0
	while i < args.size():
		var a := args[i]
		if a in ["dev", "master", "type"] and i + 1 < args.size():
			match a:
				"dev": only = args[i + 1]
				"master": master = args[i + 1]
				"type": type = args[i + 1]
			i += 1
		elif a == "up":
			up_only = true
		elif a in ["primary", "secondary", "dynamic", "permanent"]:
			pass
		else:
			only = a
		i += 1
	if not only.is_empty() and _net.iface(only) == null:
		_p.errln('Device "%s" does not exist.' % only)
		return null
	if not master.is_empty() and _net.iface(master) == null:
		_p.errln('Device "%s" does not exist.' % master)
		return null
	var out: Array[AgoraNetStack.Iface] = []
	for iface in _net.interfaces:
		if (only.is_empty() or iface.name == only) and (not up_only or iface.admin_up) \
				and (master.is_empty() or iface.master == master) and (type.is_empty() or iface.kind == type):
			out.append(iface)
	return out


# --- ip link --------------------------------------------------------------------

func _link(args: PackedStringArray) -> int:
	var cmd := args[0] if not args.is_empty() else "show"
	if _is_show(cmd):
		var sel: Variant = _select_ifaces(args.slice(1))
		if sel == null:
			return 1
		for i: AgoraNetStack.Iface in sel:
			if _brief:
				_p.outln("%-16s %-14s %s <%s> " % [i.name, i.operstate().to_upper(), i.mac, flag_names(i)])
				continue
			var lines := PackedStringArray([_link_header(i, true), _link_ether(i)])
			if _stats > 0:
				lines.append_array(_link_stats(i))
			_emit(lines)
		return 0
	if _matches(cmd, "set"):
		return _link_set(args.slice(1))
	if cmd == "add":
		return _link_add(args.slice(1))
	if _matches(cmd, "delete"):
		return _link_del(args.slice(1))
	if _matches(cmd, "help"):
		_p.outln("Usage: ip link set { DEVICE | dev DEVICE } [ { up | down } ]\n\t\t[ address LLADDR ] [ mtu MTU ]\n\t\t[ txqueuelen PACKETS ]\n       ip link show [ DEVICE | up ]")
		return 0
	return _unknown_command(cmd, "link")


func _link_add(args: PackedStringArray) -> int:
	var name := ""
	var type := ""
	var i := 0
	while i < args.size():
		match args[i]:
			"name", "dev":
				if i + 1 >= args.size():
					return _incomplete()
				name = args[i + 1]
				i += 1
			"type":
				if i + 1 >= args.size():
					return _incomplete()
				type = args[i + 1]
				i += 1
			_:
				name = args[i]
		i += 1
	if name.is_empty():
		_p.errln('Not enough information: "dev" argument is required.')
		return 255
	if type.is_empty():
		_p.errln("Not enough information: \"type\" argument is required")
		return 255
	if not _need_root():
		return 2
	if type != "bridge":
		_p.errln("Error: Unknown device type.")
		return 2
	var code := _net.add_bridge(name)
	return _rtnl_error(code) if code != AgoraErrno.OK else 0


func _link_del(args: PackedStringArray) -> int:
	var name := ""
	for a in args:
		if a != "dev":
			name = a
	if name.is_empty():
		_p.errln('Not enough information: "dev" argument is required.')
		return 255
	if _net.iface(name) == null:
		return _no_device(name)
	if not _need_root():
		return 2
	var code := _net.del_link(name)
	return _rtnl_error(code) if code != AgoraErrno.OK else 0


func _link_set(args: PackedStringArray) -> int:
	var dev := ""
	var changes: Array = []
	var i := 0
	while i < args.size():
		var a := args[i]
		match a:
			"up", "down", "nomaster":
				changes.append([a])
			"mtu", "address", "master", "txqueuelen", "qlen", "txqlen":
				if i + 1 >= args.size():
					return _incomplete()
				changes.append(["txqueuelen" if a in ["qlen", "txqlen"] else a, args[i + 1]])
				i += 1
			"dev":
				if i + 1 >= args.size():
					return _incomplete()
				dev = args[i + 1]
				i += 1
			_:
				if not dev.is_empty():
					_p.errln('Error: either "dev" is duplicate, or "%s" is a garbage.' % a)
					return 255
				dev = a
		i += 1
	if dev.is_empty():
		_p.errln('Not enough information: "dev" argument is required.')
		return 255
	var iface := _net.iface(dev)
	if iface == null:
		return _no_device(dev)
	for c: Array in changes:
		if c[0] == "mtu" and not (c[1] as String).is_valid_int():
			_p.errln('Error: argument "%s" is wrong: Invalid "mtu" value' % c[1])
			return 255
		if c[0] == "txqueuelen" and (not (c[1] as String).is_valid_int() or int(c[1]) < 0):
			_p.errln('Error: argument "%s" is wrong: Invalid "txqueuelen" value' % c[1])
			return 255
		if c[0] == "address" and not AgoraNetStack.is_valid_mac(c[1]):
			_p.errln('Error: "%s" is invalid lladdr.' % c[1])
			return 255
		if c[0] == "master" and _net.iface(c[1]) == null:
			_p.errln('Device "%s" does not exist.' % c[1])
			return 1
	if not _need_root():
		return 2
	for c: Array in changes:
		match c[0]:
			"master", "nomaster":
				var code := _net.set_master(dev, c[1] if c[0] == "master" else "")
				if code != AgoraErrno.OK:
					return _rtnl_error(code)
			"up", "down":
				_net.set_link(dev, c[0] == "up")
			"mtu":
				var mtu := int(c[1])
				if _net.set_mtu(dev, mtu) != AgoraErrno.OK:
					_p.errln("Error: mtu %s device %s." % ["less than" if mtu < AgoraNetStack.ETH_MIN_MTU else "greater than", "minimum" if mtu < AgoraNetStack.ETH_MIN_MTU else "maximum"])
					return 2
			"txqueuelen":
				iface.tx_queue_len = int(c[1])
			"address":
				var code := _net.set_mac(dev, c[1])
				if code != AgoraErrno.OK:
					return _rtnl_error(code)
	return 0


# --- ip address -----------------------------------------------------------------

func _addr(args: PackedStringArray) -> int:
	var cmd := args[0] if not args.is_empty() else "show"
	if _is_show(cmd):
		return _addr_show(args.slice(1))
	if cmd == "add" or _matches(cmd, "replace") or _matches(cmd, "change"):
		return _addr_change(args.slice(1), cmd)
	if _matches(cmd, "delete"):
		return _addr_change(args.slice(1), "del")
	if _matches(cmd, "flush"):
		return _addr_flush(args.slice(1))
	if _matches(cmd, "help"):
		_p.outln("Usage: ip address {add|change|replace} IFADDR dev IFNAME [ LIFETIME ]\n                                                      [ CONFFLAG-LIST ]\n       ip address del IFADDR dev IFNAME [mngtmpaddr]\n       ip address {save|flush} [ dev IFNAME ] [ scope SCOPE-ID ]\n                            [ to PREFIX ] [ FLAG-LIST ] [ label LABEL ] [up]\n       ip address [ show [ dev IFNAME ] [ scope SCOPE-ID ] [ master DEVICE ]\n                         [ type TYPE ] [ to PREFIX ] [ FLAG-LIST ]\n                         [ label LABEL ] [up] [ vrf NAME ] ]")
		return 0
	return _unknown_command(cmd, "address")


func _addr_line(i: AgoraNetStack.Iface, a: Dictionary) -> String:
	var text := "    inet %s/%d" % [AgoraInet.to_str(a.address), a.prefix]
	if a.broadcast > 0:
		text += " brd " + AgoraInet.to_str(a.broadcast)
	text += " scope " + a.scope
	if a.secondary:
		text += " secondary"
	if a.get("valid_until", -1.0) >= 0.0:
		text += " dynamic"
	return text + " " + a.label


func _lifetime_line(a: Dictionary) -> String:
	var until: float = a.get("valid_until", -1.0)
	if until < 0.0:
		return "       valid_lft forever preferred_lft forever"
	var left := maxi(0, int(until - _p.machine.clock.now()))
	return "       valid_lft %dsec preferred_lft %dsec" % [left, left]


func _addr_show(args: PackedStringArray) -> int:
	var sel: Variant = _select_ifaces(args)
	if sel == null:
		return 1
	for i: AgoraNetStack.Iface in sel:
		if _family == 6 or (_family == 4 and i.addrs.is_empty()):
			continue
		if _brief:
			var text := "%-16s %-14s " % [i.name, i.operstate().to_upper()]
			for a in i.addrs:
				text += "%s/%d " % [AgoraInet.to_str(a.address), a.prefix]
			_p.outln(text)
			continue
		if _oneline:
			for a in i.addrs:
				_p.outln("%d: %s%s\\%s" % [i.index, i.name, _addr_line(i, a), _lifetime_line(a)])
			continue
		var lines := PackedStringArray([_link_header(i, false)])
		if _family != 4:
			lines.append(_link_ether(i))
		for a in i.addrs:
			lines.append(_addr_line(i, a))
			lines.append(_lifetime_line(a))
		if _stats > 0:
			lines.append_array(_link_stats(i))
		_emit(lines)
	return 0


func _addr_change(args: PackedStringArray, cmd: String) -> int:
	var dev := ""
	var local: Array = []
	var opts := {}
	var brd_mode := ""
	var i := 0
	while i < args.size():
		var a := args[i]
		if a in ["dev", "brd", "broadcast", "label", "scope", "local", "valid_lft", "preferred_lft"]:
			if i + 1 >= args.size():
				return _incomplete()
			var v := args[i + 1]
			i += 1
			match a:
				"dev": dev = v
				"label": opts.label = v
				"scope":
					if not SCOPES.has(v):
						_p.errln('Error: argument "%s" is wrong: invalid scope value.' % v)
						return 255
					opts.scope = v
				"brd", "broadcast":
					if v == "+" or v == "-":
						brd_mode = v
					else:
						var b := _addr_arg(v)
						if b < 0:
							return 1
						opts.broadcast = b
				"local":
					local = _prefix_arg(v)
					if local.is_empty():
						return 1
		elif a in ["noprefixroute", "home", "nodad"]:
			pass
		else:
			if not local.is_empty():
				_p.errln('Error: either "local" is duplicate, or "%s" is a garbage.' % a)
				return 255
			local = _prefix_arg(a)
			if local.is_empty():
				return 1
		i += 1
	if dev.is_empty():
		_p.errln('Not enough information: "dev" argument is required.')
		return 255
	if local.is_empty():
		return _rtnl_error(AgoraErrno.EINVAL)
	if opts.has("label") and not (opts.label as String).begins_with(dev):
		_p.errln('"dev" (%s) must match "label" (%s).' % [dev, opts.label])
		return 1
	if _net.iface(dev) == null:
		return _no_device(dev)
	if not _need_root():
		return 2
	var addr: int = local[0]
	var prefix: int = local[1]
	if cmd == "del":
		var has_prefix := false
		for a in args:
			if a.contains("/"):
				has_prefix = true
		if not has_prefix:
			_p.errln("Warning: Executing wildcard deletion to stay compatible with old scripts.\n         Explicitly specify the prefix length (%s/32) to avoid this warning.\n         This special behaviour is likely to disappear in further releases,\n         fix your scripts!" % AgoraInet.to_str(addr))
			prefix = -1
		var code := _net.del_address(dev, addr, prefix)
		return _rtnl_error(code) if code != AgoraErrno.OK else 0
	if brd_mode == "+":
		opts.broadcast = AgoraInet.broadcast_of(addr, prefix)
	elif brd_mode == "-":
		opts.broadcast = AgoraInet.network(addr, prefix)
	if cmd != "add":
		# replace and change update an existing address in place.
		_net.del_address(dev, addr, prefix)
	var code := _net.add_address(dev, addr, prefix, opts)
	return _rtnl_error(code) if code != AgoraErrno.OK else 0


func _addr_flush(args: PackedStringArray) -> int:
	if args.is_empty():
		_p.errln("Flush requires arguments.")
		return 1
	var label := ""
	var rest: PackedStringArray = []
	var k := 0
	while k < args.size():
		if args[k] == "label" and k + 1 < args.size():
			label = args[k + 1]
			k += 2
			continue
		rest.append(args[k])
		k += 1
	var sel: Variant = _select_ifaces(rest)
	if sel == null:
		return 1
	if not _need_root():
		return 2
	for i: AgoraNetStack.Iface in sel:
		if label.is_empty():
			_net.flush_addresses(i.name)
			continue
		for a in i.addrs.duplicate():
			if a.label == label and i.addrs.has(a):
				_net.del_address(i.name, a.address, a.prefix)
	return 0


# --- ip route -------------------------------------------------------------------

func _route(args: PackedStringArray) -> int:
	var cmd := args[0] if not args.is_empty() else "show"
	if _is_show(cmd):
		return _route_show(args.slice(1))
	if cmd == "add" or _matches(cmd, "replace") or _matches(cmd, "change") or cmd == "append":
		return _route_change(args.slice(1), cmd)
	if _matches(cmd, "delete"):
		return _route_change(args.slice(1), "del")
	if _matches(cmd, "get"):
		return _route_get(args.slice(1))
	if _matches(cmd, "flush"):
		return _route_flush(args.slice(1))
	if _matches(cmd, "help"):
		_p.outln("Usage: ip route { list | flush } SELECTOR\n       ip route get ADDRESS [ from ADDRESS ] [ oif STRING ]\n       ip route { add | del | change | append | replace } ROUTE\nSELECTOR := [ root PREFIX ] [ match PREFIX ] [ exact PREFIX ]\n            [ table TABLE_ID ] [ proto RTPROTO ] [ type TYPE ] [ scope SCOPE ]\nROUTE := NODE_SPEC [ INFO_SPEC ]\nNODE_SPEC := [ TYPE ] PREFIX [ metric METRIC ]\nINFO_SPEC := NH [ src ADDRESS ] [ proto RTPROTO ] [ scope SCOPE ]\nNH := [ via ADDRESS ] [ dev STRING ] [ onlink ]\nTYPE := { unicast | unreachable | blackhole | prohibit }")
		return 0
	return _unknown_command(cmd, "route")


## One route as ip route prints it. Fields matched by the filter (the
## device, the table) are left out.
func _route_text(r: Dictionary, show_dev: bool, table: String) -> String:
	var parts: PackedStringArray = []
	if r.type != "unicast":
		parts.append(r.type)
	parts.append("default" if r.prefix == 0 else AgoraInet.cidr_str(r.dst, r.prefix))
	if r.gateway != 0:
		parts.append("via " + AgoraInet.to_str(r.gateway))
	if show_dev and not r.dev.is_empty():
		parts.append("dev " + r.dev)
	if not table.is_empty():
		parts.append("table " + table)
	if r.proto != "boot":
		parts.append("proto " + r.proto)
	if r.scope != "global":
		parts.append("scope " + r.scope)
	if r.src != 0:
		parts.append("src " + AgoraInet.to_str(r.src))
	if r.metric != 0:
		parts.append("metric %d" % r.metric)
	if r.get("onlink", false):
		parts.append("onlink")
	var i := _net.iface(r.dev)
	if r.type == "unicast" and i and not i.carrier:
		parts.append("linkdown")
	return " ".join(parts)


func _route_show(args: PackedStringArray) -> int:
	var table := "main"
	var dev := ""
	var proto := ""
	var scope := ""
	var type := ""
	var exact: Array = []
	var i := 0
	while i < args.size():
		var a := args[i]
		if a in ["table", "dev", "proto", "scope", "type", "root", "match", "exact", "oif"]:
			if i + 1 >= args.size():
				return _incomplete()
			var v := args[i + 1]
			i += 1
			match a:
				"table": table = v
				"dev", "oif": dev = v
				"proto": proto = v
				"scope": scope = v
				"type": type = v
				_:
					exact = _prefix_arg(v)
					if exact.is_empty():
						return 1
		elif ROUTE_TYPES.has(a):
			type = a
		else:
			exact = _prefix_arg(a)
			if exact.is_empty():
				return 1
		i += 1
	if not table in ["main", "local", "all", "254", "255", "0"]:
		_p.errln('Error: argument "%s" is wrong: "table" value is invalid' % table)
		return 255
	if not dev.is_empty() and _net.iface(dev) == null:
		_p.errln('Cannot find device "%s"' % dev)
		return 1
	var tables: Array = []
	if table in ["main", "254", "all", "0"]:
		tables.append(["main", _net.routes])
	if table in ["local", "255", "all", "0"]:
		tables.append(["local", _net.local_routes()])
	for t: Array in tables:
		for r: Dictionary in t[1]:
			if not dev.is_empty() and r.dev != dev:
				continue
			if not proto.is_empty() and r.proto != proto:
				continue
			if not scope.is_empty() and r.scope != scope:
				continue
			if not type.is_empty() and r.type != type:
				continue
			if not exact.is_empty() and (r.dst != AgoraInet.network(exact[0], exact[1]) or r.prefix != exact[1]):
				continue
			_p.outln(_route_text(r, dev.is_empty(), t[0] if table in ["all", "0"] and t[0] != "main" else ""))
	return 0


func _route_change(args: PackedStringArray, cmd: String) -> int:
	var opts := {}
	var dst: Array = []
	var i := 0
	while i < args.size():
		var a := args[i]
		if a in ["via", "dev", "oif", "metric", "priority", "preference", "proto", "protocol", "src", "scope", "table", "to"]:
			if i + 1 >= args.size():
				return _incomplete()
			var v := args[i + 1]
			i += 1
			match a:
				"via":
					var gw := _addr_arg(v)
					if gw < 0:
						return 1
					opts.gateway = gw
				"dev", "oif":
					opts.dev = v
				"metric", "priority", "preference":
					if not v.is_valid_int() or int(v) < 0:
						_p.errln('Error: argument "%s" is wrong: "metric" value is invalid' % v)
						return 255
					opts.metric = int(v)
				"proto", "protocol":
					opts.proto = v
				"src":
					var src := _addr_arg(v)
					if src < 0:
						return 1
					opts.src = src
				"scope":
					if not SCOPES.has(v):
						_p.errln('Error: argument "%s" is wrong: invalid "scope" value' % v)
						return 255
					opts.scope = v
				"table":
					if not v in ["main", "254"]:
						_p.errln('Error: argument "%s" is wrong: "table" value is invalid' % v)
						return 255
				"to":
					dst = _prefix_arg(v)
					if dst.is_empty():
						return 1
		elif a == "onlink":
			opts.onlink = true
		elif ROUTE_TYPES.has(a):
			opts.type = a
		else:
			if not dst.is_empty():
				_p.errln('Error: either "to" is duplicate, or "%s" is a garbage.' % a)
				return 255
			dst = _prefix_arg(a)
			if dst.is_empty():
				return 1
		i += 1
	if dst.is_empty():
		return _incomplete()
	if opts.has("dev") and _net.iface(opts.dev) == null:
		return _no_device(opts.dev)
	if not _need_root():
		return 2
	if cmd == "del":
		var code := _net.del_route(dst[0], dst[1], opts)
		return _rtnl_error(code) if code != AgoraErrno.OK else 0
	if cmd != "add" and cmd != "append":
		var same := {"metric": opts.get("metric", 0)}
		_net.del_route(dst[0], dst[1], same)
	var code := _net.add_route(dst[0], dst[1], opts)
	match code:
		AgoraErrno.OK:
			return 0
		AgoraErrno.ENETUNREACH:
			_p.errln("Error: Nexthop has invalid gateway.")
			return 2
		AgoraErrno.ENETDOWN:
			_p.errln("Error: Nexthop device is not up.")
			return 2
		AgoraErrno.EINVAL:
			_p.errln("Error: Invalid prefsrc address.")
			return 2
	return _rtnl_error(code)


func _route_get(args: PackedStringArray) -> int:
	var target := -1
	var i := 0
	while i < args.size():
		var a := args[i]
		if a in ["from", "oif", "iif", "tos", "mark", "uid"]:
			i += 2
			continue
		if a == "to":
			i += 1
			continue
		target = _addr_arg(a.get_slice("/", 0))
		if target < 0:
			return 1
		i += 1
	if target < 0:
		return _incomplete()
	var r := _net.lookup(target)
	if r.is_empty():
		return _rtnl_error(AgoraErrno.ENETUNREACH)
	match r.type:
		"unreachable": return _rtnl_error(AgoraErrno.EHOSTUNREACH)
		"prohibit": return _rtnl_error(AgoraErrno.EACCES)
		"blackhole": return _rtnl_error(AgoraErrno.EINVAL)
	var uid := _p.cred.uid
	if r.type == "local":
		_p.outln("local %s dev lo src %s uid %d " % [AgoraInet.to_str(target), AgoraInet.to_str(r.src), uid])
		_p.outln("    cache <local> ")
		return 0
	var iface := _net.iface(r.dev)
	if _net.is_broadcast(iface, target):
		_p.outln("broadcast %s dev %s src %s uid %d " % [AgoraInet.to_str(target), r.dev, AgoraInet.to_str(r.src), uid])
		_p.outln("    cache <local,brd> ")
		return 0
	var via := " via " + AgoraInet.to_str(r.gateway) if r.gateway != 0 else ""
	_p.outln("%s%s dev %s src %s uid %d " % [AgoraInet.to_str(target), via, r.dev, AgoraInet.to_str(r.src), uid])
	_p.outln("    cache ")
	return 0


func _route_flush(args: PackedStringArray) -> int:
	if args.is_empty():
		_p.errln("Flush requires arguments.")
		return 1
	if args[0] == "cache":
		return 0 # there is no routing cache since Linux 3.6
	var dev := ""
	var proto := ""
	var i := 0
	while i + 1 < args.size():
		match args[i]:
			"dev": dev = args[i + 1]
			"proto": proto = args[i + 1]
			"table":
				if not args[i + 1] in ["main", "254"]:
					return 0
		i += 2
	if not dev.is_empty() and _net.iface(dev) == null:
		return _no_device(dev)
	if not _need_root():
		return 2
	_net.routes = _net.routes.filter(func(r: Dictionary) -> bool:
		return not ((dev.is_empty() or r.dev == dev) and (proto.is_empty() or r.proto == proto)))
	return 0


# --- ip neighbour ---------------------------------------------------------------

func _neigh(args: PackedStringArray) -> int:
	var cmd := args[0] if not args.is_empty() else "show"
	if _is_show(cmd):
		return _neigh_show(args.slice(1), false)
	if _matches(cmd, "flush"):
		return _neigh_show(args.slice(1), true)
	if cmd == "add" or _matches(cmd, "replace") or _matches(cmd, "change"):
		return _neigh_change(args.slice(1), cmd)
	if _matches(cmd, "delete"):
		return _neigh_change(args.slice(1), "del")
	if _matches(cmd, "help"):
		_p.outln("Usage: ip neigh { add | del | change | replace }\n                { ADDR [ lladdr LLADDR ] [ nud STATE ] | proxy ADDR } [ dev DEV ]\n       ip neigh { show | flush } [ proxy ] [ to PREFIX ] [ dev DEV ] [ nud STATE ]\n\nSTATE := { permanent | noarp | stale | reachable | none |\n           incomplete | delay | probe | failed }")
		return 0
	return _unknown_command(cmd, "neigh")


func _neigh_show(args: PackedStringArray, flush: bool) -> int:
	var dev := ""
	var nud := ""
	var to: Array = []
	var i := 0
	while i < args.size():
		var a := args[i]
		if a in ["dev", "nud", "to"] and i + 1 < args.size():
			match a:
				"dev": dev = args[i + 1]
				"nud": nud = args[i + 1].to_upper()
				"to":
					to = _prefix_arg(args[i + 1])
					if to.is_empty():
						return 1
			i += 2
			continue
		if a == "all":
			i += 1
			continue
		to = _prefix_arg(a)
		if to.is_empty():
			return 1
		i += 1
	if flush and dev.is_empty() and to.is_empty() and not args.has("all"):
		_p.errln("Flush requires arguments.")
		return 1
	if not dev.is_empty() and _net.iface(dev) == null:
		return _no_device(dev)
	if flush and not _need_root():
		return 2
	if _family == 6:
		return 0
	for e in _net.neigh.entries():
		if not dev.is_empty() and e.dev != dev:
			continue
		if not to.is_empty() and not AgoraInet.in_subnet(e.ip, to[0], to[1]):
			continue
		if not nud.is_empty() and nud != "ALL" and e.state != nud:
			continue
		if flush:
			if e.state != "PERMANENT" and e.state != "NOARP":
				_net.neigh.remove(e.dev, e.ip)
			continue
		var text := AgoraInet.to_str(e.ip)
		if dev.is_empty():
			text += " dev " + e.dev
		if not e.mac.is_empty():
			text += " lladdr " + e.mac
		_p.outln(text + " " + e.state)
	return 0


func _neigh_change(args: PackedStringArray, cmd: String) -> int:
	var dev := ""
	var mac := ""
	var nud := "PERMANENT"
	var dst := -1
	var i := 0
	while i < args.size():
		var a := args[i]
		if a in ["dev", "lladdr", "nud", "to"]:
			if i + 1 >= args.size():
				return _incomplete()
			var v := args[i + 1]
			i += 1
			match a:
				"dev": dev = v
				"lladdr":
					if not AgoraNetStack.is_valid_mac(v):
						_p.errln('"%s" is invalid lladdr.' % v)
						return 255
					mac = v.to_lower()
				"nud":
					if not NUD_STATES.has(v):
						_p.errln('Error: argument "%s" is wrong: nud state is bad' % v)
						return 255
					nud = v.to_upper()
				"to":
					dst = _addr_arg(v)
					if dst < 0:
						return 1
		else:
			dst = _addr_arg(a)
			if dst < 0:
				return 1
		i += 1
	if dev.is_empty() or dst < 0:
		_p.errln("Device and destination are required arguments.")
		return 255
	if _net.iface(dev) == null:
		return _no_device(dev)
	if not _need_root():
		return 2
	var existing := _net.neigh.find(dev, dst)
	if cmd == "del":
		if existing.is_empty():
			return _rtnl_error(AgoraErrno.ENOENT)
		_net.neigh.remove(dev, dst)
		return 0
	if cmd == "add" and not existing.is_empty():
		return _rtnl_error(AgoraErrno.EEXIST)
	if _matches(cmd, "change") and existing.is_empty():
		return _rtnl_error(AgoraErrno.ENOENT)
	if mac.is_empty() and nud != "NOARP":
		mac = existing.get("mac", "")
		if mac.is_empty():
			_p.errln("Error: lladdr is required.")
			return 255
	_net.neigh.add(dev, dst, mac, nud)
	return 0
