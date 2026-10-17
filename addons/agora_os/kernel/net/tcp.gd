class_name AgoraTcp
extends RefCounted
## TCP for one network stack.
##
## Opening a connection is real: SYN, SYN-ACK and ACK travel as packets, so
## routes, ARP, firewalls and NAT all decide whether it works. A closed port
## answers with RST (ECONNREFUSED); ICMP errors during the handshake abort
## it (EHOSTUNREACH, ENETUNREACH, ...); unanswered SYNs are retried with
## backoff until ETIMEDOUT. Once connected, data flows through a pair of
## AgoraStreams between the two endpoints, plus a small control channel
## (terminal modes, signals, exit status) like SSH's channel requests.
## Closing sends FIN.
##
## A segment's payload is {sport, dport, flags (["SYN", "ACK", ...]),
## endpoint}; "endpoint" is the sender's Conn, which is how the two
## sides find each other's streams.

## Socket states, with their numbers in /proc/net/tcp.
const STATE_CODES := {
	"ESTABLISHED": 1, "SYN_SENT": 2, "SYN_RECV": 3, "FIN_WAIT1": 4, "FIN_WAIT2": 5,
	"TIME_WAIT": 6, "CLOSE": 7, "CLOSE_WAIT": 8, "LAST_ACK": 9, "LISTEN": 10, "CLOSING": 11,
}
const TIME_WAIT_LEN := 60.0
const SOMAXCONN := 128

## Errno for ICMP destination-unreachable codes (icmp_err_convert).
const ICMP_ERRNO := {
	0: AgoraErrno.ENETUNREACH, 1: AgoraErrno.EHOSTUNREACH, 2: AgoraErrno.ENOPROTOOPT,
	3: AgoraErrno.ECONNREFUSED, 4: AgoraErrno.EMSGSIZE, 9: AgoraErrno.ENETUNREACH,
	10: AgoraErrno.EHOSTUNREACH, 13: AgoraErrno.EHOSTUNREACH,
}


## A listening socket.
class Listener:
	var address := 0
	var port := 0
	var backlog := SOMAXCONN
	var pid := 0
	var uid := 0
	var queue: Array = []
	var closed := false
	var _tcp: WeakRef

	## Waits for the next connection. Returns null once the socket is closed
	## or [param abort] says so.
	func accept(abort: Callable = Callable()) -> Conn:
		var tree := Engine.get_main_loop() as SceneTree
		while queue.is_empty() and not closed and tree and not (abort.is_valid() and abort.call()):
			await tree.create_timer(0.02).timeout
		return queue.pop_front() if not queue.is_empty() else null

	func close() -> void:
		closed = true
		var tcp := _tcp.get_ref() as AgoraTcp if _tcp else null
		if tcp:
			tcp.listeners.erase(self)
		for c: Conn in queue:
			c.close()
		queue.clear()


## One end of a connection.
class Conn:
	signal control(message: Dictionary)

	var local_addr := 0
	var local_port := 0
	var remote_addr := 0
	var remote_port := 0
	var state := "CLOSE"
	var pid := 0
	var uid := 0
	## What the other end sends; read it.
	var input := AgoraStream.new()
	## Where to write; the other end's input once connected.
	var output: AgoraStream
	var error := AgoraErrno.OK
	var expires := 0.0
	var _peer: WeakRef
	var _tcp: WeakRef

	func _init() -> void:
		input.add_reader()

	var peer: Conn:
		get:
			return _peer.get_ref() as Conn if _peer else null

	func is_open() -> bool:
		return state == "ESTABLISHED" or state == "CLOSE_WAIT"

	## True while data can still arrive (also after our shutdown_write).
	func can_read() -> bool:
		return is_open() or (_write_closed and state in ["FIN_WAIT1", "FIN_WAIT2"])

	## Sends an out-of-band message to the other end (terminal modes,
	## signals, exit status).
	func send_control(message: Dictionary) -> void:
		var other := peer
		if other and state in ["ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT1"]:
			other.control.emit.call_deferred(message)

	## shutdown(SHUT_WR): no more data from this end; the other end reads
	## end-of-file, and this end can still read.
	func shutdown_write() -> void:
		var tcp := _tcp.get_ref() as AgoraTcp if _tcp else null
		if _write_closed or not is_open():
			return
		_write_closed = true
		if output:
			output.release_writer()
		state = "LAST_ACK" if state == "CLOSE_WAIT" else "FIN_WAIT1"
		if tcp:
			tcp._send_segment(self, ["FIN", "ACK"])

	var _write_closed := false

	## Drops whoever listens on the control channel (their callables
	## usually hold this connection, which would keep both alive).
	func _forget_listeners() -> void:
		for c: Dictionary in control.get_connections():
			control.disconnect(c.callable)

	func close() -> void:
		var tcp := _tcp.get_ref() as AgoraTcp if _tcp else null
		_forget_listeners.call_deferred()
		if _write_closed:
			input.release_reader()
			_write_closed = false
			return
		if state in ["CLOSE", "TIME_WAIT", "LAST_ACK", "FIN_WAIT1"]:
			return
		if output:
			output.release_writer()
		input.release_reader()
		var was := state
		state = "LAST_ACK" if was == "CLOSE_WAIT" else "FIN_WAIT1"
		if tcp:
			tcp._send_segment(self, ["FIN", "ACK"])
			if was in ["SYN_SENT", "SYN_RECV"]:
				tcp._drop(self)


var listeners: Array[Listener] = []
## Connections by "local_addr:local_port>remote_addr:remote_port".
var conns := {}
var syn_retries := 6
var _stack: WeakRef
var _next_port := AgoraUdp.EPHEMERAL_LOW


func _init(stack: AgoraNetStack) -> void:
	_stack = weakref(stack)


func _net() -> AgoraNetStack:
	return _stack.get_ref() as AgoraNetStack


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func _key(la: int, lp: int, ra: int, rp: int) -> String:
	return "%d:%d>%d:%d" % [la, lp, ra, rp]


## Why the last [method listen] failed.
var last_error := AgoraErrno.OK


## bind(2) + listen(2). Returns null with [member last_error] set:
## EACCES below 1024 for users, EADDRINUSE if taken.
func listen(p: AgoraProcess, port: int, address: int = 0, backlog: int = SOMAXCONN) -> Listener:
	if port < 1024 and not p.cred.is_root():
		last_error = AgoraErrno.EACCES
		return null
	for l in listeners:
		if l.port == port and (l.address == 0 or address == 0 or l.address == address):
			last_error = AgoraErrno.EADDRINUSE
			return null
	var l := Listener.new()
	l.address = address
	l.port = port
	l.backlog = mini(backlog, SOMAXCONN)
	l.pid = p.pid
	l.uid = p.cred.uid
	l._tcp = weakref(self)
	listeners.append(l)
	last_error = AgoraErrno.OK
	return l


func listener_on(port: int) -> Listener:
	for l in listeners:
		if l.port == port:
			return l
	return null


func _free_port(remote: int, rport: int) -> int:
	for k in AgoraUdp.EPHEMERAL_HIGH - AgoraUdp.EPHEMERAL_LOW:
		var port := _next_port
		_next_port = AgoraUdp.EPHEMERAL_LOW if _next_port >= AgoraUdp.EPHEMERAL_HIGH else _next_port + 1
		var used := false
		for c: Conn in conns.values():
			if c.local_port == port and c.remote_addr == remote and c.remote_port == rport:
				used = true
		for l in listeners:
			if l.port == port:
				used = true
		if not used:
			return port
	return 0


## connect(2): opens a connection to [param dst]:[param dport]. Returns
## {conn} on success or {error} with an errno.
func open_connection(p: AgoraProcess, dst: int, dport: int) -> Dictionary:
	var net := _net()
	var route := net.lookup(dst)
	if route.is_empty():
		return {"error": AgoraErrno.ENETUNREACH}
	match route.type:
		"unreachable": return {"error": AgoraErrno.EHOSTUNREACH}
		"prohibit": return {"error": AgoraErrno.EACCES}
		"blackhole": return {"error": AgoraErrno.EINVAL}
	var c := Conn.new()
	c._tcp = weakref(self)
	c.local_addr = route.src
	c.remote_addr = dst
	c.remote_port = dport
	c.local_port = _free_port(dst, dport)
	c.pid = p.pid
	c.uid = p.cred.uid
	c.state = "SYN_SENT"
	conns[_key(c.local_addr, c.local_port, dst, dport)] = c
	var tree := Engine.get_main_loop() as SceneTree
	var wait := 1.0
	for attempt in syn_retries + 1:
		var code := _send_segment(c, ["SYN"])
		if code != AgoraErrno.OK:
			_drop(c)
			return {"error": code}
		var deadline := _now() + wait
		while c.state == "SYN_SENT" and _now() < deadline and not p.is_dead() and tree:
			await tree.create_timer(0.016).timeout
		if c.state != "SYN_SENT" or p.is_dead():
			break
		wait *= 2.0
	if c.state == "ESTABLISHED":
		return {"conn": c}
	var err := c.error if c.error != AgoraErrno.OK else AgoraErrno.ETIMEDOUT
	_drop(c)
	return {"error": err}


func _drop(c: Conn) -> void:
	c.state = "CLOSE"
	conns.erase(_key(c.local_addr, c.local_port, c.remote_addr, c.remote_port))


func _send_segment(c: Conn, flags: Array) -> int:
	var net := _net()
	if net == null:
		return AgoraErrno.ENETDOWN
	var length := 40 if "SYN" not in flags else 60
	var packet := net.make_packet(c.local_addr, c.remote_addr, AgoraNetStack.IPPROTO_TCP,
		{"sport": c.local_port, "dport": c.remote_port, "flags": flags, "endpoint": c}, length - 20)
	return net.ip_output(packet)


## A RST for a segment nobody wanted.
func _reset(packet: Dictionary) -> void:
	var net := _net()
	var seg: Dictionary = packet.payload
	if (seg.get("flags", []) as Array).has("RST"):
		return
	net.ip_output(net.make_packet(packet.dst, packet.src, AgoraNetStack.IPPROTO_TCP,
		{"sport": seg.get("dport", 0), "dport": seg.get("sport", 0), "flags": ["RST", "ACK"]}, 20))


func receive(packet: Dictionary, _iface: AgoraNetStack.Iface) -> void:
	var seg: Dictionary = packet.payload
	var flags: Array = seg.get("flags", [])
	var key := _key(packet.dst, int(seg.get("dport", 0)), packet.src, int(seg.get("sport", 0)))
	var c: Conn = conns.get(key)
	if c:
		_segment(c, packet, flags, seg.get("endpoint") as Conn)
		return
	if flags.has("SYN") and not flags.has("ACK"):
		var l: Listener = null
		for candidate in listeners:
			if candidate.port == seg.get("dport") and (candidate.address == 0 or candidate.address == packet.dst):
				l = candidate
		if l == null:
			_reset(packet)
			return
		if l.queue.size() >= l.backlog:
			return # a full backlog drops the SYN; the client retries
		var s := Conn.new()
		s._tcp = weakref(self)
		s.local_addr = packet.dst
		s.local_port = int(seg.dport)
		s.remote_addr = packet.src
		s.remote_port = int(seg.sport)
		s.pid = l.pid
		s.uid = l.uid
		s.state = "SYN_RECV"
		s.set_meta("listener", l)
		var client := seg.get("endpoint") as Conn
		if client:
			s._peer = weakref(client)
		conns[key] = s
		_send_segment(s, ["SYN", "ACK"])
		return
	_reset(packet)


func _segment(c: Conn, _packet: Dictionary, flags: Array, endpoint: Conn) -> void:
	if flags.has("RST"):
		if c.state == "SYN_SENT":
			c.error = AgoraErrno.ECONNREFUSED
		_close_hard(c)
		return
	match c.state:
		"SYN_SENT":
			if flags.has("SYN") and flags.has("ACK") and endpoint:
				c._peer = weakref(endpoint)
				c.output = endpoint.input
				c.output.add_writer()
				c.state = "ESTABLISHED"
				_send_segment(c, ["ACK"])
		"SYN_RECV":
			if flags.has("SYN") and not flags.has("ACK"):
				_send_segment(c, ["SYN", "ACK"]) # the client retried
			elif flags.has("ACK"):
				var client := c.peer
				if client == null:
					_drop(c)
					return
				c.output = client.input
				c.output.add_writer()
				c.state = "ESTABLISHED"
				var l: Listener = c.get_meta("listener")
				c.remove_meta("listener")
				if l.closed:
					c.close()
				else:
					l.queue.append(c)
		"ESTABLISHED":
			if flags.has("FIN"):
				c.state = "CLOSE_WAIT"
				_send_segment(c, ["ACK"])
		"FIN_WAIT1", "FIN_WAIT2":
			if flags.has("FIN"):
				c.state = "TIME_WAIT"
				c.expires = _now() + TIME_WAIT_LEN
				_send_segment(c, ["ACK"])
			elif flags.has("ACK"):
				c.state = "FIN_WAIT2"
		"LAST_ACK":
			if flags.has("ACK"):
				_drop(c)


func _close_hard(c: Conn) -> void:
	c._forget_listeners.call_deferred()
	if c.output:
		c.output.release_writer()
	c.input.release_reader()
	_drop(c)


## An ICMP error about one of our segments: during the handshake it ends
## the attempt with the matching errno.
func icmp_error(orig: Dictionary, type: int, code: int) -> void:
	var seg: Dictionary = orig.get("payload", {})
	var c: Conn = conns.get(_key(orig.src, int(seg.get("sport", 0)), orig.dst, int(seg.get("dport", 0))))
	if c == null or not c.state in ["SYN_SENT", "SYN_RECV"]:
		return
	c.error = AgoraErrno.EHOSTUNREACH if type == AgoraIcmp.TIME_EXCEEDED else ICMP_ERRNO.get(code, AgoraErrno.EHOSTUNREACH)
	_drop(c)


## Closes every socket of a process that went away.
func close_for(pid: int) -> void:
	for l in listeners.duplicate():
		if l.pid == pid:
			l.close()
	for c: Conn in conns.values():
		if c.pid == pid and c.state in ["ESTABLISHED", "CLOSE_WAIT", "SYN_RECV"]:
			c.close()


## Every socket for /proc/net/tcp: [local, lport, remote, rport, state, uid].
func sockets() -> Array:
	var out: Array = []
	for l in listeners:
		out.append([l.address, l.port, 0, 0, "LISTEN", l.uid])
	var now := _now()
	for k: String in conns.keys():
		var c: Conn = conns[k]
		if c.state == "TIME_WAIT" and c.expires < now:
			conns.erase(k)
			continue
		out.append([c.local_addr, c.local_port, c.remote_addr, c.remote_port, c.state, c.uid])
	return out
