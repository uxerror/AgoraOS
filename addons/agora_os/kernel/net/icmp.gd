class_name AgoraIcmp
extends RefCounted
## ICMP for one network stack: answers echo requests, sends errors
## (destination unreachable, time exceeded) and hands every incoming ICMP
## message to the raw sockets that tools like ping and traceroute open.
##
## A message is the datagram's payload: {type, code, ...}. Echo messages
## carry {id, seq}; errors carry "orig", the header and first bytes of the
## datagram that caused them, so the sender can tell which one it was.

const ECHO_REPLY := 0
const DEST_UNREACH := 3
const ECHO_REQUEST := 8
const TIME_EXCEEDED := 11

## Destination unreachable codes.
const NET_UNREACH := 0
const HOST_UNREACH := 1
const PROT_UNREACH := 2
const PORT_UNREACH := 3
const FRAG_NEEDED := 4
const NET_ANO := 9
const HOST_ANO := 10
const PKT_FILTERED := 13

const ERRORS: PackedInt32Array = [DEST_UNREACH, 4, 5, TIME_EXCEEDED, 12]

## /proc/sys/net/ipv4/icmp_echo_ignore_all and _broadcasts.
var echo_ignore_all := false
var echo_ignore_broadcasts := true


## A raw ICMP socket: every ICMP datagram the machine receives is queued
## in [member inbox] until the owner reads it.
class Socket:
	var inbox: Array[Dictionary] = []
	var _icmp: WeakRef

	func close() -> void:
		var icmp := _icmp.get_ref() as AgoraIcmp
		if icmp:
			icmp._sockets.erase(self)


var _sockets: Array[Socket] = []
var _stack: WeakRef


func _init(stack: AgoraNetStack) -> void:
	_stack = weakref(stack)


func open_socket() -> Socket:
	var s := Socket.new()
	s._icmp = weakref(self)
	_sockets.append(s)
	return s


func receive(packet: Dictionary, iface: AgoraNetStack.Iface) -> void:
	var net := _stack.get_ref() as AgoraNetStack
	if net == null:
		return
	var msg: Dictionary = packet.payload
	if msg.get("type") == ECHO_REQUEST and not echo_ignore_all:
		var broadcast := net.is_broadcast(iface, packet.dst) and not net.is_local(packet.dst)
		if not (broadcast and echo_ignore_broadcasts):
			var src: int = packet.dst if not broadcast else net.select_source(iface.name, packet.src)
			var reply := net.make_packet(src, packet.src, AgoraNetStack.IPPROTO_ICMP,
				{"type": ECHO_REPLY, "code": 0, "id": msg.get("id", 0), "seq": msg.get("seq", 0)}, packet.len - 20)
			reply.lat = packet.get("lat", 0.0)
			net.ip_output(reply)
	if ERRORS.has(int(msg.get("type", -1))) and msg.has("orig") and msg.orig.proto == AgoraNetStack.IPPROTO_TCP:
		net.tcp.icmp_error(msg.orig, msg.type, msg.get("code", 0))
	for s in _sockets:
		s.inbox.append(packet.duplicate(true))


## Sends an ICMP error about [param orig] back to its sender, from
## [param from] (or the address the route back picks). Never answers an
## ICMP error or a broadcast, as RFC 1122 requires.
func send_error(orig: Dictionary, type: int, code: int, from: int = 0) -> void:
	var net := _stack.get_ref() as AgoraNetStack
	if net == null or orig.src == 0 or orig.src == AgoraInet.BROADCAST:
		return
	if orig.proto == AgoraNetStack.IPPROTO_ICMP and ERRORS.has(int(orig.payload.get("type", -1))):
		return
	var quoted := {
		"src": orig.src, "dst": orig.dst, "proto": orig.proto, "ttl": orig.ttl, "id": orig.id,
		"len": orig.len, "payload": (orig.payload as Dictionary).duplicate(true),
	}
	var err := net.make_packet(from, orig.src, AgoraNetStack.IPPROTO_ICMP,
		{"type": type, "code": code, "orig": quoted}, 8 + 28)
	err.lat = orig.get("lat", 0.0)
	net.ip_output(err)


## The text ping and traceroute print for an ICMP error.
static func describe(type: int, code: int) -> String:
	if type == TIME_EXCEEDED:
		return "Time to live exceeded" if code == 0 else "Frag reassembly time exceeded"
	if type != DEST_UNREACH:
		return "Bad ICMP type: %d" % type
	match code:
		NET_UNREACH: return "Destination Net Unreachable"
		HOST_UNREACH: return "Destination Host Unreachable"
		PROT_UNREACH: return "Destination Protocol Unreachable"
		PORT_UNREACH: return "Destination Port Unreachable"
		FRAG_NEEDED: return "Frag needed and DF set"
		NET_ANO: return "Destination Net Prohibited"
		HOST_ANO: return "Destination Host Prohibited"
		PKT_FILTERED: return "Packet filtered"
	return "Dest Unreachable, Bad Code: %d" % code
