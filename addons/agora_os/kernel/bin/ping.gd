extends AgoraProgram
## ping: sends ICMP echo requests and reports the replies, as iputils ping
## does (busybox's applet prints its own, older format). Round-trip times
## come from the delays the packets picked up on the way.

const TICK := 0.016
## How long ping waits for late replies after the last request, seconds.
const LINGER := 10.0

var _interrupted := false
var _busybox := false


func summary() -> String:
	return "send ICMP ECHO_REQUEST to network hosts"


func usage() -> String:
	return """
Usage
  ping [options] <destination>

Options:
  <destination>      dns name or ip address
  -b                 allow pinging broadcast
  -c <count>         stop after <count> replies
  -i <interval>      seconds between sending each packet
  -n                 no dns name resolution
  -q                 quiet output
  -s <size>          use <size> as number of data bytes to be sent
  -t <ttl>           define time to live
  -W <timeout>       time to wait for response
  -w <deadline>      reply wait <deadline> in seconds"""


func _bad(p: AgoraProcess, what: String) -> int:
	p.errln("ping: invalid argument: '%s'" % what)
	return 2


func main(p: AgoraProcess) -> int:
	_busybox = multicall == "busybox"
	var a := AgoraArgs.parse(p.argv, "ciIstWw")
	if not a.error.is_empty():
		p.errln("ping: " + a.error)
		p.errln(usage())
		return 2
	if a.operands.is_empty():
		if _busybox:
			p.errln("BusyBox v%s multi-call binary\n\nUsage: ping [OPTION]... host" % "1.1.3")
			return 1
		p.errln("ping: usage error: Destination address required")
		return 1
	var count := 0
	var interval := 1.0
	var size := 56
	var ttl := -1
	var timeout := LINGER
	var deadline := 0.0
	for pair: Array in [["c", "count"], ["i", "interval"], ["s", "size"], ["t", "ttl"], ["W", "timeout"], ["w", "deadline"]]:
		if not a.has(pair[0]):
			continue
		var v := a.value(pair[0])
		if not v.is_valid_float():
			return _bad(p, v)
		match pair[0]:
			"c": count = int(v)
			"i": interval = float(v)
			"s": size = int(v)
			"t": ttl = int(v)
			"W": timeout = float(v)
			"w": deadline = float(v)
		if (pair[0] in ["c", "w"] and float(v) <= 0.0) or (pair[0] == "t" and (int(v) < 1 or int(v) > 255)) or (pair[0] == "s" and (int(v) < 0 or int(v) > 65507)):
			return _bad(p, v)
	if interval < 0.2 and not p.cred.is_root():
		p.errln("ping: cannot flood; minimal interval allowed for user is 200ms")
		return 2
	var quiet := a.has("q")
	var host := a.operands[0]
	var dst := AgoraResolver.lookup(p, host)
	if dst < 0:
		if _busybox:
			p.errln("ping: unknown host " + host)
			return 1
		p.errln("ping: %s: Name or service not known" % host)
		return 2
	var names := not a.has("n") and AgoraInet.parse(host) < 0
	var net := p.machine.net
	var route := net.lookup(dst)
	if route.is_empty() or route.type == "unreachable" or route.type == "prohibit":
		var why := "Network is unreachable" if route.is_empty() else "No route to host" if route.type == "unreachable" else "Permission denied"
		p.errln(("ping: sendto: " if _busybox else "ping: connect: ") + why)
		return 2
	if route.type == "unicast" and net.is_broadcast(net.iface(route.dev), dst) and not a.has("b"):
		p.errln("ping: Do you want to ping broadcast? Then -b. If not, check your local firewall rules")
		return 2
	var dst_text := AgoraInet.to_str(dst)
	if _busybox:
		p.outln("PING %s (%s): %d data bytes" % [host, dst_text, size])
	else:
		p.outln("PING %s (%s) %d(%d) bytes of data." % [host, dst_text, size, size + 28])

	var sock := net.icmp.open_socket()
	var id := p.pid & 0xFFFF
	p.signal_handler = func(sig: int) -> bool:
		if sig == AgoraProcess.SIGINT:
			_interrupted = true
			return true
		return false
	var tree := Engine.get_main_loop() as SceneTree
	var start := Time.get_ticks_msec()
	var next_send := start
	var last_send := start
	var sent := 0
	var received := 0
	var errors := 0
	var pipe := 0
	var seen := {}
	var rtts: Array[float] = []
	var first_seq := 0 if _busybox else 1
	while not p.is_dead():
		var now := Time.get_ticks_msec()
		if not _interrupted and (count == 0 or sent < count) and now >= next_send:
			var seq := first_seq + sent
			sent += 1
			pipe = maxi(pipe, sent - received - errors)
			var pkt := net.make_packet(0, dst, AgoraNetStack.IPPROTO_ICMP,
				{"type": AgoraIcmp.ECHO_REQUEST, "code": 0, "id": id, "seq": seq}, 8 + size, ttl)
			var code := net.ip_output(pkt)
			if code != AgoraErrno.OK:
				p.errln("ping: sendmsg: " + AgoraErrno.describe(code))
				errors += 1
			last_send = now
			next_send = now + int(interval * 1000.0)
		while not sock.inbox.is_empty():
			var pkt: Dictionary = sock.inbox.pop_front()
			var msg: Dictionary = pkt.payload
			var from := AgoraInet.to_str(pkt.src)
			if names:
				var name := AgoraResolver.reverse(p, pkt.src)
				if not name.is_empty():
					from = "%s (%s)" % [name, from]
			if msg.type == AgoraIcmp.ECHO_REPLY and msg.id == id:
				var dup: bool = seen.has(msg.seq)
				seen[msg.seq] = true
				if not dup:
					received += 1
					rtts.append(float(pkt.lat))
				if not quiet:
					p.outln(_reply_line(size + 8, from, msg.seq, pkt.ttl, float(pkt.lat)) + (" (DUP!)" if dup else ""))
			elif AgoraIcmp.ERRORS.has(int(msg.type)) and msg.has("orig"):
				var orig: Dictionary = msg.orig
				var echo: Dictionary = orig.payload
				if orig.proto != AgoraNetStack.IPPROTO_ICMP or echo.get("type") != AgoraIcmp.ECHO_REQUEST or echo.get("id") != id:
					continue
				if _busybox:
					p.errln("ping: Warning: Got ICMP %d (%s)" % [msg.type, "Destination Unreachable" if msg.type == AgoraIcmp.DEST_UNREACH else "Time Exceeded"])
					continue
				errors += 1
				if not quiet:
					p.outln("From %s icmp_seq=%d %s" % [from, echo.seq, AgoraIcmp.describe(msg.type, msg.code)])
		if _interrupted:
			break
		if deadline > 0.0 and now - start >= int(deadline * 1000.0):
			break
		if count > 0 and sent >= count:
			if received + errors >= count or now - last_send >= int(timeout * 1000.0):
				break
		await tree.create_timer(TICK).timeout
	sock.close()
	if p.is_dead():
		return 1
	_statistics(p, host, sent, received, errors, pipe, rtts, Time.get_ticks_msec() - start)
	return 0 if received > 0 else 1


## iputils prints three significant digits.
static func _ms(t: float) -> String:
	if t >= 100.0:
		return "%d" % int(t)
	if t >= 10.0:
		return "%.1f" % t
	if t >= 1.0:
		return "%.2f" % t
	return "%.3f" % t


func _reply_line(bytes: int, from: String, seq: int, ttl: int, rtt: float) -> String:
	if _busybox:
		return "%d bytes from %s: icmp_seq=%d ttl=%d time=%.1f ms" % [bytes, from, seq, ttl, rtt]
	return "%d bytes from %s: icmp_seq=%d ttl=%d time=%s ms" % [bytes, from, seq, ttl, _ms(rtt)]


func _statistics(p: AgoraProcess, host: String, sent: int, received: int, errors: int, pipe: int, rtts: Array[float], elapsed_ms: int) -> void:
	var loss := (sent - received) * 100 / sent if sent > 0 else 0
	var lo := 0.0
	var hi := 0.0
	var avg := 0.0
	var mdev := 0.0
	if not rtts.is_empty():
		lo = rtts.min()
		hi = rtts.max()
		var sum := 0.0
		var sq := 0.0
		for t in rtts:
			sum += t
			sq += t * t
		avg = sum / rtts.size()
		mdev = sqrt(maxf(0.0, sq / rtts.size() - avg * avg))
	p.outln("")
	p.outln("--- %s ping statistics ---" % host)
	if _busybox:
		p.outln("%d packets transmitted, %d packets received, %d%% packet loss" % [sent, received, loss])
		if received > 0:
			p.outln("round-trip min/avg/max = %.1f/%.1f/%.1f ms" % [lo, avg, hi])
		return
	var line := "%d packets transmitted, %d received" % [sent, received]
	if errors > 0:
		line += ", +%d errors" % errors
	p.outln(line + ", %d%% packet loss, time %dms" % [loss, elapsed_ms])
	if received > 0:
		p.outln("rtt min/avg/max/mdev = %.3f/%.3f/%.3f/%.3f ms%s" % [lo, avg, hi, mdev, ", pipe %d" % pipe if pipe > 1 else ""])
	elif pipe > 1:
		p.outln("pipe %d" % pipe)
