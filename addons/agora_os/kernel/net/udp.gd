class_name AgoraUdp
extends RefCounted
## UDP for one network stack. A datagram's payload is {sport, dport, data},
## where data is whatever the application sends (a Dictionary for DHCP).
##
## Sockets bind a port, optionally an address and a device (SO_BINDTODEVICE).
## A socket opened with "any_dst" also takes datagrams for addresses the
## machine doesn't have yet, which is what a DHCP client needs before it
## has a lease (udhcpc uses a raw packet socket for that).

const EPHEMERAL_LOW := 32768
const EPHEMERAL_HIGH := 60999


class Socket:
	var port := 0
	var address := 0
	var device := ""
	var any_dst := false
	var broadcast := false
	var pid := 0
	var uid := 0
	## {src, sport, dst, data, iface, ttl}, oldest first.
	var inbox: Array[Dictionary] = []
	## ICMP errors about datagrams we sent (IP_RECVERR): {dst, dport, errno}.
	var errors: Array[Dictionary] = []
	var _udp: WeakRef

	func close() -> void:
		var udp := _udp.get_ref() as AgoraUdp if _udp else null
		if udp:
			udp.sockets.erase(self)

	## Sends [param data] ([param length] bytes) to [param dst]:[param dport].
	## [param opts]: src (source address for a socket bound to 0.0.0.0),
	## dst_mac (send straight to that MAC address out of the bound device,
	## without ARP), ttl. Returns an errno.
	func sendto(dst: int, dport: int, data: Variant, length: int, opts: Dictionary = {}) -> int:
		var udp := _udp.get_ref() as AgoraUdp if _udp else null
		return udp._send(self, dst, dport, data, length, opts) if udp else AgoraErrno.EBADF


var sockets: Array[Socket] = []
var _stack: WeakRef
var _next_port := EPHEMERAL_LOW


func _init(stack: AgoraNetStack) -> void:
	_stack = weakref(stack)


## Why the last [method open] failed.
var last_error := AgoraErrno.OK


## Opens a socket on [param port] (0 picks a free one) for [param p].
## [param opts]: address, device, any_dst, broadcast (SO_BROADCAST).
## Returns null with errno in [member last_error]: EACCES below 1024 for
## users, EADDRINUSE if taken, ENODEV for an unknown device.
func open(p: AgoraProcess, port: int, opts: Dictionary = {}) -> Socket:
	var net := _stack.get_ref() as AgoraNetStack
	var device: String = opts.get("device", "")
	if not device.is_empty() and net.iface(device) == null:
		last_error = AgoraErrno.ENODEV
		return null
	if port == 0:
		port = _free_port()
	elif port < 1024 and not p.cred.is_root():
		last_error = AgoraErrno.EACCES
		return null
	var address: int = opts.get("address", 0)
	for s in sockets:
		if s.port == port and (s.address == 0 or address == 0 or s.address == address) and (s.device == device or s.device.is_empty() or device.is_empty()):
			last_error = AgoraErrno.EADDRINUSE
			return null
	var sock := Socket.new()
	sock.port = port
	sock.address = address
	sock.device = device
	sock.any_dst = opts.get("any_dst", false)
	sock.broadcast = opts.get("broadcast", false)
	sock.pid = p.pid
	sock.uid = p.cred.uid
	sock._udp = weakref(self)
	sockets.append(sock)
	last_error = AgoraErrno.OK
	return sock


func _free_port() -> int:
	for k in EPHEMERAL_HIGH - EPHEMERAL_LOW:
		var port := _next_port
		_next_port = EPHEMERAL_LOW if _next_port >= EPHEMERAL_HIGH else _next_port + 1
		var used := false
		for s in sockets:
			if s.port == port:
				used = true
				break
		if not used:
			return port
	return 0


## Closes every socket of a process that went away.
func close_for(pid: int) -> void:
	sockets = sockets.filter(func(s: Socket) -> bool: return s.pid != pid)


func _send(sock: Socket, dst: int, dport: int, data: Variant, length: int, opts: Dictionary) -> int:
	var net := _stack.get_ref() as AgoraNetStack
	if net == null:
		return AgoraErrno.ENETDOWN
	var packet := net.make_packet(opts.get("src", sock.address), dst, AgoraNetStack.IPPROTO_UDP,
		{"sport": sock.port, "dport": dport, "data": data}, 8 + length, opts.get("ttl", -1))
	if not sock.device.is_empty():
		var i := net.iface(sock.device)
		if opts.has("dst_mac"):
			return net.send_on(i, packet, opts.dst_mac)
		if dst == AgoraInet.BROADCAST:
			if not sock.broadcast:
				return AgoraErrno.EACCES
			return net.send_on(i, packet, AgoraNetStack.BROADCAST_MAC)
	elif dst == AgoraInet.BROADCAST and not sock.broadcast:
		return AgoraErrno.EACCES
	return net.ip_output(packet)


## A datagram arrived: queue it on the matching socket, or answer with
## port unreachable. [param raw] marks datagrams for an address we don't
## have, which only any_dst sockets see.
func receive(packet: Dictionary, iface: AgoraNetStack.Iface, raw: bool = false) -> void:
	var net := _stack.get_ref() as AgoraNetStack
	var udp: Dictionary = packet.payload
	var best: Socket = null
	for s in sockets:
		if s.port != udp.get("dport", -1):
			continue
		if not s.device.is_empty() and s.device != iface.name:
			continue
		if raw and not s.any_dst:
			continue
		if not raw and s.address != 0 and s.address != packet.dst and not net.is_broadcast(iface, packet.dst):
			continue
		if best == null or (s.address != 0 and best.address == 0) or (not s.device.is_empty() and best.device.is_empty()):
			best = s
	if best == null:
		if not raw and not net.is_broadcast(iface, packet.dst):
			net.icmp.send_error(packet, AgoraIcmp.DEST_UNREACH, AgoraIcmp.PORT_UNREACH)
		return
	best.inbox.append({
		"src": packet.src, "sport": udp.get("sport", 0), "dst": packet.dst, "data": udp.get("data"),
		"iface": iface.name, "ttl": packet.ttl,
	})


## An ICMP error about a datagram one of our sockets sent.
func icmp_error(orig: Dictionary, type: int, code: int) -> void:
	var udp: Dictionary = orig.get("payload", {})
	for s in sockets:
		if s.port == udp.get("sport", -1):
			s.errors.append({"dst": orig.dst, "dport": udp.get("dport", 0),
				"errno": AgoraErrno.EHOSTUNREACH if type == AgoraIcmp.TIME_EXCEEDED else AgoraTcp.ICMP_ERRNO.get(code, AgoraErrno.EHOSTUNREACH)})


func wants_raw(iface: AgoraNetStack.Iface) -> bool:
	for s in sockets:
		if s.any_dst and (s.device.is_empty() or s.device == iface.name):
			return true
	return false
