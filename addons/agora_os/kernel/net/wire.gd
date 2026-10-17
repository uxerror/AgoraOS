class_name AgoraWire
extends RefCounted
## The bytes a frame would have on the wire. The stack moves dictionaries;
## tools that show raw data (tcpdump -A, -x, -X) and checksums need the
## encoding real headers have: Ethernet, ARP, IPv4, ICMP, UDP, TCP, and DNS
## and DHCP inside UDP. Data without a byte form is zero-filled up to the
## length the packet claims.

const TCP_FLAG_BITS := {"FIN": 0x01, "SYN": 0x02, "RST": 0x04, "PSH": 0x08, "ACK": 0x10, "URG": 0x20}
## TCP options Linux puts in a SYN (with tcp_timestamps off): mss 1460,
## nop, nop, sackOK, nop, wscale 7.
const SYN_OPTIONS: PackedByteArray = [2, 4, 0x05, 0xB4, 1, 1, 4, 2, 1, 3, 3, 7]


static func frame(f: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	_mac(out, f.get("dst", ""))
	_mac(out, f.get("src", ""))
	_u16(out, int(f.get("type", 0)))
	match int(f.get("type", 0)):
		AgoraNetStack.ETH_P_IP:
			out.append_array(packet(f.payload))
		AgoraNetStack.ETH_P_ARP:
			out.append_array(arp(f.payload))
	return out


static func arp(a: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	_u16(out, 1)
	_u16(out, AgoraNetStack.ETH_P_IP)
	out.append_array([6, 4])
	_u16(out, int(a.get("op", 0)))
	_mac(out, a.get("sha", ""))
	_u32(out, int(a.get("spa", 0)))
	_mac(out, a.get("tha", ""))
	_u32(out, int(a.get("tpa", 0)))
	return out


## Linux sets DF on what its sockets send; the kernel's own ICMP answers
## and the DHCP tools' raw packets go without it.
static func dont_fragment(p: Dictionary) -> bool:
	var body: Dictionary = p.get("payload", {})
	match int(p.get("proto", 0)):
		AgoraNetStack.IPPROTO_ICMP:
			return body.get("type") == AgoraIcmp.ECHO_REQUEST
		AgoraNetStack.IPPROTO_UDP:
			return not int(body.get("sport", 0)) in [AgoraDhcp.SERVER_PORT, AgoraDhcp.CLIENT_PORT]
	return true


static func ip_header(p: Dictionary) -> PackedByteArray:
	var h := PackedByteArray([0x45, 0])
	_u16(h, int(p.get("len", 20)))
	_u16(h, int(p.get("id", 0)))
	_u16(h, 0x4000 if dont_fragment(p) else 0)
	h.append_array([int(p.get("ttl", 64)) & 255, int(p.get("proto", 0)) & 255, 0, 0])
	_u32(h, int(p.get("src", 0)))
	_u32(h, int(p.get("dst", 0)))
	var sum := checksum(h)
	h[10] = sum >> 8
	h[11] = sum & 255
	return h


## The whole IP datagram, header included.
static func packet(p: Dictionary) -> PackedByteArray:
	var out := ip_header(p)
	var size := maxi(0, int(p.get("len", 20)) - 20)
	var body: Dictionary = p.get("payload", {})
	match int(p.get("proto", 0)):
		AgoraNetStack.IPPROTO_ICMP:
			out.append_array(_fit(icmp(body, size), size))
		AgoraNetStack.IPPROTO_UDP:
			out.append_array(_transport(p, udp(body, size), 6))
		AgoraNetStack.IPPROTO_TCP:
			out.append_array(_transport(p, tcp(body, size), 16))
		_:
			out.append_array(_fit(PackedByteArray(), size))
	return out


static func icmp(m: Dictionary, size: int) -> PackedByteArray:
	var out := PackedByteArray([int(m.get("type", 0)), int(m.get("code", 0)), 0, 0])
	if m.has("orig"):
		out.append_array([0, 0, 0, 0])
		var orig: Dictionary = m.orig
		out.append_array(packet(orig).slice(0, 28))
	else:
		_u16(out, int(m.get("id", 0)))
		_u16(out, int(m.get("seq", 0)))
		# iputils: a timeval, then the bytes 0x10, 0x11, ... ("!\"#$%&'()*+,-./0123..." in -A).
		var stamp := Time.get_unix_time_from_system()
		var data := PackedByteArray()
		data.resize(16)
		data.encode_s64(0, int(stamp))
		data.encode_s64(8, int(fmod(stamp, 1.0) * 1000000.0))
		for k in range(16, maxi(16, size - 8)):
			data.append(k & 255)
		out.append_array(data)
	out = _fit(out, size)
	var sum := checksum(out)
	out[2] = sum >> 8
	out[3] = sum & 255
	return out


static func udp(u: Dictionary, size: int) -> PackedByteArray:
	var out := PackedByteArray()
	_u16(out, int(u.get("sport", 0)))
	_u16(out, int(u.get("dport", 0)))
	_u16(out, size)
	_u16(out, 0)
	var data: Variant = u.get("data")
	if data is String:
		out.append_array((data as String).to_utf8_buffer())
	elif AgoraDns.is_valid(data):
		out.append_array(dns(data))
	elif data is Dictionary and data.has("xid") and data.has("chaddr"):
		out.append_array(dhcp(data))
	return _fit(out, size)


static func tcp(s: Dictionary, size: int) -> PackedByteArray:
	var out := PackedByteArray()
	var flags: Array = s.get("flags", [])
	_u16(out, int(s.get("sport", 0)))
	_u16(out, int(s.get("dport", 0)))
	_u32(out, int(s.get("seq", 0)))
	_u32(out, int(s.get("ack", 0)) if flags.has("ACK") else 0)
	var bits := 0
	for f: String in flags:
		bits |= TCP_FLAG_BITS.get(f, 0)
	var options := SYN_OPTIONS if flags.has("SYN") else PackedByteArray()
	_u16(out, ((20 + options.size()) / 4) << 12 | bits)
	_u16(out, int(s.get("win", 0)))
	out.append_array([0, 0, 0, 0])
	out.append_array(options)
	out.append_array(str(s.get("data", "")).to_utf8_buffer())
	return _fit(out, size)


## Fills in the checksum at [param at] over the pseudo-header and segment.
static func _transport(p: Dictionary, seg: PackedByteArray, at: int) -> PackedByteArray:
	var pseudo := PackedByteArray()
	_u32(pseudo, int(p.get("src", 0)))
	_u32(pseudo, int(p.get("dst", 0)))
	pseudo.append_array([0, int(p.get("proto", 0))])
	_u16(pseudo, seg.size())
	pseudo.append_array(seg)
	var sum := checksum(pseudo)
	if sum == 0 and at == 6:
		sum = 0xFFFF # UDP sends an all-ones checksum for zero
	seg[at] = sum >> 8
	seg[at + 1] = sum & 255
	return seg


static func dns(m: Dictionary) -> PackedByteArray:
	var out := PackedByteArray()
	_u16(out, int(m.get("id", 0)))
	var bits := (0x8000 if m.get("qr", false) else 0) | (0x400 if m.get("aa", false) else 0) \
		| (0x200 if m.get("tc", false) else 0) | (0x100 if m.get("rd", false) else 0) \
		| (0x80 if m.get("ra", false) else 0) | int(AgoraDns.RCODES.get(m.get("rcode", "NOERROR"), 0))
	_u16(out, bits)
	for section in ["question", "answer", "authority", "additional"]:
		_u16(out, (m.get(section, []) as Array).size())
	for q: Dictionary in m.get("question", []):
		_name(out, q.name)
		_u16(out, AgoraDns.TYPES.get(q.type, 0))
		_u16(out, 1)
	for section in ["answer", "authority", "additional"]:
		for r: Dictionary in m.get(section, []):
			_name(out, r.name)
			_u16(out, AgoraDns.TYPES.get(r.type, 0))
			_u16(out, 1)
			_u32(out, int(r.get("ttl", 0)))
			var rdata := PackedByteArray()
			if r.type == "A":
				_u32(rdata, AgoraInet.parse(r.data))
			else:
				_name(rdata, r.data)
			_u16(out, rdata.size())
			out.append_array(rdata)
	return out


static func dhcp(m: Dictionary) -> PackedByteArray:
	var out := PackedByteArray([int(m.get("op", 1)), 1, 6, 0])
	_u32(out, int(m.get("xid", 0)))
	_u16(out, 0)
	_u16(out, int(m.get("flags", 0)))
	for field in ["ciaddr", "yiaddr", "siaddr", "giaddr"]:
		_u32(out, int(m.get(field, 0)))
	_mac(out, m.get("chaddr", ""))
	out.resize(out.size() + 10 + 64 + 128)
	out.append_array([99, 130, 83, 99])
	var types := ["", "DISCOVER", "OFFER", "REQUEST", "DECLINE", "ACK", "NAK", "RELEASE", "INFORM"]
	out.append_array([53, 1, maxi(0, types.find(m.get("type", "")))])
	out.append(255)
	return out


## The Internet checksum (RFC 1071).
static func checksum(data: PackedByteArray) -> int:
	var sum := 0
	var k := 0
	while k + 1 < data.size():
		sum += (data[k] << 8) | data[k + 1]
		k += 2
	if k < data.size():
		sum += data[k] << 8
	while sum >> 16:
		sum = (sum & 0xFFFF) + (sum >> 16)
	return ~sum & 0xFFFF


static func _fit(data: PackedByteArray, size: int) -> PackedByteArray:
	if data.size() > size:
		return data.slice(0, size)
	data.resize(size) # zero-filled
	return data


static func _u16(out: PackedByteArray, v: int) -> void:
	out.append_array([(v >> 8) & 255, v & 255])


static func _u32(out: PackedByteArray, v: int) -> void:
	out.append_array([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255])


static func _mac(out: PackedByteArray, mac: String) -> void:
	var parts := mac.split(":")
	for k in 6:
		out.append(parts[k].hex_to_int() if parts.size() == 6 else 0)


static func _name(out: PackedByteArray, name: String) -> void:
	for label in AgoraDns.normalize(name).split(".", false):
		var b := label.to_utf8_buffer()
		out.append(b.size())
		out.append_array(b)
	out.append(0)
