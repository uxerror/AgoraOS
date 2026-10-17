extends AgoraProgram
## traceroute (the modern traceroute 2.x output; busybox's applet uses
## the old LBL defaults): sends probes with growing TTLs and lists the
## routers that answer with "time exceeded", until the destination itself
## answers. UDP probes to ports 33434 and up by default, ICMP echo with -I.

const BASE_PORT := 33434
const TICK := 0.016


func summary() -> String:
	return "print the route packets trace to network host"


func usage() -> String:
	return """Usage:
  traceroute [ -In ] [ -f first_ttl ] [ -m max_ttl ] [ -p port ] [ -q nqueries ] [ -w waittime ] host [ packetlen ]
Options:
  -I  --icmp                  Use ICMP ECHO for tracerouting
  -f first_ttl                Start from the first_ttl hop (instead from 1)
  -m max_ttl                  Set the max number of hops (max TTL to be reached). Default is 30
  -n                          Do not resolve IP addresses to their domain names
  -p port                     Set the destination port to use
  -q nqueries                 Set the number of probes per each hop. Default is 3
  -w waittime                 Set the number of seconds to wait for response to a probe (default is 5.0)"""


func main(p: AgoraProcess) -> int:
	var busybox := multicall == "busybox"
	var a := AgoraArgs.parse(p.argv, "fmpqwz")
	if not a.error.is_empty() or a.operands.is_empty():
		p.errln(usage())
		return 2
	var icmp := a.has("I") or a.has("icmp")
	var numeric := a.has("n")
	var first := int(a.value("f", "1"))
	var max_ttl := int(a.value("m", "30"))
	var queries := int(a.value("q", "3"))
	var wait := float(a.value("w", "5.0"))
	var port := int(a.value("p", str(BASE_PORT)))
	var host := a.operands[0]
	var size := int(a.operands[1]) if a.operands.size() > 1 else (40 if busybox else 60)
	if icmp and not p.cred.is_root():
		p.errln("You do not have enough privileges to use this traceroute method.")
		p.errln("socket: Operation not permitted")
		return 1
	var dst := AgoraResolver.lookup(p, host)
	if dst < 0:
		p.errln("%s: Name or service not known" % host)
		p.errln("Cannot handle \"host\" cmdline arg `%s' on position 1 (argc %d)" % [host, p.argv.size() - 1])
		return 2
	var net := p.machine.net
	p.outln("traceroute to %s (%s), %d hops max, %d byte packets" % [host, AgoraInet.to_str(dst), max_ttl, size])
	if net.lookup(dst).is_empty():
		p.errln("connect: Network is unreachable")
		return 1
	var replies := net.icmp.open_socket()
	var sock: AgoraUdp.Socket = null if icmp else net.udp.open(p, 0)
	var id := p.pid & 0xFFFF
	var tree := Engine.get_main_loop() as SceneTree
	var seq := 0
	for ttl in range(first, max_ttl + 1):
		var line := "%2d " % ttl
		var last := -1
		var done := false
		for q in queries:
			seq += 1
			var probe_port := port + seq - 1
			if icmp:
				net.ip_output(net.make_packet(0, dst, AgoraNetStack.IPPROTO_ICMP,
					{"type": AgoraIcmp.ECHO_REQUEST, "code": 0, "id": id, "seq": seq}, size - 20, ttl))
			else:
				sock.sendto(dst, probe_port, {}, size - 28, {"ttl": ttl})
			var answer: Dictionary = {}
			var deadline := Time.get_ticks_msec() + int(wait * 1000.0)
			while answer.is_empty() and Time.get_ticks_msec() < deadline and not p.is_dead():
				answer = _match(replies, icmp, id, seq, probe_port, sock.port if sock else 0)
				if answer.is_empty():
					await tree.create_timer(TICK).timeout
			if p.is_dead():
				break
			if answer.is_empty():
				line += " *"
				continue
			var from: int = answer.src
			if from != last:
				var ip := AgoraInet.to_str(from)
				var name := "" if numeric else AgoraResolver.reverse(p, from)
				line += " " + ip if numeric else " %s (%s)" % [name if not name.is_empty() else ip, ip]
				last = from
			line += "  %.3f ms" % float(answer.lat)
			var msg: Dictionary = answer.payload
			if msg.type == AgoraIcmp.ECHO_REPLY or (msg.type == AgoraIcmp.DEST_UNREACH and msg.code == AgoraIcmp.PORT_UNREACH):
				done = true
			elif msg.type == AgoraIcmp.DEST_UNREACH:
				var marks := {AgoraIcmp.NET_UNREACH: " !N", AgoraIcmp.HOST_UNREACH: " !H", AgoraIcmp.PROT_UNREACH: " !P",
					AgoraIcmp.NET_ANO: " !X", AgoraIcmp.HOST_ANO: " !X", AgoraIcmp.PKT_FILTERED: " !X"}
				line += marks.get(msg.code, " !<%d>" % msg.code)
				done = true
		p.outln(line)
		if done or p.is_dead():
			break
	replies.close()
	if sock:
		sock.close()
	return 0


## The reply to the probe just sent, if it has arrived.
func _match(replies: AgoraIcmp.Socket, icmp: bool, id: int, seq: int, port: int, sport: int) -> Dictionary:
	while not replies.inbox.is_empty():
		var pkt: Dictionary = replies.inbox.pop_front()
		var msg: Dictionary = pkt.payload
		if icmp and msg.type == AgoraIcmp.ECHO_REPLY and msg.get("id") == id and msg.get("seq") == seq:
			return pkt
		if not AgoraIcmp.ERRORS.has(int(msg.type)) or not msg.has("orig"):
			continue
		var orig: Dictionary = msg.orig
		var inner: Dictionary = orig.payload
		if icmp and orig.proto == AgoraNetStack.IPPROTO_ICMP and inner.get("id") == id and inner.get("seq") == seq:
			return pkt
		if not icmp and orig.proto == AgoraNetStack.IPPROTO_UDP and inner.get("dport") == port and inner.get("sport") == sport:
			return pkt
	return {}
