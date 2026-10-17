class_name AgoraDhcp
extends RefCounted
## DHCP (RFC 2131) messages, shared by udhcpc and udhcpd. A message is the
## data of a UDP datagram between ports 68 and 67:
##
##   {op, xid, flags, ciaddr, yiaddr, siaddr, giaddr, chaddr, type, options}
##
## "type" is option 53 by name (DISCOVER, OFFER, ...). "options" holds the
## rest by name: subnet, router (array), dns (array), domain, hostname,
## broadcast, lease, server_id, requested, client_id, message.

const SERVER_PORT := 67
const CLIENT_PORT := 68
const BOOTREQUEST := 1
const BOOTREPLY := 2
const BROADCAST_FLAG := 0x8000
## A BOOTP packet is at least 300 bytes.
const SIZE := 300

## Option names udhcpc passes to its script, with their environment names.
const SCRIPT_VARS := {
	"subnet": "subnet", "router": "router", "dns": "dns", "domain": "domain",
	"hostname": "hostname", "broadcast": "broadcast", "lease": "lease", "server_id": "serverid",
	"message": "message", "mtu": "mtu", "ntpsrv": "ntpsrv", "wins": "wins",
}


static func message(op: int, type: String, xid: int, chaddr: String, options: Dictionary = {}) -> Dictionary:
	return {
		"op": op, "xid": xid, "flags": 0, "ciaddr": 0, "yiaddr": 0, "siaddr": 0, "giaddr": 0,
		"chaddr": chaddr, "type": type, "options": options,
	}


static func random_xid() -> int:
	return randi() & 0x7FFFFFFF


## Options that hold addresses (ints, or arrays of ints).
const ADDRESS_OPTIONS: PackedStringArray = ["subnet", "router", "dns", "broadcast", "server_id", "requested", "ntpsrv", "wins"]


## Text for an option value, as udhcpc's script environment has it:
## addresses dotted, lists separated by spaces.
static func option_text(name: String, value: Variant) -> String:
	if value is Array:
		var parts: PackedStringArray = []
		for v: Variant in value:
			parts.append(option_text(name, v))
		return " ".join(parts)
	if value is int and ADDRESS_OPTIONS.has(name):
		return AgoraInet.to_str(value)
	return str(value)


## Is [param msg] a DHCP message (from the right side)?
static func is_valid(msg: Variant, op: int) -> bool:
	return msg is Dictionary and msg.get("op") == op and msg.has("xid") and msg.has("type")
