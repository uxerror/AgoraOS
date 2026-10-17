class_name AgoraNetfilter
extends RefCounted
## Netfilter for one network stack: the filter and nat tables iptables
## edits, run at the same hooks as in Linux, with connection tracking.
##
##   incoming:  PREROUTING (nat) -> routing -> INPUT (filter)
##                                          -> FORWARD (filter) -> POSTROUTING (nat)
##   outgoing:  OUTPUT (nat, filter) -> POSTROUTING (nat)
##
## The nat table sees only the first packet of a flow; the translation it
## picks is stored with the flow and applied to every later packet, and
## undone on the replies.
##
## A rule is a Dictionary: proto ("" for any, else a number), src/dst
## ([address, prefix] or []), src_inv/dst_inv, in/out (interface names,
## "+" as a wildcard suffix), in_inv/out_inv, sport/dport ([low, high] or
## []), sport_inv/dport_inv, icmp_type (-1 for any), states (names, from
## -m state or -m conntrack), state_match ("state"/"conntrack"), target,
## target_opts, pkts, bytes.

const BUILTIN := {
	"filter": ["INPUT", "FORWARD", "OUTPUT"],
	"nat": ["PREROUTING", "INPUT", "OUTPUT", "POSTROUTING"],
}
const VERDICTS: PackedStringArray = ["ACCEPT", "DROP", "REJECT", "RETURN", "LOG", "MASQUERADE", "SNAT", "DNAT"]
const MAX_DEPTH := 32

## table -> chain -> {policy ("" for user chains), rules: [], pkts, bytes}
var tables := {}
var conntrack := AgoraConntrack.new()
var _stack: WeakRef


func _init(stack: AgoraNetStack) -> void:
	_stack = weakref(stack)
	for t: String in BUILTIN:
		tables[t] = {}
		for c: String in BUILTIN[t]:
			tables[t][c] = {"policy": "ACCEPT", "rules": [], "pkts": 0, "bytes": 0}


func _net() -> AgoraNetStack:
	return _stack.get_ref() as AgoraNetStack


func chain(table: String, name: String) -> Dictionary:
	return tables.get(table, {}).get(name, {})


func is_builtin(table: String, name: String) -> bool:
	return BUILTIN.get(table, []).has(name)


## Counts the user chains that jump to [param name].
func references(table: String, name: String) -> int:
	var n := 0
	for c: String in tables[table]:
		for r: Dictionary in tables[table][c].rules:
			if r.target == name:
				n += 1
	return n


# --- hooks ----------------------------------------------------------------------

## Attaches the flow of [param packet] to it (once).
func _track(packet: Dictionary) -> Dictionary:
	if not packet.has("_ct"):
		var c := conntrack.classify(packet)
		packet._ct = c.id
		packet._dir = c.dir
		packet._state = c.state
	return {"id": packet._ct, "dir": packet._dir, "state": packet._state}


## PREROUTING: tracking and destination NAT. False drops the packet.
func prerouting(packet: Dictionary, iface: AgoraNetStack.Iface) -> bool:
	var ctx := _track(packet)
	return _nat_dst(packet, ctx, "PREROUTING", iface, null)


## OUTPUT (nat): tracking and destination NAT of locally sent packets.
func local_out(packet: Dictionary, out: AgoraNetStack.Iface) -> bool:
	var ctx := _track(packet)
	return _nat_dst(packet, ctx, "OUTPUT", null, out)


## Runs a filter chain (INPUT, FORWARD or OUTPUT). False drops the packet.
func filter(name: String, packet: Dictionary, in_iface: AgoraNetStack.Iface, out_iface: AgoraNetStack.Iface) -> bool:
	var ctx := _track(packet)
	var verdict := _run("filter", name, packet, ctx, in_iface, out_iface)
	if verdict == "DROP":
		conntrack.discard(ctx.id)
		return false
	return true


## POSTROUTING: source NAT, then the flow is confirmed.
func postrouting(packet: Dictionary, out: AgoraNetStack.Iface) -> bool:
	var ctx := _track(packet)
	if not _nat_src(packet, ctx, out):
		conntrack.discard(ctx.id)
		return false
	conntrack.confirm(ctx.id)
	return true


## The packet reached a local socket: its flow exists from now on.
func delivered(packet: Dictionary) -> void:
	if packet.has("_ct"):
		conntrack.confirm(packet._ct)


## The packet went nowhere (not for us, not forwarded).
func dropped(packet: Dictionary) -> void:
	if packet.has("_ct"):
		conntrack.discard(packet._ct)


# --- NAT ------------------------------------------------------------------------

static func _get_port(packet: Dictionary, which: String) -> int:
	var p: Dictionary = packet.payload
	if packet.proto == AgoraNetStack.IPPROTO_ICMP:
		return int(p.get("id", 0))
	return int(p.get(which, 0))


static func _set_port(packet: Dictionary, which: String, value: int) -> void:
	var p: Dictionary = packet.payload
	if packet.proto == AgoraNetStack.IPPROTO_ICMP:
		if p.has("id"):
			p.id = value
	elif packet.proto in [AgoraNetStack.IPPROTO_TCP, AgoraNetStack.IPPROTO_UDP]:
		p[which] = value


func _nat_dst(packet: Dictionary, ctx: Dictionary, hook: String, in_iface: AgoraNetStack.Iface, out_iface: AgoraNetStack.Iface) -> bool:
	var ct: Dictionary = conntrack.entries.get(ctx.id, {})
	if ct.is_empty():
		return true
	if ctx.state == "RELATED":
		_nat_related(packet, ct, ctx.dir)
		return true
	if ctx.dir == "orig":
		if not ct.confirmed and not ct.has("dst_checked"):
			ct.dst_checked = true
			var verdict := _run("nat", hook, packet, ctx, in_iface, out_iface)
			if verdict == "DROP":
				return false
			if ct.has("pending_dnat"):
				var to: Array = ct.pending_dnat
				ct.erase("pending_dnat")
				var reply: Dictionary = ct.reply.duplicate()
				reply.src = to[0]
				if to[1] > 0:
					reply.sport = to[1]
				ct.dnat = {"addr": to[0], "port": to[1]}
				conntrack.set_reply(ctx.id, reply)
		if not ct.dnat.is_empty():
			packet.dst = ct.dnat.addr
			if ct.dnat.port > 0:
				_set_port(packet, "dport", ct.dnat.port)
	elif not ct.snat.is_empty():
		packet.dst = ct.orig.src
		_set_port(packet, "dport", ct.orig.sport)
	return true


func _nat_src(packet: Dictionary, ctx: Dictionary, out: AgoraNetStack.Iface) -> bool:
	var ct: Dictionary = conntrack.entries.get(ctx.id, {})
	if ct.is_empty() or ctx.state == "RELATED":
		return true
	if ctx.dir == "orig":
		if not ct.confirmed and not ct.has("src_checked"):
			ct.src_checked = true
			var verdict := _run("nat", "POSTROUTING", packet, ctx, null, out)
			if verdict == "DROP":
				return false
			if ct.has("pending_snat"):
				var to: Array = ct.pending_snat
				ct.erase("pending_snat")
				var addr: int = to[0]
				if addr == 0:
					return false # MASQUERADE on an interface without an address
				var port := _pick_port(ct, addr, to[1], to[2])
				ct.snat = {"addr": addr, "port": port}
				if to.size() > 3:
					ct.masq_dev = to[3]
				var reply: Dictionary = ct.reply.duplicate()
				reply.dst = addr
				reply.dport = port
				conntrack.set_reply(ctx.id, reply)
		if not ct.snat.is_empty():
			packet.src = ct.snat.addr
			_set_port(packet, "sport", ct.snat.port)
	elif not ct.dnat.is_empty():
		packet.src = ct.orig.dst
		_set_port(packet, "sport", ct.orig.dport)
	return true


## Keeps the source port if the translated flow is unique, else finds one
## in [low, high] (1024-65535 by default, like Linux).
func _pick_port(ct: Dictionary, addr: int, low: int, high: int) -> int:
	var reply: Dictionary = ct.reply.duplicate()
	var free := func(t: Dictionary) -> bool: return conntrack.reply_free(t) and not _local_port(ct.proto, addr, t.dport)
	reply.dst = addr
	var port: int = ct.orig.sport
	if low <= 0:
		low = 1024 if port >= 1024 or ct.proto == AgoraNetStack.IPPROTO_ICMP else 1
		high = 65535 if port >= 1024 or ct.proto == AgoraNetStack.IPPROTO_ICMP else 1023
		reply.dport = port
		if free.call(reply):
			return port
	elif port >= low and port <= high:
		reply.dport = port
		if free.call(reply):
			return port
	for candidate in range(low, high + 1):
		reply.dport = candidate
		if free.call(reply):
			return candidate
	return port


## True if a socket of this machine uses [param port] on [param addr]:
## translating a flow onto it would steal its replies.
func _local_port(proto: int, addr: int, port: int) -> bool:
	var net := _net()
	if net == null:
		return false
	if proto == AgoraNetStack.IPPROTO_UDP:
		for s in net.udp.sockets:
			if s.port == port and (s.address == 0 or s.address == addr):
				return true
	elif proto == AgoraNetStack.IPPROTO_TCP:
		if net.tcp.listener_on(port):
			return true
		for c: AgoraTcp.Conn in net.tcp.conns.values():
			if c.local_port == port and c.local_addr == addr:
				return true
	return false


## ICMP errors about a translated flow get their outer and quoted headers
## translated too, so the sender recognizes its datagram.
func _nat_related(packet: Dictionary, ct: Dictionary, dir: String) -> void:
	var inner: Dictionary = packet.payload.orig
	if dir == "reply" and not ct.snat.is_empty():
		packet.dst = ct.orig.src
		inner.src = ct.orig.src
		_set_port(inner, "sport", ct.orig.sport)
	elif dir == "reply" and not ct.dnat.is_empty():
		inner.dst = ct.orig.dst
		_set_port(inner, "dport", ct.orig.dport)
		packet.src = ct.orig.dst if packet.src == ct.dnat.addr else packet.src


# --- rules ----------------------------------------------------------------------

func _run(table: String, name: String, packet: Dictionary, ctx: Dictionary, in_iface: AgoraNetStack.Iface, out_iface: AgoraNetStack.Iface, depth: int = 0) -> String:
	var c: Dictionary = chain(table, name)
	if c.is_empty() or depth > MAX_DEPTH:
		return "ACCEPT"
	var in_name := in_iface.name if in_iface else ""
	var out_name := out_iface.name if out_iface else ""
	for rule: Dictionary in c.rules:
		if not _matches(rule, packet, ctx, in_name, out_name):
			continue
		rule.pkts += 1
		rule.bytes += int(packet.len)
		var target: String = rule.target
		match target:
			"":
				continue
			"ACCEPT", "DROP":
				return target
			"RETURN":
				break
			"REJECT":
				_reject(packet, rule.target_opts.get("with", "icmp-port-unreachable"))
				return "DROP"
			"LOG":
				_log(packet, rule.target_opts.get("prefix", ""), in_name, out_name)
				continue
			"MASQUERADE":
				var net := _net()
				var addr := net.select_source(out_name, packet.dst) if net and out_iface else 0
				var ports: Array = rule.target_opts.get("ports", [0, 0])
				_ct(ctx).pending_snat = [addr, ports[0], ports[1], out_name]
				return "ACCEPT"
			"SNAT":
				var to: Array = rule.target_opts.to
				_ct(ctx).pending_snat = [to[0], to[1], to[2]]
				return "ACCEPT"
			"DNAT":
				var to: Array = rule.target_opts.to
				_ct(ctx).pending_dnat = [to[0], to[1]]
				return "ACCEPT"
			_:
				var verdict := _run(table, target, packet, ctx, in_iface, out_iface, depth + 1)
				if verdict != "RETURN" and verdict != "":
					return verdict
	if not c.policy.is_empty():
		c.pkts += 1
		c.bytes += int(packet.len)
		return c.policy
	return "RETURN"


func _ct(ctx: Dictionary) -> Dictionary:
	return conntrack.entries.get(ctx.id, {})


static func _iface_match(pattern: String, name: String) -> bool:
	if pattern.ends_with("+"):
		return name.begins_with(pattern.trim_suffix("+"))
	return pattern == name


func _matches(rule: Dictionary, packet: Dictionary, ctx: Dictionary, in_name: String, out_name: String) -> bool:
	if rule.proto is int and (packet.proto == rule.proto) == rule.get("proto_inv", false):
		return false
	if not rule.src.is_empty() and AgoraInet.in_subnet(packet.src, rule.src[0], rule.src[1]) == rule.src_inv:
		return false
	if not rule.dst.is_empty() and AgoraInet.in_subnet(packet.dst, rule.dst[0], rule.dst[1]) == rule.dst_inv:
		return false
	if not rule.in.is_empty() and _iface_match(rule.in, in_name) == rule.in_inv:
		return false
	if not rule.out.is_empty() and _iface_match(rule.out, out_name) == rule.out_inv:
		return false
	var payload: Dictionary = packet.payload
	for which in ["sport", "dport"]:
		var range_: Array = rule[which]
		if range_.is_empty():
			continue
		var port := int(payload.get(which, -1))
		if (port >= range_[0] and port <= range_[1]) == rule[which + "_inv"]:
			return false
	if rule.icmp_type >= 0:
		if packet.proto != AgoraNetStack.IPPROTO_ICMP or int(payload.get("type", -1)) != rule.icmp_type:
			return false
		if rule.icmp_code >= 0 and int(payload.get("code", -1)) != rule.icmp_code:
			return false
	if not rule.states.is_empty() and not (rule.states as Array).has(ctx.state):
		return false
	return true


const REJECT_CODES := {
	"icmp-net-unreachable": AgoraIcmp.NET_UNREACH, "icmp-host-unreachable": AgoraIcmp.HOST_UNREACH,
	"icmp-port-unreachable": AgoraIcmp.PORT_UNREACH, "icmp-proto-unreachable": AgoraIcmp.PROT_UNREACH,
	"icmp-net-prohibited": AgoraIcmp.NET_ANO, "icmp-host-prohibited": AgoraIcmp.HOST_ANO,
	"icmp-admin-prohibited": AgoraIcmp.PKT_FILTERED,
}


func _reject(packet: Dictionary, with: String) -> void:
	var net := _net()
	if net:
		net.icmp.send_error(packet, AgoraIcmp.DEST_UNREACH, REJECT_CODES.get(with, AgoraIcmp.PORT_UNREACH))


## A line for the kernel log, as the LOG target writes it.
func _log(packet: Dictionary, prefix: String, in_name: String, out_name: String) -> void:
	var net := _net()
	var m := net._m() if net else null
	if m == null:
		return
	var text := "%sIN=%s OUT=%s SRC=%s DST=%s LEN=%d TOS=0x00 PREC=0x00 TTL=%d ID=%d " % [
		prefix, in_name, out_name, AgoraInet.to_str(packet.src), AgoraInet.to_str(packet.dst),
		int(packet.len), int(packet.ttl), int(packet.get("id", 0))]
	var p: Dictionary = packet.payload
	match packet.proto:
		AgoraNetStack.IPPROTO_ICMP:
			text += "PROTO=ICMP TYPE=%d CODE=%d" % [int(p.get("type", 0)), int(p.get("code", 0))]
			if p.has("id"):
				text += " ID=%d SEQ=%d" % [int(p.id), int(p.get("seq", 0))]
		AgoraNetStack.IPPROTO_UDP:
			text += "PROTO=UDP SPT=%d DPT=%d LEN=%d" % [int(p.get("sport", 0)), int(p.get("dport", 0)), int(packet.len) - 20]
		AgoraNetStack.IPPROTO_TCP:
			text += "PROTO=TCP SPT=%d DPT=%d WINDOW=65535 RES=0x00 %sURGP=0" % [int(p.get("sport", 0)), int(p.get("dport", 0)), _tcp_flags(p)]
		_:
			text += "PROTO=%d" % packet.proto
	m.klog(text)


static func _tcp_flags(p: Dictionary) -> String:
	var out := ""
	for f in ["ACK", "PSH", "RST", "SYN", "FIN"]:
		if (p.get("flags", []) as Array).has(f):
			out += f + " "
	return out
