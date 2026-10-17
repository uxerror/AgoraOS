class_name AgoraConntrack
extends RefCounted
## Connection tracking (nf_conntrack) for one network stack.
##
## Every flow is an entry with two tuples, {proto, src, sport, dst, dport}:
## the original direction and the reply direction. A packet matching one
## of them belongs to the flow; ICMP errors belong to the flow of the
## datagram they quote (RELATED). NAT is recorded by changing the reply
## tuple, so replies can be translated back.
##
## Ports are the TCP/UDP ports; for ICMP echo both are the echo id, and
## "type" tells a request (8) from a reply (0), as Linux's tuple does.

const TIMEOUTS := {
	AgoraNetStack.IPPROTO_ICMP: 30.0,
	AgoraNetStack.IPPROTO_UDP: 30.0,
	AgoraNetStack.IPPROTO_TCP: 432000.0,
}
const UDP_STREAM_TIMEOUT := 180.0
const GENERIC_TIMEOUT := 600.0
const MAX := 65536

## id -> {id, proto, orig, reply, seen_reply, assured, confirmed, expires,
## snat, dnat, masq_dev}
var entries := {}
## tuple key -> [id, "orig" or "reply"], for confirmed entries.
var _index := {}
var _next_id := 1


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func key(t: Dictionary) -> String:
	return "%d|%d|%d|%d|%d|%d" % [t.proto, t.src, t.sport, t.dst, t.dport, t.get("type", -1)]


static func invert(t: Dictionary) -> Dictionary:
	var out := {"proto": t.proto, "src": t.dst, "sport": t.dport, "dst": t.src, "dport": t.sport}
	if t.has("type"):
		out.type = AgoraIcmp.ECHO_REPLY if t.type == AgoraIcmp.ECHO_REQUEST else AgoraIcmp.ECHO_REQUEST
	return out


## The tuple of a datagram, or {} if it can't be tracked as a flow of its
## own (ICMP errors, other ICMP messages).
static func tuple_of(packet: Dictionary) -> Dictionary:
	var payload: Dictionary = packet.get("payload", {})
	match packet.proto:
		AgoraNetStack.IPPROTO_TCP, AgoraNetStack.IPPROTO_UDP:
			return {"proto": packet.proto, "src": packet.src, "sport": int(payload.get("sport", 0)), "dst": packet.dst, "dport": int(payload.get("dport", 0))}
		AgoraNetStack.IPPROTO_ICMP:
			var type := int(payload.get("type", -1))
			if type == AgoraIcmp.ECHO_REQUEST or type == AgoraIcmp.ECHO_REPLY:
				var id := int(payload.get("id", 0))
				return {"proto": packet.proto, "src": packet.src, "sport": id, "dst": packet.dst, "dport": id, "type": type}
			return {}
	return {"proto": packet.proto, "src": packet.src, "sport": 0, "dst": packet.dst, "dport": 0}


static func is_icmp_error(packet: Dictionary) -> bool:
	return packet.proto == AgoraNetStack.IPPROTO_ICMP and AgoraIcmp.ERRORS.has(int(packet.payload.get("type", -1))) and packet.payload.has("orig")


func _lookup(t: Dictionary) -> Array:
	var hit: Array = _index.get(key(t), [])
	if hit.is_empty():
		return []
	var ct: Dictionary = entries.get(hit[0], {})
	if ct.is_empty() or ct.expires < _now():
		_remove(hit[0])
		return []
	return hit


## Finds or starts the flow of [param packet]. Returns {id, dir, state}
## with state NEW, ESTABLISHED, RELATED or INVALID (id 0 when untracked).
func classify(packet: Dictionary) -> Dictionary:
	if is_icmp_error(packet):
		var inner := tuple_of(packet.payload.orig)
		if not inner.is_empty():
			# The quoted datagram went the other way.
			var hit := _lookup(invert(inner))
			if not hit.is_empty():
				return {"id": hit[0], "dir": hit[1], "state": "RELATED"}
		return {"id": 0, "dir": "orig", "state": "INVALID"}
	var t := tuple_of(packet)
	if t.is_empty():
		return {"id": 0, "dir": "orig", "state": "INVALID"}
	var hit := _lookup(t)
	if not hit.is_empty():
		var ct: Dictionary = entries[hit[0]]
		if hit[1] == "reply" and not ct.seen_reply:
			ct.seen_reply = true
		elif hit[1] == "orig" and ct.seen_reply and ct.proto == AgoraNetStack.IPPROTO_UDP:
			ct.assured = true
		_refresh(ct)
		return {"id": hit[0], "dir": hit[1], "state": "ESTABLISHED" if ct.seen_reply else "NEW"}
	if packet.proto == AgoraNetStack.IPPROTO_ICMP and int(packet.payload.get("type", -1)) == AgoraIcmp.ECHO_REPLY:
		return {"id": 0, "dir": "orig", "state": "INVALID"} # a reply to nothing
	var id := _next_id
	_next_id += 1
	entries[id] = {
		"id": id, "proto": t.proto, "orig": t, "reply": invert(t), "seen_reply": false,
		"assured": false, "confirmed": false, "expires": _now() + _timeout_of(t.proto, false),
		"snat": {}, "dnat": {}, "masq_dev": "",
	}
	return {"id": id, "dir": "orig", "state": "NEW"}


func _timeout_of(proto: int, assured: bool) -> float:
	if proto == AgoraNetStack.IPPROTO_UDP and assured:
		return UDP_STREAM_TIMEOUT
	return TIMEOUTS.get(proto, GENERIC_TIMEOUT)


func _refresh(ct: Dictionary) -> void:
	ct.expires = _now() + _timeout_of(ct.proto, ct.assured)


## The packet was let through: the flow now exists for later packets.
func confirm(id: int) -> void:
	var ct: Dictionary = entries.get(id, {})
	if ct.is_empty() or ct.confirmed:
		return
	if entries.size() > MAX:
		_gc()
	ct.confirmed = true
	_index[key(ct.orig)] = [id, "orig"]
	_index[key(ct.reply)] = [id, "reply"]


## Drops a flow that was never confirmed (its first packet was dropped).
func discard(id: int) -> void:
	var ct: Dictionary = entries.get(id, {})
	if not ct.is_empty() and not ct.confirmed:
		entries.erase(id)


## True if a reply tuple is free, for picking a NAT port.
func reply_free(t: Dictionary) -> bool:
	return _lookup(t).is_empty()


## Changes the reply tuple of an unconfirmed flow (NAT).
func set_reply(id: int, reply: Dictionary) -> void:
	entries[id].reply = reply


func _remove(id: int) -> void:
	var ct: Dictionary = entries.get(id, {})
	entries.erase(id)
	if ct.is_empty():
		return
	for t: Dictionary in [ct.orig, ct.reply]:
		var hit: Array = _index.get(key(t), [])
		if not hit.is_empty() and hit[0] == id:
			_index.erase(key(t))


func _gc() -> void:
	var now := _now()
	for id: int in entries.keys():
		if entries[id].expires < now:
			_remove(id)


## Forgets flows masqueraded out of [param dev] (its address went away).
func flush_masquerade(dev: String) -> void:
	for id: int in entries.keys():
		if entries[id].masq_dev == dev:
			_remove(id)


func flush() -> void:
	entries.clear()
	_index.clear()


## Live, confirmed flows, oldest first.
func list() -> Array[Dictionary]:
	_gc()
	var out: Array[Dictionary] = []
	for id: int in entries:
		if entries[id].confirmed:
			out.append(entries[id])
	return out


## A flow as /proc/net/nf_conntrack shows it.
static func format(ct: Dictionary) -> String:
	var names := {AgoraNetStack.IPPROTO_ICMP: "icmp", AgoraNetStack.IPPROTO_TCP: "tcp", AgoraNetStack.IPPROTO_UDP: "udp"}
	var proto: int = ct.proto
	var text := "ipv4     2 %-8s %d %d " % [names.get(proto, "unknown"), proto, maxi(0, int(ct.expires - _now()))]
	text += _tuple_text(ct.orig, proto, true)
	if not ct.seen_reply:
		text += "[UNREPLIED] "
	text += _tuple_text(ct.reply, proto, false)
	if ct.assured:
		text += "[ASSURED] "
	return text + "mark=0 zone=0 use=2"


static func _tuple_text(t: Dictionary, proto: int, orig: bool) -> String:
	var text := "src=%s dst=%s " % [AgoraInet.to_str(t.src), AgoraInet.to_str(t.dst)]
	match proto:
		AgoraNetStack.IPPROTO_ICMP:
			text += "type=%d code=0 id=%d " % [8 if orig else 0, t.sport]
		AgoraNetStack.IPPROTO_TCP, AgoraNetStack.IPPROTO_UDP:
			text += "sport=%d dport=%d " % [t.sport, t.dport]
	return text
