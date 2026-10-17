class_name AgoraTcp
extends RefCounted
## TCP for one network stack. Everything travels as segments: the
## three-way handshake, data, acknowledgements, FIN and RST, so routes,
## ARP, firewalls, NAT and cables matter for the whole life of a
## connection, not only its start.
##
## - A closed port answers with RST (ECONNREFUSED). ICMP errors during the
##   handshake abort it (EHOSTUNREACH, ENETUNREACH, ...). Unanswered SYNs
##   are retried with backoff (net.ipv4.tcp_syn_retries) until ETIMEDOUT.
## - Data is cut into MSS-sized segments with sequence numbers. What isn't
##   acknowledged is sent again when the retransmission timer runs out,
##   doubling it each time; after net.ipv4.tcp_retries2 tries the
##   connection is given up (ETIMEDOUT). Receivers take segments in order
##   and acknowledge every one; anything else gets a duplicate ACK.
## - No congestion control, no flow control (the window is always 65535).
##
## A segment's payload is {sport, dport, seq, ack, flags, win, data}; data
## is text, its length counted in UTF-8 bytes.

## Socket states, with their numbers in /proc/net/tcp.
const STATE_CODES := {
	"ESTABLISHED": 1, "SYN_SENT": 2, "SYN_RECV": 3, "FIN_WAIT1": 4, "FIN_WAIT2": 5,
	"TIME_WAIT": 6, "CLOSE": 7, "CLOSE_WAIT": 8, "LAST_ACK": 9, "LISTEN": 10, "CLOSING": 11,
}
const TIME_WAIT_LEN := 60.0
const SOMAXCONN := 128
const MSS := 1460
const WINDOW := 65535
## Retransmission timeout limits, as in Linux (TCP_TIMEOUT_INIT, TCP_RTO_MIN/MAX).
const RTO_INIT := 1.0
const RTO_MIN := 0.2
const RTO_MAX := 120.0
const TICK := 0.02

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
			await tree.create_timer(TICK).timeout
		return queue.pop_front() if not queue.is_empty() else null

	func close() -> void:
		closed = true
		var tcp := _tcp.get_ref() as AgoraTcp if _tcp else null
		if tcp:
			tcp.listeners.erase(self)
		for c: Conn in queue:
			c.close()
		queue.clear()


## One end of a connection. Read what arrives from [member input], write
## to [member output].
class Conn:
	var local_addr := 0
	var local_port := 0
	var remote_addr := 0
	var remote_port := 0
	var state := "CLOSE"
	var pid := 0
	var uid := 0
	var input := AgoraStream.new()
	var output := AgoraStream.new()
	## Why the connection ended (ECONNREFUSED, ECONNRESET, ETIMEDOUT...).
	var error := AgoraErrno.OK
	var expires := 0.0
	# Sequence space.
	var iss := 0
	var snd_una := 0
	var snd_nxt := 0
	var rcv_nxt := 0
	## Sent, not yet acknowledged: {seq, len, flags, data, sent, first}.
	var unacked: Array[Dictionary] = []
	var rto := RTO_INIT
	var srtt := 0.0
	var tries := 0
	var fin_sent := false
	var write_closed := false
	var read_closed := false
	var _timer := false
	var _pump: Callable
	var _tcp: WeakRef

	func _init() -> void:
		input.add_reader()
		input.add_writer()
		output.add_reader()

	func is_open() -> bool:
		return state == "ESTABLISHED" or state == "CLOSE_WAIT"

	## shutdown(SHUT_WR): no more data from this end; the other end reads
	## end-of-file once everything sent so far has arrived.
	func shutdown_write() -> void:
		var tcp := _tcp.get_ref() as AgoraTcp if _tcp else null
		if write_closed or not is_open() or tcp == null:
			return
		write_closed = true
		tcp._pump(self)
		output.release_reader()
		state = "LAST_ACK" if state == "CLOSE_WAIT" else "FIN_WAIT1"
		tcp._send_fin(self)

	## close(2): sends what is left, then FIN. Nothing more is read.
	func close() -> void:
		var tcp := _tcp.get_ref() as AgoraTcp if _tcp else null
		if not read_closed:
			read_closed = true
			input.release_reader()
		if tcp == null:
			return
		if state in ["SYN_SENT", "SYN_RECV"]:
			tcp._drop(self)
			return
		shutdown_write()


var listeners: Array[Listener] = []
## Connections by "local_addr:local_port>remote_addr:remote_port".
var conns := {}
var syn_retries := 6
var retries2 := 15
## Why the last [method listen] failed.
var last_error := AgoraErrno.OK
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


static func _bytes(text: String) -> int:
	return text.to_utf8_buffer().size()


static func _isn() -> int:
	return randi() & 0x7FFFFFFF


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


func _new_conn(local: int, lport: int, remote: int, rport: int, pid: int, uid: int) -> Conn:
	var c := Conn.new()
	c._tcp = weakref(self)
	c.local_addr = local
	c.local_port = lport
	c.remote_addr = remote
	c.remote_port = rport
	c.pid = pid
	c.uid = uid
	c.iss = _isn()
	c.snd_una = c.iss
	c.snd_nxt = c.iss + 1
	c._pump = _pump.bind(c)
	c.output.changed.connect(c._pump)
	conns[_key(local, lport, remote, rport)] = c
	return c


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
	var c := _new_conn(route.src, _free_port(dst, dport), dst, dport, p.pid, p.cred.uid)
	c.state = "SYN_SENT"
	var tree := Engine.get_main_loop() as SceneTree
	var wait := RTO_INIT
	for attempt in syn_retries + 1:
		var code := _emit(c, ["SYN"], c.iss, "")
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


## Forgets a connection: the application reads end-of-file and can't
## write any more.
func _drop(c: Conn) -> void:
	if c._pump.is_valid() and c.output.changed.is_connected(c._pump):
		c.output.changed.disconnect(c._pump)
	c._pump = Callable() # it is bound to c
	c.state = "CLOSE"
	c.unacked.clear()
	c.input.release_writer()
	if not c.write_closed:
		c.write_closed = true
		c.output.release_reader()
	conns.erase(_key(c.local_addr, c.local_port, c.remote_addr, c.remote_port))


func _emit(c: Conn, flags: Array, seq: int, data: String) -> int:
	var net := _net()
	if net == null:
		return AgoraErrno.ENETDOWN
	var header := 40 if "SYN" in flags else 20 # SYNs carry options (MSS, SACK, ...)
	var seg := {"sport": c.local_port, "dport": c.remote_port, "seq": seq, "flags": flags, "win": WINDOW, "data": data}
	if "ACK" in flags:
		seg.ack = c.rcv_nxt
	return net.ip_output(net.make_packet(c.local_addr, c.remote_addr, AgoraNetStack.IPPROTO_TCP, seg, header + _bytes(data)))


## Takes what the application wrote and sends it in segments.
func _pump(c: Conn) -> void:
	if c.write_closed or not c.state in ["ESTABLISHED", "CLOSE_WAIT"]:
		return
	var text := c.output.read_available()
	while not text.is_empty():
		var chunk := text.left(MSS)
		text = text.substr(chunk.length())
		var seg := {"seq": c.snd_nxt, "len": _bytes(chunk), "flags": ["ACK", "PSH"], "data": chunk, "sent": _now(), "first": true}
		c.snd_nxt += seg.len
		c.unacked.append(seg)
		_emit(c, seg.flags, seg.seq, chunk)
	_arm(c)


func _send_fin(c: Conn) -> void:
	if c.fin_sent:
		return
	c.fin_sent = true
	var seg := {"seq": c.snd_nxt, "len": 1, "flags": ["FIN", "ACK"], "data": "", "sent": _now(), "first": true}
	c.snd_nxt += 1
	c.unacked.append(seg)
	_emit(c, seg.flags, seg.seq, "")
	_arm(c)


## Runs the retransmission timer while something is unacknowledged.
func _arm(c: Conn) -> void:
	if c._timer or c.unacked.is_empty():
		return
	c._timer = true
	var tree := Engine.get_main_loop() as SceneTree
	while tree and not c.unacked.is_empty() and conns.has(_key(c.local_addr, c.local_port, c.remote_addr, c.remote_port)):
		await tree.create_timer(TICK).timeout
		if c.unacked.is_empty():
			break
		var oldest: Dictionary = c.unacked[0]
		if _now() - oldest.sent < c.rto:
			continue
		c.tries += 1
		if c.tries > retries2:
			c.error = AgoraErrno.ETIMEDOUT
			_drop(c)
			break
		c.rto = minf(c.rto * 2.0, RTO_MAX)
		# Go back: send everything that is outstanding again.
		for seg in c.unacked:
			seg.sent = _now()
			seg.first = false
			_emit(c, seg.flags, seg.seq, seg.data)
	c._timer = false


## A RST for a segment nobody wanted.
func _reset(packet: Dictionary) -> void:
	var net := _net()
	var seg: Dictionary = packet.payload
	var flags: Array = seg.get("flags", [])
	if flags.has("RST"):
		return
	var reply := {"sport": seg.get("dport", 0), "dport": seg.get("sport", 0), "flags": ["RST", "ACK"], "win": 0, "data": ""}
	if flags.has("ACK"):
		reply.seq = int(seg.get("ack", 0))
		reply.flags = ["RST"]
	else:
		reply.seq = 0
		reply.ack = int(seg.get("seq", 0)) + _bytes(str(seg.get("data", ""))) + (1 if flags.has("SYN") or flags.has("FIN") else 0)
	net.ip_output(net.make_packet(packet.dst, packet.src, AgoraNetStack.IPPROTO_TCP, reply, 20))


func receive(packet: Dictionary, _iface: AgoraNetStack.Iface) -> void:
	var seg: Dictionary = packet.payload
	var flags: Array = seg.get("flags", [])
	var key := _key(packet.dst, int(seg.get("dport", 0)), packet.src, int(seg.get("sport", 0)))
	var c: Conn = conns.get(key)
	if c:
		_segment(c, seg, flags)
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
		var s := _new_conn(packet.dst, int(seg.dport), packet.src, int(seg.sport), l.pid, l.uid)
		s.state = "SYN_RECV"
		s.rcv_nxt = int(seg.get("seq", 0)) + 1
		s.set_meta("listener", l)
		_emit(s, ["SYN", "ACK"], s.iss, "")
		return
	_reset(packet)


func _segment(c: Conn, seg: Dictionary, flags: Array) -> void:
	if flags.has("RST"):
		if c.state == "SYN_SENT":
			c.error = AgoraErrno.ECONNREFUSED
		elif c.state != "TIME_WAIT":
			c.error = AgoraErrno.ECONNRESET
		_drop(c)
		return
	var seq := int(seg.get("seq", 0))
	match c.state:
		"SYN_SENT":
			if flags.has("SYN") and flags.has("ACK") and int(seg.get("ack", -1)) == c.snd_nxt:
				c.rcv_nxt = seq + 1
				c.snd_una = c.snd_nxt
				c.state = "ESTABLISHED"
				_emit(c, ["ACK"], c.snd_nxt, "")
			return
		"SYN_RECV":
			if flags.has("SYN") and not flags.has("ACK"):
				_emit(c, ["SYN", "ACK"], c.iss, "") # the client retried
				return
			if not flags.has("ACK") or int(seg.get("ack", -1)) != c.snd_nxt:
				return
			c.snd_una = c.snd_nxt
			c.state = "ESTABLISHED"
			var l: Listener = c.get_meta("listener")
			c.remove_meta("listener")
			if l.closed:
				c.close()
				return
			l.queue.append(c)
		"TIME_WAIT":
			if flags.has("FIN"):
				_emit(c, ["ACK"], c.snd_nxt, "") # our last ACK got lost
			return
	if flags.has("ACK"):
		_acknowledged(c, int(seg.get("ack", 0)))
	if not conns.has(_key(c.local_addr, c.local_port, c.remote_addr, c.remote_port)):
		return
	var data: String = seg.get("data", "")
	var length := _bytes(data)
	if length == 0 and not flags.has("FIN"):
		return
	if seq != c.rcv_nxt:
		_emit(c, ["ACK"], c.snd_nxt, "") # a duplicate, or a gap: say what we expect
		return
	if length > 0:
		c.rcv_nxt += length
		if not c.read_closed:
			c.input.write(data)
	if flags.has("FIN"):
		c.rcv_nxt += 1
		c.input.release_writer()
		match c.state:
			"ESTABLISHED": c.state = "CLOSE_WAIT"
			"FIN_WAIT1": c.state = "CLOSING"
			"FIN_WAIT2": _time_wait(c)
	_emit(c, ["ACK"], c.snd_nxt, "")


## The other end has everything before [param ack].
func _acknowledged(c: Conn, ack: int) -> void:
	if ack <= c.snd_una or ack > c.snd_nxt:
		return
	c.snd_una = ack
	while not c.unacked.is_empty() and c.unacked[0].seq + c.unacked[0].len <= ack:
		var seg: Dictionary = c.unacked.pop_front()
		if seg.first:
			# Karn's rule: only segments sent once give a round-trip sample.
			var sample := _now() - float(seg.sent)
			c.srtt = sample if c.srtt == 0.0 else c.srtt * 0.875 + sample * 0.125
			c.rto = clampf(c.srtt * 3.0, RTO_MIN, RTO_MAX)
		c.tries = 0
	if c.fin_sent and ack == c.snd_nxt:
		match c.state:
			"FIN_WAIT1": c.state = "FIN_WAIT2"
			"CLOSING": _time_wait(c)
			"LAST_ACK": _drop(c)


func _time_wait(c: Conn) -> void:
	c.state = "TIME_WAIT"
	c.expires = _now() + TIME_WAIT_LEN
	c.unacked.clear()
	if c._pump.is_valid() and c.output.changed.is_connected(c._pump):
		c.output.changed.disconnect(c._pump)
	c._pump = Callable() # it is bound to c


## The kernel stops: every socket goes away.
func shutdown() -> void:
	for l in listeners.duplicate():
		l.close()
	for c: Conn in conns.values():
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
		if c.pid == pid:
			c.close()


## Every socket for /proc/net/tcp: [local, lport, remote, rport, state,
## uid, tx_queue, rx_queue].
func sockets() -> Array:
	var out: Array = []
	for l in listeners:
		out.append([l.address, l.port, 0, 0, "LISTEN", l.uid, 0, l.queue.size()])
	var now := _now()
	for k: String in conns.keys():
		var c: Conn = conns[k]
		if c.state == "TIME_WAIT" and c.expires < now:
			_drop(c)
			continue
		out.append([c.local_addr, c.local_port, c.remote_addr, c.remote_port, c.state, c.uid,
			c.snd_nxt - c.snd_una - (1 if c.fin_sent and c.snd_una < c.snd_nxt else 0), c.input.available()])
	return out
