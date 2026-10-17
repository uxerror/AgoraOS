class_name AgoraDns
extends RefCounted
## DNS messages (RFC 1035), shared by the resolver, dnsmasq and the lookup
## tools. A message is the data of a UDP datagram to or from port 53:
##
##   {id, qr, opcode, aa, tc, rd, ra, rcode, question: [{name, type}],
##    answer: [{name, type, ttl, data}], authority: [], additional: []}
##
## Names are lowercase without the trailing dot. Record data is a dotted
## address for A, a name for PTR, CNAME and NS.

const PORT := 53
const TYPES := {"A": 1, "NS": 2, "CNAME": 5, "SOA": 6, "PTR": 12, "MX": 15, "TXT": 16, "AAAA": 28, "ANY": 255}
const RCODES := {"NOERROR": 0, "FORMERR": 1, "SERVFAIL": 2, "NXDOMAIN": 3, "NOTIMP": 4, "REFUSED": 5}


static func query(id: int, name: String, type: String, rd: bool = true) -> Dictionary:
	return {
		"id": id, "qr": false, "opcode": "QUERY", "aa": false, "tc": false, "rd": rd, "ra": false,
		"rcode": "NOERROR", "question": [{"name": normalize(name), "type": type}],
		"answer": [], "authority": [], "additional": [],
	}


## A reply to [param q] with [param rcode] and no records yet.
static func reply(q: Dictionary, rcode: String = "NOERROR") -> Dictionary:
	var r: Dictionary = q.duplicate(true)
	r.qr = true
	r.ra = true
	r.rcode = rcode
	r.answer = []
	r.authority = []
	r.additional = []
	return r


static func record(name: String, type: String, ttl: int, data: String) -> Dictionary:
	return {"name": normalize(name), "type": type, "ttl": ttl, "data": data}


static func normalize(name: String) -> String:
	return name.to_lower().trim_suffix(".")


static func random_id() -> int:
	return randi() & 0xFFFF


## "4.3.2.1.in-addr.arpa" for 1.2.3.4.
static func ptr_name(addr: int) -> String:
	return "%d.%d.%d.%d.in-addr.arpa" % [addr & 255, (addr >> 8) & 255, (addr >> 16) & 255, (addr >> 24) & 255]


## The address a PTR name stands for, or -1.
static func ptr_address(name: String) -> int:
	var n := normalize(name)
	if not n.ends_with(".in-addr.arpa"):
		return -1
	var parts := n.trim_suffix(".in-addr.arpa").split(".")
	if parts.size() != 4:
		return -1
	parts.reverse()
	return AgoraInet.parse(".".join(parts))


## Size on the wire, roughly as RFC 1035 encodes it (no name compression).
static func size(msg: Dictionary) -> int:
	var n := 12
	for q: Dictionary in msg.get("question", []):
		n += (q.name as String).length() + 2 + 4
	for section in ["answer", "authority", "additional"]:
		for r: Dictionary in msg.get(section, []):
			n += (r.name as String).length() + 2 + 10
			n += 4 if r.type == "A" else (r.data as String).length() + 2
	return n


static func is_valid(msg: Variant) -> bool:
	return msg is Dictionary and msg.has("id") and msg.has("question") and msg.has("rcode")


## Private address ranges (RFC 1918), for dnsmasq's bogus-priv.
static func is_private(addr: int) -> bool:
	return AgoraInet.in_subnet(addr, 0x0A000000, 8) or AgoraInet.in_subnet(addr, 0xAC100000, 12) \
		or AgoraInet.in_subnet(addr, 0xC0A80000, 16) or AgoraInet.in_subnet(addr, 0x7F000000, 8)
