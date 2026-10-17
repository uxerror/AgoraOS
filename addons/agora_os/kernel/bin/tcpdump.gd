extends AgoraProgram
## tcpdump 4.99: prints the frames an interface sends and receives, read
## from a packet socket ([AgoraCapture]). Decodes Ethernet, ARP, IPv4,
## ICMP, UDP, TCP (relative sequence numbers per conversation), DNS and
## DHCP, takes a filter expression in the pcap language, and shows raw
## bytes with -A, -x and -X (see [AgoraWire]). Without -n, addresses are
## looked up through the resolver, which makes DNS queries tcpdump then
## sees, just like the real one.

const VERSION := "4.99.0"
const LIBPCAP := "1.10.0"
const SNAPLEN := 262144
const TICK := 0.016

## /etc/services, as netbase has it.
const TCP_SERVICES := {
	20: "ftp-data", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "domain", 80: "http",
	110: "pop3", 111: "sunrpc", 113: "auth", 119: "nntp", 139: "netbios-ssn", 143: "imap2",
	443: "https", 445: "microsoft-ds", 513: "login", 514: "shell", 587: "submission", 993: "imaps",
	995: "pop3s", 3306: "mysql", 5432: "postgresql", 6000: "x11", 6667: "ircd", 8080: "http-alt",
}
const UDP_SERVICES := {
	53: "domain", 67: "bootps", 68: "bootpc", 69: "tftp", 123: "ntp", 137: "netbios-ns",
	138: "netbios-dgm", 161: "snmp", 162: "snmp-trap", 514: "syslog", 520: "route",
}
const PROTO_NAMES := {AgoraNetStack.IPPROTO_ICMP: "ICMP", AgoraNetStack.IPPROTO_TCP: "TCP", AgoraNetStack.IPPROTO_UDP: "UDP"}
const PROTO_KEYWORDS := {"ip": 0, "arp": 0, "ether": 0, "icmp": AgoraNetStack.IPPROTO_ICMP, "tcp": AgoraNetStack.IPPROTO_TCP, "udp": AgoraNetStack.IPPROTO_UDP}
const RCODE_TEXT := {"FORMERR": "FormErr", "SERVFAIL": "ServFail", "NXDOMAIN": "NXDomain", "NOTIMP": "NotImp", "REFUSED": "Refused"}
const ZERO_MAC := "00:00:00:00:00:00"
## Option letters that take a value.
const WITH_VALUE := "BcCEFGiMQrsTVwWyzZj"

var _stop := false
var _names := true
var _verbose := 0
var _quiet := false
var _link := false
var _stamps := 0
## "A", "x" or "X" with the count (2 includes the link-level header).
var _dump := ""
var _dump_link := false
var _any := false
var _p: AgoraProcess
var _hosts := {}
var _tcp_seq := {}
var _first_time := -1.0
var _prev_time := -1.0
# Filter parsing.
var _toks: PackedStringArray = []
var _pos := 0
var _last_quals: Dictionary = {}
var _filter_error := ""


func summary() -> String:
	return "dump traffic on a network"


func usage() -> String:
	return """Usage: tcpdump [-AbdDefhHIJKlLnNOpqStuUvxX#] [ -B size ] [ -c count ] [--count]
		[ -C file_size ] [ -E algo:secret ] [ -F file ] [ -G seconds ]
		[ -i interface ] [ --immediate-mode ] [ -j tstamptype ]
		[ -M secret ] [ --number ] [ --print ] [ -Q in|out|inout ]
		[ -r file ] [ -s snaplen ] [ -T type ] [ --version ]
		[ -V file ] [ -w file ] [ -W filecount ] [ -y datalinktype ]
		[ --time-stamp-precision precision ] [ --micro ] [ --nano ]
		[ -z postrotate-command ] [ -Z user ] [ expression ]"""


func _version() -> String:
	return "tcpdump version %s\nlibpcap version %s (with TPACKET_V3)\nOpenSSL 1.1.1w  11 Sep 2023" % [VERSION, LIBPCAP]


## getopt_long as glibc does it: options may follow the expression words.
## Returns {flags: {letter: count}, values: {letter: value}, words, error}.
static func _parse(argv: PackedStringArray) -> Dictionary:
	var r := {"flags": {}, "values": {}, "words": PackedStringArray(), "error": ""}
	var i := 1
	var long_values := {"interface": "i", "count": "c", "direction": "Q", "snapshot-length": "s"}
	var long_flags := {"list-interfaces": "D", "help": "h", "version": "version", "immediate-mode": "", "print": "", "micro": "", "number": "", "no-promiscuous-mode": "p", "line-buffered": "l"}
	while i < argv.size():
		var arg := argv[i]
		i += 1
		if arg == "--":
			r.words.append_array(argv.slice(i))
			break
		if arg.begins_with("--"):
			var name := arg.substr(2).get_slice("=", 0)
			if long_values.has(name):
				var value := arg.get_slice("=", 1) if arg.contains("=") else ""
				if not arg.contains("="):
					if i >= argv.size():
						r.error = "option '--%s' requires an argument" % name
						return r
					value = argv[i]
					i += 1
				r.values[long_values[name]] = value
			elif long_flags.has(name):
				var letter: String = long_flags[name]
				if not letter.is_empty():
					r.flags[letter] = int(r.flags.get(letter, 0)) + 1
			else:
				r.error = "unrecognized option '%s'" % arg
				return r
			continue
		if arg.length() < 2 or not arg.begins_with("-"):
			r.words.append(arg)
			continue
		var j := 1
		while j < arg.length():
			var c := arg[j]
			if WITH_VALUE.contains(c):
				var value := arg.substr(j + 1)
				if value.is_empty():
					if i >= argv.size():
						r.error = "option requires an argument -- '%s'" % c
						return r
					value = argv[i]
					i += 1
				r.values[c] = value
				break
			if not "AbdDefhHIJKlLnNOpqStuUvxX#".contains(c):
				r.error = "invalid option -- '%s'" % c
				return r
			r.flags[c] = int(r.flags.get(c, 0)) + 1
			j += 1
	return r


func main(p: AgoraProcess) -> int:
	_p = p
	var a := _parse(p.argv)
	if not a.error.is_empty():
		p.errln("tcpdump: " + a.error)
		p.errln(_version())
		p.errln(usage())
		return 1
	var flags: Dictionary = a.flags
	var values: Dictionary = a.values
	if flags.has("version"):
		p.outln(_version())
		return 0
	if flags.has("h"):
		p.outln(_version())
		p.outln(usage())
		return 0
	var net := p.machine.net
	if flags.has("D"):
		var n := 1
		for d: Array in _devices(net):
			p.outln("%d.%s" % [n, d[0]] + (" " + d[1] if not (d[1] as String).is_empty() else "") + " [%s]" % d[2])
			n += 1
		return 0
	for letter in ["w", "r", "C", "G", "W", "F", "V", "z", "E", "M"]:
		if values.has(letter):
			p.errln("tcpdump: -%s is not supported: packets here are not stored as bytes" % letter)
			return 1
	_names = not flags.has("n")
	_verbose = int(flags.get("v", 0))
	_quiet = flags.has("q")
	_link = flags.has("e")
	_stamps = int(flags.get("t", 0))
	for letter in ["X", "x", "A"]:
		if flags.has(letter):
			_dump = letter
			_dump_link = int(flags[letter]) > 1
			break
	var count := 0
	if values.has("c"):
		var v: String = values.c
		if not v.is_valid_int() or int(v) <= 0:
			p.errln("tcpdump: invalid packet count " + v)
			return 1
		count = int(v)
	var snaplen := SNAPLEN
	if values.has("s"):
		var v: String = values.s
		if not v.is_valid_int() or int(v) < 0 or int(v) > SNAPLEN:
			p.errln("tcpdump: invalid snaplen " + v)
			return 1
		snaplen = int(v) if int(v) > 0 else SNAPLEN
	var direction := "inout"
	if values.has("Q"):
		direction = values.Q
		if not direction in ["in", "out", "inout"]:
			p.errln("tcpdump: unknown direction '%s'" % direction)
			return 1
	var device: String = values.get("i", "")
	var listed := _devices(net)
	if device.is_valid_int():
		if int(device) < 1 or int(device) > listed.size():
			p.errln("tcpdump: Invalid adapter index %s: only %d interfaces found" % [device, listed.size()])
			return 1
		device = listed[int(device) - 1][0]
	if device.is_empty():
		for d: Array in listed:
			if d[0] != "any" and not (d[2] as String).contains("Loopback"):
				device = d[0]
				break
	if device.is_empty():
		p.errln("tcpdump: no suitable device found")
		return 1
	var cap := net.open_capture(p, device, not flags.has("p"))
	if cap == null:
		match net.last_capture_error:
			AgoraErrno.EPERM:
				p.errln("tcpdump: %s: You don't have permission to capture on that device" % device)
				p.errln("(socket: Operation not permitted)")
			AgoraErrno.ENODEV:
				p.errln("tcpdump: %s: No such device exists" % device)
				p.errln("(SIOCGIFHWADDR: No such device)")
			_:
				p.errln("tcpdump: %s: That device is not up" % device)
		return 1
	cap.direction = direction
	_any = device == "any"
	var filter: Variant = await _compile(" ".join(a.words))
	if filter == null:
		cap.close()
		p.errln("tcpdump: " + _filter_error)
		return 1
	if _verbose == 0:
		p.errln("tcpdump: verbose output suppressed, use -v[v]... for full protocol decode")
		p.err("listening on ")
	else:
		p.err("tcpdump: listening on ")
	var link_type := "LINUX_SLL2 (Linux cooked v2)" if _any else "EN10MB (Ethernet)"
	p.errln("%s, link-type %s, snapshot length %d bytes" % [device, link_type, snaplen])

	p.signal_handler = func(sig: int) -> bool:
		if sig in [AgoraProcess.SIGINT, AgoraProcess.SIGTERM, AgoraProcess.SIGHUP]:
			_stop = true
			return true
		return false
	var tree := Engine.get_main_loop() as SceneTree
	var captured := 0
	var received := 0
	var interrupted := false
	var failure := ""
	while not p.is_dead() and tree:
		while not cap.inbox.is_empty() and not _stop and not p.is_dead():
			var entry: Dictionary = cap.inbox.pop_front()
			if not _matches(filter, entry):
				continue
			received += 1
			var line: String = await _describe(entry)
			if p.is_dead() or not p.out(line + "\n"):
				break
			captured += 1
			if count > 0 and captured >= count:
				break
		if _stop:
			interrupted = true
			break
		if count > 0 and captured >= count:
			break
		if not _any:
			var i := net.iface(device)
			if i == null or not i.admin_up:
				failure = "The interface disappeared" if i == null else "The interface went down"
				break
		await tree.create_timer(TICK).timeout
	for entry in cap.inbox:
		if _matches(filter, entry):
			received += 1
	cap.close()
	p.signal_handler = Callable()
	if p.is_dead():
		return 1
	if not failure.is_empty():
		p.errln("tcpdump: pcap_loop: " + failure)
	if interrupted:
		p.errln("")
	p.errln("%d packet%s captured" % [captured, _s(captured)])
	p.errln("%d packet%s received by filter" % [received, _s(received)])
	p.errln("0 packets dropped by kernel")
	return 1 if not failure.is_empty() else 0


static func _s(n: int) -> String:
	return "" if n == 1 else "s"


## The interfaces in the order pcap_findalldevs gives them: up and
## running ones first, then "any", the loopback, and what is down.
## [[name, description, flags text]].
static func _devices(net: AgoraNetStack) -> Array:
	var running: Array = []
	var loop: Array = []
	var rest: Array = []
	for i in net.interfaces:
		if i.is_loopback():
			loop.append([i.name, "", "Up, Running, Loopback" if i.admin_up else "Loopback"])
		elif i.admin_up and i.carrier:
			running.append([i.name, "", "Up, Running, Connected"])
		else:
			rest.append([i.name, "", "Up, Disconnected" if i.admin_up else "Disconnected"])
	return running + [["any", "(Pseudo-device that captures on all interfaces)", "Up, Running"]] + loop + rest


# --- printing -----------------------------------------------------------------

func _describe(entry: Dictionary) -> String:
	var frame: Dictionary = entry.frame
	var out := _stamp(float(entry.time))
	var wire_len := _wire_len(entry)
	if _any:
		var how := "Out"
		if entry.dir == "in":
			how = "P  " if entry.otherhost else "B  " if frame.dst == AgoraNetStack.BROADCAST_MAC \
				else "M  " if AgoraBridge.is_multicast(frame.dst) else "In "
		out += "%-5s %s " % [entry.iface, how]
		if _link:
			var iface := _p.machine.net.iface(entry.iface)
			out += "ifindex %d %s ethertype %s, length %d: " % [iface.index if iface else 0, frame.src, _ethertype(int(frame.type)), wire_len - 14 + 20]
	elif _link:
		var dst := _mac(frame.dst)
		if _quiet:
			out += "%s > %s, %s, length %d: " % [_mac(frame.src), dst, _ethertype_name(int(frame.type)), wire_len]
		else:
			out += "%s > %s, ethertype %s, length %d: " % [_mac(frame.src), dst, _ethertype(int(frame.type)), wire_len]
	match int(frame.type):
		AgoraNetStack.ETH_P_ARP:
			out += await _arp(frame.payload, wire_len - 14)
		AgoraNetStack.ETH_P_IP:
			out += await _ip(frame.payload)
		_:
			out += "ethertype Unknown (0x%04x), length %d" % [int(frame.type), wire_len]
	if not _dump.is_empty():
		var bytes := AgoraWire.frame(frame)
		bytes.resize(wire_len) # padding of short frames received
		if not _dump_link:
			bytes = bytes.slice(14)
		match _dump:
			"A": out += _ascii(bytes)
			"x": out += _hex(bytes)
			"X": out += _hex_ascii(bytes)
	return out


## Bytes on the wire: frames from the cable are padded to 60.
static func _wire_len(entry: Dictionary) -> int:
	var frame: Dictionary = entry.frame
	var n := AgoraNetStack.ETH_HLEN + int(frame.get("len", 0))
	if entry.dir == "in" and entry.iface != "lo":
		n = maxi(AgoraNetStack.ETH_ZLEN, n)
	return n


static func _ethertype_name(type: int) -> String:
	return "IPv4" if type == AgoraNetStack.ETH_P_IP else "ARP" if type == AgoraNetStack.ETH_P_ARP else "Unknown"


static func _ethertype(type: int) -> String:
	return "%s (0x%04x)" % [_ethertype_name(type), type]


func _mac(mac: String) -> String:
	return "Broadcast" if _names and mac == AgoraNetStack.BROADCAST_MAC else mac


func _stamp(t: float) -> String:
	if _first_time < 0.0:
		_first_time = t
	var prev := _prev_time if _prev_time >= 0.0 else t
	_prev_time = t
	var usec := int(fmod(t, 1.0) * 1000000.0) % 1000000
	match _stamps:
		0:
			var d := _p.machine.clock.local_datetime(t)
			return "%02d:%02d:%02d.%06d " % [d.hour, d.minute, d.second, usec]
		1:
			return ""
		2:
			return "%d.%06d " % [int(t), usec]
		3, 5:
			var delta := maxf(0.0, t - (prev if _stamps == 3 else _first_time))
			var whole := int(delta)
			return "%02d:%02d:%02d.%06d " % [whole / 3600, whole / 60 % 60, whole % 60, int(fmod(delta, 1.0) * 1000000.0)]
	var d := _p.machine.clock.local_datetime(t)
	return "%04d-%02d-%02d %02d:%02d:%02d.%06d " % [d.year, d.month, d.day, d.hour, d.minute, d.second, usec]


func _host(addr: int) -> String:
	if not _names:
		return AgoraInet.to_str(addr)
	if not _hosts.has(addr):
		var name: String = await AgoraResolver.reverse(_p, addr)
		_hosts[addr] = name if not name.is_empty() else AgoraInet.to_str(addr)
	return _hosts[addr]


func _port(port: int, proto: int) -> String:
	var table := TCP_SERVICES if proto == AgoraNetStack.IPPROTO_TCP else UDP_SERVICES
	return table[port] if _names and table.has(port) else str(port)


func _arp(arp: Dictionary, length: int) -> String:
	var out := "" if _link else "ARP, "
	var tpa: String = await _host(int(arp.get("tpa", 0)))
	var spa: String = await _host(int(arp.get("spa", 0)))
	if arp.get("op") == AgoraNeighbours.ARPOP_REQUEST:
		var tha: String = arp.get("tha", ZERO_MAC)
		out += "Request who-has %s%s tell %s" % [tpa, "" if tha == ZERO_MAC else " (%s)" % _mac(tha), spa]
	elif arp.get("op") == AgoraNeighbours.ARPOP_REPLY:
		out += "Reply %s is-at %s" % [spa, _mac(arp.get("sha", ""))]
	else:
		out += "Unknown opcode (%d)" % int(arp.get("op", 0))
	return out + ", length %d" % length


func _ip_header(pkt: Dictionary) -> String:
	var proto := int(pkt.proto)
	return "(tos 0x0, ttl %d, id %d, offset 0, flags [%s], proto %s (%d), length %d)" % [
		int(pkt.ttl), int(pkt.id), "DF" if AgoraWire.dont_fragment(pkt) else "none",
		PROTO_NAMES.get(proto, "unknown"), proto, int(pkt.len)]


func _ip(pkt: Dictionary) -> String:
	var out := "" if _link else "IP "
	if _verbose > 0:
		out += _ip_header(pkt) + "\n    "
	return out + await _ip_body(pkt)


## "src > dst: ..." for a datagram.
func _ip_body(pkt: Dictionary) -> String:
	var proto := int(pkt.proto)
	var body: Dictionary = pkt.get("payload", {})
	var src: String = await _host(int(pkt.src))
	var dst: String = await _host(int(pkt.dst))
	match proto:
		AgoraNetStack.IPPROTO_ICMP:
			return "%s > %s: %s" % [src, dst, await _icmp(pkt)]
		AgoraNetStack.IPPROTO_TCP:
			return "%s.%s > %s.%s: %s" % [src, _port(int(body.get("sport", 0)), proto), dst, _port(int(body.get("dport", 0)), proto), _tcp(pkt)]
		AgoraNetStack.IPPROTO_UDP:
			return "%s.%s > %s.%s: %s" % [src, _port(int(body.get("sport", 0)), proto), dst, _port(int(body.get("dport", 0)), proto), await _udp(pkt)]
	return "%s > %s: ip-proto-%d %d" % [src, dst, proto, int(pkt.len) - 20]


func _icmp(pkt: Dictionary) -> String:
	var m: Dictionary = pkt.payload
	var length := int(pkt.len) - 20
	var type := int(m.get("type", -1))
	var code := int(m.get("code", 0))
	var text := ""
	match type:
		AgoraIcmp.ECHO_REQUEST, AgoraIcmp.ECHO_REPLY:
			text = "ICMP echo %s, id %d, seq %d" % ["request" if type == AgoraIcmp.ECHO_REQUEST else "reply", int(m.get("id", 0)), int(m.get("seq", 0))]
		AgoraIcmp.TIME_EXCEEDED:
			text = "ICMP time exceeded in-transit" if code == 0 else "ICMP ip reassembly time exceeded"
		AgoraIcmp.DEST_UNREACH:
			var orig: Dictionary = m.get("orig", {})
			var target: String = await _host(int(orig.get("dst", 0)))
			match code:
				AgoraIcmp.NET_UNREACH: text = "ICMP net %s unreachable" % target
				AgoraIcmp.HOST_UNREACH: text = "ICMP host %s unreachable" % target
				AgoraIcmp.PROT_UNREACH: text = "ICMP %s protocol %d unreachable" % [target, int(orig.get("proto", 0))]
				AgoraIcmp.PORT_UNREACH:
					var oproto := int(orig.get("proto", 0))
					var dport := int((orig.get("payload", {}) as Dictionary).get("dport", 0))
					text = "ICMP %s %s port %s unreachable" % [target, "tcp" if oproto == AgoraNetStack.IPPROTO_TCP else "udp", _port(dport, oproto)]
				AgoraIcmp.FRAG_NEEDED: text = "ICMP %s unreachable - need to frag (mtu 1500)" % target
				AgoraIcmp.NET_ANO: text = "ICMP net %s unreachable - admin prohibited" % target
				AgoraIcmp.HOST_ANO: text = "ICMP host %s unreachable - admin prohibited" % target
				AgoraIcmp.PKT_FILTERED: text = "ICMP host %s unreachable - admin prohibited filter" % target
				_: text = "ICMP %s unreachable - #%d" % [target, code]
		_:
			text = "ICMP type-#%d" % type
	text += ", length %d" % length
	if _verbose > 0 and m.has("orig"):
		# The quoted header, as tcpdump -v decodes it.
		var orig: Dictionary = m.orig
		text += "\n\tIP %s\n    %s" % [_ip_header(orig), await _quoted(orig)]
	return text


## The start of a datagram quoted in an ICMP error: only 8 bytes of its
## payload are there.
func _quoted(orig: Dictionary) -> String:
	var proto := int(orig.proto)
	var body: Dictionary = orig.get("payload", {})
	var src: String = await _host(int(orig.src))
	var dst: String = await _host(int(orig.dst))
	match proto:
		AgoraNetStack.IPPROTO_UDP:
			return "%s.%s > %s.%s: UDP, length %d" % [src, _port(int(body.get("sport", 0)), proto), dst, _port(int(body.get("dport", 0)), proto), int(orig.len) - 28]
		AgoraNetStack.IPPROTO_TCP:
			return "%s.%s > %s.%s: [|tcp]" % [src, _port(int(body.get("sport", 0)), proto), dst, _port(int(body.get("dport", 0)), proto)]
		AgoraNetStack.IPPROTO_ICMP:
			return "%s > %s: ICMP echo %s, id %d, seq %d, length %d" % [src, dst, "request" if body.get("type") == AgoraIcmp.ECHO_REQUEST else "reply",
				int(body.get("id", 0)), int(body.get("seq", 0)), int(orig.len) - 20]
	return "%s > %s: ip-proto-%d" % [src, dst, proto]


func _tcp(pkt: Dictionary) -> String:
	var seg: Dictionary = pkt.payload
	var flags: Array = seg.get("flags", [])
	var data := str(seg.get("data", ""))
	var header := 20 + (AgoraWire.SYN_OPTIONS.size() if flags.has("SYN") else 0)
	var length := maxi(0, int(pkt.len) - 20 - header)
	if _quiet:
		return "tcp %d" % length
	var seq := int(seg.get("seq", 0)) & 0xFFFFFFFF
	var ack := int(seg.get("ack", 0)) & 0xFFFFFFFF
	if flags.has("ACK"):
		# print-tcp.c: one entry per conversation, made (or renewed by a SYN)
		# from the packet that is shown in absolute numbers.
		var sport := int(seg.get("sport", 0))
		var dport := int(seg.get("dport", 0))
		var rev: bool = int(pkt.src) > int(pkt.dst) or (pkt.src == pkt.dst and sport > dport)
		var key := "%d.%d-%d.%d" % ([pkt.dst, dport, pkt.src, sport] if rev else [pkt.src, sport, pkt.dst, dport])
		if not _tcp_seq.has(key) or flags.has("SYN"):
			_tcp_seq[key] = [ack - 1, seq] if rev else [seq, ack - 1]
		else:
			var base: Array = _tcp_seq[key]
			if rev:
				seq = (seq - int(base[1])) & 0xFFFFFFFF
				ack = (ack - int(base[0])) & 0xFFFFFFFF
			else:
				seq = (seq - int(base[0])) & 0xFFFFFFFF
				ack = (ack - int(base[1])) & 0xFFFFFFFF
	var letters := ""
	for pair: Array in [["FIN", "F"], ["SYN", "S"], ["RST", "R"], ["PSH", "P"], ["ACK", "."], ["URG", "U"]]:
		if flags.has(pair[0]):
			letters += pair[1]
	var out := "Flags [%s]" % (letters if not letters.is_empty() else "none")
	if _verbose > 0:
		var bytes := AgoraWire.packet(pkt)
		out += ", cksum 0x%04x (correct)" % ((bytes[36] << 8) | bytes[37])
	if length > 0:
		out += ", seq %d:%d" % [seq, (seq + length) & 0xFFFFFFFF]
	elif flags.has("SYN") or flags.has("FIN") or flags.has("RST"):
		out += ", seq %d" % seq
	if flags.has("ACK"):
		out += ", ack %d" % ack
	out += ", win %d" % int(seg.get("win", 0))
	if flags.has("SYN"):
		out += ", options [mss 1460,nop,nop,sackOK,nop,wscale 7]"
	out += ", length %d" % length
	var ports := [int(seg.get("sport", 0)), int(seg.get("dport", 0))]
	if 22 in ports and data.begins_with("SSH-"):
		out += ": " + data.get_slice("\n", 0).trim_suffix("\r")
	return out


func _udp(pkt: Dictionary) -> String:
	var u: Dictionary = pkt.payload
	var length := int(pkt.len) - 28
	if _quiet:
		return "UDP, length %d" % length
	var out := ""
	if _verbose > 1:
		out = "[udp sum ok] "
	var ports := [int(u.get("sport", 0)), int(u.get("dport", 0))]
	var data: Variant = u.get("data")
	if AgoraDns.PORT in ports and AgoraDns.is_valid(data):
		return out + await _dns(data, length)
	if (AgoraDhcp.SERVER_PORT in ports or AgoraDhcp.CLIENT_PORT in ports) and data is Dictionary and data.has("chaddr"):
		if int(data.get("op", 0)) == AgoraDhcp.BOOTREQUEST:
			return out + "BOOTP/DHCP, Request from %s, length %d" % [_mac(data.chaddr), length]
		return out + "BOOTP/DHCP, Reply, length %d" % length
	return out + "UDP, length %d" % length


func _dns(m: Dictionary, size: int) -> String:
	var question: Array = m.get("question", [])
	var q: Dictionary = question[0] if not question.is_empty() else {}
	var asked := " %s? %s." % [q.get("type", "A"), q.get("name", "")] if not q.is_empty() else ""
	if not m.get("qr", false):
		return "%d%s%s (%d)" % [int(m.id), "+" if m.get("rd", false) else "", asked, size]
	var out := "%d%s%s%s" % [int(m.id), "*" if m.get("aa", false) else "", "" if m.get("ra", false) else "-", "|" if m.get("tc", false) else ""]
	if RCODE_TEXT.has(m.get("rcode", "NOERROR")):
		out += " " + RCODE_TEXT[m.rcode]
	if _verbose > 0:
		out += " q:" + asked
	var answer: Array = m.get("answer", [])
	out += " %d/%d/%d" % [answer.size(), (m.get("authority", []) as Array).size(), (m.get("additional", []) as Array).size()]
	var records: PackedStringArray = []
	for rr: Dictionary in answer:
		var text := ""
		if _verbose > 0:
			text = "%s. [%s] " % [rr.name, _relts(int(rr.get("ttl", 0)))]
		text += "%s %s" % [rr.type, rr.data if rr.type == "A" else str(rr.data) + "."]
		records.append(text)
	if not records.is_empty():
		out += " " + ", ".join(records)
	return out + " (%d)" % size


## A duration as tcpdump writes TTLs: 1h30m, 5m, 0s.
static func _relts(secs: int) -> String:
	if secs == 0:
		return "0s"
	var out := ""
	for unit: Array in [[31536000, "y"], [604800, "w"], [86400, "d"], [3600, "h"], [60, "m"], [1, "s"]]:
		if secs >= unit[0]:
			out += "%d%s" % [secs / int(unit[0]), unit[1]]
			secs %= int(unit[0])
	return out


static func _graph(b: int) -> bool:
	return b > 32 and b < 127


## -A: the bytes as text, unprintable ones as dots.
static func _ascii(bytes: PackedByteArray) -> String:
	var out := "\n"
	for k in bytes.size():
		var b := bytes[k]
		if b == 13:
			if k + 1 == bytes.size() or bytes[k + 1] != 10:
				out += "."
		elif _graph(b) or b in [9, 10, 32]:
			out += char(b)
		else:
			out += "."
	return out


## -x: hex, 16 bytes a line.
static func _hex(bytes: PackedByteArray) -> String:
	var out := ""
	var k := 0
	while k < bytes.size():
		if k % 16 == 0:
			out += "\n\t0x%04x: " % k
		out += " %02x%02x" % [bytes[k], bytes[k + 1]] if k + 1 < bytes.size() else " %02x" % bytes[k]
		k += 2
	return out


## -X: hex and text side by side.
static func _hex_ascii(bytes: PackedByteArray) -> String:
	var out := ""
	for start in range(0, bytes.size(), 16):
		var hexs := ""
		var text := ""
		for k in range(start, mini(start + 16, bytes.size()), 2):
			hexs += " %02x%02x" % [bytes[k], bytes[k + 1]] if k + 1 < bytes.size() else " %02x" % bytes[k]
			text += char(bytes[k]) if _graph(bytes[k]) else "."
			if k + 1 < bytes.size():
				text += char(bytes[k + 1]) if _graph(bytes[k + 1]) else "."
		out += "\n\t0x%04x: %s  %s" % [start, hexs.rpad(40), text]
	return out


# --- filters ------------------------------------------------------------------

## Parses and prepares a pcap filter expression: names are resolved now,
## as libpcap does when it compiles. Returns the tree, or null with
## [member _filter_error] set. An empty expression takes everything.
func _compile(text: String) -> Variant:
	_toks = _tokenize(text)
	_pos = 0
	_last_quals = {}
	_filter_error = ""
	if _toks.is_empty():
		return ["true"]
	var tree: Variant = _expr()
	if tree == null or _pos < _toks.size():
		if _filter_error.is_empty():
			_filter_error = "can't parse filter expression: syntax error"
		return null
	if not await _resolve(tree):
		return null
	return tree


static func _tokenize(text: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var word := ""
	var k := 0
	while k < text.length():
		var c := text[k]
		var two := text.substr(k, 2)
		var special := ""
		if two in ["&&", "||"]:
			special = two
		elif c in ["(", ")", "!"]:
			special = c
		if not special.is_empty() or c in [" ", "\t", "\n"]:
			if not word.is_empty():
				out.append(word)
				word = ""
			if not special.is_empty():
				out.append(special)
			k += maxi(1, special.length())
			continue
		word += c
		k += 1
	if not word.is_empty():
		out.append(word)
	return out


func _peek(ahead: int = 0) -> String:
	return _toks[_pos + ahead] if _pos + ahead < _toks.size() else ""


func _expr() -> Variant:
	var left: Variant = _term()
	while left != null and _peek() in ["or", "||"]:
		_pos += 1
		var right: Variant = _term()
		left = ["or", left, right] if right != null else null
	return left


func _term() -> Variant:
	var left: Variant = _unary()
	while left != null and _peek() in ["and", "&&"]:
		_pos += 1
		var right: Variant = _unary()
		left = ["and", left, right] if right != null else null
	return left


func _unary() -> Variant:
	var t := _peek()
	if t in ["not", "!"]:
		_pos += 1
		var inner: Variant = _unary()
		return ["not", inner] if inner != null else null
	if t == "(":
		_pos += 1
		var inner: Variant = _expr()
		if inner == null or _peek() != ")":
			return null
		_pos += 1
		return inner
	return _primitive()


const _KEYWORDS: PackedStringArray = ["and", "or", "not", "&&", "||", "!", "(", ")", "src", "dst", "host", "net", "port",
	"portrange", "less", "greater", "broadcast", "ip", "arp", "ether", "tcp", "udp", "icmp"]


func _primitive() -> Variant:
	var t := _peek()
	if t.is_empty():
		return null
	if t in ["less", "greater"]:
		_pos += 1
		var n := _peek()
		if not n.is_valid_int():
			return null
		_pos += 1
		return ["len", t, int(n)]
	var proto := ""
	var dir := ""
	var type := ""
	if PROTO_KEYWORDS.has(t):
		proto = t
		_pos += 1
		t = _peek()
		if not t in ["src", "dst", "host", "net", "port", "portrange", "broadcast"]:
			return ["proto", proto] if proto != "ether" else null
	if t == "broadcast":
		_pos += 1
		return ["broadcast"]
	if t in ["src", "dst"]:
		dir = t
		_pos += 1
		if _peek() in ["or", "and"] and _peek(1) in ["src", "dst"] and _peek(1) != dir:
			dir = "src %s dst" % _peek()
			_pos += 2
	if _peek() in ["host", "net", "port", "portrange"]:
		type = _peek()
		_pos += 1
	elif proto.is_empty() and dir.is_empty():
		# A bare value repeats the qualifiers before it: "host a or b".
		if _last_quals.is_empty() or _KEYWORDS.has(t):
			return null
		proto = _last_quals.proto
		dir = _last_quals.dir
		type = _last_quals.type
	else:
		type = "host"
	var value := _peek()
	if value.is_empty() or _KEYWORDS.has(value):
		return null
	_pos += 1
	_last_quals = {"proto": proto, "dir": dir, "type": type}
	return ["prim", proto, dir, type, value]


## Checks values and resolves names in place. False with an error set.
func _resolve(node: Array) -> bool:
	match node[0]:
		"and", "or":
			if not await _resolve(node[1]):
				return false
			return await _resolve(node[2])
		"not":
			return await _resolve(node[1])
		"prim":
			pass
		_:
			return true
	var proto: String = node[1]
	var type: String = node[3]
	var value: String = node[4]
	if proto in ["tcp", "udp", "icmp"] and type in ["host", "net"]:
		_filter_error = "'%s' modifier applied to %s" % [proto, type]
		return false
	if proto in ["ether", "arp", "icmp"] and type in ["port", "portrange"]:
		_filter_error = "'%s' modifier applied to %s" % [proto, type]
		return false
	match type:
		"host":
			if proto == "ether":
				if not AgoraNetStack.is_valid_mac(value):
					_filter_error = "unknown ether host '%s'" % value
					return false
				node.append(value.to_lower())
				return true
			var addr := AgoraInet.parse(value)
			if addr < 0:
				addr = await AgoraResolver.lookup(_p, value)
			if addr < 0:
				_filter_error = "unknown host '%s'" % value
				return false
			node.append(addr)
		"net":
			var addr_text := value.get_slice("/", 0)
			var parts := addr_text.split(".")
			var prefix := parts.size() * 8
			while parts.size() < 4:
				parts.append("0")
			var addr := AgoraInet.parse(".".join(parts))
			if value.contains("/"):
				var len_text := value.get_slice("/", 1)
				prefix = int(len_text) if len_text.is_valid_int() else -1
			if addr < 0 or prefix < 0 or prefix > 32:
				_filter_error = "can't parse filter expression: syntax error"
				return false
			if AgoraInet.network(addr, prefix) != addr:
				_filter_error = "non-network bits set in \"%s\"" % value
				return false
			node.append([addr, prefix])
		"port":
			var port := _port_number(value)
			if port < 0:
				return false
			node.append([port, port])
		"portrange":
			var lo := _port_number(value.get_slice("-", 0))
			var hi := _port_number(value.get_slice("-", 1)) if value.contains("-") else lo
			if lo < 0 or hi < 0:
				return false
			node.append([mini(lo, hi), maxi(lo, hi)])
	return true


func _port_number(text: String) -> int:
	if text.is_valid_int():
		if int(text) < 0 or int(text) > 65535:
			_filter_error = "illegal port number %s > 65535" % text
			return -1
		return int(text)
	for table: Dictionary in [TCP_SERVICES, UDP_SERVICES]:
		for port: int in table:
			if table[port] == text:
				return port
	_filter_error = "unknown port '%s'" % text
	return -1


func _matches(node: Array, entry: Dictionary) -> bool:
	match node[0]:
		"true":
			return true
		"and":
			return _matches(node[1], entry) and _matches(node[2], entry)
		"or":
			return _matches(node[1], entry) or _matches(node[2], entry)
		"not":
			return not _matches(node[1], entry)
		"len":
			var n := _wire_len(entry)
			return n <= int(node[2]) if node[1] == "less" else n >= int(node[2])
		"broadcast":
			return entry.frame.dst == AgoraNetStack.BROADCAST_MAC
		"proto":
			return _is_proto(entry.frame, node[1])
	# A qualified primitive: [prim, proto, dir, type, value, resolved].
	var frame: Dictionary = entry.frame
	var proto: String = node[1]
	var dir: String = node[2]
	var type: String = node[3]
	if not proto.is_empty() and not _is_proto(frame, proto):
		return false
	var pair := []
	match type:
		"host", "net":
			if proto == "ether":
				pair = [frame.src, frame.dst]
			elif frame.type == AgoraNetStack.ETH_P_IP:
				pair = [frame.payload.src, frame.payload.dst]
			elif frame.type == AgoraNetStack.ETH_P_ARP and proto != "ip":
				pair = [frame.payload.get("spa", 0), frame.payload.get("tpa", 0)]
		"port", "portrange":
			if frame.type == AgoraNetStack.ETH_P_IP and frame.payload.proto in [AgoraNetStack.IPPROTO_TCP, AgoraNetStack.IPPROTO_UDP]:
				var body: Dictionary = frame.payload.payload
				pair = [int(body.get("sport", -1)), int(body.get("dport", -1))]
	if pair.is_empty():
		return false
	var hits := []
	for v: Variant in pair:
		match type:
			"host":
				hits.append(v == node[5])
			"net":
				hits.append(AgoraInet.in_subnet(int(v), node[5][0], node[5][1]))
			_:
				hits.append(int(v) >= node[5][0] and int(v) <= node[5][1])
	match dir:
		"src": return hits[0]
		"dst": return hits[1]
		"src and dst": return hits[0] and hits[1]
	return hits[0] or hits[1]


static func _is_proto(frame: Dictionary, proto: String) -> bool:
	match proto:
		"ether":
			return true
		"ip":
			return frame.type == AgoraNetStack.ETH_P_IP
		"arp":
			return frame.type == AgoraNetStack.ETH_P_ARP
	return frame.type == AgoraNetStack.ETH_P_IP and frame.payload.proto == PROTO_KEYWORDS[proto]
