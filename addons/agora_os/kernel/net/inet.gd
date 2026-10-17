class_name AgoraInet
extends RefCounted
## IPv4 address helpers. Addresses are plain ints (192.168.1.1 is
## 0xC0A80101), so masks and comparisons are ordinary integer math.

const ANY := 0
const BROADCAST := 0xFFFFFFFF


## Parses a dotted quad. Returns -1 if [param text] isn't one.
static func parse(text: String) -> int:
	var parts := text.split(".")
	if parts.size() != 4:
		return -1
	var out := 0
	for part in parts:
		if part.is_empty() or part.length() > 3 or not part.is_valid_int():
			return -1
		var n := int(part)
		if n < 0 or n > 255:
			return -1
		out = (out << 8) | n
	return out


static func to_str(addr: int) -> String:
	return "%d.%d.%d.%d" % [(addr >> 24) & 255, (addr >> 16) & 255, (addr >> 8) & 255, addr & 255]


static func mask(prefix: int) -> int:
	return 0 if prefix <= 0 else (BROADCAST << (32 - prefix)) & BROADCAST


## Prefix length of a netmask like 255.255.255.0, or -1 if the mask has holes.
static func prefix_of_mask(m: int) -> int:
	var prefix := 0
	while prefix < 32 and m & (1 << (31 - prefix)):
		prefix += 1
	return prefix if mask(prefix) == m else -1


static func network(addr: int, prefix: int) -> int:
	return addr & mask(prefix)


static func broadcast_of(addr: int, prefix: int) -> int:
	return network(addr, prefix) | (~mask(prefix) & BROADCAST)


static func in_subnet(addr: int, net: int, prefix: int) -> bool:
	return network(addr, prefix) == network(net, prefix)


## Parses "10.0.0.1/8" or "10.0.0.1" (prefix [param default_prefix]).
## Returns [address, prefix], or [] if malformed.
static func parse_cidr(text: String, default_prefix: int = 32) -> Array:
	var addr_text := text.get_slice("/", 0)
	var prefix := default_prefix
	if text.contains("/"):
		var p := text.get_slice("/", 1)
		if not p.is_valid_int() or int(p) < 0 or int(p) > 32:
			return []
		prefix = int(p)
	var addr := parse(addr_text)
	return [addr, prefix] if addr >= 0 else []


## "192.168.1.0/24", or just the address for a /32.
static func cidr_str(addr: int, prefix: int) -> String:
	return to_str(addr) if prefix == 32 else "%s/%d" % [to_str(addr), prefix]


## The address as /proc/net/route prints it: the 32-bit word in network
## byte order, read on a little-endian CPU (192.168.1.1 -> 0101A8C0).
static func to_le_hex(addr: int) -> String:
	var le := ((addr & 255) << 24) | (((addr >> 8) & 255) << 16) | (((addr >> 16) & 255) << 8) | ((addr >> 24) & 255)
	return "%08X" % le
